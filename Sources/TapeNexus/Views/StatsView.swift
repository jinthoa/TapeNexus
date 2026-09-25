import SwiftUI

/// Insights tab — a read-only dashboard built entirely from data the app
/// already collects: `LibraryStore.entries` (per-download host/format/date) and
/// `AchievementsManager.stats` (cumulative totals, streaks, score). No backend,
/// no sync changes. Charts are hand-rolled (GeometryReader + Rectangle) so we
/// don't pull in the Charts framework and bump the build.
struct StatsView: View {
    @EnvironmentObject var state: AppState

    private var entries: [LibraryEntry] { state.library.entries }
    private var stats: AchievementStats { state.achievements.stats }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statCards
                weeklyChart
                topHosts
                topFormats
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Insights")
                .font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
            Text("Your download activity at a glance.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }

    // MARK: Stat cards

    private var statCards: some View {
        HStack(spacing: 10) {
            StatCard(system: "arrow.down.circle.fill", value: "\(stats.totalCompleted)",
                     label: "Downloads", tint: Theme.accent)
            StatCard(system: "externaldrive.fill", value: state.achievements.formattedTotalBytes,
                     label: "Total data", tint: Theme.accent2)
            StatCard(system: "flame.fill", value: "\(stats.bestStreak)d",
                     label: "Best streak", tint: Theme.warn)
            StatCard(system: "globe", value: "\(stats.hostsSeen.count)",
                     label: "Hosts", tint: Theme.blue)
            StatCard(system: "trophy.fill", value: "\(stats.score)",
                     label: "Score", tint: Theme.ok)
        }
    }

    // MARK: Weekly downloads chart

    private var weeklyChart: some View {
        let buckets = weeklyBuckets
        let maxCount = max(1, buckets.map(\.count).max() ?? 0)
        return card {
            VStack(alignment: .leading, spacing: 12) {
                chartTitle("Downloads over the last 12 weeks", hint: "\(entries.count) archived")
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(buckets) { b in
                        VStack(spacing: 4) {
                            Text(b.count > 0 ? "\(b.count)" : "")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                            GeometryReader { geo in
                                let h = geo.size.height * CGFloat(b.count) / CGFloat(maxCount)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(LinearGradient(colors: [Theme.accent, Theme.accent2],
                                                         startPoint: .bottom, endPoint: .top))
                                    .frame(height: max(b.count > 0 ? 3 : 0, h))
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                            }
                            .frame(width: 18, height: 90)
                            Text(b.label)
                                .font(.system(size: 8)).foregroundStyle(Theme.muted)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    // MARK: Top hosts

    private var topHosts: some View {
        let rows = topCounts(keyed: { $0.host }, limit: 6)
        return card {
            VStack(alignment: .leading, spacing: 10) {
                chartTitle("Top hosts", hint: "\(stats.hostsSeen.count) distinct")
                if rows.isEmpty { emptyHint }
                else {
                    ForEach(rows, id: \.key) { r in
                        HBarRow(label: r.key, count: r.count,
                                maxCount: rows[0].count, tint: Theme.accent)
                    }
                }
            }
        }
    }

    // MARK: Top formats

    private var topFormats: some View {
        let rows = topCounts(keyed: { $0.formatDesc.isEmpty ? "unknown" : $0.formatDesc }, limit: 6)
        return card {
            VStack(alignment: .leading, spacing: 10) {
                chartTitle("Formats used", hint: nil)
                if rows.isEmpty { emptyHint }
                else {
                    ForEach(rows, id: \.key) { r in
                        HBarRow(label: r.key, count: r.count,
                                maxCount: rows[0].count, tint: Theme.accent2)
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private var emptyHint: some View {
        Text("Nothing archived yet — finish a download to see stats here.")
            .font(.system(size: 11)).foregroundStyle(Theme.muted)
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func chartTitle(_ title: String, hint: String?) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            Spacer()
            if let hint { Text(hint).font(.system(size: 10)).foregroundStyle(Theme.muted) }
        }
    }

    /// Bucket archived entries into the last 12 calendar weeks (oldest → newest).
    private var weeklyBuckets: [WeekBucket] {
        let cal = Calendar.current
        let now = Date()
        guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: now) else { return [] }
        var starts: [Date] = []
        for i in stride(from: 11, through: 0, by: -1) {
            if let s = cal.date(byAdding: .weekOfYear, value: -i, to: thisWeek.start) {
                starts.append(s)
            }
        }
        var counts = Dictionary(uniqueKeysWithValues: starts.map { ($0, 0) })
        for e in entries {
            guard let wk = cal.dateInterval(of: .weekOfYear, for: e.completedAt)?.start,
                  counts[wk] != nil else { continue }
            counts[wk, default: 0] += 1
        }
        let nf = DateFormatter()
        nf.dateFormat = "w/yy"
        return starts.map { WeekBucket(label: nf.string(from: $0), count: counts[$0] ?? 0) }
    }

    /// Top-N grouped counts of archived entries by a key, sorted by count desc.
    private func topCounts(keyed: (LibraryEntry) -> String, limit: Int) -> [(key: String, count: Int)] {
        var g = [String: Int]()
        for e in entries { g[keyed(e), default: 0] += 1 }
        return g.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) }
    }
}

// MARK: - Subviews

private struct StatCard: View {
    let system: String
    let value: String
    let label: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: system).font(.system(size: 16)).foregroundStyle(tint)
            Text(value).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct HBarRow: View {
    let label: String
    let count: Int
    let maxCount: Int
    let tint: Color
    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: 170, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.panel2)
                    RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.85))
                        .frame(width: maxCount > 0
                               ? geo.size.width * CGFloat(count) / CGFloat(max(maxCount, 1)) : 0)
                }
            }
            .frame(height: 12)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

private struct WeekBucket: Identifiable {
    let id = UUID()
    let label: String
    let count: Int
}