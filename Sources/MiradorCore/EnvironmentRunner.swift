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

    public enum StartupPhase: Sendable {
        case installing, building, starting

        public var label: String {
            switch self {
            case .installing: "Installing dependencies…"
            case .building: "Building packages…"
            case .starting: "Starting Strapi…"
            }
        }
    }

    /// What a starting environment is busy with, read from the checkout itself.
    public static func startupPhase(of path: String) -> StartupPhase {
        let fm = FileManager.default
        if !fm.fileExists(atPath: (path as NSString).appendingPathComponent(installedMarker)) { return .installing }
        if !fm.fileExists(atPath: (path as NSString).appendingPathComponent(builtMarker)) { return .building }
        return .starting
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
        let appDirectory = store.load().settings.appDirectory
        let appPath = (worktreePath as NSString).appendingPathComponent(appDirectory)
        guard FileManager.default.fileExists(atPath: appPath) else { throw RunError.missingApp(appDirectory, worktreePath) }

        let settings = store.load().settings
        let port = settings.port(for: worktreePath)
        stop(slotOf: worktreePath, store: store)
        killPortListeners(port: port)

        // A fresh worktree has no build output yet: build once before develop, and let watch wait for it.
        let built = "test -e \(builtMarker)"
        let watch = try spawn(
            "until \(built); do sleep 3; done; exec yarn watch",
            cwd: worktreePath,
            log: logURL(for: worktreePath, process: "watch")
        )
        let develop = try spawn(
            "(test -f \(installedMarker) || yarn install) && (\(built) || yarn build) && cd '\(appDirectory)' && exec yarn develop --watch-admin",
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

    public static func isPortOpen(port: Int) -> Bool {
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

    public static func adminURL(port: Int) -> URL { URL(string: "http://localhost:\(port)/admin")! }
}
