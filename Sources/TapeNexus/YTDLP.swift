import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct VideoMeta: Codable {
    var title: String
    var uploader: String
    var thumbnail: String
    var durationStr: String
}

/// Outcome of a `--simulate` metadata probe.
enum SimulateResult {
    case success(VideoMeta)
    /// yt-dlp doesn't recognise the host at all → silently drop (clipboard auto-grab).
    case unsupported
    /// yt-dlp recognised the link but couldn't resolve it (network, age-restricted,
    /// format error, timeout, …) → keep the row so the user can retry, show the error.
    case failed(String)
}

/// Resolves and drives the bundled/copied yt-dlp binary.
final class YTDLPController: @unchecked Sendable {
    let store: SettingsStore

    init(store: SettingsStore) { self.store = store }

    /// Diagnostic counter: how many DJ progress lines we've parsed this run.
    private var _djSeen = 0

    /// Application Support copy (writable, auto-updated), falling back to the
    /// binary shipped inside the app bundle.
    var binaryURL: URL {
        let asCopy = SettingsStore.binURL
        if FileManager.default.isExecutableFile(atPath: asCopy.path) { return asCopy }
        // fall back to bundled binary
        if let bundle = Bundle.main.url(forResource: "yt-dlp", withExtension: nil, subdirectory: "bin"),
           FileManager.default.isExecutableFile(atPath: bundle.path) {
            // seed the AS copy so the updater has a writable home
            try? FileManager.default.createDirectory(at: asCopy.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: asCopy)
            try? FileManager.default.copyItem(at: bundle, to: asCopy)
            chmod(asCopy.path, 0o755)
            return asCopy
        }
        return asCopy // may not exist yet; commands will fail gracefully
    }

    /// Directory in Application Support that holds yt-dlp + ffmpeg + ffprobe.
    /// Seeds ffmpeg/ffprobe from the app bundle on first use so yt-dlp can merge
    /// bestvideo+bestaudio into a single file. Pass to yt-dlp via --ffmpeg-location.
    var ffmpegLocation: URL {
        let dir = SettingsStore.binURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["ffmpeg", "ffprobe"] {
            let dest = dir.appendingPathComponent(name)
            let bundled = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "bin")
            let bundledOK = bundled.flatMap {
                FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil
            }
            // Seed when missing; also replace a stale wrong-arch copy (e.g. an
            // x86_64 ffmpeg left by an older build on an arm64 host, which would
            // otherwise keep running under Rosetta and trigger the macOS
            // "Intel app support ending" warning).
            let needsSeed = !FileManager.default.isExecutableFile(atPath: dest.path)
                || (hostIsArm64 && !Self.isArm64Binary(at: dest.path))
            if needsSeed, let b = bundledOK {
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: b, to: dest)
                chmod(dest.path, 0o755)
            }
        }
        return dir
    }

    private var hostIsArm64: Bool {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) { ptr -> Bool in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<utsname>.size) {
                String(cString: $0) == "arm64"
            }
        }
    }

    /// True if the Mach-O at `path` is a thin arm64 or universal (arm64-slice)
    /// binary. Used to detect a stale x86_64 ffmpeg/ffprobe that needs replacing.
    private static func isArm64Binary(at path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 8)
        guard head.count >= 8 else { return false }
        return head.withUnsafeBytes { raw -> Bool in
            let magic = raw.load(as: UInt32.self)
            if magic == 0xFEEDFACF {              // MH_MAGIC_64 (thin 64-bit Mach-O)
                let cputype = raw.load(fromByteOffset: 4, as: Int32.self)
                return cputype == 0x0100000C      // CPU_TYPE_ARM64
            }
            if magic == 0xCAFEBABE {              // universal — has an arm64 slice, fine
                return true
            }
            return false
        }
    }

    func ensureBinary() { _ = binaryURL; _ = ffmpegLocation }

    // MARK: - Debug log (progress diagnostics)

    /// Appends a timestamped line to ~/Library/Logs/TapeNexus/pty.log. Used to
    /// diagnose why live progress does/doesn't stream in the real GUI app.
    private static let debugLogURL: URL? = {
        guard let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = lib.appendingPathComponent("Logs/TapeNexus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pty.log")
    }()
    private static func debugLog(_ msg: String) {
        guard let url = debugLogURL else { return }
        let line = "\(Date().ISO8601Format()) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let fh = try? FileHandle(forWritingTo: url) {
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
            try? fh.close()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Version

    @discardableResult
    func runSync(_ args: [String], timeout: TimeInterval = 60) -> (code: Int, out: String, err: String) {
        let p = Process()
        p.executableURL = binaryURL
        p.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        // timeout
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) { [weak p] in
            if p?.isRunning == true { p?.terminate() }
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (Int(p.terminationStatus),
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "")
    }

    func currentVersion() -> String {
        let r = runSync(["--version"], timeout: 15)
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? ""
    }

    // MARK: - Simulate (supports check + metadata)

    /// Probes a URL with `--simulate` and returns metadata, or a failure classification.
    func simulate(_ url: String) -> SimulateResult {
        let sep = "\u{1F}" // unlikely delimiter
        let tmpl = "META\(sep)%(title)s\(sep)%(uploader)s\(sep)%(thumbnail)s\(sep)%(duration_string)s"
        // Default yt-dlp extraction. (Tried player_client=web_safari for speed, but it
        // hard-fails "Requested format is not available" on some videos during
        // --simulate, which would make the app silently drop those links.)
        let r = runSync([
            "--simulate", "--no-warnings", "--no-playlist",
            "--print", tmpl, url
        ], timeout: 25)
        if r.code == 0 {
            let line = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.components(separatedBy: sep)
            guard parts.count >= 5, line.hasPrefix("META") else {
                return .failed("No metadata returned")
            }
            return .success(VideoMeta(title: parts[1], uploader: parts[2],
                                      thumbnail: parts[3], durationStr: parts[4]))
        }
        // Failure: distinguish "host not recognised" (genuine skip) from a
        // recognised-but-erroring link (keep + surface the error so it can be retried).
        let combined = (r.err + r.out)
        if combined.contains("Unsupported URL") {
            return .unsupported
        }
        let lines = combined.split(separator: "\n").map(String.init)
        let firstErr = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        let trimmed = firstErr.trimmingCharacters(in: .whitespaces)
        return .failed(trimmed.isEmpty ? "Could not verify link (yt-dlp exited \(r.code))" : trimmed)
    }

    /// Flat-playlist probe: returns the entry URLs of a playlist link, or nil if
    /// the URL isn't a playlist / can't be expanded. Capped at `cap` entries.
    func simulatePlaylist(_ url: String, cap: Int) -> [String]? {
        let r = runSync([
            "--flat-playlist", "--no-warnings", "--no-playlist-reverse",
            "--print", "%(url)s", url
        ], timeout: 45)
        guard r.code == 0 else { return nil }
        let entries = r.out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.hasPrefix("http") }
        return entries.isEmpty ? nil : Array(entries.prefix(max(1, cap)))
    }

    // MARK: - Download

    /// Spawns a download for `item`. Returns the yt-dlp pid (0 on failure).
    /// Calls callbacks on a private background queue (caller hops to main).
    func startDownload(item: DownloadItem,
                       settings: AppSettings,
                       onProgress: @escaping (Double, String, String, Int64, Int64) -> Void,
                       onFilePath: @escaping (String) -> Void,
                       onLog: @escaping (String) -> Void,
                       onComplete: @escaping (Bool, String) -> Void) -> pid_t {
        let p = Process()
        // yt-dlp emits --progress-template lines only when progress output is
        // ENABLED. `--progress` is on by default for TTYs but OFF for a piped
        // stdout, and --progress-template only *formats* the progress — it does
        // not turn it on. So without --progress a piped yt-dlp prints zero `DJ`
        // lines the whole transfer (the UI sits at "preparing" then jumps to
        // done). Passing --progress (see buildArgs) makes the `DJ %(progress)j`
        // lines stream incrementally on a plain Pipe — no PTY needed.
        //
        // History of the wrong fixes: we tried wrapping yt-dlp in
        // `/usr/bin/script` for a PTY, but `script` calls tcgetattr on its own
        // stdout and fails "Operation not supported on socket" when that's a
        // Pipe, so it relayed nothing. A DIY posix_openpt PTY wired via
        // FileHandle(fileDescriptor:) never connected in the GUI app either
        // (master read 0 bytes). The real cause was always the missing
        // --progress flag — verified by a raw-pipe run that streamed 632 DJ
        // lines over a single short download.
        let ytArgs = buildArgs(item: item, settings: settings)
        p.executableURL = binaryURL
        p.arguments = ytArgs
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        Self.debugLog("START yt-dlp url=\(item.url)")

        do {
            try p.run()
        } catch {
            onComplete(false, "Failed to launch yt-dlp: \(error.localizedDescription)")
            return 0
        }
        let pid = p.processIdentifier

        // hop all callbacks to the main thread (state mutations happen there)
        let mainProgress: (Double, String, String, Int64, Int64) -> Void = { p, s, e, dl, t in
            DispatchQueue.main.async { onProgress(p, s, e, dl, t) }
        }
        let mainFile: (String) -> Void = { path in
            DispatchQueue.main.async { onFilePath(path) }
        }
        let mainLog: (String) -> Void = { line in
            DispatchQueue.main.async { onLog(line) }
        }

        // stdout: yt-dlp's --print (FILEPATH:) and --progress-template (DJ/PJ)
        // lines, newline-separated via --newline. parseStdout trims any \r.
        readLines(outPipe.fileHandleForReading) { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("DJ ") {
                self._djSeen += 1
                if self._djSeen <= 3 { Self.debugLog("DJ#\(self._djSeen) \(t.prefix(70))") }
            }
            self.parseStdout(line,
                             onProgress: mainProgress,
                             onFilePath: mainFile,
                             onLog: mainLog)
        }
        readLines(errPipe.fileHandleForReading) { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let isProgressBar = t.contains("% of") && t.contains("ETA")
            if !t.isEmpty && !isProgressBar { mainLog(t) }
        }

        DispatchQueue.global().async {
            p.waitUntilExit()
            let code = Int(p.terminationStatus)
            Thread.sleep(forTimeInterval: 0.1) // let FILEPATH line flush
            DispatchQueue.main.async {
                onComplete(code == 0, code == 0 ? "" : "yt-dlp exited with code \(code)")
            }
        }
        return pid
    }

    private func buildArgs(item: DownloadItem, settings: AppSettings) -> [String] {
        let dest = settings.destinationFolder
        // Per-item format override falls back to the global setting.
        let preset = item.formatPreset.isEmpty ? settings.formatPreset : item.formatPreset
        let custom = item.formatPreset.isEmpty ? settings.customFormat : item.customFormat
        // Per-host organization files into <dest>/<extractor>/<title>.<ext>
        // (e.g. YouTube/, Vimeo/) instead of a flat dump.
        let outTemplate = settings.organizeByHost
            ? "\(dest)/%(extractor)s/%(title)s.%(ext)s"
            : "\(dest)/%(title)s.%(ext)s"
        var args: [String] = [
            "--newline",
            // --progress turns progress output ON for a piped stdout (it's on
            // by default only for TTYs). Without it, --progress-template below
            // formats progress that is never emitted → zero DJ lines. This is
            // the single flag that makes live progress stream to the UI.
            "--progress",
            "--no-playlist",
            "--no-mtime",
            "--ffmpeg-location", ffmpegLocation.path,
            "-f", AppSettings.formatArg(preset: preset, custom: custom),
            "-o", outTemplate,
            "--progress-template", "download:DJ %(progress)j",
            "--progress-template", "postprocess:PJ %(progress)j",
            "--print", "after_move:FILEPATH:%(filepath)s",
        ]
        // Auth: read cookies from a browser profile so age-restricted /
        // members-only / login-gated content can be downloaded.
        if !settings.cookiesBrowser.isEmpty {
            args += ["--cookies-from-browser", settings.cookiesBrowser]
        }
        // Time-range clip. yt-dlp's --download-sections takes "*START-END";
        // one-sided ranges use 0 / inf. --force-keyframes-at-cuts keeps cuts
        // accurate (re-encodes at boundaries).
        if item.hasClip {
            let start = item.clipStart.isEmpty ? "0" : item.clipStart
            let section: String
            if item.clipEnd.isEmpty { section = "*\(start)-inf" }
            else if item.clipStart.isEmpty { section = "*0-\(item.clipEnd)" }
            else { section = "*\(start)-\(item.clipEnd)" }
            args += ["--download-sections", section, "--force-keyframes-at-cuts"]
        }
        if settings.sponsorBlock {
            args += ["--sponsorblock-remove", "default"]
        }
        if settings.embedMetadata {
            args += ["--embed-metadata"]
        }
        if settings.embedSubs {
            let langs = settings.subtitleLangs.isEmpty ? "en,.*,auto" : settings.subtitleLangs
            args += ["--write-subs", "--embed-subs", "--sub-langs", langs]
        }
        args.append(item.url)
        return args
    }

    private func parseStdout(_ line: String,
                             onProgress: (Double, String, String, Int64, Int64) -> Void,
                             onFilePath: (String) -> Void,
                             onLog: (String) -> Void) {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }
        if t.hasPrefix("DJ ") || t.hasPrefix("PJ ") {
            let tag = t.prefix(2)
            let json = String(t.dropFirst(3))
            if let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // yt-dlp's %(progress)j exposes "_percent" (0...100), not "percentage".
                // Fall back to deriving it from byte counts for robustness.
                let pct = (obj["_percent"] as? Double)
                    ?? (obj["percentage"] as? Double)
                    ?? 0
                let downloaded = (obj["downloaded_bytes"] as? Int64)
                    ?? (obj["downloaded_bytes"] as? Double).map(Int64.init) ?? 0
                let total = (obj["total_bytes"] as? Int64)
                    ?? (obj["total_bytes"] as? Double).map(Int64.init)
                    ?? (obj["total_bytes_estimate"] as? Double).map(Int64.init) ?? 0
                let speed = obj["speed"] as? Double ?? 0
                let eta = obj["eta"] as? Double ?? 0
                let speedStr = speed > 0 ? formatSpeed(speed) : ""
                let etaStr = eta > 0 ? formatETA(eta) : ""
                var norm: Double = 0
                if pct > 0 {
                    norm = pct / 100.0
                } else if total > 0 {
                    norm = Double(downloaded) / Double(total)
                }
                _ = tag
                onProgress(norm, speedStr, etaStr, downloaded, total)
            }
            return
        }
        if t.hasPrefix("FILEPATH:") {
            let path = String(t.dropFirst("FILEPATH:".count)).trimmingCharacters(in: .whitespaces)
            onFilePath(path)
            return
        }
        onLog(t)
    }

    private func formatSpeed(_ bps: Double) -> String {
        let units = ["B/s","KB/s","MB/s","GB/s"]
        var v = bps; var i = 0
        while v > 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: "%.1f %@", v, units[i])
    }
    private func formatETA(_ sec: Double) -> String {
        let s = Int(sec)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm%02ds", s/60, s%60) }
        return String(format: "%dh%02dm", s/3600, (s%3600)/60)
    }

    // MARK: - Line reader

    private func readLines(_ handle: FileHandle, onLine: @escaping (String) -> Void) {
        DispatchQueue.global().async {
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.prefix(upTo: nl)
                    if let s = String(data: lineData, encoding: .utf8) { onLine(s) }
                    buffer = buffer.advanced(by: lineData.count + 1)
                }
            }
            if !buffer.isEmpty, let s = String(data: buffer, encoding: .utf8) { onLine(s) }
        }
    }

    // MARK: - Process-tree signals (pause / resume / stop)

    func signalTree(_ pid: pid_t, _ sig: Int32) {
        guard pid > 0 else { return }
        var all: [pid_t] = [pid]
        var frontier: [pid_t] = [pid]
        var depth = 0
        while !frontier.isEmpty && depth < 6 {
            var next: [pid_t] = []
            for p in frontier {
                next.append(contentsOf: children(of: p))
            }
            all.append(contentsOf: next)
            frontier = next
            depth += 1
        }
        for p in all { kill(p, sig) }
    }

    private func children(of pid: pid_t) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(data: data, encoding: .utf8) ?? ""
        return s.split(whereSeparator: { $0.isWhitespace }).compactMap { pid_t($0) }
    }
}