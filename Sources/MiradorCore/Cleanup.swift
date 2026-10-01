import Foundation

/// Finds local branches and worktrees that are no longer needed, and removes the ones explicitly picked.
/// Git is always called through /usr/bin/git so output is never rewritten by shell wrappers.
public enum Cleanup {
    public enum BranchState: String, Sendable, CaseIterable {
        case merged, closed, gone, localOnly, active

        public var label: String {
            switch self {
            case .merged: "PR merged"
            case .closed: "PR closed"
            case .gone: "Remote deleted"
            case .localOnly: "Local only"
            case .active: "Active"
            }
        }

        /// Safe to suggest for deletion.
        public var isStale: Bool { self == .merged || self == .closed || self == .gone }
    }

    public struct Branch: Identifiable, Hashable, Sendable {
        public var name: String
        public var upstream: String?
        public var lastCommit: Date
        public var worktreePath: String?
        public var state: BranchState
        public var prNumber: Int?
        public var protectedReason: String?
        /// Why a branch with a merged/closed PR is still kept active.
        public var note: String?

        public var id: String { name }
        public var canDelete: Bool { protectedReason == nil }
    }

    public struct WorktreeInfo: Identifiable, Hashable, Sendable {
        public var path: String
        public var branch: String?
        public var branchState: BranchState?
        public var prNumber: Int?
        public var dirtyFiles: Int
        public var lastActivity: Date?
        public var protectedReason: String?

        public var id: String { path }
        public var name: String { (path as NSString).lastPathComponent }
        public var canRemove: Bool { protectedReason == nil }
    }

    public struct Report: Sendable {
        public var branches: [Branch]
        public var worktrees: [WorktreeInfo]
        public var scannedAt: Date
    }

    static let git = "/usr/bin/git"

    static func run(_ args: [String], in dir: String) -> Shell.Result {
        Shell.run(git, ["-C", dir] + args)
    }

    public static func isProtectedName(_ name: String) -> Bool {
        ["develop", "main", "master"].contains(name) || name.hasPrefix("releases/") || name.hasPrefix("release/")
    }

    // MARK: Scan

    public static func scan(settings: AppSettings, running: [String]) -> Report {
        let repo = (settings.repoPath as NSString).standardizingPath
        _ = run(["fetch", "--prune", "--quiet", "origin"], in: repo)

        let format = "%(refname:short)%09%(upstream:short)%09%(upstream:track)%09%(committerdate:unix)%09%(worktreepath)"
        let raw = run(["for-each-ref", "--format=\(format)", "refs/heads"], in: repo).stdout
        var branches: [Branch] = []
        for line in raw.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, !f[0].isEmpty else { continue }
            let upstream = f[1].isEmpty ? nil : f[1]
            let gone = f[2].contains("gone")
            branches.append(Branch(
                name: f[0], upstream: upstream,
                lastCommit: Date(timeIntervalSince1970: TimeInterval(f[3]) ?? 0),
                worktreePath: f[4].isEmpty ? nil : f[4],
                state: gone ? .gone : (upstream == nil ? .localOnly : .active)
            ))
        }

        // Squash merges are invisible to git, so ask GitHub which PR each branch belongs to.
        let prs = pullRequestStates(for: branches.map(\.name))
        for i in branches.indices {
            if let pr = prs[branches[i].name] {
                branches[i].prNumber = pr.number
                switch pr.state {
                case "MERGED": branches[i].state = .merged
                case "CLOSED": branches[i].state = .closed
                default: if branches[i].state != .gone { branches[i].state = .active }
                }
                // Work continued after the PR ended: not stale.
                if let ended = pr.endedAt, branches[i].state == .merged || branches[i].state == .closed,
                   branches[i].lastCommit > ended.addingTimeInterval(60) {
                    branches[i].state = .active
                    branches[i].note = "New commits after #\(pr.number) was \(pr.state.lowercased())"
                }
            }
            if isProtectedName(branches[i].name) { branches[i].state = .active }
            branches[i].protectedReason = protection(for: branches[i])
        }

        let worktrees = Worktrees.list(settings: settings).filter { !$0.isMain }.map { wt -> WorktreeInfo in
            let branch = wt.branch.flatMap { name in branches.first { $0.name == name } }
            let dirty = run(["status", "--porcelain"], in: wt.path).stdout.split(separator: "\n").count
            var info = WorktreeInfo(
                path: wt.path, branch: wt.branch, branchState: branch?.state, prNumber: branch?.prNumber ?? wt.prNumberFromName,
                dirtyFiles: dirty, lastActivity: LocalWork.lastCheckout(wt.path)
            )
            if running.contains(wt.path) { info.protectedReason = "Environment running" }
            return info
        }

        return Report(branches: branches.sorted { $0.lastCommit > $1.lastCommit }, worktrees: worktrees, scannedAt: .now)
    }

    static func protection(for b: Branch) -> String? {
        if isProtectedName(b.name) { return "Protected branch" }
        if let wt = b.worktreePath { return "Checked out in \((wt as NSString).lastPathComponent)" }
        return nil
    }

    struct PRState { var number: Int; var state: String; var endedAt: Date? }

    /// Latest PR per head branch name, 40 branches per GraphQL request.
    static func pullRequestStates(for names: [String]) -> [String: PRState] {
        struct Node: Decodable { var number: Int; var state: String; var mergedAt: Date?; var closedAt: Date? }
        struct Conn: Decodable { var nodes: [Node] }
        struct Body: Decodable { var repository: [String: Conn?] }
        var out: [String: PRState] = [:]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let unique = Array(Set(names)).sorted()
        for start in stride(from: 0, to: unique.count, by: 40) {
            let chunk = Array(unique[start..<min(start + 40, unique.count)])
            let fields = chunk.enumerated().map { i, name in
                let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                return "b\(i): pullRequests(headRefName: \"\(escaped)\", first: 1, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { number state mergedAt closedAt } }"
            }.joined(separator: "\n")
            let query = "query { repository(owner: \"strapi\", name: \"strapi\") { \(fields) } }"
            let r = Shell.run("gh", ["api", "graphql", "-f", "query=\(query)"])
            guard r.status == 0,
                  let env = try? decoder.decode(GraphQLEnvelope<Body>.self, from: Data(r.stdout.utf8)),
                  let repo = env.data?.repository else { continue }
            for (i, name) in chunk.enumerated() {
                if let node = repo["b\(i)"]??.nodes.first {
                    out[name] = PRState(number: node.number, state: node.state, endedAt: node.mergedAt ?? node.closedAt)
                }
            }
        }
        return out
    }

    // MARK: Delete (explicit names only, each re-checked)

    /// Per-item progress, so the UI can show what is being removed right now.
    public enum Progress: Sendable {
        case started(String)
        case finished(String, error: String?)
    }
    public typealias ProgressHandler = @Sendable (Progress) -> Void

    public struct Outcome: Sendable {
        public var removed: [String] = []
        public var failed: [(String, String)] = []
    }

    public static func deleteBranches(_ names: [String], settings: AppSettings, progress: ProgressHandler? = nil) -> Outcome {
        let repo = (settings.repoPath as NSString).standardizingPath
        var outcome = Outcome()
        // Fresh state right before deleting: never trust a stale scan.
        let checkedOut = Set(run(["for-each-ref", "--format=%(refname:short)%09%(worktreepath)", "refs/heads"], in: repo).stdout
            .split(separator: "\n")
            .compactMap { line -> String? in
                let f = line.split(separator: "\t", omittingEmptySubsequences: false)
                return f.count == 2 && !f[1].isEmpty ? String(f[0]) : nil
            })
        for name in names {
            progress?(.started(name))
            let error: String?
            if isProtectedName(name) { error = "protected" }
            else if checkedOut.contains(name) { error = "checked out in a worktree" }
            else {
                let r = run(["branch", "-D", "--", name], in: repo)
                error = r.status == 0 ? nil : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let error { outcome.failed.append((name, error)) } else { outcome.removed.append(name) }
            progress?(.finished(name, error: error))
        }
        return outcome
    }

    public static func removeWorktrees(_ paths: [String], force: Bool, alsoDeleteBranch: Bool, settings: AppSettings, running: [String],
                                       progress: ProgressHandler? = nil) -> Outcome {
        let repo = (settings.repoPath as NSString).standardizingPath
        var outcome = Outcome()
        let known = Worktrees.list(settings: settings)
        let real = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        for path in paths {
            progress?(.started(path))
            let fail = { (reason: String) in
                outcome.failed.append((path, reason))
                progress?(.finished(path, error: reason))
            }
            guard let wt = known.first(where: { real($0.path) == real(path) }), !wt.isMain else { fail("not a worktree"); continue }
            if running.contains(where: { real($0) == real(path) }) { fail("environment running"); continue }
            let r = run(["worktree", "remove"] + (force ? ["--force"] : []) + ["--", wt.path], in: repo)
            guard r.status == 0 else { fail(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)); continue }
            outcome.removed.append(path)
            if alsoDeleteBranch, let branch = wt.branch, !isProtectedName(branch) {
                _ = run(["branch", "-D", "--", branch], in: repo)
            }
            progress?(.finished(path, error: nil))
        }
        _ = run(["worktree", "prune"], in: repo)
        return outcome
    }
}
