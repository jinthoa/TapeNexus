import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Shared process-tree signal helpers. yt-dlp and gallery-dl both spawn a
/// Process whose pause/resume/stop is done by signalling its pid tree (the
/// launched binary may fork children, e.g. ffmpeg for merges). The logic is
/// identical for every engine, so it lives here once instead of being copied
/// into each controller.
enum ProcessControl {
    /// Send `sig` to a pid and all its descendants (capped at depth 6 so a
    /// runaway tree can't loop forever). Descendants are discovered via
    /// `pgrep -P`.
    static func signalTree(_ pid: pid_t, _ sig: Int32) {
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

    /// Immediate child pids of `pid`, via `pgrep -P`.
    static func children(of pid: pid_t) -> [pid_t] {
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