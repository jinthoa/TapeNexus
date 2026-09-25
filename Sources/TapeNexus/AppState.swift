import Foundation
import Combine
import AppKit

@MainActor
final class AppState: ObservableObject {
    @Published var items: [DownloadItem] = []
    @Published var settings: AppSettings
    @Published var filter: StatusFilter = .all
    @Published var showSettings: Bool = false
    @Published var updateStatus = UpdateStatus()
    @Published var appUpdateStatus = AppUpdateStatus()
    /// Non-nil when the launch update check found a newer release and the
    /// Skip / Download-and-install alert should be shown. Set back to nil to
    /// dismiss (Skip or after starting the install).
    @Published var updateAlert: (current: String, latest: String)?
    @Published var skippedCount: Int = 0
    @Published var lastLog: [UUID: [String]] = [:]
    @Published var pasteField: String = ""

    /// Transient status for post-download media tools (extract audio / transcode
    /// / trim). Shown as a banner in the Library tab; cleared after a few seconds.
    @Published var mediaToolStatus: String?

    // v1.0.4: format preview (--list-formats) state, keyed by item id.
    @Published var formatLists: [UUID: [FormatInfo]] = [:]
    @Published var formatsLoading: Set<UUID> = []
    @Published var formatsError: [UUID: String] = [:]

    let store: SettingsStore
    let yt: YTDLPController
    let galleryDL: GalleryDLController
    let downloads: DownloadManager
    let clipboard = ClipboardMonitor()
    let updater: Updater
    let appUpdater = AppUpdater()
    let menuBar = MenuBarController()
    /// Local download stats + unlocked badges (fun; per-machine for now).
    let achievements: AchievementsManager
    /// Persistent archive of completed downloads — survives "Clear done".
    /// Surfaced as the Library tab; snapshotted from finished queue items.
    let library: LibraryStore
    /// Channel/playlist subscriptions — polled on an interval so new videos
    /// auto-queue. Surfaced as the Subscriptions tab.
    let subscriptions: SubscriptionStore
    /// Optional cloud sync (Supabase). nil when sync.json is empty/absent —
    /// the app stays fully local. When configured + signed in, achievements
    /// sync across machines.
    let sync: SyncManager?

    // Quiet-hours scheduler state.
    private var quietTimer: DispatchSourceTimer?
    /// Subscriptions for nested ObservableObjects (LibraryStore) so their
    /// `objectWillChange` republishes through this AppState and SwiftUI views
    /// reading `state.library` re-render.
    private var cancellables = Set<AnyCancellable>()
    private var quietActive: Bool = false
    private var quietPausedIDs: Set<UUID> = []

    /// Throttled queue for `--simulate` metadata probes. Bounded by
    /// `maxConcurrent` so adding a playlist (or batch-pasting URLs) doesn't fire
    /// N metadata requests at the source site in the same instant and get
    /// IP-throttled / 429'd. Items wait in `.resolving` for a slot.
    private let metaQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        q.name = "tapenexus.meta"
        return q
    }()

    init() {
        let store = SettingsStore()
        self.store = store
        self.settings = store.settings
        self.achievements = AchievementsManager(supportDir: store.supportDir)
        self.library = LibraryStore(supportDir: store.supportDir)
        self.subscriptions = SubscriptionStore(supportDir: store.supportDir)
        self.sync = SyncManager(supportDir: store.supportDir)
        let yt = YTDLPController(store: store)
        self.yt = yt
        let gdl = GalleryDLController(store: store)
        self.galleryDL = gdl
        let dm = DownloadManager(yt: yt, galleryDL: gdl)
        self.downloads = dm
        self.updater = Updater(yt: yt)

        // hydrate persisted queue
        self.items = store.queue
        // any items mid-resolve when the app last quit would be stuck; drop them back
        // to Queued so they aren't perpetually "Resolving" with no metadata.
        for i in items.indices where items[i].status == .resolving {
            items[i].status = .queued
        }

        // One-time first-run seed: if there's no library.json yet, import the
        // currently-done queue items so existing users don't lose their history
        // the first time they hit "Clear done".
        library.seed(from: items)
        // Count this launch for the secret launch-based achievements. Silent —
        // no unlock notification at startup, the badges just appear in the popover.
        _ = achievements.recordLaunch()
        // Republish LibraryStore changes through AppState so views reading
        // `state.library` re-render on archive/remove/delete.
        library.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        // Republish AchievementsManager too — the Stats tab and popover read
        // `state.achievements.stats` and should refresh on completion/launch.
        achievements.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        subscriptions.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        // wire manager + updater
        dm.state = self
        yt.ensureBinary()
        gdl.ensureBinary()
        metaQueue.maxConcurrentOperationCount = max(1, settings.maxConcurrent)
        updater.onStatus = { [weak self] s in self?.updateStatus = s }
        appUpdater.onStatus = { [weak self] s in self?.appUpdateStatus = s }
        // When the launch check finds a newer release, surface the popup.
        appUpdater.onUpdateAvailable = { [weak self] current, latest in
            self?.updateAlert = (current: current, latest: latest)
        }
        // Touch the notifier singleton so it requests notification authorization
        // up front (the first real post happens on download completion).
        _ = Notifier.shared

        // App self-update: a notify-only check a few seconds after launch. If a
        // newer release is found, an alert offers Skip / Download and install;
        // the Settings button does the same download + install on demand.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            DispatchQueue.main.async { self?.appUpdater.check(auto: true) }
        }

        // Menu-bar mode + quiet-hours scheduler.
        menuBar.state = self
        applyMenuBarMode()
        startQuietTimer()

        // clipboard wiring
        clipboard.enabled = settings.autoGrabClipboard
        clipboard.pollInterval = settings.pollIntervalSeconds
        clipboard.onCandidate = { [weak self] url in
            self?.addCandidate(url)
        }
        clipboard.start()

        if settings.autoUpdateYTDLP {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
                DispatchQueue.main.async { self?.updater.checkAndUpdate(auto: true) }
            }
        } else {
            let ytRef = yt
            DispatchQueue.global().async {
                let v = ytRef.currentVersion()
                DispatchQueue.main.async { self.updateStatus.currentVersion = v }
            }
        }

        // kick off anything that was queued from a previous session
        if settings.autoStartDownloads {
            downloads.pump()
        }

        // If cloud sync is configured and we have a saved session, pull the
        // server achievements row and merge it into local (so badges earned on
        // another machine appear here), then push the merged snapshot back.
        if let sync = sync, sync.isSignedIn {
            Task { await sync.pullAndMerge(into: achievements) }
        }
    }

    // MARK: - Queue mutations

    func item(_ id: UUID) -> DownloadItem? { items.first(where: { $0.id == id }) }

    /// looks up an item in the live queue
    func anyItem(_ id: UUID) -> DownloadItem? {
        items.first(where: { $0.id == id })
    }

    func update(_ id: UUID, _ mutate: (inout DownloadItem) -> Void) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            mutate(&items[idx])
        }
    }

    func appendLog(_ id: UUID, line: String) {
        var arr = lastLog[id] ?? []
        arr.append(line); if arr.count > 30 { arr.removeFirst(arr.count - 30) }
        lastLog[id] = arr
        // surface a short hint for failed/unsupported
        if line.contains("ERROR") || line.contains("Unsupported URL") {
            update(id) { if $0.errorMessage.isEmpty { $0.errorMessage = line } }
        }
    }

    func removeItem(_ id: UUID) {
        items.removeAll { $0.id == id }
        lastLog.removeValue(forKey: id)
    }

    func persist() { store.queue = items; store.persistQueue() }

    // MARK: - Adding URLs

    func addManualURL() {
        let raw = pasteField
        pasteField = ""
        // Batch paste: pull every http(s) URL out of the field (one per line or
        // a whole blob of text) and queue each. Falls back to a single trimmed
        // entry so a non-URL paste still tries once.
        let urls = SupportedURLs.extractURLs(from: raw)
        if urls.isEmpty {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { addCandidate(t, startImmediately: true) }
        } else {
            addURLs(urls, startImmediately: true)
        }
    }

    /// Entry point for drag-and-drop, .txt drop, or batch paste of many URLs.
    /// Inserts the whole batch as a block at the top (first URL at the very
    /// top) and submits metadata probes in top-to-bottom order, so with a big
    /// batch the visible top rows resolve first — no scrolling to watch progress.
    func addURLs(_ urls: [String], startImmediately: Bool = true) {
        // De-duplicate against existing items AND within this batch.
        var seen = Set(items.map { $0.url })
        var fresh: [String] = []
        for u in urls where !seen.contains(u) {
            seen.insert(u); fresh.append(u)
        }
        guard !fresh.isEmpty else { return }
        // Insert in reverse so fresh[0] ends at index 0 (top of the block).
        for u in fresh.reversed() {
            let placeholder = DownloadItem(id: UUID(), url: u, status: .resolving,
                                           formatDesc: settings.formatLabel())
            items.insert(placeholder, at: 0)
        }
        persist()
        // Verify in list order (top→bottom); metaQueue is FIFO so the top row
        // is probed first. Collect ids+urls from the freshly inserted block.
        let block = items.prefix(fresh.count).map { ($0.id, $0.url) }
        for (id, url) in block {
            verify(id: id, url: url, startImmediately: startImmediately)
        }
    }

    // MARK: Post-download media tools (extract audio / transcode / trim)

    /// Run an ffmpeg recipe on a Library file and surface a status banner.
    /// `args` is the full ffmpeg argument list; `out` is the produced file,
    /// revealed in Finder on success.
    func runMediaTool(args: [String], out: URL, doneMsg: String) {
        mediaToolStatus = "Working…"
        let ffmpeg = yt.ffmpegLocation.appendingPathComponent("ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else {
            mediaToolStatus = "Bundled ffmpeg isn't available."
            return
        }
        MediaTools.run(ffmpeg: ffmpeg, args: args) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.mediaToolStatus = doneMsg
                self.library.revealPath(out)
            } else {
                self.mediaToolStatus = "Couldn't process that file (ffmpeg failed)."
            }
        }
    }

    func addCandidate(_ url: String, startImmediately: Bool? = nil) {
        guard !items.contains(where: { $0.url == url }) else { return }
        let start = startImmediately ?? settings.autoStartDownloads
        // optimistic placeholder row, verified async
        let id = UUID()
        let placeholder = DownloadItem(id: id, url: url, status: .resolving,
                                       formatDesc: settings.formatLabel())
        items.insert(placeholder, at: 0)
        persist()
        verify(id: id, url: url, startImmediately: start)
    }

    /// Add a candidate that carries its own format preset (used by Subscriptions
    /// so each feed can target a different quality/format than the global default).
    func addCandidate(_ url: String, preset: String, startImmediately: Bool? = nil) {
        guard !items.contains(where: { $0.url == url }) else { return }
        let start = startImmediately ?? settings.autoStartDownloads
        let id = UUID()
        let label = AppSettings.formatLabel(preset: preset, custom: "")
        let placeholder = DownloadItem(id: id, url: url, status: .resolving,
                                       formatDesc: label, formatPreset: preset)
        items.insert(placeholder, at: 0)
        persist()
        verify(id: id, url: url, startImmediately: start)
    }

    // MARK: Subscriptions

    /// Check a single subscription: flat-list its current entries and queue any
    /// that aren't in the last-seen set. The first check is a baseline — it
    /// records the entries but queues nothing (no back-catalogue dump). Runs the
    /// yt-dlp probe off the main thread.
    func checkSubscription(_ id: UUID) {
        guard let sub = subscriptions.subs.first(where: { $0.id == id }) else { return }
        let ytRef = yt
        let url = sub.url
        let known = Set(sub.knownURLs)
        let firstCheck = sub.knownURLs.isEmpty
        metaQueue.addOperation { [weak self] in
            let entries = ytRef.simulatePlaylist(url, cap: 200) ?? []
            DispatchQueue.main.async {
                guard let self = self else { return }
                let entrySet = Set(entries)
                let newURLs = entries.filter { !known.contains($0) }
                self.subscriptions.update(id) { s in
                    s.knownURLs = entries
                    s.lastCheckedAt = Date()
                    s.lastNewCount = firstCheck ? 0 : newURLs.count
                }
                // Queue only genuinely new videos (skip the baseline pass).
                if !firstCheck {
                    for u in newURLs where !self.items.contains(where: { $0.url == u }) {
                        self.addCandidate(u, preset: sub.preset, startImmediately: true)
                    }
                    if !newURLs.isEmpty {
                        self.achievements.recordPlaylistExpansion()
                    }
                }
            }
        }
    }

    /// Check every enabled subscription whose interval has elapsed (or that has
    /// never been checked). Called by the periodic timer and the "Check all" button.
    func checkAllSubscriptions() {
        let now = Date()
        for sub in subscriptions.subs where sub.enabled {
            let due = sub.lastCheckedAt.map { now.timeIntervalSince($0) >= Double(sub.intervalMinutes) * 60 } ?? true
            if due { checkSubscription(sub.id) }
        }
    }

    private func verify(id: UUID, url: String, startImmediately: Bool) {
        // Playlist expansion: if the link looks like a playlist and the user
        // opted in, flat-list its entries and queue each as its own item.
        if settings.expandPlaylists && Self.looksLikePlaylist(url) {
            verifyPlaylist(id: id, url: url, startImmediately: startImmediately)
            return
        }
        verifySingle(id: id, url: url, startImmediately: startImmediately)
    }

    private func verifySingle(id: UUID, url: String, startImmediately: Bool) {
        // Pick the engine by host and stamp it on the item so the download
        // launch dispatches to the right binary. Twitter/X (images + /media)
        // and Reddit (images / saved) go to gallery-dl; everything else to yt-dlp.
        let engine = SupportedURLs.engine(for: url)
        update(id) { $0.engine = engine }
        // Cache hit: a URL we've already resolved this session (or a previous
        // one) is reused without another `--simulate` network call.
        if let cached = store.metaCache[url] {
            applyMeta(id: id, url: url, meta: cached, startImmediately: startImmediately)
            return
        }
        let simRef: AnyObject
        switch engine {
        case .galleryDl: simRef = galleryDL
        case .ytDlp:     simRef = yt
        }
        metaQueue.addOperation { [weak self] in
            let result: SimulateResult
            if let g = simRef as? GalleryDLController {
                result = g.simulate(url)
            } else if let y = simRef as? YTDLPController {
                result = y.simulate(url)
            } else {
                result = .failed("No download engine available")
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.item(id) != nil else { return } // removed meanwhile
                switch result {
                case .success(let meta):
                    self.store.metaCache[url] = meta
                    self.applyMeta(id: id, url: url, meta: meta, startImmediately: startImmediately)
                case .unsupported:
                    // host not recognised by yt-dlp → silently skip
                    self.removeItem(id)
                    self.skippedCount += 1
                    self.clipboard.forget(url)
                    self.persist()
                case .failed(let msg):
                    // recognised but couldn't resolve (network / age-restricted / format
                    // error / timeout) → keep the row so the user can retry, and show why.
                    self.update(id) {
                        $0.status = .failed
                        $0.errorMessage = msg
                    }
                    self.persist()
                }
            }
        }
    }

    private func verifyPlaylist(id: UUID, url: String, startImmediately: Bool) {
        let ytRef = yt
        let cap = settings.playlistCap
        DispatchQueue.global().async { [weak self] in
            let entries = ytRef.simulatePlaylist(url, cap: cap)
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.item(id) != nil else { return } // removed meanwhile
                if let entries = entries, entries.count > 1 {
                    // Replace the playlist placeholder with one row per video,
                    // inserted as a block (first entry at top) and probed
                    // top-to-bottom — same as a batch paste.
                    self.removeItem(id)
                    self.addURLs(entries, startImmediately: startImmediately)
                    // Achievements: a playlist was expanded into the queue.
                    let unlocked = self.achievements.recordPlaylistExpansion()
                    let signedIn = self.sync?.isSignedIn ?? false
                    if signedIn {
                        for a in unlocked {
                            Notifier.shared.post(
                                title: "🏆 Achievement unlocked",
                                body: "\(a.title) — \(a.subtitle)")
                        }
                        if let sync = self.sync {
                            Task { await sync.pushAchievements(self.achievements.stats) }
                        }
                    }
                } else {
                    // Not actually a multi-entry playlist → verify as a single video.
                    self.verifySingle(id: id, url: url, startImmediately: startImmediately)
                }
            }
        }
    }

    static func looksLikePlaylist(_ url: String) -> Bool {
        let l = url.lowercased()
        return l.contains("list=") || l.contains("/playlist") || l.contains("playlist?")
    }

    private func applyMeta(id: UUID, url: String, meta: VideoMeta, startImmediately: Bool) {
        update(id) {
            $0.title = meta.title
            $0.uploader = meta.uploader
            $0.thumbnailURL = meta.thumbnail
            $0.durationStr = meta.durationStr
            $0.status = .queued
        }
        persist()
        if startImmediately {
            downloads.pump()
        }
    }

    // MARK: - Controls (forwarded to DownloadManager)

    func pause(_ id: UUID) { downloads.pause(id) }
    func resume(_ id: UUID) { downloads.resume(id) }
    func stop(_ id: UUID) { downloads.stop(id) }
    func retry(_ id: UUID) { downloads.retry(id) }
    func retryAll() { downloads.retryAll() }
    func startNow(_ id: UUID) { downloads.startNow(id) }
    /// Cancel a queued item's pending/scheduled start (park as stopped).
    func cancelStart(_ id: UUID) { downloads.cancelStart(id) }
    func startAll() { downloads.startAll() }
    func pauseAll() { downloads.pauseAll() }
    func resumeAll() { downloads.resumeAll() }
    func clearFinished() { downloads.clearFinished() }
    func remove(_ id: UUID) { downloads.remove(id) }
    func deleteFile(_ id: UUID) { downloads.deleteFile(id) }

    func reveal(_ id: UUID) {
        guard let p = anyItem(id)?.outputFilePath, !p.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (p as NSString).deletingLastPathComponent)
    }

    // MARK: - Settings changes

    func updateSettings(_ s: AppSettings) {
        settings = s
        store.settings = s
        store.ensureDestinationExists()
        metaQueue.maxConcurrentOperationCount = max(1, s.maxConcurrent)
        clipboard.enabled = s.autoGrabClipboard
        clipboard.pollInterval = s.pollIntervalSeconds
        clipboard.start() // restart with new cadence
        applyMenuBarMode()
        evaluateQuietHours()
        if s.formatLabel() != "" {
            // reflect format label on queued items
            for i in items.indices where items[i].status == .queued {
                items[i].formatDesc = s.formatLabel()
            }
        }
        persist()
    }

    func checkForUpdatesNow() { updater.checkAndUpdate(auto: true) }

    /// Manual app self-update: checks GitHub and, if newer, downloads the .pkg
    /// and opens Installer (auto-launch checks are notify-only).
    func checkForAppUpdateNow() { appUpdater.check(auto: false) }

    /// "Download and install" from the launch update popup: download the cached
    /// latest release's .pkg and open Installer, then dismiss the popup.
    func installUpdateNow() {
        updateAlert = nil
        appUpdater.downloadAndInstallLatest()
    }

    /// Skip the launch update popup for this session.
    func skipUpdateAlert() { updateAlert = nil }

    /// The app's own version (CFBundleShortVersionString), for the Settings view.
    var appVersion: String { appUpdater.currentVersion }

    // MARK: - Per-item overrides (v1.0.2)

    func setItemFormat(_ id: UUID, preset: String, custom: String) {
        update(id) {
            $0.formatPreset = preset
            $0.customFormat = custom
            $0.formatDesc = preset.isEmpty
                ? settings.formatLabel()
                : AppSettings.formatLabel(preset: preset, custom: custom)
        }
        persist()
    }

    func setItemClip(_ id: UUID, start: String, end: String) {
        update(id) { $0.clipStart = start; $0.clipEnd = end }
        persist()
    }

    // MARK: - Per-item scheduling (v1.0.4)

    /// Schedule a queued item to start no earlier than `startAt`. nil clears it.
    func setItemSchedule(_ id: UUID, startAt: Date?) {
        update(id) { $0.startAt = startAt }
        persist()
        if startAt == nil { downloads.pump() }
    }

    // MARK: - Format preview (v1.0.4)

    /// Fetch yt-dlp's available-format list for an item's URL (async). The
    /// result lands in `formatLists[id]`; failures land in `formatsError[id]`.
    func loadFormats(for id: UUID) {
        guard let item = anyItem(id) else { return }
        if formatsLoading.contains(id) { return }
        formatsLoading.insert(id)
        formatsError[id] = ""
        let ytRef = yt
        let url = item.url
        DispatchQueue.global().async { [weak self] in
            let result = ytRef.listFormats(url)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.formatsLoading.remove(id)
                if let result = result, !result.isEmpty {
                    self.formatLists[id] = result
                    self.formatsError[id] = ""
                } else {
                    self.formatsError[id] = "Couldn't load formats for this link."
                }
            }
        }
    }

    /// Apply a chosen format row to an item as a custom -f override.
    func applyFormat(_ f: FormatInfo, to id: UUID) {
        setItemFormat(id, preset: "custom", custom: f.formatArg)
    }

    // MARK: - Dock badge + notifications

    /// Reflect the active download count on the Dock icon (no-op in menu-bar
    /// mode where the Dock icon is hidden).
    func refreshBadge() {
        let n = items.filter { $0.status == .downloading }.count
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : ""
    }

    // MARK: - Menu-bar mode

    func applyMenuBarMode() {
        if settings.menuBarMode { menuBar.install() } else { menuBar.uninstall() }
    }

    // MARK: - Quiet hours

    var isQuietHour: Bool {
        guard settings.quietHoursEnabled else { return false }
        let h = Calendar.current.component(.hour, from: Date())
        let s = settings.quietStart, e = settings.quietEnd
        if s == e { return false }
        if s < e { return h >= s && h < e }
        return h >= s || h < e   // wraps midnight (e.g. 23 → 7)
    }

    private func startQuietTimer() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in
            self?.evaluateQuietHours()
            // Only launch items the user explicitly scheduled — NOT a general
            // auto-start. With auto-start off, plain queued items must wait for
            // the user to press ▶; only scheduled ones fire when their time lands.
            self?.downloads.pumpScheduled()
            // Subscription poll: checkAllSubscriptions self-filters by each
            // feed's interval, so a 60s tick is cheap even with many subs.
            self?.checkAllSubscriptions()
        }
        t.resume()
        quietTimer = t
        evaluateQuietHours()
        // Kick the first subscription pass shortly after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.checkAllSubscriptions()
        }
    }

    func evaluateQuietHours() {
        let q = isQuietHour
        if q && !quietActive {
            // entering quiet window → pause running downloads, remember which
            quietActive = true
            for item in items where item.status == .downloading {
                quietPausedIDs.insert(item.id)
                downloads.pause(item.id)
            }
        } else if !q && quietActive {
            // leaving quiet window → resume only the ones we paused, then pump
            quietActive = false
            for id in quietPausedIDs {
                if let it = item(id), it.status == .paused { downloads.resume(id) }
            }
            quietPausedIDs.removeAll()
            downloads.pump()
        }
    }

    var activeCount: Int { items.filter { $0.status == .downloading }.count }
    var queuedCount: Int { items.filter { $0.status == .queued }.count }
    var doneCount: Int { items.filter { $0.status == .done }.count }

    // MARK: - Filter (approach A: unified list)

    /// Items visible under the current segmented filter. The list is the single
    /// `items` array — done/failed stay in it until "Clear done" removes them.
    var filteredItems: [DownloadItem] {
        switch filter {
        case .all: return items
        case .active: return items.filter { $0.status.filterBucket == .active }
        case .done: return items.filter { $0.status.filterBucket == .done }
        case .failed: return items.filter { $0.status.filterBucket == .failed }
        }
    }

    func count(for f: StatusFilter) -> Int {
        switch f {
        case .all: return items.count
        case .active: return items.filter { $0.status.filterBucket == .active }.count
        case .done: return items.filter { $0.status.filterBucket == .done }.count
        case .failed: return items.filter { $0.status.filterBucket == .failed }.count
        }
    }
}