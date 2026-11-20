import CryptoKit
import Foundation

public enum EnvironmentState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case crashed

    public var label: String {
        switch self {
        case .stopped: "Not running"
        case .starting: "Starting…"
        case .running: "Running"
        case .crashed: "Crashed"
        }
    }
}

/// Runs `yarn watch` + `yarn develop --watch-admin`. Two slots: the monorepo and one worktree, each on its own port,
/// so a fix can be compared with the current code side by side. Starting an environment only replaces the one in its slot.
public enum EnvironmentRunner {
    static let builtMarker = "packages/core/strapi/dist/cli.js"
    /// Written by yarn (node-modules linker) only once an install completes, unlike node_modules itself.
    static let installedMarker = "node_modules/.yarn-state.yml"

    public enum StartupPhase: String, Sendable {
        case installing, building, starting

        public var label: String {
            switch self {
            case .installing: "Installing dependencies…"
            case .building: "Building packages…"
            case .starting: "Starting Strapi…"
            }
        }
    }

    /// What a starting environment is busy with: what its start script last wrote, else read from the checkout
    /// (environments started by an older version).
    public static func startupPhase(of path: String, store: Store) -> StartupPhase {
        if let raw = try? String(contentsOf: stateURL(for: path, "phase", store: store), encoding: .utf8),
           let phase = StartupPhase(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return phase
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: (path as NSString).appendingPathComponent(installedMarker)) { return .installing }
        if !fm.fileExists(atPath: (path as NSString).appendingPathComponent(builtMarker)) { return .building }
        return .starting
    }

    // MARK: Preparation

    /// What runs before `yarn develop`.
    public struct Preparation: Equatable, Sendable {
        public enum Build: Equatable, Sendable {
            case none, full
            /// Project folders, as `nx run-many --projects` takes them.
            case projects([String])
        }

        public var install = false
        public var build = Build.none
    }

    /// Root files every package build reads.
    static let sharedBuildInputs: Set<String> = ["package.json", "yarn.lock", ".yarnrc.yml", "nx.json", "rollup.utils.mjs", ".nxignore"]

    /// Installs and builds what is missing, or what changed since the commit of the last build Mirador ran. `yarn watch`
    /// never builds on start, so commits pulled while an environment was stopped would otherwise run on old `dist` folders.
    static func preparation(installed: Bool, built: Bool, lastBuilt: String?, head: String?, changes: [String]?) -> Preparation {
        var prep = Preparation(install: !installed, build: built ? .none : .full)
        guard let lastBuilt, let head, lastBuilt != head else { return prep }
        // The last build's commit is gone (rewritten, then pruned): nothing tells what changed.
        guard let changes else { return Preparation(install: true, build: .full) }
        if changes.contains(where: isDependencyFile) { prep.install = true }
        if prep.build == .none { prep.build = buildScope(for: changes) }
        return prep
    }

    static func isDependencyFile(_ path: String) -> Bool {
        (path as NSString).lastPathComponent == "package.json" || path == "yarn.lock" || path == ".yarnrc.yml" || path.hasPrefix(".yarn/")
    }

    /// The packages to rebuild, like `yarn watch` does on a change: the `packages/*` and `packages/*/*` folders holding
    /// changed files (nx skips folders that are not projects). A change to the shared build setup rebuilds everything.
    static func buildScope(for changes: [String]) -> Preparation.Build {
        if changes.contains(where: { sharedBuildInputs.contains($0) || $0.hasPrefix(".yarn/") }) { return .full }
        var folders = Set<String>()
        for path in changes {
            let parts = path.split(separator: "/")
            guard parts.count >= 3, parts[0] == "packages" else { continue }
            for depth in 2...min(3, parts.count - 1) { folders.insert(parts.prefix(depth).joined(separator: "/")) }
        }
        return folders.isEmpty ? .none : .projects(folders.sorted())
    }

    /// Reads the checkout: install / build markers, HEAD, and what changed since the last recorded build.
    static func preparation(for path: String, store: Store) -> (Preparation, head: String?) {
        let fm = FileManager.default
        let installed = fm.fileExists(atPath: (path as NSString).appendingPathComponent(installedMarker))
        let built = fm.fileExists(atPath: (path as NSString).appendingPathComponent(builtMarker))
        let head = BranchUpdate.commit("HEAD", in: path)
        let lastBuilt = (try? String(contentsOf: stateURL(for: path, "built", store: store), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var changes: [String]?
        if let lastBuilt, let head, lastBuilt != head {
            let diff = Shell.git(["diff", "--name-only", "--no-renames", "-z", lastBuilt, head], in: path)
            if diff.status == 0 { changes = diff.stdout.split(separator: "\0").map(String.init) }
        }
        let prep = preparation(installed: installed, built: built, lastBuilt: lastBuilt, head: head, changes: changes)
        return (prep, head)
    }

    /// Records the commit the current build was made from, when Mirador has none yet (started by an older version, or
    /// never started): moving HEAD (an update) must leave the next start something to compare with.
    public static func recordBuildIfUnknown(of path: String, at commit: String, store: Store) {
        let url = stateURL(for: path, "built", store: store)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? commit.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Mirador's state for a checkout (`phase`: what its start is doing; `built`: the commit of its last build), kept out
    /// of the checkout and keyed by its real path.
    static func stateURL(for path: String, _ kind: String, store: Store) -> URL {
        let resolved = Worktrees.resolved(path)
        let digest = SHA256.hash(data: Data(resolved.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return store.directory.appendingPathComponent("environments", isDirectory: true)
            .appendingPathComponent("\((resolved as NSString).lastPathComponent)-\(digest).\(kind)")
    }

    /// Install, build, record the build, then `yarn develop`. Each step reports its phase in `phase`.
    static func developCommand(_ prep: Preparation, head: String?, appDirectory: String, phase: String, built: String) -> String {
        var steps: [String] = []
        if prep.install { steps += ["printf installing >| \(quote(phase))", "yarn install"] }
        switch prep.build {
        case .none: break
        case .full: steps += ["printf building >| \(quote(phase))", "yarn build"]
        case .projects(let folders):
            steps += ["printf building >| \(quote(phase))",
                      "yarn nx run-many --targets build:code,build:types --nx-ignore-cycles --projects \(quote(folders.joined(separator: ",")))"]
        }
        if let head { steps.append("printf %s \(quote(head)) >| \(quote(built))") }
        steps += ["printf starting >| \(quote(phase))", "cd \(quote(appDirectory))", "exec yarn develop --watch-admin"]
        return steps.joined(separator: " && ")
    }

    /// `yarn watch` only rebuilds on changes: it waits until install and build are done.
    static func watchCommand(phase: String) -> String {
        "until /usr/bin/grep -qx starting \(quote(phase)) 2>/dev/null; do sleep 3; done; exec yarn watch"
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static var logDirectory: URL {
        AppIdentity.folder(in: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs"))
    }

    public static func logURL(for worktreePath: String, process: String) -> URL {
        let name = (worktreePath as NSString).lastPathComponent
        return logDirectory.appendingPathComponent("\(name)-\(process).log")
    }

    public enum RunError: LocalizedError {
        case missingApp(String, String)
        case spawn(String)

        public var errorDescription: String? {
            switch self {
            case .missingApp(let dir, let p): "No \(dir) in \(p). Check the app folder in Settings."
            case .spawn(let msg): "Could not start: \(msg)"
            }
        }
    }

    public static func start(worktreePath: String, store: Store) throws {
        let settings = store.load().settings
        let appDirectory = settings.appDirectory
        let appPath = (worktreePath as NSString).appendingPathComponent(appDirectory)
        guard FileManager.default.fileExists(atPath: appPath) else { throw RunError.missingApp(appDirectory, worktreePath) }

        let port = settings.port(for: worktreePath)
        // A removed checkout still listed in the slot is forgotten, not "stopped" through process ids that may be reused.
        forgetRemovedCheckouts(store: store)
        stop(slotOf: worktreePath, store: store)
        killPortListeners(port: port)

        let (prep, head) = preparation(for: worktreePath, store: store)
        let phase = stateURL(for: worktreePath, "phase", store: store)
        let built = stateURL(for: worktreePath, "built", store: store)
        try? FileManager.default.createDirectory(at: phase.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Written before spawning: a phase file left by the previous run must not release `yarn watch` early.
        let first: StartupPhase = prep.install ? .installing : prep.build == .none ? .starting : .building
        try? first.rawValue.write(to: phase, atomically: true, encoding: .utf8)

        let watch = try spawn(
            watchCommand(phase: phase.path),
            cwd: worktreePath,
            log: logURL(for: worktreePath, process: "watch")
        )
        let develop = try spawn(
            developCommand(prep, head: head, appDirectory: appDirectory, phase: phase.path, built: built.path),
            cwd: worktreePath,
            log: logURL(for: worktreePath, process: "develop"),
            extraEnv: ["PORT": String(port), "BROWSER": "none"]
        )
        store.update { data in
            data.runningEnvironments.removeAll { $0.worktreePath == worktreePath }
            data.runningEnvironments.append(RunningEnvironment(worktreePath: worktreePath, processGroups: [watch, develop], port: port))
        }
    }

    /// Stops whatever runs in the same slot (monorepo or worktree) as `path`.
    public static func stop(slotOf path: String, store: Store) {
        let settings = store.load().settings
        let monorepo = settings.isMonorepo(path)
        for env in store.load().runningEnvironments where settings.isMonorepo(env.worktreePath) == monorepo {
            stop(path: env.worktreePath, store: store)
        }
    }

    public static func stop(path: String, store: Store) {
        guard let env = store.load().runningEnvironments.first(where: { $0.worktreePath == path }) else { return }
        terminate(groups: env.processGroups)
        // `nx watch` starts a daemon that detaches from our process group.
        Shell.run("yarn", ["nx", "daemon", "--stop"], cwd: env.worktreePath)
        store.update { $0.runningEnvironments.removeAll { $0.worktreePath == path } }
    }

    public static func stopAll(store: Store) {
        for env in store.load().runningEnvironments { stop(path: env.worktreePath, store: store) }
    }

    // MARK: Removed checkouts

    /// Checkouts removed outside Mirador (a terminal, another tool): their environments leave the list, tasks stop
    /// pointing at them, and what is left of their processes is stopped (Strapi can outlive its deleted folder and keep
    /// the port). Returns their paths.
    @discardableResult
    public static func forgetRemovedCheckouts(store: Store) -> [String] {
        let data = store.load()
        let gone = Set(data.runningEnvironments.map(\.worktreePath) + data.tasks.compactMap(\.worktreePath)).filter(Worktrees.isGone)
        guard !gone.isEmpty else { return [] }
        let dropped = store.update { $0.forgetCheckouts(gone.filter(Worktrees.isGone)) }
        for env in dropped { terminate(groups: env.processGroups.filter { isOurs($0, startedAt: env.startedAt) }) }
        for path in gone { forgetState(of: path, store: store) }
        return gone.sorted()
    }

    /// Drops a checkout's phase and build records.
    public static func forgetState(of path: String, store: Store) {
        for kind in ["phase", "built"] { try? FileManager.default.removeItem(at: stateURL(for: path, kind, store: store)) }
    }

    /// Whether `group` is still led by the process started for an environment at `startedAt`. Process ids are reused
    /// (after a reboot, or a while): a recorded group can belong to someone else by now.
    static func isOurs(_ group: Int32, startedAt: Date) -> Bool {
        guard group > 1 else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, group]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_eproc.e_pgid == group else { return false }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        return abs(started.timeIntervalSince(startedAt)) < 30
    }

    public static func state(of worktreePath: String, store: Store) -> EnvironmentState {
        guard let env = store.load().runningEnvironments.first(where: { $0.worktreePath == worktreePath }) else { return .stopped }
        guard env.processGroups.allSatisfy(isAlive) else { return .crashed }
        let port = env.port ?? store.load().settings.port(for: worktreePath)
        return isPortOpen(port: port) ? .running : .starting
    }

    // MARK: Processes

    /// Spawns `zsh -lc <command>` in its own process group so the whole yarn/nx/node tree can be killed at once.
    static func spawn(_ command: String, cwd: String, log: URL, extraEnv: [String: String] = [:]) throws -> Int32 {
        FileManager.default.createFile(atPath: log.path, contents: Data("$ \(command) (in \(cwd))\n".utf8))
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, log.path, O_WRONLY | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&fileActions, 1, 2)
        posix_spawn_file_actions_addchdir_np(&fileActions, cwd)

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        var env = Shell.userEnvironment
        for (k, v) in extraEnv { env[k] = v }
        env["FORCE_COLOR"] = "0"
        let args = ["/bin/zsh", "-lc", command]
        let cArgs = args.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/zsh", &fileActions, &attr, cArgs, cEnv)
        guard rc == 0 else { throw RunError.spawn(String(cString: strerror(rc))) }
        return pid
    }

    static func terminate(groups: [Int32]) {
        for g in groups where g > 1 { kill(-g, SIGTERM) }
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, groups.contains(where: isAlive) {
            usleep(200_000)
        }
        for g in groups where g > 1 && isAlive(g) { kill(-g, SIGKILL) }
    }

    static func isAlive(_ group: Int32) -> Bool {
        // Reap the leader if it is our exited child, otherwise its zombie still counts as alive.
        var status: Int32 = 0
        _ = waitpid(group, &status, WNOHANG)
        return kill(-group, 0) == 0 || errno == EPERM
    }

    /// Anything left on the port (a run started outside Mirador, a crashed app) blocks the new one.
    static func killPortListeners(port: Int) {
        let r = Shell.run("lsof", ["-nP", "-ti", "tcp:\(port)", "-sTCP:LISTEN"])
        let pids = r.stdout.split(separator: "\n").compactMap { Int32($0) }
        for pid in pids { kill(pid, SIGTERM) }
        if !pids.isEmpty { usleep(800_000) }
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// Strapi binds to whatever `HOST` resolves to: `localhost` can give an IPv6-only `[::1]` listener.
    public static func isPortOpen(port: Int) -> Bool {
        isOpenIPv4(port: port) || isOpenIPv6(port: port)
    }

    static func isOpenIPv4(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return rc == 0
    }

    static func isOpenIPv6(port: Int) -> Bool {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = UInt16(port).bigEndian
        addr.sin6_addr = in6addr_loopback
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        return rc == 0
    }

    public static func adminURL(port: Int) -> URL { URL(string: "http://localhost:\(port)/admin")! }
}
