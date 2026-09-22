import Foundation
import Combine
import AppKit

@MainActor
final class AppState: ObservableObject {
    @Published var items: [DownloadItem] = []
    @Published var history: [DownloadItem] = []
    @Published var settings: AppSettings
    @Published var filter: StatusFilter = .all
    @Published var showSettings: Bool = false
    @Published var updateStatus = UpdateStatus()
    @Published var skippedCount: Int = 0
    @Published var lastLog: [UUID: [String]] = [:]
    @Published var pasteField: String = ""

    let store: SettingsStore
    let yt: YTDLPController
    let downloads: DownloadManager
    let clipboard = ClipboardMonitor()
    let updater: Updater

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
        history.insert(contentsOf: done.map { var c = $0; c.pid = 0; return c }, at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        let ids = Set(done.map { $0.id })
        items.removeAll { ids.contains($0.id) }
        lastLog = lastLog.filter { !ids.contains($0.key) }
    }

    func persist() { store.queue = items; store.history = history; store.persistQueue() }

    // MARK: - Adding URLs

    func addManualURL() {
        let raw = pasteField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        addCandidate(raw, startImmediately: true)
        pasteField = ""
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
        let ytRef = yt
        DispatchQueue.global().async { [weak self] in
            let result = ytRef.simulate(url)
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.item(id) != nil else { return } // removed meanwhile
                switch result {
                case .success(let meta):
                    self.update(id) {
                        $0.title = meta.title
                        $0.uploader = meta.uploader
                        $0.thumbnailURL = meta.thumbnail
                        $0.durationStr = meta.durationStr
                        $0.status = .queued
                    }
                    self.persist()
                    if startImmediately {
                        self.downloads.pump()
                    }
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

    // MARK: - Controls (forwarded to DownloadManager)

    func pause(_ id: UUID) { downloads.pause(id) }
    func resume(_ id: UUID) { downloads.resume(id) }
    func stop(_ id: UUID) { downloads.stop(id) }
    func retry(_ id: UUID) { downloads.retry(id) }
    func startNow(_ id: UUID) { downloads.startNow(id) }
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
        clipboard.enabled = s.autoGrabClipboard
        clipboard.pollInterval = s.pollIntervalSeconds
        clipboard.start() // restart with new cadence
        if s.formatLabel() != "" {
            // reflect format label on queued items
            for i in items.indices where items[i].status == .queued {
                items[i].formatDesc = s.formatLabel()
            }
        }
        persist()
    }

    func checkForUpdatesNow() { updater.checkAndUpdate(auto: true) }

    var activeCount: Int { items.filter { $0.status == .downloading }.count }
    var queuedCount: Int { items.filter { $0.status == .queued }.count }
    var doneCount: Int { items.filter { $0.status == .done }.count }

    // MARK: - Filter (approach A: unified list)

    /// Items visible under the current segmented filter. The list is the single
    /// `items` array — done/failed stay in it until "Clear done" archives them.
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