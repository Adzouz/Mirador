import Foundation

/// Creates a git worktree for a task so it can be quickstarted.
public enum WorktreeCreator {
    public enum CreateError: LocalizedError {
        case exists(String)
        case git(String)

        public var errorDescription: String? {
            switch self {
            case .exists(let p): "\(p) already exists"
            case .git(let m): m
            }
        }
    }

    /// `pr-12345`, `cms-123`, or the branch's last segment.
    public static func folderName(for task: TrackedTask) -> String {
        if let pr = task.prNumber { return "pr-\(pr)" }
        if let key = task.linearKey { return key.lowercased() }
        let slug = (task.branch ?? task.title).split(separator: "/").last.map(String.init) ?? "task"
        let clean = slug.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(String(clean).prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Branch for a task without a PR: its own branch, or `fix/cms-123-title` style.
    public static func branchName(for task: TrackedTask) -> String {
        if let branch = task.branch { return branch }
        let prefix = task.kind == .feature ? "feat" : task.kind == .chore ? "chore" : "fix"
        let words = task.title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let slug = String(words).split(separator: "-").prefix(6).joined(separator: "-")
        return "\(prefix)/" + ([task.linearKey?.lowercased(), slug].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "-"))
    }

    @discardableResult
    static func git(_ args: [String], in dir: String) throws -> String {
        let r = Shell.run("git", ["-C", dir] + args)
        guard r.status == 0 else { throw CreateError.git(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return r.stdout
    }

    /// Returns the new worktree path and its branch.
    public static func create(for task: TrackedTask, settings: AppSettings) throws -> (path: String, branch: String?) {
        let repo = (settings.repoPath as NSString).standardizingPath
        let folder = (settings.worktreesPath as NSString).standardizingPath
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = (folder as NSString).appendingPathComponent(folderName(for: task))
        guard !FileManager.default.fileExists(atPath: path) else { throw CreateError.exists(path) }

        try git(["fetch", "--quiet", "origin", "develop"], in: repo)

        if let pr = task.prNumber {
            // gh handles forks and names the branch like the PR head.
            try git(["worktree", "add", "--detach", path, "origin/develop"], in: repo)
            let r = Shell.run("gh", ["pr", "checkout", String(pr), "--repo", GitHubSync.repo], cwd: path)
            guard r.status == 0 else {
                _ = try? git(["worktree", "remove", "--force", path], in: repo)
                throw CreateError.git(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return (path, Worktrees.currentBranch(at: path))
        }

        let branch = branchName(for: task)
        let hasLocal = Shell.run("git", ["-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]).status == 0
        if hasLocal {
            try git(["worktree", "add", path, branch], in: repo)
        } else if Shell.run("git", ["-C", repo, "fetch", "--quiet", "origin", branch]).status == 0 {
            try git(["worktree", "add", "--track", "-b", branch, path, "origin/\(branch)"], in: repo)
        } else {
            try git(["worktree", "add", "--no-track", "-b", branch, path, "origin/develop"], in: repo)
        }
        return (path, branch)
    }
}

/// Pulls the "How to test it?" section out of a PR description.
public enum TestSteps {
    static let headings = ["how to test", "steps to reproduce", "testing", "test plan", "how to reproduce"]

    public static func extract(from body: String?) -> String? {
        guard var body, !body.isEmpty else { return nil }
        body = body.replacingOccurrences(of: "\r\n", with: "\n")
        body = body.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        let lines = body.components(separatedBy: .newlines)
        func headingText(_ line: String) -> String? {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("#") else { return nil }
            return t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard let start = lines.firstIndex(where: { line in
            headingText(line).map { h in headings.contains { h.hasPrefix($0) } } ?? false
        }) else { return nil }
        var section: [String] = []
        for line in lines[(start + 1)...] {
            if headingText(line) != nil { break }
            section.append(line)
        }
        // Drop the shared indentation (bodies pasted from terminals are often indented).
        let indent = section.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
        let text = section.map { String($0.dropFirst(min(indent, $0.prefix(while: { $0 == " " }).count))) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholder = "provide information about the environment and the path to verify the behaviour."
        return text.isEmpty || text.lowercased() == placeholder ? nil : text
    }
}
