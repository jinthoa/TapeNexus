import Foundation

enum DownloadStatus: String, Codable, CaseIterable {
    case resolving, queued, downloading, paused, done, failed, stopped
}

/// Which bundled engine drives a download. yt-dlp is the default and handles
/// the broad video catalog; gallery-dl is routed in for hosts yt-dlp can't do
/// well — Twitter/X images + the /media tab, and Reddit images/saved posts.
/// Persisted on DownloadItem so a restarted queue re-dispatches correctly.
enum DownloadEngine: String, Codable, CaseIterable {
    case ytDlp
    case galleryDl
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
    /// When the download reached `.done`. Nil until completion. Persisted so the
    /// Library archive has a timestamp even after the queue row is cleared.
    var completedAt: Date? = nil

    // Per-item overrides (v1.0.2). Empty → fall back to global settings.
    var formatPreset: String = ""    // "" | "best" | "1080p" | ... | "custom"
    var customFormat: String = ""    // -f string when preset == "custom"
    var clipStart: String = ""       // free-text timestamp e.g. "1:23" or "83"
    var clipEnd: String = ""

    // v1.0.4: per-item scheduling. nil = start whenever a slot is free.
    var startAt: Date? = nil

    // v1.0.12: auto-retry count for failed downloads. Persisted so a restart
    // doesn't reset the budget (which would retry forever). Reset on success,
    // manual retry, and fresh add.
    var retryCount: Int = 0

    // v1.0.22: which engine drives this download. Defaults to yt-dlp so queues
    // persisted by older builds load unchanged. yt-dlp-specific overrides
    // (formatPreset/customFormat/clipStart/clipEnd) are ignored when galleryDl.
    var engine: DownloadEngine = .ytDlp

    // transient (not Codable)
    var pid: pid_t = 0
    /// True once we've already retried this item without browser cookies after
    /// a cookies-read failure, so we don't loop. Transient — not persisted.
    var cookiesRetried: Bool = false
    /// True while a deferred (delay-staggered) launch is pending for this item,
    /// so pump() doesn't re-select it and inflate the stagger timing. Transient.
    var launchScheduled: Bool = false
    /// When a deferred launch is scheduled to fire, for the "Starting in Ns"
    /// countdown indicator. nil when no deferred launch is pending. Transient.
    var launchAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case id, url, title, uploader, thumbnailURL, durationStr, status,
             progress, speedStr, etaStr, formatDesc, errorMessage,
             downloadedBytes, totalBytes, outputFilePath, addedAt, pausedByUser,
             formatPreset, customFormat, clipStart, clipEnd,
             startAt,
             retryCount,
             completedAt,
             engine
    }

    init(id: UUID = UUID(), url: String, title: String = "", uploader: String = "",
         thumbnailURL: String = "", durationStr: String = "",
         status: DownloadStatus = .queued, progress: Double = 0,
         speedStr: String = "", etaStr: String = "", formatDesc: String = "",
         errorMessage: String = "", downloadedBytes: Int64 = 0, totalBytes: Int64 = 0,
         outputFilePath: String = "", addedAt: Date = Date(), pausedByUser: Bool = false,
         formatPreset: String = "", customFormat: String = "",
         clipStart: String = "", clipEnd: String = "",
         startAt: Date? = nil,
         retryCount: Int = 0,
         completedAt: Date? = nil,
         engine: DownloadEngine = .ytDlp) {
        self.id = id; self.url = url; self.title = title; self.uploader = uploader
        self.thumbnailURL = thumbnailURL; self.durationStr = durationStr
        self.status = status; self.progress = progress; self.speedStr = speedStr
        self.etaStr = etaStr; self.formatDesc = formatDesc
        self.errorMessage = errorMessage; self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes; self.outputFilePath = outputFilePath
        self.addedAt = addedAt; self.pausedByUser = pausedByUser
        self.formatPreset = formatPreset; self.customFormat = customFormat
        self.clipStart = clipStart; self.clipEnd = clipEnd
        self.startAt = startAt
        self.retryCount = retryCount
        self.completedAt = completedAt
        self.engine = engine
    }

    private init(fromCore dec: Decoder) throws {
        let c = try dec.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        uploader = try c.decodeIfPresent(String.self, forKey: .uploader) ?? ""
        thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL) ?? ""
        durationStr = try c.decodeIfPresent(String.self, forKey: .durationStr) ?? ""
        status = try c.decode(DownloadStatus.self, forKey: .status)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        speedStr = try c.decodeIfPresent(String.self, forKey: .speedStr) ?? ""
        etaStr = try c.decodeIfPresent(String.self, forKey: .etaStr) ?? ""
        formatDesc = try c.decodeIfPresent(String.self, forKey: .formatDesc) ?? ""
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage) ?? ""
        downloadedBytes = try c.decodeIfPresent(Int64.self, forKey: .downloadedBytes) ?? 0
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        outputFilePath = try c.decodeIfPresent(String.self, forKey: .outputFilePath) ?? ""
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        pausedByUser = try c.decodeIfPresent(Bool.self, forKey: .pausedByUser) ?? false
        formatPreset = try c.decodeIfPresent(String.self, forKey: .formatPreset) ?? ""
        customFormat = try c.decodeIfPresent(String.self, forKey: .customFormat) ?? ""
        clipStart = try c.decodeIfPresent(String.self, forKey: .clipStart) ?? ""
        clipEnd = try c.decodeIfPresent(String.self, forKey: .clipEnd) ?? ""
        startAt = try c.decodeIfPresent(Date.self, forKey: .startAt)
        retryCount = try c.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        engine = try c.decodeIfPresent(DownloadEngine.self, forKey: .engine) ?? .ytDlp
    }
    init(from decoder: Decoder) throws { try self.init(fromCore: decoder) }

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
    var hasClip: Bool { !clipStart.isEmpty || !clipEnd.isEmpty }
    var hasSchedule: Bool { startAt != nil }
    /// True if a scheduled start time has been reached (or was never set).
    var scheduleReady: Bool {
        guard let s = startAt else { return true }
        return s <= Date()
    }
}

/// One row of `yt-dlp --list-formats` output, parsed for the format preview.
struct FormatInfo: Identifiable, Hashable {
    enum Kind: String { case video, audio, mixed }
    let id: String          // yt-dlp format_id
    let ext: String
    let resolution: String  // e.g. "1920x1080" or "" for audio-only
    let sizeStr: String     // human filesize, e.g. "~1.73GiB" or ""
    let tbr: String         // bitrate, e.g. "1866k" or ""
    let kind: Kind

    var kindLabel: String {
        switch kind {
        case .video: return "video only"
        case .audio: return "audio only"
        case .mixed: return "audio+video"
        }
    }
    var summary: String {
        var parts: [String] = []
        if !resolution.isEmpty { parts.append(resolution) }
        if !ext.isEmpty { parts.append(ext) }
        if !tbr.isEmpty { parts.append(tbr) }
        if parts.isEmpty { return id }
        return parts.joined(separator: " · ")
    }

    /// -f string to pass to yt-dlp for this row. Video-only formats get
    /// bestaudio merged in (yt-dlp falls back to /best otherwise).
    var formatArg: String {
        switch kind {
        case .video: return "\(id)+bestaudio/best"
        case .audio, .mixed: return id
        }
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

    // v1.0.2 additions — all decodeIfPresent so old settings.json upgrades cleanly.
    var cookiesBrowser: String = ""          // "" | "safari" | "chrome" | "firefox" | "edge" | "brave" | "chromium"
    var subtitleLangs: String = "en,.*,auto" // --sub-langs value
    var organizeByHost: Bool = false         // file into <dest>/<extractor>/<title>.<ext>
    var expandPlaylists: Bool = false        // expand a playlist URL into per-video queue items
    var playlistCap: Int = 50                // safety cap on expanded playlist entries
    var notifyOnComplete: Bool = true        // macOS notification when a download finishes/fails
    var menuBarMode: Bool = false            // run as a menu-bar-only app (no Dock icon)
    var quietHoursEnabled: Bool = false      // auto-pause all downloads during a time window
    var quietStart: Int = 23                 // quiet window start hour (0–23)
    var quietEnd: Int = 7                    // quiet window end hour (0–23)
    var downloadDelaySeconds: Int = 0        // seconds to wait between starting each download (0 = off); avoids bursting the source site

    // v1.0.12: auto-retry failed downloads up to a capped number of attempts.
    var autoRetryFailed: Bool = false
    var maxAutoRetries: Int = 3

    // v1.0.15: optional video container conversion via the bundled ffmpeg.
    // remux = --remux-video (fast, no re-encode); transcode = --recode-video
    // (re-encode, slower). The two are mutually exclusive; buildArgs lets
    // transcode win if both are somehow on. Audio presets ignore both.
    var remuxEnabled: Bool = false
    var transcodeEnabled: Bool = false
    var convertFormat: String = "mp4"   // target container for remux/transcode
    // Codec overrides apply ONLY to transcode (re-encode), not remux (which
    // preserves the source codecs). "default" lets ffmpeg pick for the container.
    var transcodeVideoCodec: String = "default"
    var transcodeAudioCodec: String = "default"

    /// Target containers offered for remux/transcode (yt-dlp accepts these for
    /// --remux-video / --recode-video).
    static let convertFormats: [String] = ["mp4", "mkv", "webm", "avi", "mov", "flv"]

    /// Video codecs offered for transcode (ffmpeg encoder names). "default"
    /// omits -c:v so ffmpeg chooses for the target container.
    static let transcodeVideoCodecs: [(key: String, label: String)] = [
        ("default",    "Default"),
        ("libx264",    "H.264"),
        ("libx265",    "H.265 (HEVC)"),
        ("libvpx-vp9", "VP9"),
        ("libaom-av1", "AV1"),
    ]

    /// Audio codecs offered for transcode (ffmpeg encoder names). "default"
    /// omits -c:a so ffmpeg chooses for the target container.
    static let transcodeAudioCodecs: [(key: String, label: String)] = [
        ("default",      "Default"),
        ("aac",          "AAC"),
        ("libopus",      "Opus"),
        ("libmp3lame",   "MP3"),
        ("flac",         "FLAC"),
        ("libvorbis",    "Vorbis"),
    ]

    static let formatPresets: [(key: String, label: String, arg: String)] = [
        ("best",   "Best (mp4)",        "bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo*+bestaudio/best"),
        ("1080p",  "Up to 1080p",       "bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=1080]+bestaudio/best[height<=1080]"),
        ("720p",   "Up to 720p",        "bestvideo[height<=720][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=720]+bestaudio/best[height<=720]"),
        ("audio",  "Audio only (m4a)",  "bestaudio/best"),
        ("mp3",    "Audio only (MP3)",  "bestaudio/best"),
        ("custom", "Custom…",           "")
    ]

    /// Presets that re-encode to a specific audio container via
    /// `--extract-audio --audio-format <ext>`.
    static let audioExtractFormats: [String: String] = ["mp3": "mp3"]

    static let cookieBrowsers: [(key: String, label: String)] = [
        ("",         "None"),
        ("safari",   "Safari"),
        ("chrome",   "Chrome"),
        ("firefox",  "Firefox"),
        ("edge",     "Edge"),
        ("brave",    "Brave"),
        ("chromium", "Chromium"),
    ]

    enum CodingKeys: String, CodingKey {
        case destinationFolder, formatPreset, customFormat, maxConcurrent,
             autoGrabClipboard, autoStartDownloads, autoUpdateYTDLP, sponsorBlock,
             embedMetadata, embedSubs, pollIntervalSeconds,
             cookiesBrowser, subtitleLangs, organizeByHost, expandPlaylists,
             playlistCap, notifyOnComplete, menuBarMode,
             quietHoursEnabled, quietStart, quietEnd,
             downloadDelaySeconds,
             autoRetryFailed, maxAutoRetries,
             remuxEnabled, transcodeEnabled, convertFormat,
             transcodeVideoCodec, transcodeAudioCodec
    }

    init(destinationFolder: String, formatPreset: String, customFormat: String,
         maxConcurrent: Int, autoGrabClipboard: Bool, autoStartDownloads: Bool,
         autoUpdateYTDLP: Bool, sponsorBlock: Bool, embedMetadata: Bool,
         embedSubs: Bool, pollIntervalSeconds: Double,
         cookiesBrowser: String = "", subtitleLangs: String = "en,.*,auto",
         organizeByHost: Bool = false, expandPlaylists: Bool = false,
         playlistCap: Int = 50, notifyOnComplete: Bool = true,
         menuBarMode: Bool = false, quietHoursEnabled: Bool = false,
         quietStart: Int = 23, quietEnd: Int = 7,
         downloadDelaySeconds: Int = 0,
         autoRetryFailed: Bool = false, maxAutoRetries: Int = 3,
         remuxEnabled: Bool = false, transcodeEnabled: Bool = false,
         convertFormat: String = "mp4",
         transcodeVideoCodec: String = "default",
         transcodeAudioCodec: String = "default") {
        self.destinationFolder = destinationFolder
        self.formatPreset = formatPreset; self.customFormat = customFormat
        self.maxConcurrent = maxConcurrent
        self.autoGrabClipboard = autoGrabClipboard
        self.autoStartDownloads = autoStartDownloads
        self.autoUpdateYTDLP = autoUpdateYTDLP
        self.sponsorBlock = sponsorBlock; self.embedMetadata = embedMetadata
        self.embedSubs = embedSubs; self.pollIntervalSeconds = pollIntervalSeconds
        self.cookiesBrowser = cookiesBrowser; self.subtitleLangs = subtitleLangs
        self.organizeByHost = organizeByHost; self.expandPlaylists = expandPlaylists
        self.playlistCap = playlistCap; self.notifyOnComplete = notifyOnComplete
        self.menuBarMode = menuBarMode; self.quietHoursEnabled = quietHoursEnabled
        self.quietStart = quietStart; self.quietEnd = quietEnd
        self.downloadDelaySeconds = downloadDelaySeconds
        self.autoRetryFailed = autoRetryFailed; self.maxAutoRetries = maxAutoRetries
        self.remuxEnabled = remuxEnabled; self.transcodeEnabled = transcodeEnabled
        self.convertFormat = convertFormat
        self.transcodeVideoCodec = transcodeVideoCodec
        self.transcodeAudioCodec = transcodeAudioCodec
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        destinationFolder = try c.decode(String.self, forKey: .destinationFolder)
        formatPreset = try c.decodeIfPresent(String.self, forKey: .formatPreset) ?? "1080p"
        customFormat = try c.decodeIfPresent(String.self, forKey: .customFormat) ?? "bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo*+bestaudio/best"
        maxConcurrent = try c.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? 2
        autoGrabClipboard = try c.decodeIfPresent(Bool.self, forKey: .autoGrabClipboard) ?? true
        autoStartDownloads = try c.decodeIfPresent(Bool.self, forKey: .autoStartDownloads) ?? false
        autoUpdateYTDLP = try c.decodeIfPresent(Bool.self, forKey: .autoUpdateYTDLP) ?? true
        sponsorBlock = try c.decodeIfPresent(Bool.self, forKey: .sponsorBlock) ?? false
        embedMetadata = try c.decodeIfPresent(Bool.self, forKey: .embedMetadata) ?? true
        embedSubs = try c.decodeIfPresent(Bool.self, forKey: .embedSubs) ?? false
        pollIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .pollIntervalSeconds) ?? 1.2
        cookiesBrowser = try c.decodeIfPresent(String.self, forKey: .cookiesBrowser) ?? ""
        subtitleLangs = try c.decodeIfPresent(String.self, forKey: .subtitleLangs) ?? "en,.*,auto"
        organizeByHost = try c.decodeIfPresent(Bool.self, forKey: .organizeByHost) ?? false
        expandPlaylists = try c.decodeIfPresent(Bool.self, forKey: .expandPlaylists) ?? false
        playlistCap = try c.decodeIfPresent(Int.self, forKey: .playlistCap) ?? 50
        notifyOnComplete = try c.decodeIfPresent(Bool.self, forKey: .notifyOnComplete) ?? true
        menuBarMode = try c.decodeIfPresent(Bool.self, forKey: .menuBarMode) ?? false
        quietHoursEnabled = try c.decodeIfPresent(Bool.self, forKey: .quietHoursEnabled) ?? false
        quietStart = try c.decodeIfPresent(Int.self, forKey: .quietStart) ?? 23
        quietEnd = try c.decodeIfPresent(Int.self, forKey: .quietEnd) ?? 7
        downloadDelaySeconds = try c.decodeIfPresent(Int.self, forKey: .downloadDelaySeconds) ?? 0
        autoRetryFailed = try c.decodeIfPresent(Bool.self, forKey: .autoRetryFailed) ?? false
        maxAutoRetries = try c.decodeIfPresent(Int.self, forKey: .maxAutoRetries) ?? 3
        remuxEnabled = try c.decodeIfPresent(Bool.self, forKey: .remuxEnabled) ?? false
        transcodeEnabled = try c.decodeIfPresent(Bool.self, forKey: .transcodeEnabled) ?? false
        convertFormat = try c.decodeIfPresent(String.self, forKey: .convertFormat) ?? "mp4"
        transcodeVideoCodec = try c.decodeIfPresent(String.self, forKey: .transcodeVideoCodec) ?? "default"
        transcodeAudioCodec = try c.decodeIfPresent(String.self, forKey: .transcodeAudioCodec) ?? "default"
    }

    static var `default`: AppSettings {
        let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .appendingPathComponent("YT", isDirectory: true).path
            ?? NSHomeDirectory() + "/Downloads/YT"
        return AppSettings(
            destinationFolder: dest,
            formatPreset: "1080p",
            customFormat: "bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo*+bestaudio/best",
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

    func formatArg() -> String { Self.formatArg(preset: formatPreset, custom: customFormat) }

    /// Shared resolver so a per-item override or the global setting both resolve
    /// through one path. Falls back to "best" if the preset is unknown/empty.
    static func formatArg(preset: String, custom: String) -> String {
        if preset.isEmpty { return "bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo*+bestaudio/best" }
        if preset == "custom" { return custom.isEmpty ? "bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo*+bestaudio/best" : custom }
        return formatPresets.first(where: { $0.key == preset })?.arg
            ?? "bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo*+bestaudio/best"
    }

    static func formatLabel(preset: String, custom: String) -> String {
        if preset.isEmpty { return "" }
        if preset == "custom" { return "custom: \(custom)" }
        return formatPresets.first(where: { $0.key == preset })?.label ?? "Best"
    }

    func formatLabel() -> String { Self.formatLabel(preset: formatPreset, custom: customFormat) }
}

struct UpdateStatus: Equatable {
    var currentVersion: String = ""
    var latestVersion: String = ""
    var state: State = .idle
    var message: String = ""

    enum State { case idle, checking, downloading, updating, upToDate, updated, failed }
}