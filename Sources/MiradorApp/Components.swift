import SwiftUI
import MiradorCore

extension TaskStatus {
    var color: Color {
        switch self {
        case .todo, .toReview: Color(nsColor: .systemGray)
        case .inProgress, .reviewing, .takenOver: .blue
        case .doneLocally, .draftPR: .indigo
        case .inReview, .reReview, .waitingOnAuthor, .waitingForReview: .orange
        case .changesRequested, .addressing: .red
        case .approved: .green
        case .merged, .released: .purple
        case .blocked: .pink
        case .closed: Color(nsColor: .systemGray)
        }
    }
}

extension EnvironmentState {
    var color: Color {
        switch self {
        case .stopped: Color(nsColor: .systemGray)
        case .starting: .orange
        case .running: .green
        case .crashed: .red
        }
    }
}

struct StatusBadge: View {
    let status: TaskStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(status.color).frame(width: 6, height: 6)
            Text(status.label).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .foregroundStyle(status.color)
        .background(status.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(status.color.opacity(0.45)))
    }
}

struct PriorityIcon: View {
    let priority: Priority

    var body: some View {
        Group {
            switch priority {
            case .none:
                Image(systemName: "minus").foregroundStyle(Theme.mutedForeground)
            case .urgent:
                Image(systemName: "exclamationmark.square.fill").foregroundStyle(.orange)
            case .high, .medium, .low:
                Image(systemName: "cellularbars", variableValue: priority == .high ? 1 : priority == .medium ? 0.66 : 0.33)
                    .foregroundStyle(Theme.foreground)
            }
        }
        .font(.system(size: 11))
        .frame(width: 14)
        .help(priority.label)
    }
}

struct PriorityMenu: View {
    @Environment(AppModel.self) private var model
    let task: TrackedTask

    var body: some View {
        ForEach(Priority.allCases) { p in
            Button {
                model.mutate(task.id) { $0.priorityOverride = p.rawValue }
            } label: {
                Label(p.label, systemImage: task.priority == p ? "checkmark" : "")
            }
        }
        if task.priorityOverride != nil, task.linearKey != nil {
            Divider()
            Button("Use Linear priority") { model.mutate(task.id) { $0.priorityOverride = nil } }
        }
    }
}

struct EnvironmentBadge: View {
    let state: EnvironmentState
    var detail: String?

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if state == .running || state == .starting {
                    Circle().fill(state.color.opacity(0.25)).frame(width: 12, height: 12)
                }
                Circle().fill(state.color).frame(width: 7, height: 7)
            }
            .frame(width: 12, height: 12)
            Text(detail ?? state.label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.foreground)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
    }
}

struct LinkButtons: View {
    @Environment(AppModel.self) private var model
    let task: TrackedTask
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            if let url = task.githubURL {
                Button { model.open(url) } label: {
                    Label(task.prNumber.map { "#\(String($0))" } ?? "PR", systemImage: "arrow.triangle.pull")
                }
                .help("Open PR on GitHub")
            }
            if let url = task.linearURL {
                Button { model.open(url) } label: {
                    Label(task.linearKey ?? "Linear", systemImage: "circle.hexagongrid")
                }
                .help("Open Linear ticket")
            }
        }
        .shadButton(compact ? .ghost : .outline)
    }
}

struct EnvironmentControls: View {
    @Environment(AppModel.self) private var model
    let path: String

    var body: some View {
        let state = model.state(of: path)
        let busy = model.busyEnvironment != nil
        HStack(spacing: 8) {
            EnvironmentBadge(state: state, detail: state == .starting ? model.startDetails[path] : nil)
            Muted(":\(String(model.port(for: path)))")
            Spacer(minLength: 8)
            Menu {
                Button("develop log") { model.openLog(path, process: "develop") }
                Button("watch log") { model.openLog(path, process: "watch") }
            } label: {
                Image(systemName: "text.alignleft")
            }
            .menuStyle(.button)
            .buttonStyle(ShadButtonStyle(variant: .ghost, size: .icon))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Open logs")
            if state == .running {
                Button { model.open(EnvironmentRunner.adminURL(port: model.port(for: path))) } label: { Label("Open admin", systemImage: "arrow.up.right") }
                    .shadButton(.outline)
            }
            if state == .stopped || state == .crashed {
                Button { model.startEnvironment(path) } label: { Label(state == .crashed ? "Restart" : "Quickstart", systemImage: "play.fill") }
                    .shadButton(.primary)
                    .help(quickstartHelp)
                    .disabled(busy)
            } else {
                Button { model.stopEnvironment(path) } label: { Label("Stop", systemImage: "stop.fill") }
                    .shadButton(.secondary)
                    .disabled(busy)
            }
        }
    }
}

extension EnvironmentControls {
    var quickstartHelp: String {
        var text = "yarn watch + yarn develop --watch-admin on :\(String(model.port(for: path)))."
        if let other = model.slotConflict(for: path) {
            text += " Stops \((other.worktreePath as NSString).lastPathComponent), which uses the same slot."
        }
        if !model.isMonorepo(path) { text += " The monorepo can keep running next to it." }
        return text
    }
}

struct WorktreeActions: View {
    @Environment(AppModel.self) private var model
    let path: String

    var body: some View {
        HStack(spacing: 4) {
            Button { model.reveal(path) } label: { Label("Finder", systemImage: "folder") }
            ForEach(Opener.available) { app in
                Button { model.open(path, with: app) } label: {
                    Label(app.shortName, systemImage: app.symbol)
                }
            }
        }
        .shadButton(.ghost)
    }
}

struct PathField: View {
    @Environment(AppModel.self) private var model
    let path: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill").imageScale(.small).foregroundStyle(Theme.mutedForeground)
            Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                model.copy(path)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(ShadButtonStyle(variant: .ghost, size: .icon))
            .help("Copy path")
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 34)
        .background(Theme.muted, in: RoundedRectangle(cornerRadius: Theme.radius - 2))
    }
}

extension Opener {
    var shortName: String { self == .vscode ? "VS Code" : rawValue }
    var symbol: String {
        switch self {
        case .cursor, .vscode: "chevron.left.forwardslash.chevron.right"
        case .warp, .terminal: "terminal"
        }
    }
}

extension CIStatus.State {
    var color: Color {
        switch self {
        case .passing: .green
        case .failing: .red
        case .pending: .orange
        }
    }

    var symbol: String {
        switch self {
        case .passing: "checkmark.circle.fill"
        case .failing: "xmark.circle.fill"
        case .pending: "clock.fill"
        }
    }
}

struct CIIcon: View {
    let ci: CIStatus

    var body: some View {
        Image(systemName: ci.state.symbol)
            .font(.system(size: 11))
            .foregroundStyle(ci.state.color)
            .help(ci.summary + (ci.expected.isEmpty ? "" : " (\(ci.expected.joined(separator: ", ")) is red by design)"))
    }
}

struct AuthorTag: View {
    let task: TrackedTask
    let me: String?

    var body: some View {
        if task.isMine(me: me) {
            HStack(spacing: 3) {
                Image(systemName: "person.fill")
                Text("You")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
            .fixedSize()
            .help(task.prAuthor.map { "@\($0) (you)" } ?? "Your task")
        } else if let author = task.prAuthor {
            HStack(spacing: 3) {
                Image(systemName: "person")
                Text(author).lineLimit(1).truncationMode(.tail)
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.mutedForeground)
            .frame(maxWidth: 130, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
            .help("@\(author)")
        }
    }
}

/// Same prompt for "never connected" and "key stopped working".
struct LinearKeyPrompt: View {
    @Environment(AppModel.self) private var model
    var action: () -> Void

    var body: some View {
        Card(padding: 12) {
            HStack(spacing: 6) {
                if model.linearAuthFailed { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                Text("Connect Linear").font(.system(size: 12, weight: .semibold))
            }
            Muted(model.linearAuthFailed
                  ? "Your Linear API key stopped working. Add a new one to keep tickets and mentions in sync."
                  : "Sync assigned tickets and mentions.", size: 11)
                .fixedSize(horizontal: false, vertical: true)
            Button(model.linearAuthFailed ? "Replace API key" : "Add API key", action: action).shadButton(.primary)
        }
    }
}

extension QAState {
    var color: Color {
        switch self {
        case .pending: .orange
        case .done: .green
        case .skipped: Color(nsColor: .systemGray)
        }
    }

    var symbol: String {
        switch self {
        case .pending: "hourglass"
        case .done: "checkmark.seal.fill"
        case .skipped: "forward.fill"
        }
    }
}

struct QABadge: View {
    let qa: QAState

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: qa.symbol).font(.system(size: 9, weight: .semibold))
            Text(qa.label).font(.system(size: 10.5, weight: .semibold))
        }
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(qa.color)
        .background(qa.color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(qa.color.opacity(0.4)))
        .help(qa.label)
    }
}

struct QAMenu: View {
    @Environment(AppModel.self) private var model
    let task: TrackedTask

    var body: some View {
        ForEach(QAState.allCases) { state in
            Button {
                model.setQA(task, state)
            } label: {
                Label(state.label, systemImage: task.qa == state ? "checkmark" : state.symbol)
            }
        }
    }
}
