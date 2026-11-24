import Foundation

/// Moves a checkout to the latest commits of what it follows: its upstream (like `git pull --ff-only`), else its PR
/// (`refs/pull/<n>/head`, for detached `gh pr checkout`s), else the same branch name on the strapi/strapi remote.
/// Beyond a fast-forward, it follows a branch rewritten on the remote (force-push, commits dropped or reworded) only
/// when every commit of the checkout was on that remote at some point and none of the dropped ones are the user's.
/// Dropping anything else is for the user to confirm.
public enum BranchUpdate {
    /// Where the latest commits come from.
    public struct Source: Equatable, Sendable {
        /// A remote name, a URL, or "." for a local branch.
        public var remote: String
        /// `refs/heads/…` or `refs/pull/<n>/head`.
        public var ref: String
        /// The remote-tracking copy of `ref`, when there is one: its reflog holds the versions fetched so far.
        public var trackingRef: String?
        /// "origin/fix/thing", "#123", "owner:branch".
        public var label: String
    }

    public struct Divergence: Equatable, Sendable {
        public var source: Source
        /// Commits in the checkout that the new version does not have.
        public var commits: Int
        /// How many of them the local git user committed; nil when `user.email` is not set.
        public var mine: Int?
    }

    public enum Outcome: Equatable, Sendable {
        case upToDate(Source)
        case updated(from: String, to: String, Source)
        /// Following the new version would drop commits that may be local work.
        case diverged(Divergence)
        case failed(String)
    }

    /// `replacingLocal` follows the new version even over commits it does not have (once the user confirmed).
    /// Uncommitted changes are always kept: git refuses to move rather than overwrite them.
    public static func run(at path: String, prNumber: Int? = nil, replacingLocal: Bool = false) -> Outcome {
        guard let source = source(at: path, prNumber: prNumber) else {
            return .failed("Nothing to update from: no remote branch or PR for this checkout.")
        }
        guard let head = commit("HEAD", in: path) else { return .failed("Could not read the current commit.") }
        let fetch = Shell.git(["fetch", "--quiet", source.remote, source.ref], in: path)
        guard fetch.status == 0 else { return .failed(fetchError(fetch.stderr, source: source)) }
        guard let latest = commit("FETCH_HEAD", in: path) else { return .failed("Could not read the fetched commit.") }

        if latest == head { return .upToDate(source) }
        let range = "\(latest)..\(head)"
        let diverged = { Outcome.diverged(Divergence(source: source, commits: count(range, in: path), mine: mine(range, in: path))) }
        let move: [String]
        if isAncestor(head, of: latest, in: path) {
            move = ["merge", "--ff-only", "--quiet", latest]
        } else if replacingLocal {
            move = ["reset", "--keep", latest]
        } else if wasOnRemote(head, source: source, in: path) {
            // The remote rewrote or dropped commits it had. A pushed commit of the user's is in that reflog too: never
            // drop it unasked (nor anything when `user.email` is unknown).
            guard mine(range, in: path) == 0 else { return diverged() }
            move = ["reset", "--keep", latest]
        } else if isAncestor(latest, of: head, in: path) {
            // Commits not pushed yet: nothing to pull.
            return .upToDate(source)
        } else {
            return diverged()
        }
        // The checks above hold for the HEAD read before the fetch; a commit made meanwhile was never looked at.
        guard commit("HEAD", in: path) == head else {
            return .failed("The checkout changed during the update. Update again.")
        }
        let moved = Shell.git(move, in: path)
        return moved.status == 0 ? .updated(from: head, to: latest, source) : .failed(moveError(moved.stderr))
    }

    // MARK: Source

    static func source(at path: String, prNumber: Int?) -> Source? {
        let branch = output(["symbolic-ref", "--quiet", "--short", "HEAD"], in: path)
        if let branch,
           let remote = output(["config", "--get", "branch.\(branch).remote"], in: path),
           let merge = output(["config", "--get", "branch.\(branch).merge"], in: path) {
            let tracking = remote == "." ? nil
                : output(["rev-parse", "--symbolic-full-name", "\(branch)@{upstream}"], in: path).flatMap { $0.hasPrefix("refs/remotes/") ? $0 : nil }
            return Source(remote: remote, ref: merge, trackingRef: tracking, label: label(remote: remote, ref: merge, tracking: tracking))
        }
        let remote = remote(for: GitHubSync.repo, in: Shell.git(["remote", "-v"], in: path).stdout) ?? "origin"
        if branch == nil, let prNumber {
            return Source(remote: remote, ref: "refs/pull/\(prNumber)/head", trackingRef: nil, label: "#\(prNumber)")
        }
        if let branch {
            return Source(remote: remote, ref: "refs/heads/\(branch)", trackingRef: "refs/remotes/\(remote)/\(branch)",
                          label: "\(remote)/\(branch)")
        }
        return nil
    }

    static func label(remote: String, ref: String, tracking: String?) -> String {
        if let tracking { return String(tracking.dropFirst("refs/remotes/".count)) }
        if let number = pullNumber(in: ref) { return "#\(number)" }
        let branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        if remote == "." { return branch }
        if let owner = githubOwner(of: remote) { return "\(owner):\(branch)" }
        return "\(remote)/\(branch)"
    }

    /// `refs/pull/123/head` → 123
    static func pullNumber(in ref: String) -> Int? {
        let parts = ref.split(separator: "/")
        guard parts.count == 4, parts[0] == "refs", parts[1] == "pull", parts[3] == "head" else { return nil }
        return Int(parts[2])
    }

    /// `git@github.com:owner/repo.git`, `https://github.com/owner/repo` → owner
    static func githubOwner(of url: String) -> String? {
        guard let range = url.range(of: #"github\.com[:/][^/]+/"#, options: .regularExpression) else { return nil }
        let owner = url[range].dropFirst("github.com/".count).dropLast()
        return owner.isEmpty ? nil : String(owner)
    }

    /// The remote pointing at `owner/repo` on GitHub, from `git remote -v`.
    static func remote(for repo: String, in remotes: String) -> String? {
        for line in remotes.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard fields.count >= 2 else { continue }
            var url = fields[1].lowercased()
            if url.hasSuffix("/") { url.removeLast() }
            if url.hasSuffix(".git") { url.removeLast(4) }
            if url.hasSuffix("github.com/\(repo)") || url.hasSuffix("github.com:\(repo)") { return String(fields[0]) }
        }
        return nil
    }

    // MARK: History

    /// Whether `head` was the remote branch at some point, per its reflog (`git pull --rebase`'s fork point): then the
    /// remote rewrote its own commits and following it loses nothing that only exists here.
    static func wasOnRemote(_ head: String, source: Source, in path: String) -> Bool {
        guard let tracking = source.trackingRef else { return false }
        return output(["merge-base", "--fork-point", tracking, head], in: path) == head
    }

    static func commit(_ rev: String, in path: String) -> String? {
        output(["rev-parse", "--verify", "--quiet", "\(rev)^{commit}"], in: path)
    }

    static func isAncestor(_ a: String, of b: String, in path: String) -> Bool {
        Shell.git(["merge-base", "--is-ancestor", a, b], in: path).status == 0
    }

    static func count(_ range: String, in path: String) -> Int {
        output(["rev-list", "--count", range], in: path).flatMap { Int($0) } ?? 0
    }

    static func mine(_ range: String, in path: String) -> Int? {
        guard let email = output(["config", "--get", "user.email"], in: path)?.lowercased() else { return nil }
        return Shell.git(["log", "--format=%ce", range], in: path).stdout
            .split(separator: "\n").filter { $0.lowercased() == email }.count
    }

    static func output(_ args: [String], in path: String) -> String? {
        let r = Shell.git(args, in: path)
        let text = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !text.isEmpty ? text : nil
    }

    // MARK: Errors

    static func fetchError(_ stderr: String, source: Source) -> String {
        if stderr.contains("couldn't find remote ref") { return "\(source.label) is not on the remote." }
        return "Could not fetch \(source.label): \(firstLine(of: stderr))"
    }

    /// Git refusing to overwrite local changes, in plain words.
    static func moveError(_ stderr: String) -> String {
        guard stderr.contains("would be overwritten") || stderr.contains("not uptodate") else { return firstLine(of: stderr) }
        var files = stderr.split(separator: "\n").filter { $0.hasPrefix("\t") }.map { $0.trimmingCharacters(in: .whitespaces) }
        if files.isEmpty, let entry = stderr.range(of: #"Entry '[^']+'"#, options: .regularExpression) {
            files = [String(stderr[entry].dropFirst("Entry '".count).dropLast())]
        }
        let list = files.prefix(3).joined(separator: ", ") + (files.count > 3 ? "…" : "")
        return (files.isEmpty ? "Local changes" : "Local changes to \(list)")
            + " would be overwritten. Commit, stash or move them, then update again."
    }

    static func firstLine(of stderr: String) -> String {
        let line = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "unknown error"
        for prefix in ["fatal: ", "error: "] where line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
        return line
    }
}
