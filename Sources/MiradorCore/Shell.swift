import Foundation

public enum Shell {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    /// PATH a GUI app does not inherit: Volta, Homebrew, ~/.local/bin.
    public static var userPath: String {
        let home = NSHomeDirectory()
        let extra = ["\(home)/.volta/bin", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        return (extra + current).filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    public static var userEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = userPath
        env["VOLTA_HOME"] = env["VOLTA_HOME"] ?? "\(NSHomeDirectory())/.volta"
        return env
    }

    /// Git in `dir`, through /usr/bin/git: shell wrappers some developers use rewrite `git` output.
    @discardableResult
    public static func git(_ args: [String], in dir: String) -> Result {
        run("/usr/bin/git", ["-C", dir] + args)
    }

    /// Runs to completion on the calling thread alone. Callers are often blocked cooperative threads (detached tasks,
    /// tests): waiting on work queued elsewhere (a stderr reader on a global queue, `Process`'s exit handling) deadlocks
    /// once every thread of the pool waits like this.
    @discardableResult
    public static func run(_ executable: String, _ args: [String], cwd: String? = nil) -> Result {
        var out: [Int32] = [-1, -1], err: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { return Result(status: -1, stdout: "", stderr: String(cString: strerror(errno))) }
        guard pipe(&err) == 0 else {
            out.forEach { close($0) }
            return Result(status: -1, stdout: "", stderr: String(cString: strerror(errno)))
        }
        for fd in out + err { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)
        if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd) }

        let rc = spawn(["/usr/bin/env", executable] + args, environment: userEnvironment, actions: &actions)
        close(out[1])
        close(err[1])
        defer {
            close(out[0])
            close(err[0])
        }
        guard case .success(let pid) = rc else {
            if case .failure(let error) = rc { return Result(status: -1, stdout: "", stderr: error.message) }
            return Result(status: -1, stdout: "", stderr: "")
        }

        // Drain both pipes together so a large output cannot fill one and block the child.
        var outData = Data(), errData = Data()
        var fds = [pollfd(fd: out[0], events: Int16(POLLIN), revents: 0), pollfd(fd: err[0], events: Int16(POLLIN), revents: 0)]
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while fds.contains(where: { $0.fd >= 0 }) {
            if poll(&fds, nfds_t(fds.count), -1) < 0 {
                if errno == EINTR { continue }
                break
            }
            for i in fds.indices where fds[i].fd >= 0 && fds[i].revents != 0 {
                let n = read(fds[i].fd, &buffer, buffer.count)
                if n > 0 {
                    if i == 0 { outData.append(buffer, count: n) } else { errData.append(buffer, count: n) }
                } else if n == 0 || errno != EINTR {
                    fds[i].fd = -1 // poll skips negative descriptors
                }
            }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let signal = status & 0x7f
        return Result(
            status: signal == 0 ? (status >> 8) & 0xff : 128 + signal,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    struct SpawnError: Error {
        var message: String
    }

    /// `posix_spawn` with what a child needs whatever thread starts it: signals unblocked and at their defaults (worker
    /// threads block them, and a child keeping that mask ignores SIGTERM), and no open file of the caller besides those
    /// `actions` set up (another thread's pipe held by a child keeps that pipe's reader waiting until the child exits).
    static func spawn(_ argv: [String], environment: [String: String], actions: inout posix_spawn_file_actions_t?,
                      newProcessGroup: Bool = false) -> Swift.Result<pid_t, SpawnError> {
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var noSignals = sigset_t(), allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        var flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        if newProcessGroup {
            flags |= POSIX_SPAWN_SETPGROUP
            posix_spawnattr_setpgroup(&attr, 0)
        }
        posix_spawnattr_setflags(&attr, Int16(flags))

        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, &attr, cArgs, cEnv)
        return rc == 0 ? .success(pid) : .failure(SpawnError(message: String(cString: strerror(rc))))
    }
}
