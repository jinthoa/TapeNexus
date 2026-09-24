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

    /// Timestamp of the most recently scheduled launch, used to stagger starts
    /// by `downloadDelaySeconds` so a big queue / rapid completions don't hit
    /// the source site in a burst.
    private var lastStartAt: Date?

    /// Number of immediate (undelayed) launches still budgeted in the current
    /// start wave. Primed to `maxConcurrent` by `startAll()` / `retryAll()` so
    /// the first cap's worth of downloads launch together — filling the
    /// concurrency limit at once instead of staggering by the start delay —
    /// while refills as slots free space out by `downloadDelaySeconds`.
    private var burstRemaining: Int = 0

    /// .part file paths yt-dlp is currently writing, per active download, so a
    /// stopped download can delete its partial file(s). Populated from the
    /// progress JSON's tmpfilename; cleared on completion / stop / remove.
    private var partFilesByItem: [UUID: [String]] = [:]

    /// Called whenever queue changes; starts queued items up to the limit.
    func pump() {
        guard let state = state else { return }
        // Don't launch new downloads during quiet hours (running ones are
        // paused by AppState's quiet-hours timer).
        if state.isQuietHour { return }
        let running = state.items.filter { $0.status == .downloading }.count
        let limit = settings().maxConcurrent
        let slots = max(0, limit - running)
        guard slots > 0 else { return }
        // Only start queued items whose scheduled start time (if any) has come.
        let toStart = Array(state.items.filter { $0.status == .queued && $0.scheduleReady && !$0.launchScheduled }.prefix(slots))
        scheduleStarts(toStart)
    }

    /// Start every queued item, respecting concurrency + the start delay.
    /// The first `maxConcurrent` launch simultaneously (filling the cap at
    /// once); the rest stay queued and are launched by `pump()` as slots free,
    /// spaced out by `downloadDelaySeconds`.
    func startAll() {
        burstRemaining = settings().maxConcurrent
        pump()
    }

    func start(_ item: DownloadItem, suppressCookies: Bool = false) {
        guard let state = state else { return }
        state.update(item.id) { $0.status = .downloading; $0.progress = 0; $0.speedStr = ""; $0.etaStr = ""; $0.errorMessage = "" }
        let s = settings()
        let id = item.id
        let pid = yt.startDownload(item: item, settings: s, suppressCookies: suppressCookies,
            onProgress: { [weak state] p, speed, eta, dl, tot in
                state?.update(id) {
                    $0.progress = p; $0.speedStr = speed; $0.etaStr = eta
                    $0.downloadedBytes = dl; $0.totalBytes = tot
                }
            },
            onFilePath: { [weak state] path in
                state?.update(id) { $0.outputFilePath = path }
            },
            onPartFile: { [weak self] path in
                // Track the .part file(s) yt-dlp is writing so stop() can clean
                // them up. Dedupe — multi-stream downloads re-emit per stream.
                guard let self = self else { return }
                let existing = self.partFilesByItem[id] ?? []
                if !existing.contains(path) {
                    self.partFilesByItem[id] = existing + [path]
                }
            },
            onLog: { [weak state] log in
                // stash last log line as message context for failed items
                state?.appendLog(id, line: log)
            },
            onComplete: { [weak self, weak state] ok, err in
                guard let self = self, let state = state else { return }
                // The download finished (success or failure): the .part file is
                // gone (renamed to the final file on success), so drop tracking.
                self.partFilesByItem.removeValue(forKey: id)
                let finished = state.item(id)
                // Cookies fallback: if browser cookies were used for this attempt
                // and yt-dlp failed before any download progress (an extraction-
                // time failure — typically it couldn't read the browser's cookie
                // store), retry once without cookies so public content still
                // downloads even when the cookies environment is broken.
                if !ok, let it = finished,
                   !suppressCookies,
                   !it.cookiesRetried,
                   !state.settings.cookiesBrowser.isEmpty,
                   it.progress <= 0.001 {
                    state.update(id) { $0.cookiesRetried = true }
                    self.start(it, suppressCookies: true)
                    state.refreshBadge()
                    return
                }
                state.update(id) {
                    if ok {
                        $0.status = .done; $0.progress = 1; $0.errorMessage = ""
                        $0.retryCount = 0
                    } else {
                        // don't override a user-driven stopped/paused state
                        if $0.status == .downloading {
                            $0.status = .failed; $0.errorMessage = err
                        }
                    }
                    $0.pid = 0
                }
                if ok { state.persist() }
                // Auto-retry: if the item genuinely failed (not user-stopped),
                // auto-retry is on, and the budget isn't spent, re-queue it for
                // another attempt instead of leaving it failed. The start delay
                // (if set) paces the retries via pump()/scheduleStarts().
                let s = self.settings()
                if !ok, let it = state.item(id), it.status == .failed,
                   s.autoRetryFailed, it.retryCount < s.maxAutoRetries {
                    state.update(id) {
                        $0.retryCount += 1
                        $0.status = .queued; $0.progress = 0; $0.errorMessage = ""
                        $0.speedStr = ""; $0.etaStr = ""
                        $0.downloadedBytes = 0; $0.totalBytes = 0; $0.pid = 0
                        $0.cookiesRetried = false
                    }
                    state.persist()
                    state.refreshBadge()
                    self.pump()
                    return
                }
                // Notify + dock badge (only for genuinely terminal outcomes).
                let finished2 = state.item(id)
                if let it = finished2, (it.status == .done || it.status == .failed),
                   state.settings.notifyOnComplete {
                    Notifier.shared.post(
                        title: ok ? "Download complete" : "Download failed",
                        body: it.displayTitle)
                }
                state.refreshBadge()
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
        // Delete the partial .part file(s) yt-dlp was writing so a stopped
        // download doesn't leave disk litter. Unix allows unlinking a file that
        // is still open (freed once the dying process closes it), so removing
        // immediately is safe even before SIGKILL lands.
        if let parts = partFilesByItem.removeValue(forKey: id), !parts.isEmpty {
            for p in parts { try? FileManager.default.removeItem(atPath: p) }
        }
    }

    func retry(_ id: UUID) {
        guard let state = state, let item = state.item(id) else { return }
        if item.status == .downloading || item.status == .paused { stop(id) }
        state.update(id) {
            $0.status = .queued; $0.progress = 0; $0.errorMessage = ""
            $0.speedStr = ""; $0.etaStr = ""; $0.downloadedBytes = 0
            $0.totalBytes = 0; $0.pid = 0; $0.cookiesRetried = false
            $0.retryCount = 0
        }
        state.persist()
        pump()
    }

    /// Re-queue every failed (and stopped) item in one go. Like `startAll`,
    /// primes the burst so the first `maxConcurrent` retry together.
    func retryAll() {
        guard let state = state else { return }
        burstRemaining = settings().maxConcurrent
        let ids = state.items.filter { $0.status == .failed || $0.status == .stopped }.map { $0.id }
        for id in ids { retry(id) }
    }

    /// Like `pump()` but only launches items the user explicitly scheduled.
    /// Used by the periodic quiet-hours tick so that — with auto-start off —
    /// plain queued items don't start on their own; only scheduled ones fire
    /// when their start time arrives. Explicit actions (start now, retry,
    /// resume all) still use `pump()`.
    func pumpScheduled() {
        guard let state = state else { return }
        if state.isQuietHour { return }
        let running = state.items.filter { $0.status == .downloading }.count
        let slots = max(0, settings().maxConcurrent - running)
        guard slots > 0 else { return }
        let toStart = Array(state.items.filter { $0.status == .queued && $0.hasSchedule && $0.scheduleReady && !$0.launchScheduled }.prefix(slots))
        scheduleStarts(toStart)
    }

    /// Stagger launches by `downloadDelaySeconds` so a big queue or a run of
    /// rapid completions doesn't reach the source site in a burst. The first
    /// `maxConcurrent` launches of a start wave (primed by `startAll` /
    /// `retryAll`) go immediately so the concurrency cap fills at once; once
    /// that burst budget is spent, later launches wait so successive starts are
    /// at least `delay` apart. Each launch re-checks status / quiet hours /
    /// free slots at fire time, so a stop or quiet window during the wait is
    /// honored rather than overridden.
    private func scheduleStarts(_ items: [DownloadItem]) {
        guard !items.isEmpty else { return }
        let delay = settings().downloadDelaySeconds
        let now = Date()
        var fireAt: Date = now
        if delay > 0, let last = lastStartAt {
            fireAt = max(now, last.addingTimeInterval(TimeInterval(delay)))
        }
        for item in items {
            let id = item.id
            // Consume the burst budget first: these launches go immediately so
            // the first cap's worth of downloads start together. Once the
            // budget is exhausted, fall back to the staggered fire time.
            let immediate = burstRemaining > 0
            if immediate { burstRemaining -= 1 }
            let when = immediate ? now : fireAt
            let delta = when.timeIntervalSince(now)
            if delta <= 0 {
                launchIfStillQueued(id)
            } else {
                // Mark pending so pump() skips this item while it waits —
                // otherwise a re-pump (clipboard grab, completion) re-selects
                // it and inflates the stagger timing. Record the fire time so
                // the row can show a "Starting in Ns" countdown.
                state?.update(id) { $0.launchScheduled = true; $0.launchAt = when }
                bgQueue.asyncAfter(deadline: .now() + delta) { [weak self] in
                    guard let self = self else { return }
                    DispatchQueue.main.async { self.launchIfStillQueued(id) }
                }
            }
            lastStartAt = when
            // Only advance the stagger fire time for launches that actually
            // used it — immediate launches shouldn't push the next staggered
            // launch further out.
            if !immediate {
                fireAt = fireAt.addingTimeInterval(TimeInterval(delay))
            }
        }
    }

    /// Launch one item only if it's still queued, we're not in quiet hours, and
    /// a concurrency slot is actually free. Guards against a stale scheduled
    /// launch (the item was stopped/removed, quiet hours began, or another
    /// launch filled the slot while we waited).
    private func launchIfStillQueued(_ id: UUID) {
        guard let state = state else { return }
        // Clear the pending flag + countdown whether or not we actually launch.
        state.update(id) { $0.launchScheduled = false; $0.launchAt = nil }
        guard !state.isQuietHour,
              let it = state.item(id), it.status == .queued,
              state.items.filter({ $0.status == .downloading }).count < settings().maxConcurrent
        else { return }
        start(it)
    }

    /// Start a single queued item, respecting concurrency + the start delay.
    /// If a slot is free, schedule it (staggered vs the last launch). If no
    /// slot is free, leave it queued — pump() on the next completion launches
    /// it — so starting many never overflows into "Preparing download…".
    func startNow(_ id: UUID) {
        guard let state = state, let item = state.item(id), item.status == .queued else { return }
        let running = state.items.filter { $0.status == .downloading }.count
        guard running < settings().maxConcurrent else { return }
        scheduleStarts([item])
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
        } else {
            partFilesByItem.removeValue(forKey: id)
        }
        state.removeItem(id)
        state.persist()
    }

    /// Remove finished items from the queue (done / stopped / failed).
    func clearFinished() {
        guard let state = state else { return }
        let ids = Set(state.items.filter { $0.status == .done || $0.status == .stopped || $0.status == .failed }
                      .map { $0.id })
        state.items.removeAll { ids.contains($0.id) }
        state.lastLog = state.lastLog.filter { !ids.contains($0.key) }
        state.persist()
    }

    /// Trash the downloaded file then remove the item from the queue.
    func deleteFile(_ id: UUID) {
        guard let state = state, let item = state.item(id) else { return }
        if !item.outputFilePath.isEmpty {
            let url = URL(fileURLWithPath: item.outputFilePath)
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        if item.status != .done, !item.outputFilePath.isEmpty {
            try? FileManager.default.removeItem(atPath: item.outputFilePath + ".part")
        }
        remove(id)
    }
}