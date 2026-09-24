import Foundation
import Combine

/// Persistent, local download stats + unlocked achievements. Fun/motivational
/// only for now — stored per-machine under Application Support; a future
/// account system can claim and merge these so they follow the user.
struct AchievementStats: Codable, Equatable {
    var totalCompleted: Int = 0
    var totalBytes: Int64 = 0
    var unlockedIDs: Set<String> = []
    var firstCompletedAt: Date? = nil
    var nightOwl: Bool = false
    var earlyBird: Bool = false
}

enum Achievement: String, CaseIterable, Identifiable {
    case firstTape, mixtape, archivist, centurion
    case dataHoarder, terabyteClub, nightOwl, earlyBird

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firstTape:    return "First Tape"
        case .mixtape:      return "Mixtape"
        case .archivist:    return "Archivist"
        case .centurion:    return "Centurion"
        case .dataHoarder:  return "Data Hoarder"
        case .terabyteClub: return "Terabyte Club"
        case .nightOwl:     return "Night Owl"
        case .earlyBird:    return "Early Bird"
        }
    }

    var subtitle: String {
        switch self {
        case .firstTape:    return "Finish your first download."
        case .mixtape:      return "Finish 10 downloads."
        case .archivist:    return "Finish 50 downloads."
        case .centurion:    return "Finish 100 downloads."
        case .dataHoarder:  return "Download 100 GB in total."
        case .terabyteClub: return "Download 1 TB in total."
        case .nightOwl:     return "Finish a download between midnight and 5am."
        case .earlyBird:    return "Finish a download between 5am and 10am."
        }
    }

    var symbol: String {
        switch self {
        case .firstTape:    return "play.rectangle"
        case .mixtape:      return "music.note.list"
        case .archivist:    return "archivebox"
        case .centurion:    return "100.circle"
        case .dataHoarder:  return "externaldrive"
        case .terabyteClub: return "icloud"
        case .nightOwl:     return "moon.stars"
        case .earlyBird:    return "sunrise"
        }
    }

    /// 1024-based thresholds (matches how yt-dlp/ffmpeg report sizes).
    private static let gib: Int64 = 1024 * 1024 * 1024
    private static let tib: Int64 = 1024 * gib

    func isUnlocked(in s: AchievementStats) -> Bool {
        switch self {
        case .firstTape:    return s.totalCompleted >= 1
        case .mixtape:      return s.totalCompleted >= 10
        case .archivist:    return s.totalCompleted >= 50
        case .centurion:    return s.totalCompleted >= 100
        case .dataHoarder:  return s.totalBytes >= 100 * Self.gib
        case .terabyteClub: return s.totalBytes >= Self.tib
        case .nightOwl:     return s.nightOwl
        case .earlyBird:    return s.earlyBird
        }
    }
}

@MainActor
final class AchievementsManager: ObservableObject {
    @Published var stats: AchievementStats
    private let url: URL

    init(supportDir: URL) {
        url = supportDir.appendingPathComponent("achievements.json")
        if let loaded = Self.load(url) {
            stats = loaded
        } else {
            stats = AchievementStats()
        }
    }

    /// Human-readable running total, for the Settings panel.
    var formattedTotalBytes: String {
        ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file)
    }

    func isUnlocked(_ a: Achievement) -> Bool { stats.unlockedIDs.contains(a.id) }

    /// Record a completed download; returns any achievements unlocked by it
    /// (so the caller can fire a notification per newly-unlocked badge).
    func recordCompletion(totalBytes: Int64) -> [Achievement] {
        stats.totalCompleted += 1
        stats.totalBytes += max(0, totalBytes)
        if stats.firstCompletedAt == nil { stats.firstCompletedAt = Date() }
        let hour = Calendar.current.component(.hour, from: Date())
        if (0...4).contains(hour) { stats.nightOwl = true }
        if (5...9).contains(hour) { stats.earlyBird = true }

        var newly: [Achievement] = []
        for a in Achievement.allCases where !stats.unlockedIDs.contains(a.id) && a.isUnlocked(in: stats) {
            stats.unlockedIDs.insert(a.id)
            newly.append(a)
        }
        if !newly.isEmpty { save() }
        return newly
    }

    /// Merge a remote (server) snapshot into local stats so achievements
    /// converge across machines: union unlocked badges, take the larger tally,
    /// OR the time-of-day flags, keep the earliest first-completed timestamp.
    func merge(_ remote: AchievementStats) {
        stats.totalCompleted = max(stats.totalCompleted, remote.totalCompleted)
        stats.totalBytes = max(stats.totalBytes, remote.totalBytes)
        stats.unlockedIDs.formUnion(remote.unlockedIDs)
        stats.nightOwl = stats.nightOwl || remote.nightOwl
        stats.earlyBird = stats.earlyBird || remote.earlyBird
        if let r = remote.firstCompletedAt {
            if let l = stats.firstCompletedAt { stats.firstCompletedAt = min(l, r) }
            else { stats.firstCompletedAt = r }
        }
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(stats) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func load(_ url: URL) -> AchievementStats? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(AchievementStats.self, from: data)
    }
}