import AppKit
import Foundation

/// Polls the system pasteboard for new http(s) URLs and reports candidates.
final class ClipboardMonitor {
    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int = 0
    private var seenURLs: Set<String> = []
    private let queue = DispatchQueue(label: "tapenexus.clipboard")
    var enabled: Bool = true
    var pollInterval: TimeInterval = 1.2
    var onCandidate: ((String) -> Void)?

    func start() {
        stop()
        lastChangeCount = NSPasteboard.general.changeCount
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func tick() {
        guard enabled else { return }
        let pb = NSPasteboard.general
        let cc = pb.changeCount
        guard cc != lastChangeCount else { return }
        lastChangeCount = cc
        guard let s = pb.string(forType: .string) else { return }
        let urls = SupportedURLs.extractURLs(from: s)
        for u in urls {
            let cleaned = u.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            guard !seenURLs.contains(cleaned), SupportedURLs.looksSupported(cleaned) else { continue }
            seenURLs.insert(cleaned)
            // keep the set bounded
            if seenURLs.count > 200 { seenURLs.removeFirst() }
            DispatchQueue.main.async { self.onCandidate?(cleaned) }
        }
    }

    /// allow re-detecting a URL that was removed then re-copied
    func forget(_ url: String) { seenURLs.remove(url) }
}