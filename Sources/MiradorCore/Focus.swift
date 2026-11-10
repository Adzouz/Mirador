import Foundation

/// One ordered queue of what is on the user's side, so the next thing to do is the first row.
///
/// Order: urgent tasks first, then by step — unblock your own PRs (red CI, requested changes), answer people waiting
/// on you (re-reviews), land approved work, finish what is started, then new reviews and to-dos. Within a step:
/// priority, then whoever has waited longest. Tasks waiting on someone else, blocked or snoozed are left out.
public enum Focus {
    public struct Item: Identifiable, Hashable, Sendable {
        public var task: TrackedTask
        public var reason: String
        /// Since when the task has been in this state: how long it has been waiting on the user.
        public var since: Date
        public var step: Int

        public var id: TrackedTask.ID { task.id }
    }

    public static func queue(_ tasks: [TrackedTask], me: String?, now: Date = .now) -> [Item] {
        tasks.compactMap { task -> Item? in
            guard !task.archived, !task.status.isFinished, !task.isSnoozed(at: now) else { return nil }
            guard let (step, reason) = step(of: task, me: me) else { return nil }
            return Item(task: task, reason: reason, since: task.statusSince, step: step)
        }
        .sorted { a, b in
            let (ua, ub) = (a.task.priority == .urgent, b.task.priority == .urgent)
            if ua != ub { return ua }
            if a.step != b.step { return a.step < b.step }
            if a.task.priority.rank != b.task.priority.rank { return a.task.priority.rank < b.task.priority.rank }
            return a.since < b.since
        }
    }

    /// Focus mode's one task: the current one while it is still on the user's side (a more urgent arrival waits, so
    /// work is not interrupted), otherwise the first one not skipped.
    public static func pick(_ queue: [Item], current: TrackedTask.ID?, skipped: [TrackedTask.ID]) -> Item? {
        if let current, !skipped.contains(current), let item = queue.first(where: { $0.id == current }) { return item }
        return queue.first { !skipped.contains($0.id) }
    }

    /// Skipped tasks still worth coming back to: the ones that left the user's side are dropped.
    public static func pruneSkipped(_ skipped: [TrackedTask.ID], queue: [Item]) -> [TrackedTask.ID] {
        let ids = Set(queue.map(\.id))
        return skipped.filter(ids.contains)
    }

    /// Open tasks where the ball is in someone else's court (reviewers, the author) — not part of the queue.
    public static func waitingOnOthers(_ tasks: [TrackedTask], me: String?) -> [TrackedTask] {
        tasks.filter { !$0.archived && !$0.status.isFinished && $0.status != .blocked && step(of: $0, me: me) == nil }
    }

    static func step(of task: TrackedTask, me: String?) -> (Int, String)? {
        let mine = !task.kind.isReview && task.isMine(me: me)
        if mine, task.prNumber != nil, task.ci?.state == .failing, task.status != .draftPR {
            return (0, "CI failing on your PR")
        }
        switch task.status {
        case .changesRequested: return task.kind.isReview ? nil : (1, "Changes requested")
        case .addressing: return (1, "Addressing review comments")
        case .reReview: return task.kind.isReview ? (2, "Back for your re-review") : nil
        case .approved:
            guard mine else { return nil }
            return (3, task.qa == .pending ? "Approved — QA, then merge" : "Approved — ready to merge")
        case .reviewing: return (4, "Finish your review")
        case .takenOver: return (4, "Community PR you took over")
        case .doneLocally: return (5, "Done locally — open the PR")
        case .inProgress: return (5, "In progress")
        case .draftPR: return mine ? (5, "Draft — finish and mark ready") : nil
        case .toReview: return (6, "Review requested")
        case .todo: return (7, "To do")
        case .inReview, .waitingForReview, .waitingOnAuthor, .blocked, .merged, .released, .closed: return nil
        }
    }
}

extension TrackedTask {
    /// When the current status was entered.
    public var statusSince: Date {
        history.last(where: { $0.status == status })?.at ?? updatedAt
    }

    public func isSnoozed(at now: Date = .now) -> Bool {
        snoozedUntil.map { $0 > now } ?? false
    }
}
