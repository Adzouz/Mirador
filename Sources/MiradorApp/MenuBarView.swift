import SwiftUI
import MiradorCore

/// Menu bar panel: fixed header (environment), scrollable middle (pings, needs me), fixed footer.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @State private var panelHeight: CGFloat = 0
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.focusMode {
                        MenuFocusCard()
                    } else {
                        if !model.unreadPings.isEmpty { pingsSection }
                        needsMeSection
                    }
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
        .background(Theme.background)
        // The menu bar window keeps its first height and centers the panel in it; measure the panel and give the
        // window exactly that height.
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { panelHeight = proxy.size.height }
                .onChange(of: proxy.size.height) { _, height in panelHeight = height }
        })
        .background(WindowFitter(height: panelHeight))
        .frame(maxHeight: .infinity, alignment: .top)
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
/// The environment block at the top: the monorepo slot, then the worktree slot, each startable on its own.
struct MenuEnvironmentCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            monorepoSlot
            Divider().overlay(Theme.border)
            worktreeSlot
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius + 2))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius + 2).strokeBorder(Theme.border))
    }

    @ViewBuilder
    private var monorepoSlot: some View {
        if let repo = model.monorepo {
            if model.state(of: repo.path) == .stopped {
                EnvironmentQuickRow(path: repo.path, title: "Monorepo", subtitle: repo.branch ?? "detached")
            } else {
                RunningEnvironmentBlock(path: repo.path)
            }
        } else {
            Muted("Monorepo not found — set its folder in Settings.", size: 11)
        }
    }

    @ViewBuilder
    private var worktreeSlot: some View {
        if let running = model.running.first(where: { !model.isMonorepo($0.worktreePath) }) {
            RunningEnvironmentBlock(path: running.worktreePath)
        }
        let choices = model.worktreeChoices.filter { !model.runningPaths.contains($0.path) }
        if choices.isEmpty {
            if model.running.allSatisfy({ model.isMonorepo($0.worktreePath) }) {
                Muted("No worktree yet — create one from a task.", size: 11)
            }
        } else {
            let selected = choices.first { $0.path == model.lastWorktreePath } ?? choices[0]
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Menu {
                        ForEach(choices) { wt in
                            Button {
                                model.lastWorktreePath = wt.path
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
                        model.startEnvironment(selected.path)
                    } label: {
                        Label("Quickstart", systemImage: "play.fill")
                    }
                    .shadButton(.primary, size: .md)
                    .disabled(model.busyEnvironment != nil)
                }
                if let other = model.slotConflict(for: selected.path) {
                    Muted("Stops \((other.worktreePath as NSString).lastPathComponent) (same :\(String(model.port(for: selected.path))) slot).", size: 11)
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
                    .opacity(ping.read ? 0.6 : 1)
                    Spacer()
                    Text(ping.at.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))).font(.caption2).foregroundStyle(.tertiary).fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { model.markRead(ping.id) } label: {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(ShadButtonStyle(variant: .ghost, size: .icon))
            .opacity(ping.read ? 0 : hovering ? 1 : 0.35)
            .disabled(ping.read)
            .help("Mark as read")
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

/// Gives the hosting window the panel's measured height, anchored to its top edge (under the menu bar), now and every
/// time the menu bar window is shown again.
struct WindowFitter: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> FitterView { FitterView() }

    func updateNSView(_ view: FitterView, context: Context) {
        view.target = height
        view.fitSoon()
    }

    final class FitterView: NSView {
        var target: CGFloat = 0
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.fitSoon()
                })
            }
            fitSoon()
        }

        func fitSoon() {
            DispatchQueue.main.async { [weak self] in self?.fit() }
        }

        private func fit() {
            guard let window, target > 50 else { return }
            let current = window.contentRect(forFrameRect: window.frame).height
            guard abs(current - target) > 0.5 else { return }
            var frame = window.frame
            let newFrame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: frame.width, height: target))
            frame.origin.y += frame.height - newFrame.height
            frame.size.height = newFrame.height
            window.setFrame(frame, display: true, animate: false)
        }
    }
}
