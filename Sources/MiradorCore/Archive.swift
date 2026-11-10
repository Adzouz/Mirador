import Foundation

/// Moves finished work out of the lists: merged or closed PRs, PR-less tickets that are done in Linear, and PR-less
/// tasks whose only link is a closed GitHub issue.
public enum Archive {
    static let doneLinearStates: Set<String> = ["done", "canceled", "cancelled", "duplicate", "released"]

    /// A task with a PR follows the PR; then the Linear ticket decides; then the issue.
    public static func isOver(_ task: TrackedTask) -> Bool {
        if task.status.isFinished { return true }
        guard task.prNumber == nil else { return false }
        if let state = task.linearState { return doneLinearStates.contains(state.lowercased()) }
        if task.linearKey != nil { return false }
        return task.issueState == "closed"
    }

    /// Archives tasks that are over. A task unarchived by hand stays until its status changes again.
    @discardableResult
    public static func apply(to data: inout StoreData, now: Date = .now) -> Int {
        var count = 0
        for i in data.tasks.indices where !data.tasks[i].archived && data.tasks[i].archivedAt == nil && isOver(data.tasks[i]) {
            data.tasks[i].setArchived(true, at: now)
            count += 1
        }
        return count
    }
}

public extension StoreData {
    /// PR numbers of tasks still in the lists, so the sync can refresh the ones its searches no longer return.
    var openPRNumbers: [Int] {
        tasks.filter { !$0.archived && !$0.status.isFinished }.compactMap(\.prNumber)
    }

    var openIssueNumbers: [Int] {
        tasks.filter { !$0.archived && !$0.status.isFinished }.compactMap(\.issueNumber)
    }
}
