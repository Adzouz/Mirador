import Foundation

public enum ParsedLink: Equatable, Sendable {
    case githubPR(Int)
    case linear(String)

    public var prNumber: Int? {
        if case .githubPR(let n) = self { return n }
        return nil
    }
}

public enum LinkParser {
    /// Accepts a GitHub PR URL, a Linear issue URL, `#123`, or `CMS-123`.
    public static func parse(_ raw: String) -> ParsedLink? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 500 else { return nil }
        if let n = capture(#"github\.com/strapi/strapi/pull/(\d+)"#, in: text).flatMap(Int.init) {
            return .githubPR(n)
        }
        if text.contains("linear.app"), let key = LinearKey.find(in: text) {
            return .linear(key)
        }
        if let n = capture(#"^#?(\d{3,6})$"#, in: text).flatMap(Int.init) {
            return .githubPR(n)
        }
        if let key = LinearKey.find(in: text), text.count <= 12 {
            return .linear(key)
        }
        return nil
    }

    static func capture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}

/// What a pasted link resolves to, before it becomes a task.
public struct LinkPreview: Sendable {
    public var link: ParsedLink
    public var title: String
    public var kind: TaskKind
    public var status: TaskStatus
    public var prNumber: Int?
    public var prURL: String?
    public var prAuthor: String?
    public var branch: String?
    public var linearKey: String?
    public var linearState: String?
    public var startedAt: Date?
    public var linearPriority: Int?
    public var testSteps: String?
    public var subtitle: String

    /// Fetches details from GitHub (`gh`) or Linear. Throws with a readable message.
    public static func resolve(_ link: ParsedLink, linearKey apiKey: String?) throws -> LinkPreview {
        switch link {
        case .githubPR(let n):
            let fields = "number,title,url,state,isDraft,headRefName,author,isCrossRepository,reviewDecision,createdAt,body"
            let r = Shell.run("gh", ["pr", "view", String(n), "--repo", GitHubSync.repo, "--json", fields])
            guard r.status == 0 else { throw LinearAPI.LinearError.http(r.stderr.isEmpty ? "PR #\(n) not found" : r.stderr) }
            struct PR: Decodable {
                struct Author: Decodable { var login: String }
                var number: Int
                var title: String
                var url: String
                var state: String
                var isDraft: Bool
                var headRefName: String
                var author: Author
                var isCrossRepository: Bool
                var reviewDecision: String?
                var createdAt: Date?
                var body: String?
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let pr = try decoder.decode(PR.self, from: Data(r.stdout.utf8))
            let me = Shell.run("gh", ["api", "user", "--jq", ".login"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let mine = pr.author.login == me
            let kind: TaskKind = mine
                ? (pr.title.lowercased().hasPrefix("feat") ? .feature : pr.title.lowercased().hasPrefix("fix") ? .fix : .chore)
                : (pr.isCrossRepository ? .community : .review)
            let status: TaskStatus = mine
                ? (pr.state == "MERGED" ? .merged : pr.isDraft ? .draftPR : pr.reviewDecision == "APPROVED" ? .approved : .waitingForReview)
                : (pr.state == "MERGED" ? .merged : .toReview)
            var preview = LinkPreview(
                link: link, title: pr.title, kind: kind, status: status,
                prNumber: pr.number, prURL: pr.url, prAuthor: pr.author.login, branch: pr.headRefName,
                linearKey: LinearKey.find(in: pr.headRefName) ?? LinearKey.find(in: pr.title),
                linearState: nil,
                subtitle: "#\(pr.number) · @\(pr.author.login) · \(pr.state.lowercased())"
            )
            preview.startedAt = pr.createdAt
            preview.testSteps = TestSteps.extract(from: pr.body)
            return preview
        case .linear(let key):
            guard let apiKey else {
                return LinkPreview(link: link, title: key, kind: .fix, status: .todo, linearKey: key, subtitle: "Linear ticket (connect Linear for details)")
            }
            let issue = try LinearAPI.issue(key, key: apiKey)
            var preview = LinkPreview(
                link: link, title: issue.title, kind: issue.kind,
                status: issue.state.type == "started" ? .inProgress : .todo,
                prNumber: issue.prNumber, branch: issue.branchName, linearKey: issue.identifier,
                linearState: issue.state.name,
                subtitle: "\(issue.identifier) · \(issue.state.name)"
            )
            preview.startedAt = issue.startedAt ?? issue.createdAt
            preview.linearPriority = issue.priority
            return preview
        }
    }

    init(link: ParsedLink, title: String, kind: TaskKind, status: TaskStatus, prNumber: Int? = nil, prURL: String? = nil,
         prAuthor: String? = nil, branch: String? = nil, linearKey: String? = nil, linearState: String? = nil, subtitle: String) {
        self.link = link
        self.title = title
        self.kind = kind
        self.status = status
        self.prNumber = prNumber
        self.prURL = prURL
        self.prAuthor = prAuthor
        self.branch = branch
        self.linearKey = linearKey
        self.linearState = linearState
        self.subtitle = subtitle
    }

    /// Adds the task, or returns the index of the one already tracking this link.
    public func insert(into data: inout StoreData, worktrees: [Worktree]) -> Int {
        if let i = data.tasks.firstIndex(where: { (prNumber != nil && $0.prNumber == prNumber) || (linearKey != nil && $0.linearKey == linearKey) }) {
            data.tasks[i].archived = false
            data.tasks[i].noteStart(startedAt)
            return i
        }
        var t = TrackedTask(kind: kind, title: title, status: status, source: "manual")
        t.prNumber = prNumber
        t.prURL = prURL
        t.prAuthor = prAuthor
        t.branch = branch
        t.linearKey = linearKey
        t.linearState = linearState
        t.noteStart(startedAt)
        t.linearPriority = linearPriority
        t.testSteps = testSteps
        t.worktreePath = Worktrees.match(t, in: worktrees)?.path
        data.tasks.append(t)
        return data.tasks.count - 1
    }
}
