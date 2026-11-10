import Foundation

/// One of the three things a task can be linked to. A task holds at most one of each.
public enum TaskLink: Hashable, Sendable {
    case pr(Int)
    case linear(String)
    case issue(Int)

    /// Stable key, stored in `TrackedTask.unlinked`.
    public var ref: String {
        switch self {
        case .pr(let n): "pr:\(n)"
        case .linear(let key): "linear:\(key.uppercased())"
        case .issue(let n): "issue:\(n)"
        }
    }

    public var label: String {
        switch self {
        case .pr(let n): "PR #\(n)"
        case .linear(let key): key.uppercased()
        case .issue(let n): "Issue #\(n)"
        }
    }

    /// From `--pr 123`, `--issue 45`, `--linear CMS-1` style input.
    public static func parsePR(_ raw: String) -> TaskLink? { number(raw).map(TaskLink.pr) }
    public static func parseIssue(_ raw: String) -> TaskLink? { number(raw).map(TaskLink.issue) }
    /// A key of a configured team (`CMS-123`), or any `ABC-123` shaped key. Anything else is refused.
    public static func parseLinear(_ raw: String) -> TaskLink? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let key = LinearKey.find(in: text) { return .linear(key) }
        guard text.range(of: #"^[A-Za-z][A-Za-z0-9]{0,9}-\d+$"#, options: .regularExpression) != nil else { return nil }
        return .linear(text.uppercased())
    }

    private static func number(_ raw: String) -> Int? {
        Int(raw.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
    }
}

public extension ParsedLink {
    var taskLink: TaskLink {
        switch self {
        case .githubPR(let n): .pr(n)
        case .githubIssue(let n): .issue(n)
        case .linear(let key): .linear(key)
        }
    }
}

public extension TrackedTask {
    var links: [TaskLink] {
        [prNumber.map(TaskLink.pr), linearKey.map(TaskLink.linear), issueNumber.map(TaskLink.issue)].compactMap { $0 }
    }

    func has(_ link: TaskLink) -> Bool {
        switch link {
        case .pr(let n): prNumber == n
        case .linear(let key): linearKey?.uppercased() == key.uppercased()
        case .issue(let n): issueNumber == n
        }
    }

    /// Removed by the user: syncs must not attach it again.
    func isUnlinked(_ link: TaskLink) -> Bool { unlinked?.contains(link.ref) ?? false }

    /// Drops the link and everything that came with it. The syncs leave it off from now on.
    mutating func unlink(_ link: TaskLink) {
        guard has(link) else { return }
        switch link {
        case .pr:
            prNumber = nil
            prURL = nil
            prAuthor = nil
            ci = nil
            testSteps = nil
            qaState = nil
            qaChangedAt = nil
            lastGitHubStatus = nil
        case .linear:
            linearKey = nil
            linearState = nil
            linearPriority = nil
        case .issue:
            issueNumber = nil
            issueTitle = nil
            issueState = nil
        }
        var list = unlinked ?? []
        if !list.contains(link.ref) { list.append(link.ref) }
        unlinked = list
        updatedAt = .now
    }

    /// Sets the link, replacing one of the same type. `details` (from a lookup) fills what is known right away;
    /// without it the next sync does.
    mutating func attach(_ link: TaskLink, details: LinkPreview? = nil) {
        if let old = links.first(where: { $0.sameType(as: link) }), old != link { unlink(old) }
        unlinked = unlinked?.filter { $0 != link.ref }
        if unlinked?.isEmpty == true { unlinked = nil }
        switch link {
        case .pr(let n):
            prNumber = n
            // Let the next sync apply the status it derives for this PR.
            lastGitHubStatus = nil
            if let d = details, d.prNumber == n {
                prURL = d.prURL
                prAuthor = d.prAuthor
                testSteps = d.testSteps
                branch = branch ?? d.branch
                noteStart(d.startedAt)
            }
        case .linear(let key):
            linearKey = key.uppercased()
            if let d = details, d.linearKey == linearKey {
                linearState = d.linearState
                linearPriority = d.linearPriority
                branch = branch ?? d.branch
                noteStart(d.startedAt)
            }
        case .issue(let n):
            issueNumber = n
            if let d = details, d.issueNumber == n {
                issueTitle = d.issueTitle
                issueState = d.issueState
            }
        }
        if hasPlaceholderTitle, let title = details?.title, !title.isEmpty { self.title = title }
        updatedAt = .now
    }

    /// Takes what `other` knows and this task does not: links, branch, worktree, notes, history.
    mutating func absorb(_ other: TrackedTask) {
        if prNumber == nil, let n = other.prNumber, !isUnlinked(.pr(n)) {
            prNumber = n
            prURL = other.prURL
            prAuthor = other.prAuthor
            ci = other.ci
            testSteps = other.testSteps
            qaState = other.qaState
            qaChangedAt = other.qaChangedAt
            lastGitHubStatus = other.lastGitHubStatus
        }
        if linearKey == nil, let key = other.linearKey, !isUnlinked(.linear(key)) {
            linearKey = key
            linearState = other.linearState
            linearPriority = other.linearPriority
        }
        if issueNumber == nil, let n = other.issueNumber, !isUnlinked(.issue(n)) {
            issueNumber = n
            issueTitle = other.issueTitle
            issueState = other.issueState
        }
        branch = branch ?? other.branch
        worktreePath = worktreePath ?? other.worktreePath
        priorityOverride = priorityOverride ?? other.priorityOverride
        noteStart(other.startedAt ?? other.createdAt)
        if !other.notes.isEmpty { notes += (notes.isEmpty ? "" : "\n") + other.notes }
        history = (history + other.history).sorted { $0.at < $1.at }
        updatedAt = .now
    }
}

public extension TaskLink {
    func sameType(as other: TaskLink) -> Bool {
        switch (self, other) {
        case (.pr, .pr), (.linear, .linear), (.issue, .issue): true
        default: false
        }
    }
}

public extension Array where Element == TrackedTask {
    /// The task, other than `id`, that already holds this link: the one `StoreData.link` merges.
    func owner(of link: TaskLink, excluding id: TrackedTask.ID? = nil) -> TrackedTask? {
        first { $0.id != id && $0.has(link) }
    }
}

public extension StoreData {
    func owner(of link: TaskLink, excluding id: TrackedTask.ID? = nil) -> TrackedTask? {
        tasks.owner(of: link, excluding: id)
    }

    /// Links the task. When another task already holds the link, that task is merged into this one and removed,
    /// so a PR or ticket is never tracked twice. Returns the title of the merged task, if any.
    @discardableResult
    mutating func link(_ link: TaskLink, to id: TrackedTask.ID, details: LinkPreview? = nil) -> String? {
        guard tasks.contains(where: { $0.id == id }) else { return nil }
        var merged: String?
        if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].unlinked = tasks[i].unlinked?.filter { $0 != link.ref } }
        if let other = owner(of: link, excluding: id) {
            tasks.removeAll { $0.id == other.id }
            if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].absorb(other) }
            merged = other.title
        }
        if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].attach(link, details: details) }
        return merged
    }

    mutating func unlink(_ link: TaskLink, from id: TrackedTask.ID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].unlink(link)
    }
}
