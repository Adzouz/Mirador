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
        /// Checked-out commit; a detached worktree's PR is found from it.
        public var head: String
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
        /// False for the instant local pass: PR states are not known yet (or carried over from the previous scan).
        public var remoteChecked = false

        public init(branches: [Branch], worktrees: [WorktreeInfo], scannedAt: Date = .now, remoteChecked: Bool = false) {
            self.branches = branches
            self.worktrees = worktrees
            self.scannedAt = scannedAt
            self.remoteChecked = remoteChecked
        }

        /// Shows the last known PR states on a fresh local pass while the remote check runs, so rows do not flicker.
        public func carryingRemoteState(from old: Report?) -> Report {
            guard let old, old.remoteChecked else { return self }
            var r = self
            let branches = Dictionary(old.branches.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            for i in r.branches.indices {
                guard let o = branches[r.branches[i].name], o.lastCommit == r.branches[i].lastCommit else { continue }
                if r.branches[i].state != .gone { r.branches[i].state = o.state }
                r.branches[i].prNumber = o.prNumber
                r.branches[i].note = o.note
            }
            let worktrees = Dictionary(old.worktrees.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            for i in r.worktrees.indices {
                guard let o = worktrees[r.worktrees[i].path], o.head == r.worktrees[i].head else { continue }
                r.worktrees[i].branchState = o.branchState
                r.worktrees[i].prNumber = o.prNumber ?? r.worktrees[i].prNumber
            }
            return r
        }
    }

    static let git = "/usr/bin/git"

    static func run(_ args: [String], in dir: String) -> Shell.Result {
        Shell.run(git, ["-C", dir] + args)
    }

    public static func isProtectedName(_ name: String) -> Bool {
        ["develop", "main", "master"].contains(name) || name.hasPrefix("releases/") || name.hasPrefix("release/")
    }

    // MARK: Scan

    /// Full scan: fetch + prune, then ask GitHub. Slow (network); `scanLocal` gives the list first.
    public static func scan(settings: AppSettings, running: [String]) -> Report {
        let repo = (settings.repoPath as NSString).standardizingPath
        _ = run(["fetch", "--prune", "--quiet", "origin"], in: repo)
        var report = scanLocal(settings: settings, running: running)
        // Squash merges are invisible to git, so ask GitHub which PR each branch (or detached HEAD) belongs to.
        let byBranch = pullRequestStates(for: report.branches.map(\.name))
        let detachedHeads = report.worktrees.filter { $0.branch == nil && !$0.head.isEmpty }.map(\.head)
        let byCommit = pullRequestStates(forCommits: detachedHeads)
        let unresolved = report.worktrees.filter { wt in
            if let name = wt.branch { return byBranch[name] == nil }
            return byCommit[wt.head] == nil
        }.compactMap(\.prNumber)
        let byNumber = pullRequestStates(forNumbers: unresolved)
        applyRemote(byBranch: byBranch, byCommit: byCommit, byNumber: byNumber, to: &report)
        return report
    }

    /// Branches and worktrees from disk only (no network): what git knew at the last fetch.
    public static func scanLocal(settings: AppSettings, running: [String]) -> Report {
        let repo = (settings.repoPath as NSString).standardizingPath
        let format = "%(refname:short)%09%(upstream:short)%09%(upstream:track)%09%(committerdate:unix)%09%(worktreepath)"
        let raw = run(["for-each-ref", "--format=\(format)", "refs/heads"], in: repo).stdout
        var branches: [Branch] = []
        for line in raw.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, !f[0].isEmpty else { continue }
            let upstream = f[1].isEmpty ? nil : f[1]
            let gone = f[2].contains("gone")
            var branch = Branch(
                name: f[0], upstream: upstream,
                lastCommit: Date(timeIntervalSince1970: TimeInterval(f[3]) ?? 0),
                worktreePath: f[4].isEmpty ? nil : f[4],
                state: gone ? .gone : (upstream == nil ? .localOnly : .active)
            )
            if isProtectedName(branch.name) { branch.state = .active }
            branch.protectedReason = protection(for: branch)
            branches.append(branch)
        }

        let list = Worktrees.list(settings: settings).filter { !$0.isMain }
        // `git status` in a monorepo checkout takes a while: check them all at once.
        var dirty = [Int](repeating: 0, count: list.count)
        dirty.withUnsafeMutableBufferPointer { buffer in
            let out = buffer
            DispatchQueue.concurrentPerform(iterations: list.count) { i in
                out[i] = run(["status", "--porcelain"], in: list[i].path).stdout.split(separator: "\n").count
            }
        }
        let worktrees = list.enumerated().map { i, wt -> WorktreeInfo in
            let branch = wt.branch.flatMap { name in branches.first { $0.name == name } }
            var info = WorktreeInfo(
                path: wt.path, branch: wt.branch, head: wt.head, branchState: branch?.state,
                prNumber: branch?.prNumber ?? wt.prNumberFromName,
                dirtyFiles: dirty[i], lastActivity: LocalWork.lastCheckout(wt.path)
            )
            if running.contains(wt.path) { info.protectedReason = "Environment running" }
            return info
        }
        return Report(branches: branches.sorted { $0.lastCommit > $1.lastCommit }, worktrees: worktrees)
    }

    static func state(of pr: PRState) -> BranchState {
        switch pr.state {
        case "MERGED": .merged
        case "CLOSED": .closed
        default: .active
        }
    }

    /// Merges GitHub's answers into a local pass. Pure, so the rules are testable without the network.
    static func applyRemote(byBranch: [String: PRState], byCommit: [String: PRState], byNumber: [Int: PRState] = [:],
                            to report: inout Report) {
        for i in report.branches.indices {
            guard let pr = byBranch[report.branches[i].name] else { continue }
            report.branches[i].prNumber = pr.number
            let derived = state(of: pr)
            if derived != .active || report.branches[i].state != .gone { report.branches[i].state = derived }
            // Work continued after the PR ended: not stale.
            if let ended = pr.endedAt, derived != .active, report.branches[i].lastCommit > ended.addingTimeInterval(60) {
                report.branches[i].state = .active
                report.branches[i].note = "New commits after #\(pr.number) was \(pr.state.lowercased())"
            }
            if isProtectedName(report.branches[i].name) { report.branches[i].state = .active }
        }
        for i in report.worktrees.indices {
            if let name = report.worktrees[i].branch {
                let branch = report.branches.first { $0.name == name }
                if branch?.prNumber == nil, let pr = report.worktrees[i].prNumber.flatMap({ byNumber[$0] }) {
                    // A local name like `pr-12345` matches no PR head: use the number in the folder name.
                    report.worktrees[i].branchState = state(of: pr)
                } else {
                    report.worktrees[i].branchState = branch?.state
                    report.worktrees[i].prNumber = branch?.prNumber ?? report.worktrees[i].prNumber
                }
            } else if let pr = byCommit[report.worktrees[i].head] ?? report.worktrees[i].prNumber.flatMap({ byNumber[$0] }) {
                // Detached (`gh pr checkout` of a fork, or its branch deleted): the PR whose commits it sits on, else the
                // `pr-<number>` in the folder name. The commit wins: a folder can be reused for another PR.
                report.worktrees[i].branchState = state(of: pr)
                report.worktrees[i].prNumber = pr.number
            }
        }
        report.scannedAt = .now
        report.remoteChecked = true
    }

    static func protection(for b: Branch) -> String? {
        if isProtectedName(b.name) { return "Protected branch" }
        if let wt = b.worktreePath { return "Checked out in \((wt as NSString).lastPathComponent)" }
        return nil
    }

    struct PRState { var number: Int; var state: String; var endedAt: Date? }

    struct CommitPR: Decodable { var number: Int; var state: String; var mergedAt: Date?; var closedAt: Date?; var headRefOid: String? }

    /// The PR a detached HEAD was checked out from: one whose head commit is HEAD. Any commit already on develop is
    /// also "associated" with the merged PR that brought it there, which says nothing about this worktree.
    static func pullRequest(at sha: String, among nodes: [CommitPR]) -> PRState? {
        guard let node = nodes.first(where: { $0.headRefOid?.lowercased() == sha.lowercased() }) else { return nil }
        return PRState(number: node.number, state: node.state, endedAt: node.mergedAt ?? node.closedAt)
    }

    static func pullRequestStates(forNumbers numbers: [Int]) -> [Int: PRState] {
        struct Node: Decodable { var number: Int; var state: String; var mergedAt: Date?; var closedAt: Date? }
        struct Body: Decodable { var repository: [String: Node?] }
        var out: [Int: PRState] = [:]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let unique = Array(Set(numbers)).sorted()
        for start in stride(from: 0, to: unique.count, by: 40) {
            let chunk = Array(unique[start..<min(start + 40, unique.count)])
            let fields = chunk.map { "n\($0): pullRequest(number: \($0)) { number state mergedAt closedAt }" }.joined(separator: "\n")
            let query = "query { repository(owner: \"strapi\", name: \"strapi\") { \(fields) } }"
            let r = Shell.run("gh", ["api", "graphql", "-f", "query=\(query)"])
            guard let env = try? decoder.decode(GraphQLEnvelope<Body>.self, from: Data(r.stdout.utf8)),
                  let repo = env.data?.repository else { continue }
            for n in chunk {
                if let node = repo["n\(n)"] ?? nil {
                    out[n] = PRState(number: node.number, state: node.state, endedAt: node.mergedAt ?? node.closedAt)
                }
            }
        }
        return out
    }

    /// Latest PR containing each commit (detached worktrees), 40 commits per GraphQL request.
    static func pullRequestStates(forCommits shas: [String]) -> [String: PRState] {
        struct Conn: Decodable { var nodes: [CommitPR] }
        struct Commit: Decodable { var associatedPullRequests: Conn? }
        struct Body: Decodable { var repository: [String: Commit?] }
        var out: [String: PRState] = [:]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let unique = Array(Set(shas.filter { $0.allSatisfy(\.isHexDigit) })).sorted()
        for start in stride(from: 0, to: unique.count, by: 40) {
            let chunk = Array(unique[start..<min(start + 40, unique.count)])
            let fields = chunk.enumerated().map { i, sha in
                "c\(i): object(oid: \"\(sha)\") { ... on Commit { associatedPullRequests(first: 10, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { number state mergedAt closedAt headRefOid } } } }"
            }.joined(separator: "\n")
            let query = "query { repository(owner: \"strapi\", name: \"strapi\") { \(fields) } }"
            let r = Shell.run("gh", ["api", "graphql", "-f", "query=\(query)"])
            guard let env = try? decoder.decode(GraphQLEnvelope<Body>.self, from: Data(r.stdout.utf8)),
                  let repo = env.data?.repository else { continue }
            for (i, sha) in chunk.enumerated() {
                if let pr = pullRequest(at: sha, among: repo["c\(i)"]??.associatedPullRequests?.nodes ?? []) { out[sha] = pr }
            }
        }
        return out
    }

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
