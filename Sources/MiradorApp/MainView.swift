import AppKit
import SwiftUI
import MiradorCore

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case pings = "Pings"
    case needsMe = "Needs me"
    case active = "All active"
    case work = "My work"
    case reviews = "Reviews"
    case done = "Done"
    case environments = "Environments"
    case cleanup = "Cleanup"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .pings: "bell"
        case .needsMe: "exclamationmark.circle"
        case .active: "tray.full"
        case .work: "hammer"
        case .reviews: "eye"
        case .done: "checkmark.circle"
        case .environments: "server.rack"
        case .cleanup: "trash"
        }
    }

    func includes(_ t: TrackedTask) -> Bool {
        switch self {
        case .needsMe: !t.archived && !t.status.isFinished && t.needsMe
        case .active: !t.archived && !t.status.isFinished
        case .work: !t.archived && !t.status.isFinished && !t.kind.isReview
        case .reviews: !t.archived && !t.status.isFinished && t.kind.isReview
        case .done: t.archived || t.status.isFinished
        case .environments, .pings, .cleanup: false
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sidebarSection") private var sidebarRaw = SidebarItem.active.rawValue
    private var sidebar: SidebarItem? {
        get { SidebarItem(rawValue: sidebarRaw) ?? .active }
        nonmutating set { sidebarRaw = (newValue ?? .active).rawValue }
    }
    private var sidebarBinding: Binding<SidebarItem?> {
        Binding(get: { sidebar }, set: { sidebar = $0 })
    }
    @State private var selection: TrackedTask.ID?
    @State private var search = ""
    @AppStorage("lastSelection") private var lastSelection = ""
    @AppStorage("onboardingDone") private var onboardingDone = false
    @AppStorage("sortOrder") private var sort: SortOrder = .updated
    @AppStorage("statusFilter") private var statusFilterRaw = ""
    @AppStorage("qaFilter") private var qaFilterRaw = ""

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Text("🔭").font(.system(size: 20))
                    Text("Mirador").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.foreground)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 6)
                List(selection: sidebarBinding) {
                    Section("Tasks") {
                        ForEach([SidebarItem.needsMe, .active, .work, .reviews, .done]) { item in
                            Label(item.rawValue, systemImage: item.symbol).badge(count(item)).tag(item)
                        }
                    }
                    Section("Inbox") {
                        Label(SidebarItem.pings.rawValue, systemImage: SidebarItem.pings.symbol).badge(count(.pings)).tag(SidebarItem.pings)
                        Label(SidebarItem.environments.rawValue, systemImage: SidebarItem.environments.symbol).tag(SidebarItem.environments)
                        Label(SidebarItem.cleanup.rawValue, systemImage: SidebarItem.cleanup.symbol).tag(SidebarItem.cleanup)
                    }
                }
                SidebarFooter()
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch sidebar ?? .active {
            case .environments:
                EnvironmentsView()
            case .pings:
                PingsView()
            case .cleanup:
                CleanupView()
            default:
                HSplitView {
                    VStack(spacing: 0) {
                        ListToolbar(count: visibleTasks.count, sort: $sort, statusFilter: statusFilter, available: availableStatuses,
                                    qaFilter: qaFilter, pendingQA: pendingQACount)
                        Divider().overlay(Theme.border)
                        TaskListView(tasks: visibleTasks, selection: $selection)
                    }
                    .frame(minWidth: 380, idealWidth: 440, maxWidth: 620)
                    Group {
                        if let id = selection, let task = model.tasks.first(where: { $0.id == id }) {
                            TaskDetailView(task: task)
                        } else {
                            ContentUnavailableView("No task selected", systemImage: "checklist", description: Text("Pick a task, or paste a GitHub PR / Linear link with ⌘N."))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Theme.background)
                        }
                    }
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                }
                .searchable(text: $search, placement: .toolbar, prompt: "Search tasks")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.destructive)
                        .lineLimit(1)
                        .frame(maxWidth: 260)
                        .help(error)
                }
                SyncStatus()
                Button { model.sync() } label: {
                    if model.syncing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .help("Sync GitHub, Linear and local branches (⌘R)")
                PingsButton { sidebar = .pings }
                Button { model.showAdd() } label: { Label("Add", systemImage: "plus") }
                    .help("Add from a GitHub PR or Linear link (⌘N)")
            }
        }
        .navigationTitle("Mirador")
        .hidingToolbarTitle()
        .onAppear {
            selection = UUID(uuidString: lastSelection)
            if !onboardingDone { model.showingOnboarding = true }
        }
        .sheet(isPresented: $model.showingOnboarding) { OnboardingView() }
        .onChange(of: selection) { _, id in lastSelection = id?.uuidString ?? "" }
        .sheet(isPresented: $model.addingTask) {
            AddTaskSheet { id in
                sidebar = .active
                selection = id
            }
        }
    }

    private func count(_ item: SidebarItem) -> Int {
        switch item {
        case .done, .environments, .cleanup: 0
        case .pings: model.unreadPings.count
        default: model.tasks.filter(item.includes).count
        }
    }

    private var statusFilter: Binding<Set<TaskStatus>> {
        Binding(
            get: { Set(statusFilterRaw.split(separator: ",").compactMap { TaskStatus(rawValue: String($0)) }) },
            set: { statusFilterRaw = $0.map(\.rawValue).sorted().joined(separator: ",") }
        )
    }

    private var qaFilter: Binding<QAState?> {
        Binding(get: { QAState(rawValue: qaFilterRaw) }, set: { qaFilterRaw = $0?.rawValue ?? "" })
    }

    private var pendingQACount: Int {
        model.tasks.filter((sidebar ?? .active).includes).filter { $0.qa == .pending }.count
    }

    /// Statuses present in the current sidebar section, in flow order.
    private var availableStatuses: [TaskStatus] {
        let present = Set(model.tasks.filter((sidebar ?? .active).includes).map(\.status))
        return TaskStatus.allCases.filter(present.contains).sorted { $0.rank < $1.rank }
    }

    private var visibleTasks: [TrackedTask] {
        let item = sidebar ?? .active
        let query = search.lowercased()
        let statuses = statusFilter.wrappedValue
        let qa = qaFilter.wrappedValue
        let shown: [TrackedTask] = model.tasks.filter { task in
            guard item.includes(task) else { return false }
            if !statuses.isEmpty && !statuses.contains(task.status) { return false }
            if let qa, task.qa != qa { return false }
            return query.isEmpty || Self.searchText(of: task).contains(query)
        }
        return shown.sorted(by: sort.areInIncreasingOrder)
    }

    /// Kept out of the filter closure: one long expression there is too slow for older Swift compilers to type-check.
    private static func searchText(of task: TrackedTask) -> String {
        var parts: [String] = [task.title]
        if let branch = task.branch { parts.append(branch) }
        if let key = task.linearKey { parts.append(key) }
        if let pr = task.prNumber { parts.append(String(pr)) }
        if let author = task.prAuthor { parts.append(author) }
        return parts.joined(separator: " ").lowercased()
    }
}

struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.linearNeedsKey {
                LinearKeyPrompt { openSettings() }
            }
            if !model.running.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Running")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.mutedForeground)
                    ForEach(model.running, id: \.worktreePath) { env in
                        HStack(spacing: 6) {
                            EnvironmentBadge(state: model.state(of: env.worktreePath),
                                             detail: (env.worktreePath as NSString).lastPathComponent)
                            Spacer(minLength: 4)
                            Muted(":\(String(model.port(for: env.worktreePath)))", size: 11)
                        }
                        .help("\(model.state(of: env.worktreePath).label) · \(env.worktreePath)")
                    }
                }
                .padding(.horizontal, 8)
                Divider().overlay(Theme.border)
            }
            AccountBlock { openSettings() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Who is signed in, and whether GitHub and Linear answer.
struct AccountBlock: View {
    @Environment(AppModel.self) private var model
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Avatar(login: model.me)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.me.map { "@\($0)" } ?? "Not signed in")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.foreground)
                            .lineLimit(1)
                        if let name = model.linearUser {
                            Muted(name, size: 11).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "gearshape").font(.system(size: 11)).foregroundStyle(Theme.mutedForeground)
                        .opacity(hovering ? 1 : 0)
                }
                HStack(spacing: 10) {
                    ConnectionDot(name: "GitHub", state: model.githubConnection)
                    ConnectionDot(name: "Linear", state: linearState)
                }
            }
            .padding(8)
            .background(hovering ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open Settings")
    }

    private var linearState: ConnectionDot.State {
        if !model.linearKeyLoaded { return .checking }
        if !model.hasLinearKey { return .off("Not connected") }
        if model.linearAuthFailed { return .failed("API key not working") }
        switch model.linearConnection {
        case .checking: return .checking
        case .connected: return .ok(model.linearUser.map { "Connected as \($0)" } ?? "Connected")
        case .failed(let message): return .failed(message)
        }
    }
}

struct ConnectionDot: View {
    enum State {
        case checking, ok(String), off(String), failed(String)
    }
    let name: String
    let state: State

    init(name: String, state: State) {
        self.name = name
        self.state = state
    }

    init(name: String, state: AppModel.Connection) {
        self.name = name
        switch state {
        case .checking: self.state = .checking
        case .connected: self.state = .ok("Connected")
        case .failed(let message): self.state = .failed(message)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.mutedForeground)
        }
        .help("\(name): \(detail)")
    }

    private var color: Color {
        switch state {
        case .checking: .orange
        case .ok: .green
        case .off: Color(nsColor: .systemGray)
        case .failed: .red
        }
    }

    private var detail: String {
        switch state {
        case .checking: "Checking…"
        case .ok(let text), .off(let text), .failed(let text): text
        }
    }
}

struct Avatar: View {
    let login: String?

    var body: some View {
        ZStack {
            Circle().fill(Theme.muted)
            if let login, let url = URL(string: "https://github.com/\(login).png?size=64") {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Text(String(login.prefix(1)).uppercased()).font(.system(size: 11, weight: .semibold))
                }
                .clipShape(Circle())
            } else {
                Image(systemName: "person.fill").font(.system(size: 11)).foregroundStyle(Theme.mutedForeground)
            }
        }
        .frame(width: 26, height: 26)
        .overlay(Circle().strokeBorder(Theme.border))
    }
}

struct TaskListView: View {
    @Environment(AppModel.self) private var model
    let tasks: [TrackedTask]
    @Binding var selection: TrackedTask.ID?

    var body: some View {
        Group {
            if tasks.isEmpty {
                ContentUnavailableView("Nothing here", systemImage: "tray", description: Text("Tasks come from GitHub, Linear, new local branches, or ⌘N."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(tasks, selection: $selection) { task in
                    TaskRow(task: task)
                        .tag(task.id)
                        .listRowSeparator(.hidden)
                        .contextMenu { TaskMenu(task: task) }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.background)
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: TrackedTask

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: task.kind.symbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.mutedForeground)
                .frame(width: 24, height: 24)
                .background(Theme.muted, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let ci = task.ci, !task.status.isFinished { CIIcon(ci: ci) }
                    Text(task.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.foreground)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Muted(task.startDate.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)), size: 11)
                        .fixedSize()
                        .help("\(task.prNumber != nil ? "Opened" : "Started") \(task.startDate.formatted(date: .abbreviated, time: .shortened)) · updated \(task.updatedAt.formatted(.relative(presentation: .named)))")
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
                    if let qa = task.qa, !task.status.isFinished || qa == .pending { QABadge(qa: qa) }
                    Spacer(minLength: 0)
                    AuthorTag(task: task, me: model.me)
                    if let wt = model.worktree(for: task) {
                        let state = model.state(of: wt.path)
                        Image(systemName: state == .stopped ? "folder" : "bolt.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(state == .stopped ? Theme.mutedForeground : state.color)
                            .help(state == .stopped ? wt.path : "\(state.label) · \(wt.path)")
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

struct TaskMenu: View {
    @Environment(AppModel.self) private var model
    let task: TrackedTask

    var body: some View {
        Menu("Status") {
            ForEach(task.kind.flow + [.blocked, .closed]) { s in
                Button(s.label) { model.setStatus(task.id, s) }
            }
        }
        Menu("Priority") { PriorityMenu(task: task) }
        if task.qa != nil { Menu("QA") { QAMenu(task: task) } }
        if let url = task.githubURL { Button("Open PR") { model.open(url) } }
        if let url = task.linearURL { Button("Open Linear") { model.open(url) } }
        if let wt = model.worktree(for: task) {
            Button("Reveal worktree") { model.reveal(wt.path) }
            Button("Quickstart environment") { model.startEnvironment(wt.path) }
        }
        Divider()
        Button(task.archived ? "Unarchive" : "Archive") { model.mutate(task.id) { $0.archived.toggle() } }
        Button("Delete", role: .destructive) { model.delete(task.id) }
    }
}

struct PingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.pings.isEmpty {
                ContentUnavailableView("No pings yet", systemImage: "bell", description: Text("Review requests and mentions from GitHub and Linear show up here and as notifications."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Pings").font(.system(size: 20, weight: .semibold))
                            Spacer()
                            Button("Mark all read") { model.markRead() }
                                .shadButton(.outline)
                                .disabled(model.unreadPings.isEmpty)
                        }
                        Card(padding: 6) {
                            VStack(spacing: 0) {
                                ForEach(model.pings) { ping in
                                    PingRow(ping: ping).padding(10)
                                    if ping.id != model.pings.last?.id { Divider().overlay(Theme.border) }
                                }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.background)
    }
}

struct SyncStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Group {
                if model.syncing {
                    Text("Syncing…")
                } else if let last = model.lastSync {
                    Text("Synced \(last > context.date.addingTimeInterval(-10) ? "just now" : last.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))")
                } else {
                    Text("Not synced")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.mutedForeground)
            .monospacedDigit()
            .fixedSize()
        }
    }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case updated, started, status, priority

    var id: String { rawValue }

    var label: String {
        switch self {
        case .updated: "Last updated"
        case .started: "Start date"
        case .status: "Status"
        case .priority: "Priority"
        }
    }

    var symbol: String {
        switch self {
        case .updated: "clock.arrow.circlepath"
        case .started: "calendar"
        case .status: "circle.dashed"
        case .priority: "cellularbars"
        }
    }

    func areInIncreasingOrder(_ a: TrackedTask, _ b: TrackedTask) -> Bool {
        switch self {
        case .updated:
            return a.updatedAt > b.updatedAt
        case .started:
            return a.startDate > b.startDate
        case .status:
            if a.status.rank != b.status.rank { return a.status.rank < b.status.rank }
            return a.updatedAt > b.updatedAt
        case .priority:
            if a.priority.rank != b.priority.rank { return a.priority.rank < b.priority.rank }
            if a.status.rank != b.status.rank { return a.status.rank < b.status.rank }
            return a.updatedAt > b.updatedAt
        }
    }
}

struct ListToolbar: View {
    let count: Int
    @Binding var sort: SortOrder
    @Binding var statusFilter: Set<TaskStatus>
    let available: [TaskStatus]
    @Binding var qaFilter: QAState?
    let pendingQA: Int

    var body: some View {
        HStack(spacing: 6) {
            Muted("\(count) task\(count == 1 ? "" : "s")")
            Spacer()
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(SortOrder.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(sort.label, systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.button)
            .buttonStyle(ShadButtonStyle(variant: .ghost))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort")

            Menu {
                ForEach(available) { status in
                    Toggle(isOn: Binding(
                        get: { statusFilter.contains(status) },
                        set: { on in if on { statusFilter.insert(status) } else { statusFilter.remove(status) } }
                    )) { Text(status.label) }
                }
                if !statusFilter.isEmpty {
                    Divider()
                    Button("Show all statuses") { statusFilter = [] }
                }
            } label: {
                Label(filterLabel, systemImage: statusFilter.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
            }
            .menuStyle(.button)
            .buttonStyle(ShadButtonStyle(variant: statusFilter.isEmpty ? .ghost : .secondary))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Filter by status")

            Menu {
                Button { qaFilter = nil } label: { Label("Any QA", systemImage: qaFilter == nil ? "checkmark" : "") }
                Divider()
                ForEach(QAState.allCases) { state in
                    Button { qaFilter = state } label: {
                        Label(state == .pending ? "\(state.label) (\(pendingQA))" : state.label, systemImage: qaFilter == state ? "checkmark" : state.symbol)
                    }
                }
            } label: {
                Label(qaFilter?.label ?? "QA", systemImage: qaFilter?.symbol ?? "checkmark.seal")
            }
            .menuStyle(.button)
            .buttonStyle(ShadButtonStyle(variant: qaFilter == nil ? .ghost : .secondary))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Filter by QA")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.background)
    }

    private var filterLabel: String {
        switch statusFilter.count {
        case 0: "All statuses"
        case 1: statusFilter.first!.label
        default: "\(statusFilter.count) statuses"
        }
    }
}

/// Toolbar bell: unread count + popover with the latest pings.
struct PingsButton: View {
    @Environment(AppModel.self) private var model
    var onSeeAll: () -> Void
    @State private var open = false

    var body: some View {
        let unread = model.unreadPings.count
        Button { open.toggle() } label: {
            Image(systemName: unread > 0 ? "bell.badge.fill" : "bell")
                .symbolRenderingMode(unread > 0 ? .palette : .monochrome)
                .foregroundStyle(unread > 0 ? Color.red : Theme.foreground, Theme.foreground)
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Text("\(min(unread, 99))")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(Color.red, in: Capsule())
                            .offset(x: 9, y: -7)
                    }
                }
        }
        .help(unread > 0 ? "\(unread) unread ping\(unread == 1 ? "" : "s")" : "Pings")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Pings").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Mark all read") { model.markRead() }
                        .shadButton(.ghost)
                        .disabled(unread == 0)
                }
                .padding(12)
                Divider().overlay(Theme.border)
                if model.pings.isEmpty {
                    Muted("No pings yet. Review requests, mentions and CI failures show up here.")
                        .padding(16)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(model.pings.prefix(15)) { ping in
                                PingRow(ping: ping)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(ping.read ? Color.clear : Color.accentColor.opacity(0.06))
                                Divider().overlay(Theme.border)
                            }
                        }
                    }
                    .frame(maxHeight: 420)
                }
                Button {
                    open = false
                    onSeeAll()
                } label: {
                    Text("See all pings").frame(maxWidth: .infinity)
                }
                .shadButton(.ghost)
                .padding(8)
            }
            .frame(width: 380)
            .background(Theme.card)
        }
    }
}

extension View {
    /// The custom title item replaces the system one (which renders emoji monochrome).
    @ViewBuilder
    func hidingToolbarTitle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}

extension NSImage {
    /// A non-template image of an emoji, so the toolbar keeps its colors.
    static func emoji(_ emoji: String, size: CGFloat) -> NSImage {
        let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: size)])
        let box = text.size()
        let image = NSImage(size: box, flipped: false) { _ in
            text.draw(at: .zero)
            return true
        }
        image.isTemplate = false
        return image
    }
}

