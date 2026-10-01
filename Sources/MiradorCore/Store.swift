import Foundation

/// JSON store shared by the app and the `mirador` CLI. Every write is a locked read-modify-write,
/// so both processes can update it at the same time.
public final class Store: @unchecked Sendable {
    public let directory: URL
    public let fileURL: URL
    private let lockURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? AppIdentity.folder(in: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
        self.directory = base
        self.fileURL = base.appendingPathComponent("store.json")
        self.lockURL = base.appendingPathComponent("store.lock")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    public func load() -> StoreData {
        withLock { read() }
    }

    @discardableResult
    public func update<T>(_ body: (inout StoreData) throws -> T) rethrows -> T {
        try withLock {
            var data = read()
            let result = try body(&data)
            write(data)
            return result
        }
    }

    private func read() -> StoreData {
        guard let raw = try? Data(contentsOf: fileURL) else { return StoreData() }
        do {
            let data = try Self.decoder.decode(StoreData.self, from: raw)
            LinearKey.configure(data.settings)
            return data
        } catch {
            let backup = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            return StoreData()
        }
    }

    private func write(_ data: StoreData) {
        guard let raw = try? Self.encoder.encode(data) else { return }
        try? raw.write(to: fileURL, options: .atomic)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer {
            if fd >= 0 {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }
        return try body()
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

public extension StoreData {
    /// Finds a task by PR number, Linear key, branch, worktree path or UUID prefix.
    func find(_ ref: String) -> Int? {
        let r = ref.trimmingCharacters(in: .whitespaces)
        let number = Int(r.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        let key = LinearKey.find(in: r)
        let path = (r as NSString).standardizingPath
        return tasks.lastIndex { t in
            if let number, t.prNumber == number { return true }
            if let key, t.linearKey == key, number == nil { return true }
            if t.branch == r { return true }
            if let wt = t.worktreePath, wt == path { return true }
            return t.id.uuidString.lowercased().hasPrefix(r.lowercased()) && r.count >= 6
        }
    }
}
