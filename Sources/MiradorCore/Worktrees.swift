import Foundation

public struct Worktree: Identifiable, Hashable, Sendable {
    public var path: String
    public var branch: String?
    public var head: String
    public var isMain: Bool

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    /// `pr-12345` style folder names point at a PR number.
    public var prNumberFromName: Int? {
        guard name.hasPrefix("pr-") else { return nil }
        return Int(name.dropFirst(3))
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("node_modules/.yarn-state.yml"))
    }
}

public enum Worktrees {
    public static let defaultRepo = AppSettings().repoPath

    /// Worktrees git knows about, plus any checkout sitting in the worktrees folder.
    public static func list(settings: AppSettings = AppSettings()) -> [Worktree] {
        let repo = (settings.repoPath as NSString).standardizingPath
        let result = Shell.run("git", ["-C", repo, "worktree", "list", "--porcelain"])
        var items = result.status == 0 ? parse(result.stdout) : []
        for i in items.indices { items[i].isMain = items[i].path == repo }
        let known = Set(items.map(\.path))
        let folder = (settings.worktreesPath as NSString).standardizingPath
        let children = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        for name in children.sorted() {
            let path = (folder as NSString).appendingPathComponent(name)
            guard !known.contains(path),
                  FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) else { continue }
            let head = Shell.run("git", ["-C", path, "rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(Worktree(path: path, branch: currentBranch(at: path), head: head, isMain: false))
        }
        return items
    }

    static func parse(_ porcelain: String) -> [Worktree] {
        var items: [Worktree] = []
        for block in porcelain.components(separatedBy: "\n\n") {
            var path: String?, branch: String?, head = ""
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)) }
                if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
            }
            if let path, !block.contains("\nprunable") {
                items.append(Worktree(path: path, branch: branch, head: head, isMain: items.isEmpty))
            }
        }
        return items
    }

    /// Best worktree for a task: same branch first, then a `pr-<number>` folder.
    public static func match(_ task: TrackedTask, in worktrees: [Worktree]) -> Worktree? {
        if let branch = task.branch, let wt = worktrees.first(where: { $0.branch == branch }) { return wt }
        if let pr = task.prNumber, let wt = worktrees.first(where: { $0.prNumberFromName == pr }) { return wt }
        if let key = task.linearKey {
            if let wt = worktrees.first(where: { LinearKey.find(in: $0.branch) == key }) { return wt }
            if let wt = worktrees.first(where: { LinearKey.find(in: $0.name) == key }) { return wt }
        }
        return nil
    }

    public static func currentBranch(at path: String) -> String? {
        let r = Shell.run("git", ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"])
        let branch = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && branch != "HEAD" && !branch.isEmpty ? branch : nil
    }

    public static func topLevel(at path: String) -> String? {
        let r = Shell.run("git", ["-C", path, "rev-parse", "--show-toplevel"])
        let top = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !top.isEmpty ? top : nil
    }
}

/// Turns "a branch was just checked out in a worktree" into a task.
public enum LocalWork {
    static let ignored: Set<String> = ["develop", "main", "master"]

    static func isWorkBranch(_ branch: String) -> Bool {
        !ignored.contains(branch) && !branch.hasPrefix("release/") && !branch.hasPrefix("releases/")
    }

    static func lastCheckout(_ path: String) -> Date? {
        let r = Shell.run("git", ["-C", path, "log", "-g", "-1", "--format=%ct"])
        return TimeInterval(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).map(Date.init(timeIntervalSince1970:))
    }

    /// Branch → last checkout/commit time, for every worktree on a work branch.
    public static func activity(in worktrees: [Worktree]) -> [String: Date] {
        var out: [String: Date] = [:]
        for wt in worktrees {
            guard let branch = wt.branch, isWorkBranch(branch) else { continue }
            out[branch] = lastCheckout(wt.path) ?? .distantPast
        }
        return out
    }

    /// Creates an in-progress task for each newly checked-out work branch. On the first run only
    /// branches touched in the last two days count, so old worktrees do not flood the list.
    @discardableResult
    public static func apply(worktrees: [Worktree], activity: [String: Date], to data: inout StoreData) -> Int {
        let primed = data.seenBranches != nil
        var seen = Set(data.seenBranches ?? [])
        let cutoff = Date().addingTimeInterval(-2 * 86400)
        var created = 0
        for wt in worktrees {
            guard let branch = wt.branch, isWorkBranch(branch), !seen.contains(branch) else { continue }
            seen.insert(branch)
            // Review checkouts (pr-123) are covered by the GitHub sync.
            guard wt.prNumberFromName == nil else { continue }
            guard primed || (activity[branch] ?? .distantPast) > cutoff else { continue }
            let key = LinearKey.find(in: branch)
            let exists = data.tasks.contains { t in
                t.branch == branch || t.worktreePath == wt.path && !t.status.isFinished || (key != nil && t.linearKey == key && !t.status.isFinished)
            }
            if exists {
                if let i = data.tasks.firstIndex(where: { key != nil && $0.linearKey == key && $0.branch == nil }) {
                    data.tasks[i].branch = branch
                    data.tasks[i].worktreePath = data.tasks[i].worktreePath ?? wt.path
                }
                continue
            }
            let kind: TaskKind = branch.hasPrefix("feat") ? .feature : branch.hasPrefix("fix") || branch.hasPrefix("hotfix") ? .fix : .chore
            var t = TrackedTask(kind: kind, title: title(from: branch), status: .inProgress, source: "local")
            t.branch = branch
            t.linearKey = key
            t.worktreePath = wt.path
            t.noteStart(activity[branch].flatMap { $0 == .distantPast ? nil : $0 })
            data.tasks.append(t)
            created += 1
        }
        data.seenBranches = Array(seen)
        return created
    }

    /// `fix/cms-123-content-manager-upload-progress` → `Content manager upload progress`
    static func title(from branch: String) -> String {
        var slug = String(branch.split(separator: "/").last ?? Substring(branch))
        if let range = slug.range(of: #"^(?i)cms-\d+-?"#, options: .regularExpression) { slug.removeSubrange(range) }
        let words = slug.split(separator: "-").joined(separator: " ")
        return words.isEmpty ? branch : words.prefix(1).uppercased() + words.dropFirst()
    }
}
