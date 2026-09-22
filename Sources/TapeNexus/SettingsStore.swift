import Foundation
import Combine

/// Persists settings + queue/history as JSON under Application Support.
final class SettingsStore: ObservableObject {
    static let appName = "TapeNexus"

    let supportDir: URL
    private let settingsURL: URL
    private let queueURL: URL

    @Published var settings: AppSettings {
        didSet { schedulePersist() }
    }
    @Published var queue: [DownloadItem] = []
    @Published var history: [DownloadItem] = []
    /// URL → resolved metadata cache so re-copied links don't re-hit the network
    /// with `--simulate` every time. Persisted alongside the queue.
    @Published var metaCache: [String: VideoMeta] = [:]

    private var persistWorkItem: DispatchWorkItem?

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        // One-time rename migration: move the legacy "YTGrabber" app-support dir
        // (old settings/queue/history) to the new "TapeNexus" dir if it exists.
        let newDir = base.appendingPathComponent(Self.appName, isDirectory: true)
        let oldDir = base.appendingPathComponent("YTGrabber", isDirectory: true)
        if !fm.fileExists(atPath: newDir.path) && fm.fileExists(atPath: oldDir.path) {
            try? fm.moveItem(at: oldDir, to: newDir)
        }
        supportDir = newDir
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let binDir = supportDir.appendingPathComponent("bin", isDirectory: true)
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        settingsURL = supportDir.appendingPathComponent("settings.json")
        queueURL = supportDir.appendingPathComponent("queue.json")

        if let s = Self.loadJSON(settingsURL, as: AppSettings.self) {
            settings = s
        } else {
            settings = .default
        }
        if let q = Self.loadJSON(queueURL, as: QueueSnapshot.self) {
            queue = q.queue.filter { $0.status != .downloading && $0.status != .paused }
            history = q.history
            metaCache = q.meta ?? [:]
        }
        ensureDestinationExists()
    }

    static let binURL: URL = {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("yt-dlp")
    }()

    func ensureDestinationExists() {
        try? FileManager.default.createDirectory(atPath: settings.destinationFolder,
                                                 withIntermediateDirectories: true)
    }

    func persistQueue() {
        let snap = QueueSnapshot(queue: queue, history: history, meta: metaCache)
        saveJSON(snap, to: queueURL)
    }

    private func schedulePersist() {
        persistWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.saveJSON(self.settings, to: self.settingsURL)
        }
        persistWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    static func loadJSON<T: Decodable>(_ url: URL, as: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: data)
    }

    private func saveJSON<T: Encodable>(_ value: T, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(value) else { return }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? data.write(to: url, options: .atomic)
        }
    }
}

private struct QueueSnapshot: Codable {
    let queue: [DownloadItem]
    let history: [DownloadItem]
    let meta: [String: VideoMeta]?
}