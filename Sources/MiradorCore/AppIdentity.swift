import Foundation

/// Names the app is known by on disk.
public enum AppIdentity {
    public static let bundleID = "dev.mirador.app"
    public static let folderName = "Mirador"

    /// `<base>/Mirador`, created if needed.
    static func folder(in base: URL) -> URL {
        let url = base.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
