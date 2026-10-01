import Foundation

public struct PullRequest: Decodable, Sendable {
    public struct Login: Decodable, Sendable { public var login: String? }
    public struct Review: Decodable, Sendable {
        public var author: Login?
        public var state: String
        public var submittedAt: Date?
    }
    struct Nodes<T: Decodable & Sendable>: Decodable, Sendable { var nodes: [T] }
    struct CommitNode: Decodable, Sendable {
        struct Commit: Decodable, Sendable {
            var committedDate: Date
            var statusCheckRollup: Rollup?
        }
        var commit: Commit
    }
    public struct Rollup: Decodable, Sendable {
        struct Context: Decodable, Sendable {
            var name: String?
            var context: String?
            var conclusion: String?
            var status: String?
            var state: String?
        }
        var state: String
        var contexts: Nodes<Context>
    }
    struct Comment: Decodable, Sendable {
        var author: Login?
        var createdAt: Date
    }

    public var number: Int
    public var title: String
    public var url: String
    public var state: String
    public var isDraft: Bool
    public var merged: Bool
    public var headRefName: String
    public var createdAt: Date?
    public var body: String?
    public var isCrossRepository: Bool
    public var author: Login?
    public var reviewDecision: String?
    var commits: Nodes<CommitNode>
    var reviews: Nodes<Review>
    var comments: Nodes<Comment>?
    struct Label: Decodable, Sendable { var name: String }
    var labels: Nodes<Label>?

    public var labelNames: [String] { labels?.nodes.map(\.name) ?? [] }

    public var lastCommitAt: Date? { commits.nodes.last?.commit.committedDate }

    func comments(by me: String) -> [Date] {
        (comments?.nodes ?? []).filter { $0.author?.login == me }.map(\.createdAt)
    }

    func comments(fromOthersThan me: String) -> [Date] {
        (comments?.nodes ?? []).filter { c in
            guard let login = c.author?.login else { return false }
            return login != me && !GitHubSync.isBot(login)
        }.map(\.createdAt)
    }

    /// Latest time I reviewed or commented (conversation comments count: asking for changes in a plain comment is common).
    public func lastActivity(by me: String) -> Date? {
        let reviewed = reviews(by: me).compactMap(\.submittedAt)
        let commented = (comments?.nodes ?? []).filter { $0.author?.login == me }.map(\.createdAt)
        return (reviewed + commented).max()
    }

    /// Filled by `GitHubSync.fetchCI` after the search (too heavy to include in it).
    public var ciRollup: Rollup?

    enum CodingKeys: String, CodingKey {
        case number, title, url, state, isDraft, merged, headRefName, createdAt, body, labels, isCrossRepository, author, reviewDecision, commits, reviews, comments
    }

    public var ci: CIStatus? {
        guard let rollup = ciRollup ?? commits.nodes.last?.commit.statusCheckRollup else { return nil }
        // A check re-run appears several times: one passing run is enough, then running, else failing.
        enum Outcome: Int { case failed = 0, running = 1, passed = 2 }
        var byName: [String: Outcome] = [:]
        var order: [String] = []
        for c in rollup.contexts.nodes {
            let name = c.name ?? c.context ?? "check"
            let result = c.conclusion ?? c.state ?? ""
            let done = c.status == nil || c.status == "COMPLETED"
            let outcome: Outcome
            if !done || result == "PENDING" || result == "EXPECTED" { outcome = .running }
            else if ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(result) { outcome = .failed }
            else { outcome = .passed }
            if byName[name] == nil { order.append(name) }
            if (byName[name]?.rawValue ?? -1) < outcome.rawValue { byName[name] = outcome }
        }
        var failing: [String] = [], pending: [String] = [], expected: [String] = []
        for name in order {
            switch byName[name]! {
            case .failed: if CIStatus.isExpectedRed(name) { expected.append(name) } else { failing.append(name) }
            case .running: pending.append(name)
            case .passed: break
            }
        }
        let state: CIStatus.State = !failing.isEmpty ? .failing : !pending.isEmpty ? .pending : .passing
        return CIStatus(state: state, total: order.count, failing: failing, pending: pending, expected: expected)
    }

    public func humanReviews(excluding me: String) -> [Review] {
        reviews.nodes.filter { r in
            guard let login = r.author?.login, r.state != "PENDING" else { return false }
            return login != me && !GitHubSync.isBot(login)
        }
    }

    public func reviews(by me: String) -> [Review] {
        reviews.nodes.filter { $0.author?.login == me && $0.state != "PENDING" }
    }
}

public enum GitHubSync {
    public static let repo = "strapi/strapi"
    static let bots: Set<String> = ["greptile-apps", "coderabbitai", "copilot-pull-request-reviewer", "github-actions", "vercel",
                                    "changeset-bot", "trunk-io", "codecov", "sonarcloud", "netlify", "linear"]

    static func isBot(_ login: String) -> Bool {
        bots.contains(login) || login.hasSuffix("[bot]") || login.hasSuffix("-bot")
    }

    static let query = """
    query($q: String!) {
      viewer { login }
      search(query: $q, type: ISSUE, first: 50) {
        nodes {
          ... on PullRequest {
            number title url state isDraft merged headRefName isCrossRepository createdAt body
            author { login }
            reviewDecision
            commits(last: 1) { nodes { commit { committedDate } } }
            reviews(last: 30) { nodes { author { login } state submittedAt } }
            comments(last: 20) { nodes { author { login } createdAt } }
            labels(first: 30) { nodes { name } }
          }
        }
      }
    }
    """

    struct Response: Decodable {
        struct DataBody: Decodable {
            struct Viewer: Decodable { var login: String }
            struct Search: Decodable { var nodes: [PullRequest] }
            var viewer: Viewer
            var search: Search
        }
        var data: DataBody
    }

    public enum SyncError: LocalizedError {
        case gh(String)
        public var errorDescription: String? {
            switch self { case .gh(let msg): "GitHub: \(msg)" }
        }
    }

    static func search(_ q: String) throws -> (me: String, prs: [PullRequest]) {
        let result = Shell.run("gh", ["api", "graphql", "-F", "q=\(q)", "-f", "query=\(query)"])
        guard result.status == 0 else {
            throw SyncError.gh(result.stderr.isEmpty ? "gh exited \(result.status)" : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(Response.self, from: Data(result.stdout.utf8))
        return (response.data.viewer.login, response.data.search.nodes)
    }

    public struct Snapshot: Sendable {
        public var me: String
        public var authored: [PullRequest]
        public var requested: [PullRequest]
        public var reviewed: [PullRequest]
    }

    public static func fetch() throws -> Snapshot {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        let month = f.string(from: Date().addingTimeInterval(-30 * 86400))
        let base = "repo:\(repo) is:pr"
        let a = try search("\(base) author:@me updated:>=\(month)")
        let r = try search("\(base) is:open review-requested:@me")
        let v = try search("\(base) reviewed-by:@me -author:@me updated:>=\(month)")
        var snap = Snapshot(me: a.me, authored: a.prs, requested: r.prs, reviewed: v.prs)
        let open = Set((snap.authored + snap.requested + snap.reviewed).filter { $0.state == "OPEN" }.map(\.number))
        let rollups = fetchCI(Array(open))
        func fill(_ prs: inout [PullRequest]) { for i in prs.indices { prs[i].ciRollup = rollups[prs[i].number] } }
        fill(&snap.authored)
        fill(&snap.requested)
        fill(&snap.reviewed)
        return snap
    }

    /// CI rollups for open PRs, 10 per request. A failed batch just leaves those PRs without CI.
    static func fetchCI(_ numbers: [Int]) -> [Int: PullRequest.Rollup] {
        struct Commit: Decodable {
            struct Nodes: Decodable {
                struct Node: Decodable {
                    struct C: Decodable { var statusCheckRollup: PullRequest.Rollup? }
                    var commit: C
                }
                var nodes: [Node]
            }
            var number: Int
            var commits: Nodes
        }
        struct Body: Decodable {
            var repository: [String: Commit?]
        }
        var out: [Int: PullRequest.Rollup] = [:]
        for chunk in stride(from: 0, to: numbers.count, by: 10).map({ Array(numbers.sorted()[$0..<min($0 + 10, numbers.count)]) }) {
            let fields = chunk.map { n in
                "p\(n): pullRequest(number: \(n)) { number commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 100) { nodes { ... on CheckRun { name conclusion status } ... on StatusContext { context state } } } } } } } }"
            }.joined(separator: "\n")
            let query = "query { repository(owner: \"strapi\", name: \"strapi\") { \(fields) } }"
            let r = Shell.run("gh", ["api", "graphql", "-f", "query=\(query)"])
            guard r.status == 0,
                  let env = try? JSONDecoder().decode(GraphQLEnvelope<Body>.self, from: Data(r.stdout.utf8)),
                  let repo = env.data?.repository else { continue }
            for case let pr? in repo.values {
                if let rollup = pr.commits.nodes.last?.commit.statusCheckRollup { out[pr.number] = rollup }
            }
        }
        return out
    }

    // MARK: Status derivation

    public static func status(authored pr: PullRequest, me: String) -> TaskStatus {
        if pr.merged { return .merged }
        if pr.state == "CLOSED" { return .closed }
        if pr.isDraft { return .draftPR }
        if pr.reviewDecision == "APPROVED" { return .approved }

        // Reviewers' latest word: a review or a plain PR comment (bots ignored).
        let feedback = (pr.humanReviews(excluding: me).filter { $0.state == "CHANGES_REQUESTED" || $0.state == "COMMENTED" }.compactMap(\.submittedAt)
            + pr.comments(fromOthersThan: me)).max()
        // My latest word: a comment (e.g. "can you test again?") or a push.
        let myComment = pr.comments(by: me).max()
        let mine = [myComment, pr.lastCommitAt].compactMap { $0 }.max()

        if let feedback {
            if let mine, mine > feedback { return .waitingForReview }
            return .changesRequested
        }
        if pr.reviewDecision == "CHANGES_REQUESTED" { return .changesRequested }
        // Nobody answered yet.
        return .waitingForReview
    }

    public static func status(reviewing pr: PullRequest, me: String, requested: Bool) -> TaskStatus? {
        if pr.merged { return .merged }
        if pr.state == "CLOSED" { return .closed }
        let mine = pr.reviews(by: me).last { $0.state != "DISMISSED" }
        guard let last = pr.lastActivity(by: me) else { return requested ? .toReview : nil }
        // My approval is my latest word: done, unless someone asks me again.
        if let mine, mine.state == "APPROVED", (mine.submittedAt ?? .distantPast) >= last {
            return requested ? .reReview : .approved
        }
        // New commits since I last reviewed or commented: my turn.
        if let commit = pr.lastCommitAt, commit > last { return .reReview }
        // I spoke last. A pending re-request alone does not flip it back: GitHub keeps the request
        // when I answer with a plain comment instead of a review.
        return .waitingOnAuthor
    }

    static func kind(for pr: PullRequest) -> TaskKind {
        // The conventional-commit title is more reliable than the branch prefix.
        for text in [pr.title.lowercased(), pr.headRefName.lowercased()] {
            if text.hasPrefix("feat") { return .feature }
            if text.hasPrefix("fix") { return .fix }
            if text.hasPrefix("chore") || text.hasPrefix("test") || text.hasPrefix("docs") { return .chore }
        }
        return .chore
    }

    // MARK: Merge into store

    /// Applies a snapshot to the store. Returns the number of tasks created or changed.
    @discardableResult
    public static func apply(_ snap: Snapshot, to data: inout StoreData, worktrees: [Worktree]) -> Int {
        var changed = 0
        let requestedNumbers = Set(snap.requested.map(\.number))

        func upsert(_ pr: PullRequest, derived: TaskStatus?, reviewKind: Bool) {
            var index = data.tasks.firstIndex { $0.prNumber == pr.number }
            if index == nil {
                index = data.tasks.firstIndex { $0.prNumber == nil && $0.branch == pr.headRefName && !$0.archived }
            }
            if index == nil {
                // Only open PRs become new tasks; history is not imported.
                guard pr.state == "OPEN", let derived else { return }
                let kind: TaskKind = reviewKind ? (pr.isCrossRepository ? .community : .review) : Self.kind(for: pr)
                var task = TrackedTask(kind: kind, title: pr.title, status: derived, source: "github")
                task.lastGitHubStatus = derived
                data.tasks.append(task)
                index = data.tasks.count - 1
            }
            guard let i = index else { return }
            let before = data.tasks[i]
            var t = before
            t.prNumber = pr.number
            t.prURL = pr.url
            t.noteStart(pr.createdAt)
            t.ci = pr.ci
            t.testSteps = TestSteps.extract(from: pr.body)
            // Labels are the source of truth, except right after a change made in Mirador (the label write may still be in flight).
            if t.qaChangedAt.map({ Date().timeIntervalSince($0) > 120 }) ?? true {
                let fromLabels = QAState.from(labels: pr.labelNames)
                t.qaState = fromLabels == .pending ? nil : fromLabels
            }
            t.prAuthor = pr.author?.login
            t.branch = t.branch ?? pr.headRefName
            t.linearKey = t.linearKey ?? LinearKey.find(in: pr.headRefName) ?? LinearKey.find(in: pr.title)
            if t.worktreePath.map({ !FileManager.default.fileExists(atPath: $0) }) ?? true {
                t.worktreePath = Worktrees.match(t, in: worktrees)?.path
            }
            if let derived, derived != t.lastGitHubStatus {
                t.lastGitHubStatus = derived
                t.setStatus(derived, source: "github")
            }
            if t != before {
                if t.status != before.status || t.prNumber != before.prNumber { t.updatedAt = .now }
                data.tasks[i] = t
                changed += 1
            }
        }

        for pr in snap.authored {
            upsert(pr, derived: status(authored: pr, me: snap.me), reviewKind: false)
        }
        var seen = Set<Int>()
        for pr in snap.requested + snap.reviewed where seen.insert(pr.number).inserted {
            if pr.author?.login == snap.me { continue }
            let derived = status(reviewing: pr, me: snap.me, requested: requestedNumbers.contains(pr.number))
            upsert(pr, derived: derived, reviewKind: true)
        }
        data.lastGitHubSync = .now
        data.githubLogin = snap.me
        return changed
    }
}

public extension GitHubSync {
    /// Puts the PR's QA labels in line with `state`: adds its label, removes the other QA ones.
    static func setQALabel(pr: Int, to state: QAState) -> String? {
        let all = ["qa-done", "qa-skipped", "QA passed"]
        if let label = state.githubLabel {
            let r = Shell.run("gh", ["api", "-X", "POST", "repos/\(repo)/issues/\(pr)/labels", "-f", "labels[]=\(label)"])
            if r.status != 0 { return r.stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        for label in all where label != state.githubLabel {
            let encoded = label.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? label
            let r = Shell.run("gh", ["api", "-X", "DELETE", "repos/\(repo)/issues/\(pr)/labels/\(encoded)"])
            // 404 just means the label was not there.
            if r.status != 0, !r.stderr.contains("404"), !r.stdout.contains("Label does not exist") {
                return r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}
