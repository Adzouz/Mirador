import SwiftUI
import MiradorCore

/// The whole window in focus mode: one task, why it needs the user, and its details. No lists, counts or pings.
struct FocusModeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let item = model.focusItem {
                FocusBar(item: item)
                Divider().overlay(Theme.border)
                if let note = model.focusTransition {
                    TransitionNote(text: note) { model.focusTransition = nil }
                    Divider().overlay(Theme.border)
                }
                TaskDetailView(task: item.task)
            } else {
                AllClear()
            }
        }
        .background(Theme.background)
    }
}

private struct FocusBar: View {
    @Environment(AppModel.self) private var model
    let item: Focus.Item

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "scope").font(.system(size: 13, weight: .semibold))
            Text(item.reason).font(.system(size: 13, weight: .semibold))
            Muted("since \(item.since.formatted(.relative(presentation: .named)))", size: 12)
            Spacer()
            Button { withAnimation(.easeOut(duration: 0.2)) { model.skipFocus() } } label: {
                Label("Skip for now", systemImage: "forward")
            }
            .shadButton(.outline)
            .help("Put it on the skipped stack and move to the next task. It stays there, out of the way, until you pick it again.")
            SkippedButton()
            // No bare Esc here: the task's notes, menus and popovers below use it to cancel.
            Button { model.focusMode = false } label: { Label("Exit focus", systemImage: "xmark") }
                .shadButton(.ghost)
                .help("Exit focus (⇧⌘F)")
        }
        .foregroundStyle(Theme.foreground)
        .padding(.horizontal, 24)
        .frame(height: 52)
    }
}

/// The skipped stack: present but quiet (no count), opened on demand.
private struct SkippedButton: View {
    @Environment(AppModel.self) private var model
    @State private var open = false

    var body: some View {
        if !model.skippedTasks.isEmpty {
            Button { open.toggle() } label: { Label("Skipped", systemImage: "tray") }
                .shadButton(.ghost)
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    SkippedList { open = false }
                        .frame(width: 380)
                        .padding(12)
                }
        }
    }
}

private struct SkippedList: View {
    @Environment(AppModel.self) private var model
    var onPick: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Skipped").font(.system(size: 13, weight: .semibold))
            ForEach(model.skippedTasks) { task in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        HStack(spacing: 6) {
                            StatusBadge(status: task.status)
                            if let pr = task.prNumber { Muted("#\(String(pr))", size: 11) }
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Focus") {
                        model.resumeSkipped(task.id)
                        onPick()
                    }
                    .shadButton(.outline)
                    Button { model.unskip(task.id) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(ShadButtonStyle(variant: .ghost, size: .icon))
                        .help("Put it back in line")
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct TransitionNote: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle").foregroundStyle(.green)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.foreground).lineLimit(1)
            Muted("Next one below.", size: 12)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(ShadButtonStyle(variant: .ghost, size: .icon))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Theme.muted)
    }
}

private struct AllClear: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal").font(.system(size: 36)).foregroundStyle(Theme.mutedForeground)
            Text("Nothing needs you right now").font(.system(size: 18, weight: .semibold))
            Muted(model.skippedTasks.isEmpty
                  ? "Everything open is waiting on someone else. The next task shows up here when it is your turn."
                  : "Only skipped tasks are left.")
            if !model.skippedTasks.isEmpty {
                Card { SkippedList() }.frame(maxWidth: 440)
            }
            Button("Exit focus") { model.focusMode = false }
                .shadButton(.outline)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Menu bar panel in focus mode: the one task and a way to move on, instead of pings and lists.
struct MenuFocusCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "scope").font(.system(size: 11, weight: .semibold))
                Text("Focus").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Exit") { model.focusMode = false }.shadButton(.ghost)
            }
            if let item = model.focusItem {
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.task.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.foreground)
                            .multilineTextAlignment(.leading)
                        Muted(item.reason, size: 11)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HStack(spacing: 6) {
                    if let url = item.task.githubURL { Button("Open PR") { model.open(url) }.shadButton(.primary) }
                    Spacer()
                    Button("Skip for now") { model.skipFocus() }.shadButton(.outline)
                }
            } else {
                Muted("Nothing needs you right now.", size: 12)
            }
        }
    }
}
