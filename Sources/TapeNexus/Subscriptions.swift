import Foundation
import Combine

/// A channel or playlist the user wants auto-fed into the queue. The store
/// polls each enabled subscription on its interval: it flat-lists the current
/// entries, diffs them against the last-seen set, and queues any new URLs.
/// The first check of a fresh subscription is a *baseline* — it records the
/// current entries but queues nothing, so adding a channel doesn't dump its
/// entire back catalogue into the queue; only videos published after that go in.
struct Subscription: Identifiable, Codable, Hashable {
    var id = UUID()
    var url: String
    var title: String
    var preset: String          // format key (best/1080p/720p/audio/mp3/custom)
    var intervalMinutes: Int = 360
    var enabled: Bool = true
    var lastCheckedAt: Date? = nil
    var knownURLs: [String] = []
    var lastNewCount: Int = 0

    var host: String {
        URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
    }
    var displayTitle: String { title.isEmpty ? url : title }
}

@MainActor
final class SubscriptionStore: ObservableObject {
    @Published private(set) var subs: [Subscription] = []
    static let maxSubs = 50

    private let url: URL
    private var persistWorkItem: DispatchWorkItem?

    init(supportDir: URL) {
        url = supportDir.appendingPathComponent("subscriptions.json")
        if let data = try? Data(contentsOf: url),
           let snap = try? JSONDecoder().decode(SubSnapshot.self, from: data) {
            subs = snap.subs
        }
    }

    func add(_ s: Subscription) {
        guard subs.count < Self.maxSubs else { return }
        if let i = subs.firstIndex(where: { $0.url == s.url }) { subs[i] = s }
        else { subs.insert(s, at: 0) }
        schedulePersist()
    }

    func remove(_ id: UUID) {
        subs.removeAll { $0.id == id }
        schedulePersist()
    }

    func update(_ id: UUID, _ mutate: (inout Subscription) -> Void) {
        guard let i = subs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&subs[i])
        schedulePersist()
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
        guard let data = try? enc.encode(SubSnapshot(subs: subs)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private struct SubSnapshot: Codable {
    var subs: [Subscription]
    var version: Int = 1
    enum CodingKeys: String, CodingKey { case subs, version }
    init(subs: [Subscription]) { self.subs = subs; self.version = 1 }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: SubSnapshot.CodingKeys.self)
        subs = try c.decodeIfPresent([Subscription].self, forKey: .subs) ?? []
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: SubSnapshot.CodingKeys.self)
        try c.encode(subs, forKey: .subs)
        try c.encode(version, forKey: .version)
    }
}