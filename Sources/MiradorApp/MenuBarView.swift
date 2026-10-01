import SwiftUI
import MiradorCore

/// Menu bar panel: fixed header (environment), scrollable middle (pings, needs me), fixed footer.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !model.unreadPings.isEmpty { pingsSection }
                    needsMeSection
                }
                .padding(12)
            }
            .frame(maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Theme.border)
            footer
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.background.ignoresSafeArea())
        // The menu bar window keeps its first height; resize it to the panel so nothing shows above or below.
        .background(WindowFitter())
        .ignoresSafeArea()
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("🔭").font(.system(size: 15))
                Text("Mirador").font(.system(size: 13, weight: .semibold))
                Spacer()
                SyncStatus()
            }
            if model.linearNeedsKey && model.linearAuthFailed {
                LinearKeyPrompt {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            MenuEnvironmentCard()
        }
        .padding(12)
    }

    // MARK: Middle

    private var pingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Pings", count: model.unreadPings.count) {
                Button("Mark all read") { model.markRead() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.mutedForeground)
            }
            VStack(spacing: 2) {
                ForEach(model.unreadPings.prefix(5)) { ping in
                    PingRow(ping: ping)
                        .padding(8)
                        .background(Theme.muted.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var needsMeSection: some View {
        let tasks = model.tasks
            .filter { !$0.archived && !$0.status.isFinished && $0.needsMe }
            .sorted { $0.updatedAt > $1.updatedAt }
        return VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Needs me", count: tasks.count) { EmptyView() }
            if tasks.isEmpty {
                Muted("Nothing waiting on you.").padding(.vertical, 6)
            }
            VStack(spacing: 2) {
                ForEach(tasks) { task in MenuTaskRow(task: task) }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: { Label("Open Mirador", systemImage: "macwindow") }
            .shadButton(.outline)
            Button {
                openWindow(id: "main")
                model.showAdd()
            } label: { Label("Add", systemImage: "plus") }
            .shadButton(.outline)
            .help("Paste a GitHub PR or Linear link")
            Spacer()
            Button { model.sync() } label: {
                if model.syncing { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(ShadButtonStyle(variant: .ghost, size: .icon))
            .help("Sync now")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(ShadButtonStyle(variant: .ghost, size: .icon))
                .help("Quit Mirador")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.muted.opacity(0.5))
    }
}

struct SectionTitle<Trailing: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Theme.mutedForeground)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.mutedForeground)
                    .padding(.horizontal, 5)
                    .background(Theme.muted, in: Capsule())
            }
            Spacer()
            trailing
        }
    }
}

/// The environment block at the top: every running environment, then pick + quickstart for another one.
struct MenuEnvironmentCard: View {
    @Environment(AppModel.self) private var model
    @AppStorage("quickstartPath") private var quickstartPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.running, id: \.worktreePath) { env in
                RunningEnvironmentBlock(path: env.worktreePath)
                Divider().overlay(Theme.border)
            }
            quickstart
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius + 2))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius + 2).strokeBorder(Theme.border))
    }

    @ViewBuilder
    private var quickstart: some View {
        let running = Set(model.runningPaths)
        let options = model.startableWorktrees.filter { !running.contains($0.path) }
        if options.isEmpty {
            Muted("No other checkout to start.", size: 11)
        } else {
            let selected = options.first { $0.path == quickstartPath } ?? options[0]
            VStack(alignment: .leading, spacing: 6) {
                if model.running.isEmpty {
                    HStack {
                        EnvironmentBadge(state: model.busyEnvironment == nil ? .stopped : .starting)
                        Muted("monorepo :\(String(model.settings.monorepoPort)) · worktree :\(String(model.settings.worktreePort))", size: 11)
                    }
                }
                HStack(spacing: 6) {
                    Menu {
                        ForEach(options) { wt in
                            Button {
                                quickstartPath = wt.path
                            } label: {
                                Text(model.environmentTitle(for: wt.path))
                                Text("\(wt.name) · :\(String(model.port(for: wt.path)))")
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.environmentTitle(for: selected.path)).lineLimit(1)
                            Text("\(selected.name) · :\(String(model.port(for: selected.path)))")
                                .font(.system(size: 10)).foregroundStyle(Theme.mutedForeground)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .menuStyle(.button)
                    .buttonStyle(ShadButtonStyle(variant: .outline, size: .md))
                    .menuIndicator(.visible)
                    Button {
                        quickstartPath = selected.path
                        model.startEnvironment(selected.path)
                    } label: {
                        Label("Quickstart", systemImage: "play.fill")
                    }
                    .shadButton(.primary, size: .md)
                    .disabled(model.busyEnvironment != nil)
                }
                if let other = model.slotConflict(for: selected.path) {
                    Muted("Stops \((other.worktreePath as NSString).lastPathComponent) (same :\(String(model.port(for: selected.path))) slot).", size: 11)
                } else if !model.running.isEmpty {
                    Muted("Runs next to the environment above.", size: 11)
                }
            }
        }
    }
}

struct RunningEnvironmentBlock: View {
    @Environment(AppModel.self) private var model
    let path: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Badge(text: model.isMonorepo(path) ? "Monorepo" : "Worktree", variant: .secondary)
                Text(model.environmentTitle(for: path))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Image(systemName: "folder").imageScale(.small).foregroundStyle(Theme.mutedForeground)
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button {
                    model.copy(path)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy path", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .shadButton(.ghost)
            }
            EnvironmentControls(path: path)
        }
    }
}

/// Compact, clickable task row: opens the PR (or ticket); quickstart on hover when it has a worktree.
struct MenuTaskRow: View {
    @Environment(AppModel.self) private var model
    let task: TrackedTask
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: task.kind.symbol)
                .font(.system(size: 11))
                .foregroundStyle(Theme.mutedForeground)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    if let ci = task.ci { CIIcon(ci: ci) }
                    Text(task.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    StatusBadge(status: task.status)
                    Group {
                        if let pr = task.prNumber { Text("#\(String(pr))") }
                        if let key = task.linearKey { Text(key) }
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.mutedForeground)
                    if task.qa == .pending { QABadge(qa: .pending) }
                    Spacer(minLength: 0)
                    AuthorTag(task: task, me: model.me)
                }
            }
            if hovering, let wt = model.worktree(for: task), model.state(of: wt.path) == .stopped {
                Button { model.startEnvironment(wt.path) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(ShadButtonStyle(variant: .outline, size: .icon))
                    .help("Quickstart \(wt.name)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(hovering ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.open(task.githubURL ?? task.linearURL) }
        .help(task.githubURL != nil ? "Open PR" : task.linearURL != nil ? "Open Linear ticket" : "")
    }
}

struct PingRow: View {
    @Environment(AppModel.self) private var model
    let ping: Ping
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { model.openPing(ping) } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: ping.symbol)
                        .foregroundStyle(ping.read ? Color.secondary : Color.accentColor)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ping.headline).font(.caption.weight(.semibold))
                        Text(ping.title).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ping.at.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))).font(.caption2).foregroundStyle(.tertiary).fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { withAnimation(.easeOut(duration: 0.15)) { model.deletePing(ping.id) } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(ShadButtonStyle(variant: .ghost, size: .icon))
            .opacity(hovering ? 1 : 0.35)
            .help("Remove this ping")
        }
        .onHover { hovering = $0 }
    }
}

extension Ping {
    var symbol: String {
        switch reason {
        case .mention: "at"
        case .reviewRequested: "person.crop.circle.badge.questionmark"
        case .linearMention: "bubble.left"
        case .linearAssigned: "person.badge.plus"
        case .ciFailed: "xmark.octagon"
        case .reReviewNeeded: "arrow.triangle.2.circlepath"
        case .linearAuth: "key.slash"
        }
    }
}

/// Keeps the hosting window exactly as tall as the SwiftUI content, anchored to its top edge (under the menu bar).
struct WindowFitter: NSViewRepresentable {
    func makeNSView(context: Context) -> FitterView { FitterView() }
    func updateNSView(_ view: FitterView, context: Context) { view.fitSoon() }

    final class FitterView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            fitSoon()
        }

        override func layout() {
            super.layout()
            fitSoon()
        }

        func fitSoon() {
            DispatchQueue.main.async { [weak self] in self?.fit() }
        }

        private func fit() {
            guard let window, let content = window.contentView else { return }
            let target = content.fittingSize.height
            guard target > 50 else { return }
            let current = window.contentRect(forFrameRect: window.frame).height
            guard abs(current - target) > 1 else { return }
            var frame = window.frame
            let newFrame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: frame.width, height: target))
            frame.origin.y += frame.height - newFrame.height
            frame.size.height = newFrame.height
            window.setFrame(frame, display: true, animate: false)
        }
    }
}
