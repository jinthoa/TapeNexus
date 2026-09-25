import Foundation
import AppKit
import Combine

/// One archived download in the persistent Library — a slim snapshot of a
/// finished `DownloadItem` that survives "Clear done" so completed downloads
/// stay browseable and re-downloadable. Capped at `maxEntries` (oldest drop).
struct LibraryEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var url: String
    var title: String
    var uploader: String
    var thumbnailURL: String
    var durationStr: String
    var formatDesc: String
    var totalBytes: Int64
    var outputFilePath: String
    var completedAt: Date

    var displayTitle: String { title.isEmpty ? url : title }
    var host: String {
        URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
    }
    var sizeStr: String {
        totalBytes > 0 ? ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) : "—"
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case newest, title, size, host
    var id: String { rawValue }
    var label: String {
        switch self {
        case .newest: return "Newest"
        case .title: return "Title"
        case .size: return "Size"
        case .host: return "Host"
        }
    }
    func compare(_ a: LibraryEntry, _ b: LibraryEntry) -> Bool {
        switch self {
        case .newest: return a.completedAt > b.completedAt
        case .title: return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
        case .size: return a.totalBytes > b.totalBytes
        case .host: return a.host.localizedCaseInsensitiveCompare(b.host) == .orderedAscending
        }
    }
}

/// Persistent archive of completed downloads, stored separately from the live
/// queue so "Clear done" doesn't purge history. Finished downloads are
/// snapshotted in via `archive(_:)`; the Library tab reads, searches, sorts,
/// re-downloads, reveals, and trashes from it.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []

    static let maxEntries = 2000

    private let url: URL
    private var persistWorkItem: DispatchWorkItem?
    /// True once a `library.json` was loaded — false on first run, which makes
    /// the queue's currently-done items eligible for one-time seeding.
    private(set) var didLoad = false

    init(supportDir: URL) {
        url = supportDir.appendingPathComponent("library.json")
        if let snap = Self.load(url) {
            entries = snap.entries
            didLoad = true
        }
    }

    /// Re-read `library.json` from disk. Used after a backup restore so the
    /// in-memory archive matches the restored file (and a debounced persist
    /// can't clobber it with the pre-restore entries).
    func reload() {
        if let snap = Self.load(url) {
            entries = snap.entries
            didLoad = true
        }
    }

    // MARK: - Queries

    func entries(matching search: String, sortedBy sort: LibrarySort) -> [LibraryEntry] {
        var result = entries
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            result = result.filter {
                $0.title.lowercased().contains(q) ||
                $0.host.lowercased().contains(q) ||
                $0.url.lowercased().contains(q)
            }
        }
        result.sort { sort.compare($0, $1) }
        return result
    }

    func entry(_ id: UUID) -> LibraryEntry? { entries.first(where: { $0.id == id }) }

    // MARK: - Mutations

    /// Archive a finished download (single-file). Dedupes by URL+path: a
    /// re-download of the same file refreshes the existing row instead of
    /// adding a duplicate. Delegates to the per-file core.
    func archive(_ item: DownloadItem, completedAt: Date = Date()) {
        archive(item, filePath: item.outputFilePath, entryId: item.id, completedAt: completedAt)
    }

    /// Archive one file of a (possibly multi-file) download. A Twitter /media
    /// or multi-image Reddit post produces many files from one queue item;
    /// each is archived as its own Library entry sharing the source URL but
    /// with its own `filePath` + `entryId`. Dedupes by (URL, filePath) so a
    /// re-download refreshes the same rows rather than duplicating them.
    func archive(_ item: DownloadItem, filePath: String, entryId: UUID, completedAt: Date = Date()) {
        let entry = LibraryEntry(
            id: entryId, url: item.url, title: item.title, uploader: item.uploader,
            thumbnailURL: item.thumbnailURL, durationStr: item.durationStr,
            formatDesc: item.formatDesc, totalBytes: item.totalBytes,
            outputFilePath: filePath, completedAt: completedAt)
        if let idx = entries.firstIndex(where: { $0.url == item.url && $0.outputFilePath == filePath }) {
            entries[idx] = entry
        } else {
            entries.insert(entry, at: 0)
        }
        enforceCap()
        schedulePersist()
    }

    /// One-time first-run seed: import currently-done queue items so existing
    /// users don't lose their history the first time they hit "Clear done".
    /// Only called when no `library.json` was found.
    func seed(from items: [DownloadItem]) {
        guard !didLoad, entries.isEmpty else { return }
        let done = items.filter { $0.status == .done }
        guard !done.isEmpty else { return }
        entries = done.map {
            LibraryEntry(id: $0.id, url: $0.url, title: $0.title, uploader: $0.uploader,
                         thumbnailURL: $0.thumbnailURL, durationStr: $0.durationStr,
                         formatDesc: $0.formatDesc, totalBytes: $0.totalBytes,
                         outputFilePath: $0.outputFilePath,
                         completedAt: $0.completedAt ?? $0.addedAt)
        }
        enforceCap()
        schedulePersist()
    }

    /// Remove from the library index only — the downloaded file stays on disk.
    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        schedulePersist()
    }

    /// Trash the downloaded file AND remove from the library.
    func deleteFile(_ id: UUID) {
        guard let e = entry(id) else { return }
        if !e.outputFilePath.isEmpty {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: e.outputFilePath),
                                               resultingItemURL: nil)
        }
        remove(id)
    }

    // MARK: - File actions (AppKit)

    func reveal(_ id: UUID) {
        guard let e = entry(id), !e.outputFilePath.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (e.outputFilePath as NSString).deletingLastPathComponent)
    }

    /// Reveal an arbitrary path in Finder (used by post-download tools to show
    /// a freshly produced audio/clip file that isn't a Library entry).
    func revealPath(_ url: URL) {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    func open(_ id: UUID) {
        guard let e = entry(id), !e.outputFilePath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: e.outputFilePath))
    }

    // MARK: - Persist

    private func enforceCap() {
        guard entries.count > Self.maxEntries else { return }
        entries.sort { $0.completedAt > $1.completedAt }
        entries = Array(entries.prefix(Self.maxEntries))
    }

    private func schedulePersist() {
        persistWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.persist() }
        persistWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(LibrarySnapshot(entries: entries)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func load(_ url: URL) -> LibrarySnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(LibrarySnapshot.self, from: data)
    }
}

private struct LibrarySnapshot: Codable {
    var entries: [LibraryEntry]
    var version: Int = 1
    enum CodingKeys: String, CodingKey { case entries, version }
    init(entries: [LibraryEntry]) { self.entries = entries; self.version = 1 }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([LibraryEntry].self, forKey: .entries) ?? []
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entries, forKey: .entries)
        try c.encode(version, forKey: .version)
    }
}