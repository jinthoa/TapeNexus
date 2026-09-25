import Foundation

/// One-click local backup/restore of TapeNexus state — for moving between
/// machines without a cloud account. Packs the four JSON state files in the
/// support directory (library, achievements, settings, queue) into a single
/// inspectable `.json` bundle. Credentials are deliberately excluded: only
/// `sync.local.json` (real Supabase creds) is omitted so a shared backup never
/// leaks auth tokens — RLS is the boundary, but tokens are still secrets.
enum BackupManager {
    /// The state files bundled into a backup (and written back on restore).
    static let fileNames = ["library.json", "achievements.json",
                            "settings.json", "queue.json"]
    private static let bundleVersion = 1

    /// Build the backup bundle as pretty-printed JSON data. Missing files are
    /// recorded as null so a partial restore is still valid.
    static func exportData(supportDir: URL) -> Data? {
        var files: [String: Any] = [:]
        for name in fileNames {
            let u = supportDir.appendingPathComponent(name)
            if let data = try? Data(contentsOf: u),
               let obj = try? JSONSerialization.jsonObject(with: data, options: []) {
                files[name] = obj
            } else {
                files[name] = NSNull()
            }
        }
        let bundle: [String: Any] = [
            "app": "TapeNexus",
            "version": bundleVersion,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "files": files,
        ]
        return try? JSONSerialization.data(withJSONObject: bundle,
                                           options: [.prettyPrinted, .sortedKeys])
    }

    /// Write a backup bundle back into the support directory. Returns the list
    /// of files actually written (skips nulls). Throws on an unreadable bundle
    /// or an empty restore.
    static func importData(_ data: Data, supportDir: URL) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = root["files"] as? [String: Any] else {
            throw BackupError.invalidBundle
        }
        var written: [String] = []
        for name in fileNames {
            guard let obj = files[name], !(obj is NSNull) else { continue }
            let jsonData = try JSONSerialization.data(withJSONObject: obj,
                                                      options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: supportDir.appendingPathComponent(name), options: .atomic)
            written.append(name)
        }
        guard !written.isEmpty else { throw BackupError.emptyBundle }
        return written
    }

    enum BackupError: LocalizedError {
        case invalidBundle, emptyBundle
        var errorDescription: String? {
            switch self {
            case .invalidBundle: return "That file isn't a valid TapeNexus backup."
            case .emptyBundle: return "The backup didn't contain any restorable data."
            }
        }
    }
}