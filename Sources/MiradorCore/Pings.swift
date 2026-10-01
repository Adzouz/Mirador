import Foundation

/// Detects new review requests (from the sync snapshot) and new mentions (from GitHub notifications).
public enum Pings {
    struct Notification: Decodable {
        struct Subject: Decodable {
            var title: String
            var url: String?
            var latest_comment_url: String?
        }
        var id: String
        var reason: String
        var updated_at: String
        var subject: Subject
    }

    struct Comment: Decodable {
        struct User: Decodable { var login: String }
        var body: String?
        var html_url: String?
        var user: User?
    }

    static func fetchNotifications() -> [Notification] {
        let r = Shell.run("gh", ["api", "notifications?participating=true&per_page=50"])
        guard r.status == 0 else { return [] }
        return (try? JSONDecoder().decode([Notification].self, from: Data(r.stdout.utf8))) ?? []
    }

    static func fetchComment(_ apiURL: String) -> Comment? {
        let r = Shell.run("gh", ["api", apiURL])
        guard r.status == 0 else { return nil }
        return try? JSONDecoder().decode(Comment.self, from: Data(r.stdout.utf8))
    }

    /// `https://api.github.com/repos/o/r/pulls/1` → `https://github.com/o/r/pull/1`
    static func htmlURL(fromAPI url: String?) -> String? {
        guard let url else { return nil }
        return url
            .replacingOccurrences(of: "https://api.github.com/repos/", with: "https://github.com/")
            .replacingOccurrences(of: "/pulls/", with: "/pull/")
    }

    static func number(in url: String?) -> Int? {
        url.flatMap { $0.split(separator: "/").last.flatMap { Int($0) } }
    }

    public struct Inputs: Sendable {
        var notifications: [Notification]
        var comments: [String: Comment]
        var previousCI: [Int: CIStatus] = [:]
        /// Status GitHub derived for each PR at the previous sync.
        var previousStatus: [Int: TaskStatus] = [:]
    }

    /// Network part, done outside the store lock. Only fetches comment bodies for threads that changed.
    public static func fetch(previous data: StoreData) -> Inputs {
        var inputs = fetch(previouslySeen: data.seenThreads)
        for t in data.tasks {
            guard let pr = t.prNumber else { continue }
            if let ci = t.ci { inputs.previousCI[pr] = ci }
            if let status = t.lastGitHubStatus { inputs.previousStatus[pr] = status }
        }
        return inputs
    }

    public static func fetch(previouslySeen: [String: String]?) -> Inputs {
        let notes = fetchNotifications()
        var comments: [String: Comment] = [:]
        if previouslySeen != nil {
            for n in notes where isMention(n.reason) && previouslySeen?[n.id] != n.updated_at {
                if let url = n.subject.latest_comment_url, let c = fetchComment(url) { comments[n.id] = c }
            }
        }
        return Inputs(notifications: notes, comments: comments)
    }

    static func isMention(_ reason: String) -> Bool { reason == "mention" || reason == "team_mention" }

    /// Returns only the new pings and records them in the store. The very first run only primes state.
    @discardableResult
    public static func apply(snapshot: GitHubSync.Snapshot, inputs: Inputs, to data: inout StoreData) -> [Ping] {
        var new: [Ping] = []

        let requested = snapshot.requested.map(\.number)
        if let previous = data.requestedPRs {
            for pr in snapshot.requested where !previous.contains(pr.number) {
                new.append(Ping(id: "rr-\(pr.number)-\(Int(Date().timeIntervalSince1970))", reason: .reviewRequested,
                                title: pr.title, url: pr.url, prNumber: pr.number, actor: pr.author?.login))
            }
        }

        // A PR I review goes back to "my turn" (new commits, or asked again after I commented).
        let requestedSet = Set(requested)
        var seenPR = Set<Int>()
        for pr in snapshot.requested + snapshot.reviewed where seenPR.insert(pr.number).inserted && pr.author?.login != snapshot.me {
            guard let before = inputs.previousStatus[pr.number], before != .reReview, before != .toReview else { continue }
            guard GitHubSync.status(reviewing: pr, me: snapshot.me, requested: requestedSet.contains(pr.number)) == .reReview else { continue }
            new.append(Ping(id: "rr2-\(pr.number)-\(Int(Date().timeIntervalSince1970))", reason: .reReviewNeeded,
                            title: pr.title, url: pr.url, prNumber: pr.number, actor: pr.author?.login))
        }
        data.requestedPRs = requested

        // CI turning red on my own PRs (previous CI state is read before GitHubSync overwrites it).
        for pr in snapshot.authored where pr.state == "OPEN" {
            guard let ci = pr.ci, ci.state == .failing else { continue }
            let before = inputs.previousCI[pr.number]
            guard let before, before.state != .failing else { continue }
            new.append(Ping(id: "ci-\(pr.number)-\(Int(Date().timeIntervalSince1970))", reason: .ciFailed,
                            title: "\(pr.title) — \(ci.failing.joined(separator: ", "))", url: pr.url + "/checks", prNumber: pr.number))
        }

        var seen = data.seenThreads ?? [:]
        if data.seenThreads != nil {
            let handle = "@\(snapshot.me)".lowercased()
            var pinged = data.pingedComments ?? []
            for n in inputs.notifications where isMention(n.reason) && seen[n.id] != n.updated_at {
                // GitHub keeps reason "mention" on a thread forever and it also updates on pushes, so only ping
                // for an actual new comment naming me — never just because the thread changed or came back unread.
                guard let comment = inputs.comments[n.id], let body = comment.body, body.lowercased().contains(handle) else { continue }
                let key = comment.html_url ?? n.subject.latest_comment_url ?? "\(n.id)-\(body.hashValue)"
                guard !pinged.contains(key), comment.user?.login != snapshot.me else { continue }
                pinged.append(key)
                new.append(Ping(id: "m-\(n.id)-\(n.updated_at)", reason: .mention, title: n.subject.title,
                                url: comment.html_url ?? htmlURL(fromAPI: n.subject.url) ?? "https://github.com/notifications",
                                prNumber: number(in: n.subject.url), actor: comment.user?.login))
            }
            data.pingedComments = Array(pinged.suffix(300))
        }
        for n in inputs.notifications { seen[n.id] = n.updated_at }
        data.seenThreads = seen

        data.pings = Array((new + data.pings).prefix(40))
        return new
    }
}
