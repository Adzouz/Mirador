import AppKit
import Foundation
import Observation
import MiradorCore
import UserNotifications

@MainActor
@Observable
final class AppModel {
    let store = Store()

    var tasks: [TrackedTask] = []
    var worktrees: [Worktree] = []
    var running: [RunningEnvironment] = []
    var runningStates: [String: EnvironmentState] = [:]
    var lastSync: Date?
    var syncing = false
    var busyEnvironment: String?
    var errorMessage: String?
    var pings: [Ping] = []
    var me: String?

    enum Connection: Equatable {
        case checking, connected, failed(String)
    }
    var githubConnection: Connection = .checking
    var linearConnection: Connection = .checking
    var linearUser: String?
    var settings = AppSettings()
    var linearAuthFailed = false

    /// Linear needs attention: no key yet, or the saved one stopped working.
    var linearNeedsKey: Bool { linearKeyLoaded && (!hasLinearKey || linearAuthFailed) }

    func saveSettings(_ new: AppSettings) {
        store.update { $0.settings = new }
        reload()
        refreshWorktrees()
        sync()
    }

    private var storeModified: Date?
    private var timers: [Timer] = []

    init() {
        requestNotificationPermission()
        reload()
        refreshWorktrees()
        timers.append(.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfChanged() }
        })
        timers.append(.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollEnvironment() }
        })
        timers.append(.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        })
        pollEnvironment()
        sync()
        loadLinearKey()
    }

    // MARK: Store

    func reload() {
        let data = store.load()
        tasks = data.tasks
        running = data.runningEnvironments
        lastSync = data.lastGitHubSync
        pings = data.pings
        me = data.githubLogin
        settings = data.settings
        linearAuthFailed = data.linearAuthFailed == true
        storeModified = modificationDate()
    }

    private func reloadIfChanged() {
        if modificationDate() != storeModified { reload() }
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: store.fileURL.path))?[.modificationDate] as? Date
    }

    func mutate(_ id: TrackedTask.ID, _ body: @escaping (inout TrackedTask) -> Void) {
        store.update { data in
            guard let i = data.tasks.firstIndex(where: { $0.id == id }) else { return }
            body(&data.tasks[i])
            data.tasks[i].updatedAt = .now
        }
        reload()
    }

    /// Sets the QA mark and mirrors it as a `qa-done` / `qa-skipped` label on the PR.
    func setQA(_ task: TrackedTask, _ state: QAState) {
        mutate(task.id) {
            $0.qaState = state == .pending ? nil : state
            $0.qaChangedAt = .now
        }
        guard let pr = task.prNumber else { return }
        Task.detached {
            let error = GitHubSync.setQALabel(pr: pr, to: state)
            await MainActor.run {
                if let error { self.errorMessage = "QA label on #\(pr): \(error)" }
            }
        }
    }

    func setStatus(_ id: TrackedTask.ID, _ status: TaskStatus) {
        mutate(id) { $0.setStatus(status, source: "manual") }
    }

    var addingTask = false
    var showingOnboarding = false

    func showAdd() {
        NSApp.activate(ignoringOtherApps: true)
        addingTask = true
    }

    @discardableResult
    func add(_ preview: LinkPreview) -> TrackedTask.ID {
        let worktrees = worktrees
        let id = store.update { data in
            data.tasks[preview.insert(into: &data, worktrees: worktrees)].id
        }
        reload()
        sync()
        return id
    }

    func delete(_ id: TrackedTask.ID) {
        store.update { $0.tasks.removeAll { $0.id == id } }
        reload()
    }

    // MARK: Pings

    var unreadPings: [Ping] { pings.filter { !$0.read } }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notify(_ new: [Ping]) {
        for ping in new {
            let content = UNMutableNotificationContent()
            content.title = ping.headline
            content.body = ping.title
            content.sound = .default
            content.userInfo = ["url": ping.url, "id": ping.id]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: ping.id, content: content, trigger: nil))
        }
    }

    func openPing(_ ping: Ping) {
        open(URL(string: ping.url))
        markRead(ping.id)
    }

    func deletePing(_ id: String) {
        store.update { $0.pings.removeAll { $0.id == id } }
        reload()
    }

    func markRead(_ id: String? = nil) {
        store.update { data in
            for i in data.pings.indices where id == nil || data.pings[i].id == id { data.pings[i].read = true }
        }
        reload()
    }

    // MARK: Linear

    /// Read off the main thread: after a rebuild macOS may ask for Keychain access, and that must not block launch.
    private(set) var linearKey: String?
    private(set) var linearKeyLoaded = false
    var hasLinearKey: Bool { linearKey != nil }
    private var syncAgain = false

    private func loadLinearKey() {
        Task.detached {
            let key = LinearAPI.apiKey
            await MainActor.run {
                self.linearKey = key
                self.linearKeyLoaded = true
                if key != nil { self.sync() }
            }
        }
    }

    func setLinearKey(_ key: String?) {
        Keychain.write(LinearAPI.keyAccount, key)
        linearKey = key
        store.update { $0.linearAuthFailed = nil }
        reload()
        if key != nil { sync() }
    }

    // MARK: Sync

    /// GitHub, Linear and local branches, each independent so one failing does not block the others.
    func sync() {
        guard !syncing else { syncAgain = true; return }
        syncing = true
        let store = store
        let linearKey = linearKey
        let generation = worktreesGeneration
        Task.detached {
            let worktrees = Worktrees.list(settings: store.load().settings)
            let activity = LocalWork.activity(in: worktrees)
            var errors: [String] = []
            var pings: [Ping] = []
            var githubError: String?
            var linearError: String?
            var linearUser: String?

            do {
                let snap = try GitHubSync.fetch()
                let inputs = Pings.fetch(previous: store.load())
                pings += store.update { data in
                    GitHubSync.apply(snap, to: &data, worktrees: worktrees)
                    return Pings.apply(snapshot: snap, inputs: inputs, to: &data)
                }
            } catch {
                errors.append(error.localizedDescription)
                githubError = error.localizedDescription
            }

            if let linearKey {
                do {
                    let snap = try LinearAPI.fetch(key: linearKey)
                    linearUser = snap.viewerName
                    pings += store.update { data in
                        defer { data.lastLinearSync = .now }
                        return LinearAPI.apply(snap, to: &data, worktrees: worktrees)
                    }
                    let assigned = Set(snap.assigned.map(\.identifier))
                    let others = store.load().tasks.compactMap(\.linearKey).filter { !assigned.contains($0) }
                    let issues = try LinearAPI.issues(others, key: linearKey)
                    store.update {
                        LinearAPI.refresh(issues, in: &$0)
                        $0.linearAuthFailed = false
                    }
                } catch LinearAPI.LinearError.unauthorized {
                    errors.append(LinearAPI.LinearError.unauthorized.localizedDescription)
                    linearError = LinearAPI.LinearError.unauthorized.localizedDescription
                    pings += store.update { data -> [Ping] in
                        // One ping per breakage, not one per sync.
                        guard data.linearAuthFailed != true else { return [] }
                        data.linearAuthFailed = true
                        let ping = Ping(id: "linear-auth-\(Int(Date().timeIntervalSince1970))", reason: .linearAuth,
                                        title: "Open Mirador → Settings and paste a new Linear API key.",
                                        url: "https://linear.app/settings/account/security", prNumber: nil)
                        data.pings.insert(ping, at: 0)
                        return [ping]
                    }
                } catch {
                    errors.append(error.localizedDescription)
                    linearError = error.localizedDescription
                }
            }

            store.update { data in
                LocalWork.apply(worktrees: worktrees, activity: activity, to: &data)
                for i in data.tasks.indices where data.tasks[i].worktreePath == nil {
                    data.tasks[i].worktreePath = Worktrees.match(data.tasks[i], in: worktrees)?.path
                }
            }

            let message = errors.isEmpty ? nil : errors.joined(separator: " · ")
            SyncLog.write(message ?? "ok")
            let newPings = pings
            let (ghError, lnError, lnUser) = (githubError, linearError, linearUser)
            await MainActor.run {
                self.githubConnection = ghError.map { .failed($0) } ?? .connected
                if linearKey != nil {
                    self.linearConnection = lnError.map { .failed($0) } ?? .connected
                    if let lnUser { self.linearUser = lnUser }
                }
                self.notify(newPings)
                self.applyWorktrees(worktrees, fetched: generation)
                self.syncing = false
                self.errorMessage = message
                if self.syncAgain {
                    self.syncAgain = false
                    self.sync()
                }
                self.reload()
            }
        }
    }

    /// Bumped whenever a worktree is created or removed, so a list fetched before that cannot overwrite a newer one.
    private var worktreesGeneration = 0

    private func applyWorktrees(_ list: [Worktree], fetched generation: Int) {
        if generation == worktreesGeneration { worktrees = list } else { refreshWorktrees() }
    }

    func refreshWorktrees() {
        let generation = worktreesGeneration
        Task.detached {
            let list = Worktrees.list(settings: self.store.load().settings)
            await MainActor.run { self.applyWorktrees(list, fetched: generation) }
        }
    }

    func worktree(for task: TrackedTask) -> Worktree? {
        if let path = task.worktreePath, let wt = worktrees.first(where: { $0.path == path }) { return wt }
        return Worktrees.match(task, in: worktrees)
    }

    /// The task a worktree is for, preferring active ones.
    func primaryTask(for worktree: Worktree) -> TrackedTask? {
        tasks(for: worktree).sorted { a, b in
            if a.status.isFinished != b.status.isFinished { return !a.status.isFinished }
            return a.updatedAt > b.updatedAt
        }.first
    }

    /// "#12345 · fix(upload): add rotate…" rather than a folder name.
    func environmentTitle(for path: String) -> String {
        guard let wt = worktrees.first(where: { $0.path == path }) else { return (path as NSString).lastPathComponent }
        if wt.path == (settings.repoPath as NSString).standardizingPath {
            return "Monorepo · \(wt.branch ?? "detached")"
        }
        if let task = primaryTask(for: wt) {
            return (task.prNumber.map { "#\(String($0)) · " } ?? task.linearKey.map { "\($0) · " } ?? "") + task.title
        }
        return wt.branch ?? wt.name
    }

    var creatingWorktree: Set<TrackedTask.ID> = []

    /// Unlink removed worktrees from their tasks.
    func forgetWorktrees(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let removed = Set(paths)
        store.update { data in
            for i in data.tasks.indices where data.tasks[i].worktreePath.map(removed.contains) == true {
                data.tasks[i].worktreePath = nil
            }
        }
        reload()
        worktreesGeneration += 1
        refreshWorktrees()
    }

    func createWorktree(for task: TrackedTask) {
        creatingWorktree.insert(task.id)
        errorMessage = nil
        let settings = settings
        let store = store
        Task.detached {
            let result = Result { try WorktreeCreator.create(for: task, settings: settings) }
            if case .success(let created) = result {
                store.update { data in
                    guard let i = data.tasks.firstIndex(where: { $0.id == task.id }) else { return }
                    data.tasks[i].worktreePath = created.path
                    data.tasks[i].branch = data.tasks[i].branch ?? created.branch
                    // Already tracked, so the new branch must not spawn a second "local work" task.
                    if let branch = created.branch { data.seenBranches = (data.seenBranches ?? []) + [branch] }
                }
            }
            let list = Worktrees.list(settings: settings)
            await MainActor.run {
                self.creatingWorktree.remove(task.id)
                if case .failure(let error) = result { self.errorMessage = "Worktree: \(error.localizedDescription)" }
                self.worktreesGeneration += 1
                self.worktrees = list
                self.reload()
            }
        }
    }

    /// Worktrees that can be started (the first start installs dependencies), the ones with active tasks first.
    var startableWorktrees: [Worktree] {
        let repo = (settings.repoPath as NSString).standardizingPath
        return worktrees.sorted { a, b in
            if (a.path == repo) != (b.path == repo) { return a.path == repo }
            let ta = primaryTask(for: a), tb = primaryTask(for: b)
            let aa = ta.map { !$0.status.isFinished } ?? false, ab = tb.map { !$0.status.isFinished } ?? false
            if aa != ab { return aa }
            return (ta?.updatedAt ?? .distantPast) > (tb?.updatedAt ?? .distantPast)
        }
    }

    func tasks(for worktree: Worktree) -> [TrackedTask] {
        tasks.filter { self.worktree(for: $0)?.path == worktree.path && !$0.archived }
    }

    // MARK: Environments

    func state(of path: String) -> EnvironmentState {
        if busyEnvironment == path { return .starting }
        return runningStates[path] ?? .stopped
    }

    func port(for path: String) -> Int { settings.port(for: path) }

    /// "Installing dependencies… · 2m 10s" while an environment is starting.
    var startDetails: [String: String] = [:]

    private func updateStartDetails() {
        var details: [String: String] = [:]
        for env in running where runningStates[env.worktreePath] == .starting {
            let elapsed = Int(Date().timeIntervalSince(env.startedAt))
            let time = elapsed >= 60 ? "\(elapsed / 60)m \(elapsed % 60)s" : "\(elapsed)s"
            details[env.worktreePath] = "\(EnvironmentRunner.startupPhase(of: env.worktreePath).label) · \(time)"
        }
        if details != startDetails { startDetails = details }
    }
    func isMonorepo(_ path: String) -> Bool { settings.isMonorepo(path) }
    var runningPaths: [String] { running.map(\.worktreePath) }

    /// The environment running in the same slot (monorepo / worktree) as `path`, if it is a different one.
    func slotConflict(for path: String) -> RunningEnvironment? {
        running.first { $0.worktreePath != path && isMonorepo($0.worktreePath) == isMonorepo(path) }
    }

    private func pollEnvironment() {
        guard busyEnvironment == nil else { return }
        var states: [String: EnvironmentState] = [:]
        for env in running { states[env.worktreePath] = EnvironmentRunner.state(of: env.worktreePath, store: store) }
        if states != runningStates { runningStates = states }
        updateStartDetails()
        for (path, state) in states where state == .running { ensureAdmin(on: path) }
        adminChecked = adminChecked.filter { states[$0] == .running }
    }

    /// Checkouts already checked for a super admin during their current run.
    private var adminChecked: Set<String> = []

    /// On a fresh app (no admin yet), creates the configured super admin, like filling the welcome form.
    private func ensureAdmin(on path: String) {
        guard settings.autoCreateAdmin, !settings.adminEmail.isEmpty, !adminChecked.contains(path) else { return }
        adminChecked.insert(path)
        let port = port(for: path)
        let settings = settings
        let name = (path as NSString).lastPathComponent
        Task.detached {
            guard let password = Keychain.read(AdminBootstrap.passwordAccount) else { return }
            let credentials = AdminBootstrap.Credentials(
                email: settings.adminEmail, password: password,
                firstname: settings.adminFirstname.isEmpty ? "Admin" : settings.adminFirstname,
                lastname: settings.adminLastname
            )
            let outcome = AdminBootstrap.ensureAdmin(port: port, credentials: credentials)
            await MainActor.run {
                switch outcome {
                case .created:
                    self.notifyNow(title: "Super admin ready on \(name)", body: "Log in at :\(port) with \(settings.adminEmail)")
                case .alreadyHasAdmin:
                    break
                case .failed(let message):
                    self.errorMessage = "Admin on \(name): \(message)"
                    self.notifyNow(title: "Could not create the admin on \(name)", body: message)
                }
            }
        }
    }

    private func notifyNow(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func saveAdminPassword(_ password: String) {
        Task.detached { Keychain.write(AdminBootstrap.passwordAccount, password) }
    }

    func startEnvironment(_ path: String) {
        busyEnvironment = path
        errorMessage = nil
        let store = store
        Task.detached {
            var message: String?
            do { try EnvironmentRunner.start(worktreePath: path, store: store) } catch { message = error.localizedDescription }
            let error = message
            await MainActor.run {
                self.busyEnvironment = nil
                self.errorMessage = error
                self.reload()
                self.pollEnvironment()
            }
        }
    }

    func stopEnvironment(_ path: String) {
        busyEnvironment = path
        let store = store
        Task.detached {
            EnvironmentRunner.stop(path: path, store: store)
            await MainActor.run {
                self.busyEnvironment = nil
                self.reload()
                self.pollEnvironment()
            }
        }
    }

    // MARK: Opening things

    func open(_ url: URL?) {
        if let url { NSWorkspace.shared.open(url) }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func open(_ path: String, with app: Opener) {
        guard let appURL = app.appURL else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openLog(_ path: String, process: String) {
        NSWorkspace.shared.open(EnvironmentRunner.logURL(for: path, process: process))
    }
}

enum Opener: String, CaseIterable, Identifiable {
    case cursor = "Cursor"
    case vscode = "Visual Studio Code"
    case warp = "Warp"
    case terminal = "Terminal"

    var id: String { rawValue }

    var appURL: URL? {
        let candidates = ["/Applications/\(rawValue).app", "/System/Applications/Utilities/\(rawValue).app"]
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var available: [Opener] { allCases.filter { $0.appURL != nil } }
}

enum SyncLog {
    static let url = EnvironmentRunner.logDirectory.appendingPathComponent("sync.log")

    static func write(_ line: String) {
        let entry = "\(ISO8601DateFormatter().string(from: .now)) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: url)
        }
    }
}
