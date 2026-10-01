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

    @discardableResult
    public static func run(_ executable: String, _ args: [String], cwd: String? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + args
        process.environment = userEnvironment
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return Result(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        // Drain both pipes before waiting so large outputs cannot fill a pipe and deadlock.
        nonisolated(unsafe) var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
