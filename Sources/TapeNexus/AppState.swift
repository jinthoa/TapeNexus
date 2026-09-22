import Foundation
import Combine
import AppKit

@MainActor
final class AppState: ObservableObject {
    @Published var items: [DownloadItem] = []
    @Published var history: [DownloadItem] = []
    @Published var settings: AppSettings
    @Published var filter: StatusFilter = .all
    @Published var listMode: ListMode = .queue
    @Published var searchText: String = ""
    @Published var showSettings: Bool = false
    @Published var updateStatus = UpdateStatus()
    @Published var appUpdateStatus = AppUpdateStatus()
    @Published var skippedCount: Int = 0
    @Published var lastLog: [UUID: [String]] = [:]
    @Published var pasteField: String = ""

    // v1.0.4: format preview (--list-formats) state, keyed by item id.
    @Published var formatLists: [UUID: [FormatInfo]] = [:]
    @Published var formatsLoading: Set<UUID> = []
    @Published var formatsError: [UUID: String] = [:]

    let store: SettingsStore
    let yt: YTDLPController
    let downloads: DownloadManager
    let clipboard = ClipboardMonitor()
    let updater: Updater
    let appUpdater = AppUpdater()
    let menuBar = MenuBarController()

    // Quiet-hours scheduler state.
    private var quietTimer: DispatchSourceTimer?
    private var quietActive: Bool = false
    private var quietPausedIDs: Set<UUID> = []

    init() {
        let store = SettingsStore()
        self.store = store
        self.settings = store.settings
        let yt = YTDLPController(store: store)
        self.yt = yt
        let dm = DownloadManager(yt: yt)
        self.downloads = dm
        self.updater = Updater(yt: yt)

        // hydrate persisted queue
        self.items = store.queue
        self.history = store.history
        // any items mid-resolve when the app last quit would be stuck; drop them back
        // to Queued so they aren't perpetually "Resolving" with no metadata.
        for i in items.indices where items[i].status == .resolving {
            items[i].status = .queued
        }

        // wire manager + updater
        dm.state = self
        yt.ensureBinary()
        updater.onStatus = { [weak self] s in self?.updateStatus = s }
        appUpdater.onStatus = { [weak self] s in self?.appUpdateStatus = s }
        // Touch the notifier singleton so it requests notification authorization
        // up front (the first real post happens on download completion).
        _ = Notifier.shared

        // App self-update: a notify-only check a few seconds after launch so the
        // user learns a newer Tape Nexus is on GitHub without anything auto-
        // installing. The Settings button does the actual download + install.
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
    }

    // MARK: - Queue mutations

    func item(_ id: UUID) -> DownloadItem? { items.first(where: { $0.id == id }) }

    /// looks in both the live queue and history
    func anyItem(_ id: UUID) -> DownloadItem? {
        items.first(where: { $0.id == id }) ?? history.first(where: { $0.id == id })
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

    func archiveToHistory(_ done: [DownloadItem]) {
        history.insert(contentsOf: done.map {
            var c = $0; c.pid = 0
            if c.completedAt == nil { c.completedAt = Date() }
            return c
        }, at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        let ids = Set(done.map { $0.id })
        items.removeAll { ids.contains($0.id) }
        lastLog = lastLog.filter { !ids.contains($0.key) }
    }

    func persist() { store.queue = items; store.history = history; store.persistQueue() }

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
            for u in urls { addCandidate(u, startImmediately: true) }
        }
    }

    /// Entry point for drag-and-drop of URLs or a .txt file full of URLs.
    func addURLs(_ urls: [String], startImmediately: Bool = true) {
        for u in urls { addCandidate(u, startImmediately: startImmediately) }
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
        // Cache hit: a URL we've already resolved this session (or a previous
        // one) is reused without another `--simulate` network call.
        if let cached = store.metaCache[url] {
            applyMeta(id: id, url: url, meta: cached, startImmediately: startImmediately)
            return
        }
        let ytRef = yt
        DispatchQueue.global().async { [weak self] in
            let result = ytRef.simulate(url)
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
                    // Replace the playlist placeholder with one row per video.
                    self.removeItem(id)
                    for e in entries { self.addCandidate(e, startImmediately: startImmediately) }
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
    func pauseAll() { downloads.pauseAll() }
    func resumeAll() { downloads.resumeAll() }
    func clearFinished() { downloads.clearFinished() }
    func remove(_ id: UUID) { downloads.remove(id) }
    func deleteFile(_ id: UUID) { downloads.deleteFile(id) }
    /// Re-download an item from the history archive.
    func redownload(_ id: UUID) { downloads.redownload(id) }
    /// Remove a single item from history (keeps the downloaded file).
    func removeFromHistory(_ id: UUID) {
        history.removeAll { $0.id == id }
        persist()
    }
    /// Empty the whole history archive (does not touch downloaded files).
    func clearHistory() {
        history.removeAll()
        persist()
    }

    func reveal(_ id: UUID) {
        guard let p = anyItem(id)?.outputFilePath, !p.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (p as NSString).deletingLastPathComponent)
    }

    // MARK: - Settings changes

    func updateSettings(_ s: AppSettings) {
        settings = s
        store.settings = s
        store.ensureDestinationExists()
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
            // Re-pump so items whose scheduled start time just arrived kick off.
            self?.downloads.pump()
        }
        t.resume()
        quietTimer = t
        evaluateQuietHours()
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
    /// `items` array — done/failed stay in it until "Clear done" archives them.
    var filteredItems: [DownloadItem] {
        let bucketed: [DownloadItem]
        switch filter {
        case .all: bucketed = items
        case .active: bucketed = items.filter { $0.status.filterBucket == .active }
        case .done: bucketed = items.filter { $0.status.filterBucket == .done }
        case .failed: bucketed = items.filter { $0.status.filterBucket == .failed }
        }
        return searchText.isEmpty ? bucketed : bucketed.filter { matchesSearch($0) }
    }

    /// History entries filtered by the current search text.
    var filteredHistory: [DownloadItem] {
        searchText.isEmpty ? history : history.filter { matchesSearch($0) }
    }

    private func matchesSearch(_ item: DownloadItem) -> Bool {
        let q = searchText.lowercased()
        if q.isEmpty { return true }
        if item.title.lowercased().contains(q) { return true }
        if item.host.lowercased().contains(q) { return true }
        if item.url.lowercased().contains(q) { return true }
        if item.uploader.lowercased().contains(q) { return true }
        return false
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