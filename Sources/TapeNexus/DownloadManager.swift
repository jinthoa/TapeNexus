import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Owns the lifecycle of running downloads: concurrency limit, and the
/// pause/resume/stop/retry/clear/delete operations.
@MainActor
final class DownloadManager {
    weak var state: AppState?
    let yt: YTDLPController
    private let bgQueue = DispatchQueue(label: "tapenexus.downloads", qos: .userInitiated)

    init(yt: YTDLPController) { self.yt = yt }

    private func settings() -> AppSettings { state?.store.settings ?? .default }

    /// Called whenever queue changes; starts queued items up to the limit.
    func pump() {
        guard let state = state else { return }
        let running = state.items.filter { $0.status == .downloading }.count
        let limit = settings().maxConcurrent
        let slots = max(0, limit - running)
        guard slots > 0 else { return }
        let toStart = state.items.filter { $0.status == .queued }.prefix(slots)
        for item in toStart {
            start(item)
        }
    }

    func start(_ item: DownloadItem) {
        guard let state = state else { return }
        state.update(item.id) { $0.status = .downloading; $0.progress = 0; $0.speedStr = ""; $0.etaStr = ""; $0.errorMessage = "" }
        let s = settings()
        let id = item.id
        let pid = yt.startDownload(item: item, settings: s,
            onProgress: { [weak state] p, speed, eta, dl, tot in
                state?.update(id) {
                    $0.progress = p; $0.speedStr = speed; $0.etaStr = eta
                    $0.downloadedBytes = dl; $0.totalBytes = tot
                }
            },
            onFilePath: { [weak state] path in
                state?.update(id) { $0.outputFilePath = path }
            },
            onLog: { [weak state] log in
                // stash last log line as message context for failed items
                state?.appendLog(id, line: log)
            },
            onComplete: { [weak self, weak state] ok, err in
                guard let self = self, let state = state else { return }
                state.update(id) {
                    if ok {
                        $0.status = .done; $0.progress = 1; $0.errorMessage = ""
                    } else {
                        // don't override a user-driven stopped/paused state
                        if $0.status == .downloading {
                            $0.status = .failed; $0.errorMessage = err
                        }
                    }
                    $0.pid = 0
                }
                if ok { state.persist() }
                self.pump()
            })
        if pid > 0 {
            state.update(item.id) { $0.pid = pid }
        }
    }

    // MARK: - Controls

    func pause(_ id: UUID) {
        guard let state = state, let item = state.item(id) else { return }
        guard item.status == .downloading else { return }
        yt.signalTree(item.pid, SIGSTOP)
        state.update(id) { $0.status = .paused; $0.pausedByUser = true }
        state.persist()
    }

    func resume(_ id: UUID) {
        guard let state = state, let item = state.item(id) else { return }
        guard item.status == .paused else { return }
        yt.signalTree(item.pid, SIGCONT)
        state.update(id) { $0.status = .downloading; $0.pausedByUser = false }
    }

    func stop(_ id: UUID) {
        guard let state = state, let item = state.item(id) else { return }
        guard item.status == .downloading || item.status == .paused else { return }
        yt.signalTree(item.pid, SIGTERM)
        // escalate to SIGKILL after grace (capture only Sendable bits)
        let pid = item.pid
        let ytRef = yt
        bgQueue.asyncAfter(deadline: .now() + 3) {
            ytRef.signalTree(pid, SIGKILL)
        }
        state.update(id) { $0.status = .stopped; $0.pid = 0 }
        state.persist()
    }

    func retry(_ id: UUID) {
        guard let state = state, let item = state.item(id) else { return }
        if item.status == .downloading || item.status == .paused { stop(id) }
        state.update(id) {
            $0.status = .queued; $0.progress = 0; $0.errorMessage = ""
            $0.speedStr = ""; $0.etaStr = ""; $0.downloadedBytes = 0
            $0.totalBytes = 0; $0.pid = 0
        }
        state.persist()
        pump()
    }

    /// Start a single queued item without starting the rest of the queue.
    func startNow(_ id: UUID) {
        guard let state = state, let item = state.item(id), item.status == .queued else { return }
        start(item)
    }

    func pauseAll() {
        guard let state = state else { return }
        for item in state.items where item.status == .downloading { pause(item.id) }
    }

    func resumeAll() {
        guard let state = state else { return }
        for item in state.items where item.status == .paused { resume(item.id) }
        pump()
    }

    /// Remove from list (and stop if running). Does not delete the file.
    func remove(_ id: UUID) {
        guard let state = state else { return }
        if let item = state.item(id), item.status == .downloading || item.status == .paused {
            stop(id)
        }
        state.removeItem(id)
        state.persist()
    }

    /// Remove finished items from the queue, archiving them to history.
    func clearFinished() {
        guard let state = state else { return }
        let done = state.items.filter { $0.status == .done || $0.status == .stopped || $0.status == .failed }
        state.archiveToHistory(done)
        state.persist()
    }

    /// Trash the downloaded file then remove the item (from queue or history).
    func deleteFile(_ id: UUID) {
        guard let state = state, let item = state.anyItem(id) else { return }
        if !item.outputFilePath.isEmpty {
            let url = URL(fileURLWithPath: item.outputFilePath)
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        if item.status != .done, !item.outputFilePath.isEmpty {
            try? FileManager.default.removeItem(atPath: item.outputFilePath + ".part")
        }
        if state.item(id) != nil {
            remove(id)
        } else {
            state.history.removeAll { $0.id == id }
            state.persist()
        }
    }
}