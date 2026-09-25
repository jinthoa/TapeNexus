import Foundation

/// Post-download tools that run the bundled ffmpeg on a Library file: extract
/// audio, transcode to MP4, and trim a clip. ffmpeg is the same binary yt-dlp
/// uses for merging bestvideo+bestaudio, so no new dependency is shipped — just
/// `state.yt.ffmpegLocation`. All work runs off the main thread; the completion
/// is delivered on main.
enum MediaTools {
    /// Run `ffmpeg <args>` on a background queue. `args` is the full argument
    /// list (including `-i input` and the output path). Completion gets the
    /// output path on success, nil on failure.
    static func run(ffmpeg: URL, args: [String], completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = ffmpeg
            p.arguments = ["-y"] + args
            p.standardOutput = FileHandle()
            p.standardError = FileHandle()
            do {
                try p.run()
                p.waitUntilExit()
                DispatchQueue.main.async { completion(p.terminationStatus == 0) }
            } catch {
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    /// A non-clobbering output path beside the input: `<name><suffix>.<ext>`,
    /// `-2`, `-3`, … as needed.
    static func outputURL(for input: URL, suffix: String, ext: String) -> URL {
        let dir = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent("\(base)\(suffix).\(ext)")
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)\(suffix)-\(i).\(ext)")
            i += 1
        }
        return candidate
    }

    // MARK: Recipes — each returns (args, outputURL) for a given input.

    static func extractAudioMP3(_ input: URL) -> (args: [String], out: URL) {
        let out = outputURL(for: input, suffix: "-audio", ext: "mp3")
        return (["-i", input.path, "-vn", "-c:a", "libmp3lame", "-q:a", "2", out.path], out)
    }

    static func extractAudioAAC(_ input: URL) -> (args: [String], out: URL) {
        let out = outputURL(for: input, suffix: "-audio", ext: "m4a")
        return (["-i", input.path, "-vn", "-c:a", "aac", "-b:a", "192k", out.path], out)
    }

    static func transcodeMP4(_ input: URL) -> (args: [String], out: URL) {
        let out = outputURL(for: input, suffix: "-mp4", ext: "mp4")
        return (["-i", input.path, "-c:v", "libx264", "-preset", "veryfast",
                 "-c:a", "aac", out.path], out)
    }

    /// Trim a clip. Re-encodes (rather than `-c copy`) so the cut is frame-
    /// accurate across containers; `veryfast` keeps it quick.
    static func trim(_ input: URL, start: String, end: String) -> (args: [String], out: URL) {
        let out = outputURL(for: input, suffix: "-clip", ext: "mp4")
        return (["-ss", start, "-to", end, "-i", input.path,
                 "-c:v", "libx264", "-preset", "veryfast", "-c:a", "aac", out.path], out)
    }
}