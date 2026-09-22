import Foundation

enum DownloadStatus: String, Codable, CaseIterable {
    case resolving, queued, downloading, paused, done, failed, stopped
}

/// Segmented filter for the unified download list (approach A: one page, no
/// sidebar, no separate History). Done/failed/stopped stay in the same list
/// and are revealed by switching filter; "Clear done" removes them.
enum StatusFilter: String, CaseIterable, Identifiable {
    case all, active, done, failed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .active: return "Active"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }
}

extension DownloadStatus {
    /// Broad bucket used by the segmented filter.
    var filterBucket: StatusFilter {
        switch self {
        case .resolving, .queued, .downloading, .paused: return .active
        case .done: return .done
        case .failed, .stopped: return .failed
        }
    }
}

struct DownloadItem: Identifiable, Codable, Hashable {
    var id: UUID
    var url: String
    var title: String
    var uploader: String
    var thumbnailURL: String
    var durationStr: String
    var status: DownloadStatus
    var progress: Double              // 0...1
    var speedStr: String
    var etaStr: String
    var formatDesc: String
    var errorMessage: String
    var downloadedBytes: Int64
    var totalBytes: Int64
    var outputFilePath: String
    var addedAt: Date
    var pausedByUser: Bool

    // transient (not Codable)
    var pid: pid_t = 0

    enum CodingKeys: String, CodingKey {
        case id, url, title, uploader, thumbnailURL, durationStr, status,
             progress, speedStr, etaStr, formatDesc, errorMessage,
             downloadedBytes, totalBytes, outputFilePath, addedAt, pausedByUser
    }

    init(id: UUID = UUID(), url: String, title: String = "", uploader: String = "",
         thumbnailURL: String = "", durationStr: String = "",
         status: DownloadStatus = .queued, progress: Double = 0,
         speedStr: String = "", etaStr: String = "", formatDesc: String = "",
         errorMessage: String = "", downloadedBytes: Int64 = 0, totalBytes: Int64 = 0,
         outputFilePath: String = "", addedAt: Date = Date(), pausedByUser: Bool = false) {
        self.id = id; self.url = url; self.title = title; self.uploader = uploader
        self.thumbnailURL = thumbnailURL; self.durationStr = durationStr
        self.status = status; self.progress = progress; self.speedStr = speedStr
        self.etaStr = etaStr; self.formatDesc = formatDesc
        self.errorMessage = errorMessage; self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes; self.outputFilePath = outputFilePath
        self.addedAt = addedAt; self.pausedByUser = pausedByUser
    }

    var displayTitle: String { title.isEmpty ? url : title }
    var host: String {
        URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
    }
    var byteProgress: String {
        let d = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
        if totalBytes > 0 {
            let t = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "\(d) / \(t)"
        }
        return d.isEmpty ? "—" : d
    }
}

struct AppSettings: Codable, Equatable {
    var destinationFolder: String
    var formatPreset: String          // "best","1080p","720p","audio","custom"
    var customFormat: String          // -f string when preset == custom
    var maxConcurrent: Int
    var autoGrabClipboard: Bool
    var autoStartDownloads: Bool
    var autoUpdateYTDLP: Bool
    var sponsorBlock: Bool
    var embedMetadata: Bool
    var embedSubs: Bool
    var pollIntervalSeconds: Double

    static let formatPresets: [(key: String, label: String, arg: String)] = [
        ("best",   "Best (mp4)",        "bestvideo*+bestaudio/best"),
        ("1080p",  "Up to 1080p",       "bestvideo[height<=1080]+bestaudio/best[height<=1080]"),
        ("720p",   "Up to 720p",        "bestvideo[height<=720]+bestaudio/best[height<=720]"),
        ("audio",  "Audio only (m4a)",  "bestaudio/best"),
        ("custom", "Custom…",           "")
    ]

    static var `default`: AppSettings {
        let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .appendingPathComponent("YT", isDirectory: true).path
            ?? NSHomeDirectory() + "/Downloads/YT"
        return AppSettings(
            destinationFolder: dest,
            formatPreset: "1080p",
            customFormat: "bestvideo*+bestaudio/best",
            maxConcurrent: 2,
            autoGrabClipboard: true,
            autoStartDownloads: false,
            autoUpdateYTDLP: true,
            sponsorBlock: false,
            embedMetadata: true,
            embedSubs: false,
            pollIntervalSeconds: 1.2
        )
    }

    func formatArg() -> String {
        if formatPreset == "custom" { return customFormat.isEmpty ? "bestvideo*+bestaudio/best" : customFormat }
        return Self.formatPresets.first(where: { $0.key == formatPreset })?.arg
            ?? "bestvideo*+bestaudio/best"
    }
    func formatLabel() -> String {
        if formatPreset == "custom" { return "custom: \(customFormat)" }
        return Self.formatPresets.first(where: { $0.key == formatPreset })?.label ?? "Best"
    }
}

struct UpdateStatus: Equatable {
    var currentVersion: String = ""
    var latestVersion: String = ""
    var state: State = .idle
    var message: String = ""

    enum State { case idle, checking, downloading, updating, upToDate, updated, failed }
}