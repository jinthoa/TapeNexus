import Foundation
import Combine

/// Persistent, local download stats + unlocked achievements. Fun/motivational,
/// stored per-machine under Application Support, and synced to Supabase so they
/// follow the signed-in user across machines. The composite `score` powers the
/// opt-in global leaderboard.
struct AchievementStats: Codable, Equatable {
    var totalCompleted: Int = 0
    var totalBytes: Int64 = 0
    var unlockedIDs: Set<String> = []
    var firstCompletedAt: Date? = nil
    var nightOwl: Bool = false
    var earlyBird: Bool = false

    // v1.0.19 (Achievements 2.0): richer stats so badges + the composite score
    // can be computed. All decodeIfPresent-style via Codable defaults, so an old
    // achievements.json upgrades cleanly to the expanded set.
    var hostsSeen: Set<String> = []           // distinct download hosts (e.g. youtube.com)
    var presetsUsed: Set<String> = []         // distinct format presets used
    var completionDays: Set<String> = []      // ISO "yyyy-MM-dd" days with >=1 completion (for streaks)
    var didClip: Bool = false                 // finished a clip (start/end set)
    var didSchedule: Bool = false             // finished a scheduled (startAt) download
    var playlistsExpanded: Int = 0            // playlists expanded into queue items
    var didRetryRecover: Bool = false         // a download succeeded after an auto-retry
    var weekendWarrior: Bool = false          // finished a download on Sat/Sun
    var launches: Int = 0                     // app launch count (secret badges)

    // Leaderboard profile (opt-in). Synced in the same achievements row; the
    // `leaderboardSettingsAt` timestamp gives last-write-wins across machines.
    var displayName: String = ""
    var leaderboardOptIn: Bool = false
    var leaderboardSettingsAt: Date? = nil

    /// 1024-based thresholds (matches how yt-dlp/ffmpeg report sizes).
    static let gib: Int64 = 1024 * 1024 * 1024
    static let tib: Int64 = 1024 * Self.gib

    /// Composite leaderboard score. Weighted so volume, breadth, consistency,
    /// and badge collection all matter, but no single axis dominates:
    ///   downloads × 10  +  capped GiB × 5  +  badges × 50  +  hosts × 15  +  best streak × 20
    /// The GiB term is capped at 500 (≈ 0.5 TB) so a terabyte hoarder can't
    /// drown out everyone else; badges and breadth keep it competitive.
    var score: Int64 {
        Int64(totalCompleted) * 10
        + min(totalBytes / Self.gib, 500) * 5
        + Int64(unlockedIDs.count) * 50
        + Int64(hostsSeen.count) * 15
        + Int64(bestStreak) * 20
    }

    /// Longest run of consecutive calendar days with at least one completion.
    var bestStreak: Int {
        Self.longestRun(of: completionDays)
    }

    /// Consecutive days ending today (or 0 if nothing completed today/yesterday
    /// chain is broken). Used for live "current streak" display.
    var currentStreak: Int {
        let cal = Calendar(identifier: .gregorian)
        let today = Self.dayString(for: Date(), calendar: cal)
        guard completionDays.contains(today) else { return 0 }
        var n = 1
        var d = Date()
        while true {
            guard let prev = cal.date(byAdding: .day, value: -1, to: d) else { break }
            let s = Self.dayString(for: prev, calendar: cal)
            if completionDays.contains(s) { n += 1; d = prev } else { break }
        }
        return n
    }

    static func dayString(for date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    /// Longest run of consecutive calendar days in an arbitrary set of
    /// "yyyy-MM-dd" strings. Strings parse lexicographically as dates, so
    /// sorting + walking is enough.
    static func longestRun(of days: Set<String>) -> Int {
        guard !days.isEmpty else { return 0 }
        let cal = Calendar(identifier: .gregorian)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        let sorted = days.sorted()
        var best = 1, run = 1
        for i in 1..<sorted.count {
            if let prev = f.date(from: sorted[i - 1]),
               let cur = f.date(from: sorted[i]),
               cal.dateComponents([.day], from: prev, to: cur).day == 1 {
                run += 1; best = max(best, run)
            } else {
                run = 1
            }
        }
        return best
    }
}

enum Achievement: String, CaseIterable, Identifiable {
    // Milestone tiers (download count)
    case firstTape, mixtape, archivist, centurion, collector, librarian, vaultKeeper
    // Volume tiers
    case dataHoarder, terabyteClub
    // Time-of-day / week
    case nightOwl, earlyBird, weekendWarrior
    // Breadth
    case multiHost, globetrotter
    // Format variety
    case audiophile, highDef
    // Behavior
    case clipMaster, planner, playlistPioneer, comebackKid
    // Consistency
    case streak3, streak7
    // Meta
    case completionist
    // Secret (hidden until unlocked — see `secret`)
    case helloWorld, regular, twoHundred, wellRounded, persistent

    var id: String { rawValue }

    /// Secret badges hide their title/subtitle/symbol behind a "???" card until
    /// unlocked, then reveal with a sparkle tint. A small extra layer beyond the
    /// normal grid.
    var secret: Bool {
        switch self {
        case .helloWorld, .regular, .twoHundred, .wellRounded, .persistent:
            return true
        default:
            return false
        }
    }

    var title: String {
        switch self {
        case .firstTape:       return "First Tape"
        case .mixtape:         return "Mixtape"
        case .archivist:       return "Archivist"
        case .centurion:       return "Centurion"
        case .collector:       return "Collector"
        case .librarian:       return "Librarian"
        case .vaultKeeper:     return "Vault Keeper"
        case .dataHoarder:     return "Data Hoarder"
        case .terabyteClub:    return "Terabyte Club"
        case .nightOwl:        return "Night Owl"
        case .earlyBird:       return "Early Bird"
        case .weekendWarrior:  return "Weekend Warrior"
        case .multiHost:       return "Multi-Source"
        case .globetrotter:    return "Globetrotter"
        case .audiophile:      return "Audiophile"
        case .highDef:         return "High Definition"
        case .clipMaster:      return "Clip Master"
        case .planner:         return "The Planner"
        case .playlistPioneer: return "Playlist Pioneer"
        case .comebackKid:     return "Comeback Kid"
        case .streak3:         return "On a Roll"
        case .streak7:         return "Unstoppable"
        case .completionist:   return "Completionist"
        case .helloWorld:      return "Hello, World"
        case .regular:         return "Regular"
        case .twoHundred:      return "Double Centurion"
        case .wellRounded:     return "Well-Rounded"
        case .persistent:      return "Persistent"
        }
    }

    var subtitle: String {
        switch self {
        case .firstTape:       return "Finish your first download."
        case .mixtape:         return "Finish 10 downloads."
        case .archivist:       return "Finish 50 downloads."
        case .centurion:       return "Finish 100 downloads."
        case .collector:       return "Finish 250 downloads."
        case .librarian:       return "Finish 500 downloads."
        case .vaultKeeper:     return "Finish 1,000 downloads."
        case .dataHoarder:     return "Download 100 GB in total."
        case .terabyteClub:    return "Download 1 TB in total."
        case .nightOwl:        return "Finish a download between midnight and 5am."
        case .earlyBird:       return "Finish a download between 5am and 10am."
        case .weekendWarrior:  return "Finish a download on a weekend."
        case .multiHost:       return "Download from 3 different sites."
        case .globetrotter:    return "Download from 10 different sites."
        case .audiophile:      return "Finish an audio-only download."
        case .highDef:         return "Finish a 1080p download."
        case .clipMaster:      return "Finish a clipped download."
        case .planner:         return "Finish a scheduled download."
        case .playlistPioneer: return "Expand a playlist into the queue."
        case .comebackKid:     return "Succeed after an auto-retry."
        case .streak3:         return "Download 3 days in a row."
        case .streak7:         return "Download 7 days in a row."
        case .completionist:   return "Unlock every other achievement."
        case .helloWorld:      return "Launch Tape Nexus once."
        case .regular:         return "Launch Tape Nexus 50 times."
        case .twoHundred:      return "Finish 200 downloads."
        case .wellRounded:     return "Use 4 different format presets."
        case .persistent:      return "Unlock 15 achievements."
        }
    }

    var symbol: String {
        switch self {
        case .firstTape:       return "play.rectangle"
        case .mixtape:         return "music.note.list"
        case .archivist:       return "archivebox"
        case .centurion:       return "100.circle"
        case .collector:       return "tray.full"
        case .librarian:       return "books.vertical"
        case .vaultKeeper:     return "lock.rectangle.stack"
        case .dataHoarder:     return "externaldrive"
        case .terabyteClub:    return "icloud"
        case .nightOwl:        return "moon.stars"
        case .earlyBird:       return "sunrise"
        case .weekendWarrior:  return "calendar.badge.clock"
        case .multiHost:       return "rectangle.connected.to.line.below"
        case .globetrotter:    return "globe"
        case .audiophile:      return "waveform"
        case .highDef:         return "rectangle.stack"
        case .clipMaster:      return "scissors"
        case .planner:         return "clock.arrow.circlepath"
        case .playlistPioneer: return "list.bullet.indent"
        case .comebackKid:     return "arrow.uturn.backward.circle"
        case .streak3:         return "flame"
        case .streak7:         return "flame.fill"
        case .completionist:   return "rosette"
        case .helloWorld:      return "macwindow"
        case .regular:         return "calendar.badge.checkmark"
        case .twoHundred:      return "200.circle"
        case .wellRounded:     return "square.grid.2x2"
        case .persistent:      return "medal"
        }
    }

    func isUnlocked(in s: AchievementStats) -> Bool {
        switch self {
        case .firstTape:       return s.totalCompleted >= 1
        case .mixtape:         return s.totalCompleted >= 10
        case .archivist:       return s.totalCompleted >= 50
        case .centurion:       return s.totalCompleted >= 100
        case .collector:       return s.totalCompleted >= 250
        case .librarian:       return s.totalCompleted >= 500
        case .vaultKeeper:     return s.totalCompleted >= 1000
        case .dataHoarder:     return s.totalBytes >= 100 * AchievementStats.gib
        case .terabyteClub:    return s.totalBytes >= AchievementStats.tib
        case .nightOwl:        return s.nightOwl
        case .earlyBird:       return s.earlyBird
        case .weekendWarrior:  return s.weekendWarrior
        case .multiHost:       return s.hostsSeen.count >= 3
        case .globetrotter:    return s.hostsSeen.count >= 10
        case .audiophile:      return s.presetsUsed.contains("audio") || s.presetsUsed.contains("mp3")
        case .highDef:         return s.presetsUsed.contains("1080p") || s.presetsUsed.contains("best")
        case .clipMaster:      return s.didClip
        case .planner:         return s.didSchedule
        case .playlistPioneer: return s.playlistsExpanded >= 1
        case .comebackKid:     return s.didRetryRecover
        case .streak3:         return s.bestStreak >= 3
        case .streak7:         return s.bestStreak >= 7
        case .completionist:
            // Every other badge unlocked.
            return Achievement.allCases.filter { $0 != .completionist }.allSatisfy { s.unlockedIDs.contains($0.id) }
        case .helloWorld:      return s.launches >= 1
        case .regular:         return s.launches >= 50
        case .twoHundred:      return s.totalCompleted >= 200
        case .wellRounded:     return s.presetsUsed.count >= 4
        case .persistent:      return s.unlockedIDs.filter { $0 != Achievement.persistent.id }.count >= 15
        }
    }

    /// For grindy badges, a trackable (current, target, unit) so the UI can show
    /// a progress bar + "47/50" on locked badges. Returns nil for one-shot /
    /// boolean badges (no meaningful progress to show) — those just display the
    /// lock. `target` is always >= 2 when non-nil.
    func progress(in s: AchievementStats) -> (current: Double, target: Double, unit: String)? {
        let othersUnlocked = Achievement.allCases.filter { $0 != self }
            .filter { s.unlockedIDs.contains($0.id) }.count
        switch self {
        case .mixtape:         return (Double(s.totalCompleted), 10, "")
        case .archivist:       return (Double(s.totalCompleted), 50, "")
        case .centurion:       return (Double(s.totalCompleted), 100, "")
        case .collector:       return (Double(s.totalCompleted), 250, "")
        case .librarian:       return (Double(s.totalCompleted), 500, "")
        case .vaultKeeper:     return (Double(s.totalCompleted), 1000, "")
        case .twoHundred:      return (Double(s.totalCompleted), 200, "")
        case .dataHoarder:     return (Double(s.totalBytes) / Double(AchievementStats.gib), 100, " GB")
        case .terabyteClub:    return (Double(s.totalBytes) / Double(AchievementStats.gib), 1024, " GB")
        case .multiHost:       return (Double(s.hostsSeen.count), 3, " hosts")
        case .globetrotter:    return (Double(s.hostsSeen.count), 10, " hosts")
        case .streak3:         return (Double(s.bestStreak), 3, " days")
        case .streak7:         return (Double(s.bestStreak), 7, " days")
        case .regular:         return (Double(s.launches), 50, "")
        case .wellRounded:     return (Double(s.presetsUsed.count), 4, "")
        case .persistent:      return (Double(othersUnlocked), 15, "")
        case .completionist:   return (Double(othersUnlocked), Double(Achievement.allCases.count - 1), "")
        default:               return nil
        }
    }
}

@MainActor
final class AchievementsManager: ObservableObject {
    @Published var stats: AchievementStats
    private let url: URL
    private var profiles: [String: AchievementStats]
    private var legacy: AchievementStats?
    private var activeUserID: String?

    init(supportDir: URL) {
        url = supportDir.appendingPathComponent("achievements.json")
        let loaded = Self.loadStore(url)
        profiles = loaded.profiles
        legacy = loaded.legacy
        activeUserID = nil
        stats = AchievementStats()
    }

    /// Select the stats belonging to one authenticated account. Signed-out
    /// state is blank and is never persisted, so account B cannot inherit or
    /// upload account A's activity or leaderboard consent. A pre-v2 unscoped
    /// file is claimed once by the first authenticated user after migration.
    func activateUser(_ userID: String?) {
        if let activeUserID { profiles[activeUserID] = stats }
        activeUserID = userID
        guard let userID, !userID.isEmpty else {
            stats = AchievementStats()
            return
        }
        if profiles[userID] == nil {
            profiles[userID] = legacy ?? AchievementStats()
            legacy = nil
        }
        stats = profiles[userID] ?? AchievementStats()
        save()
    }

    /// Re-read `achievements.json` from disk. Used after a backup restore so the
    /// in-memory state matches the restored file (and a later `save()` can't
    /// clobber it with the pre-restore values).
    func reload() {
        let userID = activeUserID
        let loaded = Self.loadStore(url)
        profiles = loaded.profiles
        legacy = loaded.legacy
        activeUserID = nil
        activateUser(userID)
    }

    /// Human-readable running total, for the Settings panel.
    var formattedTotalBytes: String {
        ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file)
    }

    func isUnlocked(_ a: Achievement) -> Bool { stats.unlockedIDs.contains(a.id) }

    /// Record a completed download; returns any achievements unlocked by it
    /// (so the caller can fire a notification per newly-unlocked badge). Takes
    /// the full item so host/format/clip/schedule/retry badges can fire.
    func recordCompletion(_ item: DownloadItem) -> [Achievement] {
        let now = Date()
        stats.totalCompleted += 1
        stats.totalBytes += max(0, item.totalBytes)
        if stats.firstCompletedAt == nil { stats.firstCompletedAt = now }

        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        if (0...4).contains(hour) { stats.nightOwl = true }
        if (5...9).contains(hour) { stats.earlyBird = true }
        let weekday = cal.component(.weekday, from: now)   // 1=Sun ... 7=Sat
        if weekday == 1 || weekday == 7 { stats.weekendWarrior = true }

        stats.hostsSeen.insert(item.host)
        if !item.formatPreset.isEmpty { stats.presetsUsed.insert(item.formatPreset) }
        stats.completionDays.insert(AchievementStats.dayString(for: now))
        if item.hasClip { stats.didClip = true }
        if item.hasSchedule { stats.didSchedule = true }
        if item.retryCount > 0 { stats.didRetryRecover = true }

        return recomputeUnlocked()
    }

    /// Record that a playlist URL was expanded into per-video queue items.
    /// Returns any achievements unlocked by it.
    func recordPlaylistExpansion() -> [Achievement] {
        stats.playlistsExpanded += 1
        return recomputeUnlocked()
    }

    /// Record an app launch (called once per startup). Returns any achievements
    /// unlocked by it; the caller drops them silently (no unlock notification at
    /// launch — the badges just appear in the popover).
    func recordLaunch() -> [Achievement] {
        stats.launches += 1
        return recomputeUnlocked()
    }

    /// Recompute all badges from current stats; returns the newly-unlocked set.
    private func recomputeUnlocked() -> [Achievement] {
        var newly: [Achievement] = []
        for a in Achievement.allCases where !stats.unlockedIDs.contains(a.id) && a.isUnlocked(in: stats) {
            stats.unlockedIDs.insert(a.id)
            newly.append(a)
        }
        save()   // tallies/days/sets changed regardless of new badges
        return newly
    }

    /// Set the leaderboard display name + opt-in. Stamps a settings timestamp
    /// so cross-machine merge can do last-write-wins. Caller pushes after this.
    func setLeaderboardProfile(name: String, optIn: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        stats.displayName = trimmed
        stats.leaderboardOptIn = optIn
        stats.leaderboardSettingsAt = Date()
        save()
    }

    /// Merge a remote (server) snapshot into local stats so achievements
    /// converge across machines: union unlocked badges + sets, take the larger
    /// tally, OR the time-of-day/behavior flags, keep the earliest first
    /// completion. Leaderboard profile uses last-write-wins on the settings
    /// timestamp.
    func merge(_ remote: AchievementStats) {
        stats.totalCompleted = max(stats.totalCompleted, remote.totalCompleted)
        stats.totalBytes = max(stats.totalBytes, remote.totalBytes)
        stats.unlockedIDs.formUnion(remote.unlockedIDs)
        stats.hostsSeen.formUnion(remote.hostsSeen)
        stats.presetsUsed.formUnion(remote.presetsUsed)
        stats.completionDays.formUnion(remote.completionDays)
        stats.nightOwl = stats.nightOwl || remote.nightOwl
        stats.earlyBird = stats.earlyBird || remote.earlyBird
        stats.weekendWarrior = stats.weekendWarrior || remote.weekendWarrior
        stats.didClip = stats.didClip || remote.didClip
        stats.didSchedule = stats.didSchedule || remote.didSchedule
        stats.didRetryRecover = stats.didRetryRecover || remote.didRetryRecover
        stats.playlistsExpanded = max(stats.playlistsExpanded, remote.playlistsExpanded)
        stats.launches = max(stats.launches, remote.launches)
        if let r = remote.firstCompletedAt {
            if let l = stats.firstCompletedAt { stats.firstCompletedAt = min(l, r) }
            else { stats.firstCompletedAt = r }
        }
        // Last-write-wins for the leaderboard profile.
        let localAt = stats.leaderboardSettingsAt
        let remoteAt = remote.leaderboardSettingsAt
        if let r = remoteAt, r > (localAt ?? .distantPast) {
            stats.displayName = remote.displayName
            stats.leaderboardOptIn = remote.leaderboardOptIn
            stats.leaderboardSettingsAt = r
        }
        save()
    }

    private func save() {
        guard let activeUserID else { return }
        profiles[activeUserID] = stats
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let store = AchievementStore(version: 2, legacy: legacy, profiles: profiles)
        guard let data = try? enc.encode(store) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func loadStore(_ url: URL) -> (profiles: [String: AchievementStats], legacy: AchievementStats?) {
        guard let data = try? Data(contentsOf: url) else { return ([:], nil) }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let store = try? dec.decode(AchievementStore.self, from: data), store.version == 2 {
            return (store.profiles, store.legacy)
        }
        // v1 stored a single unscoped snapshot. Preserve it and let the first
        // authenticated user claim it exactly once.
        return ([:], try? dec.decode(AchievementStats.self, from: data))
    }
}

private struct AchievementStore: Codable {
    let version: Int
    let legacy: AchievementStats?
    let profiles: [String: AchievementStats]
}
