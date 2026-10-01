import Foundation

public enum TaskKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case feature, fix, chore, review, community

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .feature: "Feature"
        case .fix: "Fix"
        case .chore: "Chore"
        case .review: "Review"
        case .community: "Community PR"
        }
    }

    public var symbol: String {
        switch self {
        case .feature: "sparkles"
        case .fix: "ladybug"
        case .chore: "wrench.and.screwdriver"
        case .review: "eye"
        case .community: "person.2"
        }
    }

    public var isReview: Bool { self == .review || self == .community }

    public var flow: [TaskStatus] {
        switch self {
        case .feature, .fix, .chore:
            [.todo, .inProgress, .doneLocally, .draftPR, .waitingForReview, .changesRequested, .addressing, .approved, .merged, .released]
        case .review:
            [.toReview, .reviewing, .waitingOnAuthor, .reReview, .approved, .merged]
        case .community:
            [.toReview, .reviewing, .waitingOnAuthor, .takenOver, .reReview, .approved, .merged, .released]
        }
    }

    public var startStatus: TaskStatus { isReview ? .reviewing : .inProgress }
}

public struct CIStatus: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable { case passing, failing, pending }

    /// Checks that are red by design (the QA gate); shown, but never make CI "failing".
    public static let expectedRed: Set<String> = ["check-pr-status"]

    /// `(observation)` jobs are informational (e.g. `lint_oxlint (observation)`).
    public static func isExpectedRed(_ name: String) -> Bool {
        expectedRed.contains(name) || name.hasSuffix("(observation)")
    }

    public var state: State
    public var total: Int
    public var failing: [String]
    public var pending: [String]
    public var expected: [String]

    public init(state: State, total: Int, failing: [String], pending: [String], expected: [String]) {
        self.state = state
        self.total = total
        self.failing = failing
        self.pending = pending
        self.expected = expected
    }

    public var summary: String {
        switch state {
        case .passing: "CI passing"
        case .failing: failing.count == 1 ? "CI failing · \(failing[0])" : "CI failing · \(failing.count) checks"
        case .pending: "CI running · \(pending.count) left"
        }
    }
}

public enum QAState: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending, done, skipped

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .pending: "QA pending"
        case .done: "QA done"
        case .skipped: "QA skipped"
        }
    }

    /// GitHub label for this state (pending has none).
    public var githubLabel: String? {
        switch self {
        case .pending: nil
        case .done: "qa-done"
        case .skipped: "qa-skipped"
        }
    }

    /// Reads a PR's labels. `QA passed` is the older name of `qa-done`.
    public static func from(labels: [String]) -> QAState {
        let set = Set(labels.map { $0.lowercased() })
        if set.contains("qa-done") || set.contains("qa passed") { return .done }
        if set.contains("qa-skipped") { return .skipped }
        return .pending
    }
}

public enum Priority: Int, CaseIterable, Identifiable, Sendable {
    case none = 0, urgent = 1, high = 2, medium = 3, low = 4

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .none: "No priority"
        case .urgent: "Urgent"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

    /// Sort key: urgent first, none last.
    public var rank: Int { self == .none ? 5 : rawValue }
}

public enum TaskStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case todo
    case inProgress = "in-progress"
    case doneLocally = "done-locally"
    case draftPR = "draft-pr"
    case inReview = "in-review"
    case changesRequested = "changes-requested"
    case addressing
    case reReview = "re-review"
    /// My PR: I answered or pushed after the latest feedback; the reviewers' turn.
    case waitingForReview = "waiting-for-review"
    case approved
    case merged
    case released
    case toReview = "to-review"
    case reviewing
    case waitingOnAuthor = "waiting-on-author"
    case takenOver = "taken-over"
    case blocked
    case closed

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .todo: "To do"
        case .inProgress: "In progress"
        case .doneLocally: "Done locally"
        case .draftPR: "Draft PR"
        case .inReview: "Waiting for review (old)"
        case .changesRequested: "Changes requested"
        case .addressing: "Addressing review"
        case .reReview: "Re-review"
        case .waitingForReview: "Waiting for review"
        case .approved: "Approved"
        case .merged: "Merged"
        case .released: "Released"
        case .toReview: "To review"
        case .reviewing: "Reviewing"
        case .waitingOnAuthor: "Waiting on author"
        case .takenOver: "Taken over"
        case .blocked: "Blocked"
        case .closed: "Closed"
        }
    }

    public var isFinished: Bool { self == .merged || self == .released || self == .closed }

    /// Sort order for "by status": what needs action first, finished last.
    public var rank: Int {
        let order: [TaskStatus] = [
            .changesRequested, .addressing, .toReview, .reReview, .reviewing, .takenOver, .blocked,
            .inProgress, .todo, .doneLocally, .draftPR, .inReview, .waitingForReview, .waitingOnAuthor, .approved,
            .merged, .released, .closed,
        ]
        return order.firstIndex(of: self) ?? order.count
    }
}

public struct StatusChange: Codable, Hashable, Sendable {
    public var status: TaskStatus
    public var at: Date
    public var source: String

    public init(status: TaskStatus, at: Date = .now, source: String) {
        self.status = status
        self.at = at
        self.source = source
    }
}

public struct TrackedTask: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: TaskKind
    public var title: String
    public var status: TaskStatus
    public var prNumber: Int?
    public var prURL: String?
    public var prAuthor: String?
    public var branch: String?
    public var linearKey: String?
    /// Ticket state name from Linear ("In Progress", "In Review"…).
    public var linearState: String?
    public var worktreePath: String?
    public var notes: String
    public var archived: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// When the work began: PR opened, Linear ticket started, or branch checked out — the earliest known.
    public var startedAt: Date?
    /// Linear convention: 1 urgent, 2 high, 3 medium, 4 low, 0/nil none.
    public var linearPriority: Int?
    public var priorityOverride: Int?
    public var ci: CIStatus?
    /// "How to test it?" from the PR description.
    public var testSteps: String?
    /// QA mark; unset means pending for any task with a PR. Mirrors the `qa-done` / `qa-skipped` PR labels.
    public var qaState: QAState?
    /// When the mark was last changed in Mirador; label pulls wait a bit so they do not undo it.
    public var qaChangedAt: Date?

    /// Nil for tasks without a PR, where QA does not apply.
    public var qa: QAState? { prNumber == nil ? nil : (qaState ?? .pending) }
    /// Last status GitHub derived. GitHub only overrides `status` when this value changes,
    /// so a status set by hand or by Claude survives until something actually happens on the PR.
    public var lastGitHubStatus: TaskStatus?
    public var history: [StatusChange]

    public init(kind: TaskKind, title: String, status: TaskStatus? = nil, source: String) {
        let initial = status ?? kind.flow[0]
        self.id = UUID()
        self.kind = kind
        self.title = title
        self.status = initial
        self.notes = ""
        self.archived = false
        self.createdAt = .now
        self.updatedAt = .now
        self.history = [StatusChange(status: initial, source: source)]
    }

    public var startDate: Date { startedAt ?? createdAt }

    public var priority: Priority { Priority(rawValue: priorityOverride ?? linearPriority ?? 0) ?? .none }

    public mutating func noteStart(_ date: Date?) {
        guard let date else { return }
        startedAt = min(startedAt ?? date, date)
    }

    public mutating func setStatus(_ new: TaskStatus, source: String) {
        guard new != status else { return }
        status = new
        updatedAt = .now
        history.append(StatusChange(status: new, source: source))
    }

    /// Mine when I authored the PR, or when there is no PR author and it is not a review.
    public func isMine(me: String?) -> Bool {
        if let author = prAuthor { return author == me }
        return !kind.isReview
    }

    /// Whether the ball is in my court.
    public var needsMe: Bool {
        switch status {
        case .todo, .inProgress, .doneLocally, .changesRequested, .addressing, .toReview, .reviewing, .takenOver: true
        case .reReview: kind.isReview
        default: false
        }
    }

    public var linearURL: URL? {
        linearKey.flatMap { URL(string: "https://linear.app/\(LinearKey.workspace)/issue/\($0.uppercased())") }
    }

    public var githubURL: URL? {
        if let prURL { return URL(string: prURL) }
        return prNumber.flatMap { URL(string: "https://github.com/strapi/strapi/pull/\($0)") }
    }
}

public struct RunningEnvironment: Codable, Hashable, Sendable {
    public var worktreePath: String
    public var processGroups: [Int32]
    public var startedAt: Date
    public var port: Int?

    public init(worktreePath: String, processGroups: [Int32], port: Int, startedAt: Date = .now) {
        self.worktreePath = worktreePath
        self.processGroups = processGroups
        self.port = port
        self.startedAt = startedAt
    }
}

public struct Ping: Codable, Hashable, Identifiable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case reviewRequested = "review-requested"
        case mention
        case linearMention = "linear-mention"
        case linearAssigned = "linear-assigned"
        case ciFailed = "ci-failed"
        case linearAuth = "linear-auth"
        case reReviewNeeded = "re-review-needed"
    }

    public var id: String
    public var reason: Reason
    public var title: String
    public var url: String
    public var prNumber: Int?
    public var at: Date
    public var read: Bool
    /// Who triggered it (PR author asking for a review, etc.).
    public var actor: String?

    public init(id: String, reason: Reason, title: String, url: String, prNumber: Int?, at: Date = .now, actor: String? = nil) {
        self.id = id
        self.reason = reason
        self.title = title
        self.url = url
        self.prNumber = prNumber
        self.at = at
        self.read = false
        self.actor = actor
    }

    public var headline: String {
        switch reason {
        case .reviewRequested: (actor.map { "@\($0) asked a review from you" } ?? "Review requested") + (prNumber.map { " · #\($0)" } ?? "")
        case .reReviewNeeded: (actor.map { "@\($0) updated it — your turn to review again" } ?? "Ready for re-review") + (prNumber.map { " · #\($0)" } ?? "")
        case .mention: (actor.map { "@\($0) mentioned you" } ?? "You were mentioned") + (prNumber.map { " · #\($0)" } ?? "")
        case .linearMention: "Mentioned in Linear"
        case .linearAssigned: "Assigned to you in Linear"
        case .ciFailed: "CI failing" + (prNumber.map { " · #\($0)" } ?? "")
        case .linearAuth: "Linear key not working"
        }
    }
}

/// Paths shared by the app and the CLI.
public struct AppSettings: Codable, Hashable, Sendable {
    public static let home = NSHomeDirectory()
    public var repoPath: String = AppSettings.detectedRepo
    public var worktreesPath: String = ((AppSettings.detectedRepo as NSString).deletingLastPathComponent as NSString)
        .appendingPathComponent("strapi-worktrees")
    /// Linear workspace slug (linear.app/<slug>) and the team keys used in branch names (`fix/cms-123-…`).
    public var linearWorkspace: String = "strapi"
    public var linearTeamKeys: String = "CMS"
    /// Strapi app started by Quickstart, relative to the repo / worktree root.
    public var appDirectory: String = "examples/getstarted"
    /// The monorepo and one worktree can run side by side (before / after a fix), each on its own port.
    public var monorepoPort: Int = 1338
    public var worktreePort: Int = 1339
    /// Super admin created on a fresh app's first start. The password lives in the Keychain.
    public var autoCreateAdmin: Bool = false
    public var adminEmail: String = ""
    public var adminFirstname: String = ""
    public var adminLastname: String = ""

    public init() {}

    enum CodingKeys: String, CodingKey {
        case repoPath, worktreesPath, appDirectory, monorepoPort, worktreePort
        case autoCreateAdmin, adminEmail, adminFirstname, adminLastname, linearWorkspace, linearTeamKeys
    }

    /// First strapi/strapi clone found in the usual places, so a new install works without setup.
    public static let detectedRepo: String = {
        let names = ["strapi", "Strapi/strapi"]
        let parents = ["", "code", "Code", "dev", "Dev", "Developer", "Projects", "projects", "Sites", "src", "workspace", "git", "github", "repos"]
        for parent in parents {
            for name in names {
                let path = ([home, parent, name].filter { !$0.isEmpty } as [NSString]).map(String.init).joined(separator: "/")
                if let config = try? String(contentsOfFile: path + "/.git/config", encoding: .utf8), config.contains("strapi/strapi") {
                    return path
                }
            }
        }
        return "\(home)/strapi"
    }()

    public var teamKeys: [String] {
        linearTeamKeys.split(whereSeparator: { $0 == "," || $0 == " " }).map { $0.uppercased() }.filter { !$0.isEmpty }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        repoPath = try c.decodeIfPresent(String.self, forKey: .repoPath) ?? d.repoPath
        worktreesPath = try c.decodeIfPresent(String.self, forKey: .worktreesPath) ?? d.worktreesPath
        appDirectory = try c.decodeIfPresent(String.self, forKey: .appDirectory) ?? d.appDirectory
        monorepoPort = try c.decodeIfPresent(Int.self, forKey: .monorepoPort) ?? d.monorepoPort
        worktreePort = try c.decodeIfPresent(Int.self, forKey: .worktreePort) ?? d.worktreePort
        autoCreateAdmin = try c.decodeIfPresent(Bool.self, forKey: .autoCreateAdmin) ?? d.autoCreateAdmin
        adminEmail = try c.decodeIfPresent(String.self, forKey: .adminEmail) ?? d.adminEmail
        adminFirstname = try c.decodeIfPresent(String.self, forKey: .adminFirstname) ?? d.adminFirstname
        adminLastname = try c.decodeIfPresent(String.self, forKey: .adminLastname) ?? d.adminLastname
        linearWorkspace = try c.decodeIfPresent(String.self, forKey: .linearWorkspace) ?? d.linearWorkspace
        linearTeamKeys = try c.decodeIfPresent(String.self, forKey: .linearTeamKeys) ?? d.linearTeamKeys
    }

    public func isMonorepo(_ path: String) -> Bool {
        (path as NSString).standardizingPath == (repoPath as NSString).standardizingPath
    }

    public func port(for path: String) -> Int { isMonorepo(path) ? monorepoPort : worktreePort }
}

public struct StoreData: Codable, Sendable {
    public var tasks: [TrackedTask] = []
    /// At most one monorepo and one worktree environment.
    public var runningEnvironments: [RunningEnvironment] = []
    public var lastGitHubSync: Date?
    public var pings: [Ping] = []
    /// PRs in `review-requested:@me` at the last sync; a PR entering this set is a new request.
    public var requestedPRs: [Int]?
    /// Notification thread id → last `updated_at` seen.
    public var seenThreads: [String: String]?
    public var seenLinearNotifications: [String]?
    /// Branches already seen checked out in a worktree; a new one means work just started.
    public var seenBranches: [String]?
    public var lastLinearSync: Date?
    public var githubLogin: String?
    /// Comments already pinged as mentions, so a thread coming back unread does not ping the same comment twice.
    public var pingedComments: [String]?
    public var settings = AppSettings()
    /// Set when Linear rejected the saved key; cleared on the next successful sync.
    public var linearAuthFailed: Bool?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case tasks, runningEnvironments, lastGitHubSync, pings, requestedPRs, seenThreads
        case seenLinearNotifications, seenBranches, lastLinearSync, githubLogin, settings, linearAuthFailed, pingedComments
    }

    enum LegacyKeys: String, CodingKey { case runningEnvironment }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decodeIfPresent([TrackedTask].self, forKey: .tasks) ?? []
        runningEnvironments = try c.decodeIfPresent([RunningEnvironment].self, forKey: .runningEnvironments) ?? []
        // Stores written before two slots existed hold a single environment.
        if runningEnvironments.isEmpty,
           let legacy = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(RunningEnvironment.self, forKey: .runningEnvironment) {
            runningEnvironments = [legacy]
        }
        lastGitHubSync = try c.decodeIfPresent(Date.self, forKey: .lastGitHubSync)
        pings = try c.decodeIfPresent([Ping].self, forKey: .pings) ?? []
        requestedPRs = try c.decodeIfPresent([Int].self, forKey: .requestedPRs)
        seenThreads = try c.decodeIfPresent([String: String].self, forKey: .seenThreads)
        seenLinearNotifications = try c.decodeIfPresent([String].self, forKey: .seenLinearNotifications)
        seenBranches = try c.decodeIfPresent([String].self, forKey: .seenBranches)
        lastLinearSync = try c.decodeIfPresent(Date.self, forKey: .lastLinearSync)
        githubLogin = try c.decodeIfPresent(String.self, forKey: .githubLogin)
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        linearAuthFailed = try c.decodeIfPresent(Bool.self, forKey: .linearAuthFailed)
        pingedComments = try c.decodeIfPresent([String].self, forKey: .pingedComments)
    }
}

public enum LinearKey {
    /// Team keys and workspace from Settings, applied whenever the store is read.
    nonisolated(unsafe) public static var prefixes = ["CMS"]
    nonisolated(unsafe) public static var workspace = "strapi"

    public static func configure(_ settings: AppSettings) {
        let keys = settings.teamKeys
        prefixes = keys.isEmpty ? ["CMS"] : keys
        workspace = settings.linearWorkspace.isEmpty ? "strapi" : settings.linearWorkspace
    }

    /// Finds a `CMS-1234` style key (for any configured team) in a branch name, title or body.
    public static func find(in text: String?, prefixes: [String] = LinearKey.prefixes) -> String? {
        guard let text, !prefixes.isEmpty else { return nil }
        let alternatives = prefixes.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        guard let range = text.range(of: "(?i)\\b(\(alternatives))-\\d+\\b", options: .regularExpression) else { return nil }
        return text[range].uppercased()
    }
}
