import SwiftUI
import MiradorCore

/// Only what is on the user's side, in the order to do it: the first row is the next thing to work on.
struct FocusView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("focusSelection") private var selectionRaw = ""
    @State private var showSnoozed = false
    @State private var showLater = false
    /// Rows under "Then" before the rest folds into "Later": a short list stays readable.
    private let thenCount = 5

    private var selection: Binding<TrackedTask.ID?> {
        Binding(get: { UUID(uuidString: selectionRaw) }, set: { selectionRaw = $0?.uuidString ?? "" })
    }

    var body: some View {
        let queue = model.focusQueue
        HSplitView {
            VStack(spacing: 0) {
                header(queue)
                Divider().overlay(Theme.border)
                if queue.isEmpty && model.snoozedTasks.isEmpty {
                    ContentUnavailableView("Nothing on your side", systemImage: "checkmark.seal",
                                           description: Text("Everything open is waiting on someone else."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list(queue)
                }
            }
            .frame(minWidth: 380, idealWidth: 440, maxWidth: 620)
            .background(Theme.background)
            Group {
                if let id = selection.wrappedValue, let task = model.tasks.first(where: { $0.id == id }) {
                    TaskDetailView(task: task)
                } else {
                    ContentUnavailableView("No task selected", systemImage: "scope", description: Text("Pick a task on the left."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.background)
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { selectFirstIfNeeded(queue) }
        .onChange(of: queue.map(\.id)) { _, _ in selectFirstIfNeeded(model.focusQueue) }
    }

    private func header(_ queue: [Focus.Item]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(queue.isEmpty ? "All clear" : "\(queue.count) on your side")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.foreground)
            Spacer()
            Muted("\(model.waitingOnOthers.count) waiting on others", size: 11)
                .help("Open tasks where reviewers or the author have the next move. They come back here when it is your turn.")
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private func list(_ queue: [Focus.Item]) -> some View {
        List(selection: selection) {
            if let next = queue.first {
                Section {
                    NextUpCard(item: next)
                        .tag(next.id)
                        .listRowSeparator(.hidden)
                        .contextMenu { FocusMenu(task: next.task) }
                } header: {
                    sectionTitle("Next up")
                }
            }
            let rest = Array(queue.dropFirst().enumerated())
            if !rest.isEmpty {
                Section {
                    rows(rest.prefix(thenCount))
                } header: {
                    sectionTitle("Then")
                }
            }
            if rest.count > thenCount {
                Section {
                    if showLater { rows(rest.dropFirst(thenCount)) }
                } header: {
                    disclosure("Later · \(rest.count - thenCount)", open: $showLater)
                }
            }
            let snoozed = model.snoozedTasks
            if !snoozed.isEmpty {
                Section {
                    if showSnoozed {
                        ForEach(snoozed) { task in
                            SnoozedRow(task: task).tag(task.id).listRowSeparator(.hidden)
                        }
                    }
                } header: {
                    disclosure("Snoozed · \(snoozed.count)", open: $showSnoozed)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func rows(_ items: ArraySlice<(offset: Int, element: Focus.Item)>) -> some View {
        ForEach(items, id: \.element.id) { offset, item in
            FocusRow(item: item, position: offset + 2)
                .tag(item.id)
                .listRowSeparator(.hidden)
                .contextMenu { FocusMenu(task: item.task) }
        }
    }

    private func disclosure(_ title: String, open: Binding<Bool>) -> some View {
        Button { open.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: open.wrappedValue ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                Text(title)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.mutedForeground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.mutedForeground)
    }

    /// Keeps a valid selection: the previous one while it is still in the queue, otherwise the next thing to do.
    private func selectFirstIfNeeded(_ queue: [Focus.Item]) {
        if let id = selection.wrappedValue, queue.contains(where: { $0.id == id }) || model.snoozedTasks.contains(where: { $0.id == id }) { return }
        selection.wrappedValue = queue.first?.id
    }
}

private func waited(_ date: Date) -> String {
    date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
}

private struct NextUpCard: View {
    @Environment(AppModel.self) private var model
    let item: Focus.Item

    var body: some View {
        let task = item.task
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "scope").font(.system(size: 11, weight: .semibold))
                Text(item.reason).font(.system(size: 12, weight: .semibold))
                Muted("· \(waited(item.since))", size: 12)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.foreground)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let ci = task.ci { CIIcon(ci: ci) }
                Text(task.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.foreground)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                if task.priority != .none { PriorityIcon(priority: task.priority) }
                StatusBadge(status: task.status)
                Group {
                    if let pr = task.prNumber { Text("#\(String(pr))") }
                    if let key = task.linearKey { Text(key) }
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.mutedForeground)
                .fixedSize()
                Spacer(minLength: 0)
                AuthorTag(task: task, me: model.me)
            }
            HStack(spacing: 6) {
                if let url = task.githubURL {
                    Button("Open PR") { model.open(url) }.shadButton(.primary)
                } else if let url = task.linearURL {
                    Button("Open Linear") { model.open(url) }.shadButton(.primary)
                }
                if let wt = model.worktree(for: task) {
                    let state = model.state(of: wt.path)
                    if state == .stopped || state == .crashed {
                        Button("Quickstart") { model.startEnvironment(wt.path) }.shadButton(.outline)
                    }
                }
                Spacer(minLength: 0)
                SnoozeMenu(task: task)
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius + 2))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius + 2).strokeBorder(Theme.border))
        .padding(.vertical, 4)
    }
}

private struct FocusRow: View {
    @Environment(AppModel.self) private var model
    let item: Focus.Item
    let position: Int

    var body: some View {
        let task = item.task
        HStack(alignment: .top, spacing: 10) {
            Text("\(position)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.mutedForeground)
                .frame(width: 22, height: 22)
                .background(Theme.muted, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let ci = task.ci { CIIcon(ci: ci) }
                    Text(task.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.foreground)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 6) {
                    if task.priority != .none { PriorityIcon(priority: task.priority) }
                    Muted(item.reason, size: 11)
                    Muted("· \(waited(item.since))", size: 11)
                    if let pr = task.prNumber {
                        Text("#\(String(pr))").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.mutedForeground)
                    }
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SnoozedRow: View {
    @Environment(AppModel.self) private var model
    let task: TrackedTask

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz").font(.system(size: 11)).foregroundStyle(Theme.mutedForeground)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.system(size: 12)).foregroundStyle(Theme.foreground).lineLimit(1)
                if let until = task.snoozedUntil {
                    Muted("Back \(until.formatted(.relative(presentation: .named)))", size: 11)
                }
            }
            Spacer(minLength: 0)
            Button("Wake") { model.snooze(task.id, until: nil) }.shadButton(.ghost)
        }
        .padding(.vertical, 2)
    }
}

private struct SnoozeMenu: View {
    @Environment(AppModel.self) private var model
    let task: TrackedTask

    var body: some View {
        ShadMenu {
            ForEach(AppModel.Snooze.allCases, id: \.self) { s in
                Button(s.label) { model.snooze(task.id, until: s.date) }
            }
        } label: {
            Label("Snooze", systemImage: "moon.zzz")
        }
        .help("Hide it from Focus for now. It comes back at that time, or as soon as its status changes.")
    }
}

private struct FocusMenu: View {
    @Environment(AppModel.self) private var model
    let task: TrackedTask

    var body: some View {
        Menu("Snooze") {
            ForEach(AppModel.Snooze.allCases, id: \.self) { s in
                Button(s.label) { model.snooze(task.id, until: s.date) }
            }
        }
        Divider()
        TaskMenu(task: task)
    }
}
