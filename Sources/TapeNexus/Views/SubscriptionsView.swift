import SwiftUI

/// Subscriptions tab — paste a channel/playlist URL, pick a format preset and a
/// check interval; the app polls for new entries on that cadence and auto-queues
/// them. Each row shows the last-checked time and how many new videos were found
/// on the last pass, with a manual "Check now" button.
struct SubscriptionsView: View {
    @EnvironmentObject var state: AppState
    @State private var newURL: String = ""
    @State private var newPreset: String = "best"
    @State private var newInterval: Int = 360

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rss")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                Text("Subscriptions")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button("Check all") { state.checkAllSubscriptions() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            Divider().overlay(Theme.line)
            addBar
            Divider().overlay(Theme.line)
            list
        }
        .background(Theme.bg)
    }

    private var addBar: some View {
        HStack(spacing: 8) {
            TextField("Paste a channel or playlist URL…", text: $newURL)
                .textFieldStyle(.plain).font(.system(size: 12))
            Picker("", selection: $newPreset) {
                ForEach(AppSettings.formatPresets, id: \.key) { p in
                    Text(p.label).tag(p.key)
                }
            }.pickerStyle(.menu).controlSize(.small).frame(width: 150)
            Stepper("\(newInterval)m", value: $newInterval, in: 15...1440, step: 15)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 90)
            Button("Add") { addSubscription() }
                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Theme.panel)
    }

    @ViewBuilder private var list: some View {
        let shown = state.subscriptions.subs
        if shown.isEmpty {
            EmptyState(icon: "rss",
                       title: "No subscriptions yet",
                       message: "Paste a channel or playlist URL above and TapeNexus will auto-queue new videos for you.")
        } else {
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(shown) { sub in
                        SubRow(sub: sub)
                    }
                }
                .padding(14)
            }
        }
    }

    private func addSubscription() {
        let u = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }
        let s = Subscription(url: u, title: "", preset: newPreset,
                             intervalMinutes: newInterval, enabled: true)
        state.subscriptions.add(s)
        newURL = ""
        // Baseline the subscription immediately so its current entries are
        // recorded without queuing the back catalogue.
        state.checkSubscription(s.id)
    }
}

struct SubRow: View {
    @EnvironmentObject var state: AppState
    let sub: Subscription

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(sub.displayTitle).font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1).foregroundStyle(Theme.text)
                HStack(spacing: 7) {
                    Text(sub.host).foregroundStyle(Theme.muted)
                    Text("·").foregroundStyle(Theme.muted)
                    Text(presetLabel).foregroundStyle(Theme.muted)
                    Text("·").foregroundStyle(Theme.muted)
                    Text("every \(sub.intervalMinutes)m").foregroundStyle(Theme.muted)
                    if let checked = sub.lastCheckedAt {
                        Text("·").foregroundStyle(Theme.muted)
                        Text("checked \(checked.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(Theme.muted)
                    }
                }.font(.system(size: 11.5)).lineLimit(1)
                if sub.lastNewCount > 0 {
                    Text("\(sub.lastNewCount) new video\(sub.lastNewCount == 1 ? "" : "s") queued last check")
                        .font(.system(size: 11)).foregroundStyle(Theme.ok)
                } else if sub.lastCheckedAt != nil {
                    Text("Up to date").font(.system(size: 11)).foregroundStyle(Theme.muted)
                } else {
                    Text("Baseline pending…").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            HStack(spacing: 5) {
                Toggle("", isOn: Binding(
                    get: { sub.enabled },
                    set: { v in state.subscriptions.update(sub.id) { $0.enabled = v } }))
                    .tint(Theme.accent).labelsHidden()
                IconButton(system: "arrow.clockwise", help: "Check now", tint: Theme.accent2) {
                    state.checkSubscription(sub.id)
                }
                IconButton(system: "xmark", help: "Remove", tint: Theme.muted) {
                    state.subscriptions.remove(sub.id)
                }
            }
        }
        .padding(12)
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var presetLabel: String {
        AppSettings.formatPresets.first(where: { $0.key == sub.preset })?.label ?? sub.preset
    }
}