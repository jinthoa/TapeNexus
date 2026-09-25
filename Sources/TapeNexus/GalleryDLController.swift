import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Resolves and drives the bundled gallery-dl binary — the second download
/// engine, routed in for Twitter/X (images + the /media tab) and Reddit
/// (images, saved posts). Mirrors `YTDLPController`'s surface
/// (`simulate`, `startDownload` with the same callback tuple) so
/// `DownloadManager` can dispatch on `DownloadItem.engine` without caring
/// which engine it talks to.
///
/// gallery-dl's output model differs from yt-dlp: it prints one saved file
/// path per completed file (no byte-level progress stream), and exposes a
/// `--Print "{num} {count}"` hook that fires per file before download. We map
/// those into the same per-file progress fraction the queue UI already
/// consumes. Auth reuses `AppSettings.cookiesBrowser` verbatim — gallery-dl
/// accepts `--cookies-from-browser <name>` with the same browser keys yt-dlp
/// uses (chrome / firefox / safari / …).
final class GalleryDLController: @unchecked Sendable {
    let store: SettingsStore

    init(store: SettingsStore) { self.store = store }

    /// Application Support copy (writable), falling back to the binary shipped
    /// inside the app bundle. Mirrors `YTDLPController.binaryURL`.
    var binaryURL: URL {
        let asCopy = SettingsStore.galleryDlBinURL
        if FileManager.default.isExecutableFile(atPath: asCopy.path) { return asCopy }
        if let bundle = Bundle.main.url(forResource: "gallery-dl", withExtension: nil, subdirectory: "bin"),
           FileManager.default.isExecutableFile(atPath: bundle.path) {
            try? FileManager.default.createDirectory(at: asCopy.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: asCopy)
            try? FileManager.default.copyItem(at: bundle, to: asCopy)
            chmod(asCopy.path, 0o755)
            return asCopy
        }
        return asCopy // may not exist yet; commands fail gracefully
    }

    /// The bin dir that holds yt-dlp's seeded ffmpeg/ffprobe, so gallery-dl can
    /// shell out to the bundled ffmpeg if it ever needs to (it doesn't for
    /// Twitter/Reddit images+video, but kept for parity + future extractors).
    private var binDir: URL { SettingsStore.binURL.deletingLastPathComponent() }

    func ensureBinary() { _ = binaryURL }

    /// Mutable progress state shared between the escaping stdout/stderr readers
    /// and the completion handler of one download.
    final class State {
        var total: Int = 0
        var done: Int = 0
        var bytes: Int64 = 0
        var errLine: String = ""
    }

    // MARK: - Sync run (version / simulate)

    @discardableResult
    func runSync(_ args: [String], timeout: TimeInterval = 60) -> (code: Int, out: String, err: String) {
        let p = Process()
        p.executableURL = binaryURL
        p.arguments = args
        // Put the bundled bin dir first on PATH so a gallery-dl ffmpeg shelling
        // finds the seeded ffmpeg/ffprobe.
        var env = ProcessInfo.processInfo.environment
        let binPath = binDir.path
        env["PATH"] = binPath + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
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

    // MARK: - Simulate (metadata probe)

    /// Probes a URL with `--simulate -j` (dump-json, no download) and returns
    /// metadata for the queue row, or a failure classification. gallery-dl
    /// emits a JSON array of `[index, dict]` / `[index, url, dict]` entries;
    /// the first dict without a `filename` is the tweet/post root, dicts with
    /// `filename` are the individual media files.
    func simulate(_ url: String) -> SimulateResult {
        var args = ["-j", "--simulate", "--no-warnings"]
        if let cb = cookiesSpec() { args += ["--cookies-from-browser", cb] }
        args.append(url)
        let r = runSync(args, timeout: 90)
        // gallery-dl exits non-zero + an error dict in the JSON (or stderr) on
        // failure. Distinguish "host not recognised" (silent skip) from a
        // recognised-but-erroring link (keep + surface).
        let combined = r.err + r.out
        if r.code != 0 {
            if combined.contains("Unsupported URL") || combined.contains("No suitable extractor") || combined.contains("unsupported URL") {
                return .unsupported
            }
            let msg = firstErrLine(combined) ?? "Could not verify link (gallery-dl exited \(r.code))"
            return .failed(msg)
        }
        guard let data = r.out.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) else {
            return .failed("No metadata returned")
        }
        let dicts = flatDicts(top)
        if dicts.isEmpty {
            return .failed("No metadata returned")
        }
        // An explicit error entry from the extractor (e.g. login required /
        // blocked) surfaces as a dict with an "error" key.
        if let errDict = dicts.first(where: { $0["error"] != nil }) {
            let msg = (errDict["message"] as? String)
                ?? (errDict["error"] as? String)
                ?? "Extraction error"
            if msg.lowercased().contains("unsupported") { return .unsupported }
            return .failed(msg)
        }
        let root = dicts.first(where: { $0["filename"] == nil }) ?? dicts[0]
        let files = dicts.filter { $0["filename"] != nil }
        let content = (root["content"] as? String ?? root["title"] as? String ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = content.isEmpty ? url : String(content.prefix(100))
        let user = root["user"] as? [String: Any]
        let uploader = (user?["name"] as? String) ?? (user?["nick"] as? String) ?? ""
        // No reliable media URL is exposed in dump-json for Twitter video, so
        // leave the thumbnail empty — the queue row renders fine without it.
        let durationStr = durationLabel(files: files)
        return .success(VideoMeta(title: title, uploader: uploader,
                                  thumbnail: "", durationStr: durationStr))
    }

    /// "0:05" for a single video, "N files" for a multi-file post, else "".
    private func durationLabel(files: [[String: Any]]) -> String {
        let count = (files.first?["count"] as? Int) ?? files.count
        if let dur = files.compactMap({ $0["duration"] as? Double }).first(where: { $0 > 0 }) {
            return formatSeconds(dur)
        }
        if count > 1 { return "\(count) files" }
        return ""
    }

    private func formatSeconds(_ sec: Double) -> String {
        let s = Int(sec)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm%02ds", s/60, s%60) }
        return String(format: "%dh%02dm", s/3600, (s%3600)/60)
    }

    /// Flatten gallery-dl's dump-json array-of-arrays into just the metadata
    /// dicts (dropping the leading index int and any url string).
    private func flatDicts(_ top: Any) -> [[String: Any]] {
        guard let arr = top as? [Any] else { return [] }
        var out: [[String: Any]] = []
        for elem in arr {
            if let sub = elem as? [Any] {
                for x in sub {
                    if let d = x as? [String: Any] { out.append(d) }
                }
            } else if let d = elem as? [String: Any] {
                out.append(d)
            }
        }
        return out
    }

    private func firstErrLine(_ combined: String) -> String? {
        let lines = combined.split(separator: "\n").map(String.init)
        let interested = lines.first {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && (t.contains("error") || t.contains("ERROR") || t.contains("["))
        }
        return interested?.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Download

    /// Spawns a gallery-dl download for `item`. Returns the gallery-dl pid
    /// (0 on failure). Callback signature is identical to
    /// `YTDLPController.startDownload` so DownloadManager treats both engines
    /// uniformly. Per-file progress is derived from gallery-dl's
    /// `--Print "{num} {count}"` (file counter) + the saved-path lines it
    /// prints as each file completes.
    func startDownload(item: DownloadItem,
                       settings: AppSettings,
                       suppressCookies: Bool = false,
                       onProgress: @escaping (Double, String, String, Int64, Int64) -> Void,
                       onFilePath: @escaping (String) -> Void,
                       onPartFile: @escaping (String) -> Void,
                       onLog: @escaping (String) -> Void,
                       onComplete: @escaping (Bool, String) -> Void) -> pid_t {
        let p = Process()
        let gArgs = buildArgs(item: item, settings: settings, suppressCookies: suppressCookies)
        p.executableURL = binaryURL
        p.arguments = gArgs
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = binDir.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        // Shared mutable progress state for the escaping line readers + the
        // completion handler.
        let st = State()

        do {
            try p.run()
        } catch {
            onComplete(false, "Failed to launch gallery-dl: \(error.localizedDescription)")
            return 0
        }
        let pid = p.processIdentifier

        // hop callbacks to main (state mutations happen there)
        let mainProgress: (Double, String, String, Int64, Int64) -> Void = { pr, s, e, dl, t in
            DispatchQueue.main.async { onProgress(pr, s, e, dl, t) }
        }
        let mainFile: (String) -> Void = { path in
            DispatchQueue.main.async { onFilePath(path) }
        }
        let mainLog: (String) -> Void = { line in
            DispatchQueue.main.async { onLog(line) }
        }

        readLines(outPipe.fileHandleForReading) { line in
            self.parseStdout(line, st: st,
                             onProgress: mainProgress,
                             onFilePath: mainFile,
                             onLog: mainLog)
        }
        readLines(errPipe.fileHandleForReading) { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return }
            // Skip the noisy cookies-extracted info banner; keep real errors.
            if t.contains("[error]") || t.hasPrefix("gallery-dl: error") || t.contains("ERROR") {
                st.errLine = t
            }
            if !t.hasPrefix("[cookies]") {
                mainLog(t)
            }
        }

        DispatchQueue.global().async {
            p.waitUntilExit()
            let code = Int(p.terminationStatus)
            Thread.sleep(forTimeInterval: 0.1)
            let msg = st.errLine.isEmpty
                ? "gallery-dl exited with code \(code)"
                : st.errLine
            DispatchQueue.main.async {
                onComplete(code == 0, code == 0 ? "" : msg)
            }
        }
        return pid
    }

    private func buildArgs(item: DownloadItem, settings: AppSettings, suppressCookies: Bool) -> [String] {
        let dest = settings.destinationFolder
        var args: [String] = [
            "-d", dest,
            "--no-mtime",
            // Per-file counter at the 'prepare' event, so we can map to a
            // progress fraction. Saved file paths are printed to stdout by
            // default as each file completes.
            "--Print", "GPREP {num} {count}",
        ]
        if let cb = cookiesSpec(), !suppressCookies {
            args += ["--cookies-from-browser", cb]
        }
        args.append(item.url)
        return args
    }

    /// The cookies browser spec from settings, or nil when cookies are off.
    /// gallery-dl accepts the same browser keys yt-dlp uses.
    private func cookiesSpec() -> String? {
        let cb = store.settings.cookiesBrowser
        return cb.isEmpty ? nil : cb
    }

    private func parseStdout(_ line: String,
                             st: State,
                             onProgress: (Double, String, String, Int64, Int64) -> Void,
                             onFilePath: (String) -> Void,
                             onLog: (String) -> Void) {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }
        // "GPREP <num> <count>" — file counter before each download. Captures
        // the total file count up front and nudges progress to (num-1)/total.
        if t.hasPrefix("GPREP ") {
            let parts = t.dropFirst("GPREP ".count).split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 2, let n = Int(parts[0]), let c = Int(parts[1]) {
                if c > 0 { st.total = c }
                let frac = st.total > 0 ? Double(n - 1) / Double(st.total) : 0
                onProgress(max(0, min(0.999, frac)), "", "", st.bytes, 0)
            }
            return
        }
        // A saved file path (absolute) — a file just finished. Advance
        // progress, surface the path for Library archiving, accumulate bytes.
        if t.hasPrefix("/") {
            st.done += 1
            if st.total < st.done { st.total = st.done }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: t)[.size] as? Int64) ?? 0
            st.bytes += bytes
            let frac = Double(st.done) / Double(st.total)
            onProgress(min(1.0, frac), "", "", st.bytes, 0)
            onFilePath(t)
            return
        }
        onLog(t)
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
}