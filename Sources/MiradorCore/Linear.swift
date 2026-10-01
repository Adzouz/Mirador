import Foundation
import Security

public enum Keychain {
    static let service = AppIdentity.bundleID

    public static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func write(_ account: String, _ value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

public struct LinearIssue: Decodable, Sendable {
    public struct State: Decodable, Sendable {
        public var name: String
        public var type: String
    }
    struct Named: Decodable, Sendable { var name: String }
    struct URLNode: Decodable, Sendable { var url: String }
    struct Nodes<T: Decodable & Sendable>: Decodable, Sendable { var nodes: [T] }

    public var identifier: String
    public var title: String
    public var url: String
    public var branchName: String?
    public var state: State
    public var updatedAt: Date
    public var createdAt: Date?
    public var startedAt: Date?
    public var priority: Int?
    var labels: Nodes<Named>?
    var attachments: Nodes<URLNode>?

    public var labelNames: [String] { labels?.nodes.map(\.name) ?? [] }

    /// A GitHub PR attached to the ticket, if any.
    public var prNumber: Int? {
        attachments?.nodes.lazy.compactMap { LinkParser.parse($0.url)?.prNumber }.first
    }

    public var kind: TaskKind {
        let names = labelNames.map { $0.lowercased() }
        if names.contains(where: { $0.contains("bug") || $0.contains("fix") }) { return .fix }
        if names.contains(where: { $0.contains("feature") || $0.contains("improvement") }) { return .feature }
        return .fix
    }
}

public struct LinearNotification: Decodable, Sendable {
    public struct Issue: Decodable, Sendable {
        public var identifier: String
        public var title: String
        public var url: String
    }
    public struct Comment: Decodable, Sendable {
        public var body: String?
        public var url: String?
    }
    public var id: String
    public var type: String
    public var createdAt: Date
    public var readAt: Date?
    public var issue: Issue?
    public var comment: Comment?
}

struct GraphQLEnvelope<T: Decodable>: Decodable {
    struct GQLError: Decodable { var message: String }
    var data: T?
    var errors: [GQLError]?
}

public enum LinearAPI {
    public static let keyAccount = "linear-api-key"

    public static var apiKey: String? { Keychain.read(keyAccount) }

    public enum LinearError: LocalizedError {
        case noKey
        case unauthorized
        case http(String)
        public var errorDescription: String? {
            switch self {
            case .noKey: "Linear: no API key"
            case .unauthorized: "Linear: API key not working — add a new one in Settings"
            case .http(let m): "Linear: \(m)"
            }
        }
    }

    static let issueFields = """
    identifier title url branchName updatedAt createdAt startedAt priority
    state { name type }
    labels { nodes { name } }
    attachments { nodes { url } }
    """

    static func request<T: Decodable>(_ query: String, variables: [String: Any] = [:], key: String, as: T.Type, allowPartial: Bool = false) throws -> T {
        var req = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        req.timeoutInterval = 20

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<Data, Error> = .failure(LinearError.http("no response"))
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { result = .failure(error) }
            else if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                result = .failure(LinearError.unauthorized)
            } else if let http = response as? HTTPURLResponse, http.statusCode >= 400,
                      !(String(data: data ?? Data(), encoding: .utf8) ?? "").contains("\"errors\"") {
                result = .failure(LinearError.http("HTTP \(http.statusCode)"))
            } else { result = .success(data ?? Data()) }
            semaphore.signal()
        }.resume()
        semaphore.wait()

        let data = try result.get()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "bad date \(s)"))
        }
        let env = try decoder.decode(GraphQLEnvelope<T>.self, from: data)
        if let message = env.errors?.first?.message, !(allowPartial && env.data != nil) {
            let lower = message.lowercased()
            if lower.contains("authentication") || lower.contains("api key") || lower.contains("unauthorized") { throw LinearError.unauthorized }
            throw LinearError.http(message)
        }
        guard let body = env.data else { throw LinearError.http("empty response") }
        return body
    }

    public struct Snapshot: Sendable {
        public var viewerName: String
        public var assigned: [LinearIssue]
        public var notifications: [LinearNotification]
    }

    public static func fetch(key: String) throws -> Snapshot {
        struct Body: Decodable {
            struct Viewer: Decodable {
                var name: String
                var assignedIssues: LinearIssue.Nodes<LinearIssue>
            }
            var viewer: Viewer
            var notifications: LinearIssue.Nodes<LinearNotification>
        }
        let query = """
        query {
          viewer {
            name
            assignedIssues(first: 50, filter: { state: { type: { in: ["started", "unstarted"] } } }, orderBy: updatedAt) {
              nodes { \(issueFields) }
            }
          }
          notifications(first: 40) {
            nodes {
              id type createdAt readAt
              ... on IssueNotification {
                issue { identifier title url }
                comment { body url }
              }
            }
          }
        }
        """
        let body = try request(query, key: key, as: Body.self)
        return Snapshot(viewerName: body.viewer.name, assigned: body.viewer.assignedIssues.nodes, notifications: body.notifications.nodes)
    }

    /// Fetches several tickets in one request (aliased fields). Unknown keys are skipped.
    public static func issues(_ identifiers: [String], key: String) throws -> [LinearIssue] {
        let keys = Array(Set(identifiers)).sorted().prefix(50)
        guard !keys.isEmpty else { return [] }
        let fields = keys.enumerated().map { i, k in "i\(i): issue(id: \"\(k)\") { \(issueFields) }" }.joined(separator: "\n")
        let body = try request("query {\n\(fields)\n}", key: key, as: [String: LinearIssue?].self, allowPartial: true)
        return body.values.compactMap { $0 }
    }

    /// Refreshes state, priority and start date of every tracked ticket, not only assigned ones.
    public static func refresh(_ issues: [LinearIssue], in data: inout StoreData) {
        for issue in issues {
            for i in data.tasks.indices where data.tasks[i].linearKey == issue.identifier {
                data.tasks[i].linearState = issue.state.name
                data.tasks[i].linearPriority = issue.priority
                data.tasks[i].noteStart(issue.startedAt ?? issue.createdAt)
            }
        }
    }

    public static func issue(_ identifier: String, key: String) throws -> LinearIssue {
        struct Body: Decodable { var issue: LinearIssue }
        return try request("query($id: String!) { issue(id: $id) { \(issueFields) } }", variables: ["id": identifier], key: key, as: Body.self).issue
    }

    // MARK: Merge into store

    static func isMention(_ type: String) -> Bool { type.lowercased().contains("mention") }
    static func isAssignment(_ type: String) -> Bool { type == "issueAssignedToYou" }

    /// Creates tasks for started tickets and recently assigned ones, refreshes ticket info,
    /// and returns new pings (mentions, assignments). The first run only primes the seen set.
    @discardableResult
    public static func apply(_ snap: Snapshot, to data: inout StoreData, worktrees: [Worktree]) -> [Ping] {
        let recent = Date().addingTimeInterval(-7 * 86400)
        for issue in snap.assigned {
            let index = data.tasks.firstIndex { $0.linearKey == issue.identifier }
                ?? issue.prNumber.flatMap { pr in data.tasks.firstIndex { $0.prNumber == pr } }
            if let i = index {
                var t = data.tasks[i]
                t.linearKey = issue.identifier
                t.linearState = issue.state.name
                t.prNumber = t.prNumber ?? issue.prNumber
                t.noteStart(issue.startedAt ?? issue.createdAt)
                t.linearPriority = issue.priority
                if issue.state.type == "started", t.status == .todo { t.setStatus(.inProgress, source: "linear") }
                if t.worktreePath == nil { t.worktreePath = Worktrees.match(t, in: worktrees)?.path }
                data.tasks[i] = t
                continue
            }
            let started = issue.state.type == "started"
            guard started || issue.updatedAt > recent else { continue }
            var t = TrackedTask(kind: issue.kind, title: issue.title, status: started ? .inProgress : .todo, source: "linear")
            t.linearKey = issue.identifier
            t.linearState = issue.state.name
            t.prNumber = issue.prNumber
            t.noteStart(issue.startedAt ?? issue.createdAt)
            t.linearPriority = issue.priority
            t.branch = issue.branchName
            t.worktreePath = Worktrees.match(t, in: worktrees)?.path
            data.tasks.append(t)
        }

        var new: [Ping] = []
        let primed = data.seenLinearNotifications != nil
        var seenList = data.seenLinearNotifications ?? []
        var seen = Set(seenList)
        for n in snap.notifications.reversed() where !seen.contains(n.id) {
            seen.insert(n.id)
            seenList.append(n.id)
            guard primed, n.readAt == nil, let issue = n.issue else { continue }
            if isMention(n.type) {
                new.append(Ping(id: "l-\(n.id)", reason: .linearMention, title: "\(issue.identifier) · \(issue.title)", url: n.comment?.url ?? issue.url, prNumber: nil, at: n.createdAt))
            } else if isAssignment(n.type) {
                new.append(Ping(id: "l-\(n.id)", reason: .linearAssigned, title: "\(issue.identifier) · \(issue.title)", url: issue.url, prNumber: nil, at: n.createdAt))
            }
        }
        data.seenLinearNotifications = Array(seenList.suffix(300))
        data.pings = Array((new + data.pings).prefix(40))
        return new
    }
}
