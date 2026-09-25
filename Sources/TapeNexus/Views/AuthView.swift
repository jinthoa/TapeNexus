import SwiftUI
import AppKit

/// Top-right account control that swaps between a "Sign in" button (signed
/// out) and the user's avatar (signed in). Owns the sign-in sheet. Renders
/// nothing when cloud sync isn't configured. Observes `SyncManager` directly
/// so it re-renders the moment sign-in state flips.
struct AccountControl: View {
    @ObservedObject var sync: SyncManager
    @ObservedObject var achievements: AchievementsManager
    @State private var showSignIn = false

    var body: some View {
        if sync.isSignedIn {
            AvatarMenu(sync: sync, achievements: achievements)
        } else {
            Button(action: { showSignIn = true }) {
                Label("Sign in", systemImage: "person.crop.circle.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help("Sign in or create an account")
            .sheet(isPresented: $showSignIn) {
                SignInSheet(sync: sync, achievements: achievements)
            }
        }
    }
}

/// Circular avatar with the user's initial. Click → profile popover.
struct AvatarMenu: View {
    @ObservedObject var sync: SyncManager
    @ObservedObject var achievements: AchievementsManager
    @State private var showProfile = false

    private var initial: String {
        String((sync.email ?? "?").prefix(1)).uppercased()
    }

    var body: some View {
        Button(action: { showProfile = true }) {
            Text(initial)
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(LinearGradient(colors: [Theme.accent, Theme.accent2],
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing)))
                .overlay(Circle().stroke(Theme.line, lineWidth: 0.5))
                .help(sync.email ?? "")
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showProfile, arrowEdge: .top) {
            ProfilePopover(sync: sync, achievements: achievements)
        }
    }
}

/// Popover under the avatar: email + running tally, the badge grid, and
/// Sign out. This is the only place achievements are surfaced now. Also offers
/// "Link Google" / "Link email" so a user can merge the other provider onto
/// their account (both identities then map to one user_id → shared badges).
struct ProfilePopover: View {
    @ObservedObject var sync: SyncManager
    @ObservedObject var achievements: AchievementsManager
    @State private var linkError: String?
    @State private var linking = false
    @State private var showSetPassword = false
    @State private var showLeaderboard = false

    private var hasGoogle: Bool { sync.providers.contains("google") }
    private var hasEmail: Bool { sync.providers.contains("email") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(String((sync.email ?? "?").prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(LinearGradient(colors: [Theme.accent, Theme.accent2],
                                                     startPoint: .topLeading,
                                                     endPoint: .bottomTrailing)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(sync.email ?? "").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text).lineLimit(1)
                    Text("\(achievements.stats.totalCompleted) downloads · \(achievements.formattedTotalBytes)")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    // Surface the new expanded stats: composite score, best
                    // streak, distinct hosts seen.
                    HStack(spacing: 10) {
                        Label("\(achievements.stats.score)", systemImage: "trophy")
                        Label("\(achievements.stats.bestStreak)d", systemImage: "flame")
                        Label("\(achievements.stats.hostsSeen.count)", systemImage: "globe")
                    }
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.muted)
                    .labelStyle(.titleAndIcon)
                }
                Spacer()
                Button("Sign out") { Task { await sync.signOut() } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            Button(action: { showLeaderboard = true }) {
                HStack {
                    Image(systemName: "trophy")
                    Text("Leaderboard")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered).controlSize(.small)
            Divider().overlay(Theme.line)

            // Identity linking — show whichever provider isn't connected yet.
            if !hasGoogle || !hasEmail {
                VStack(alignment: .leading, spacing: 6) {
                    Text("LINKED ACCOUNTS")
                        .font(.system(size: 9, weight: .bold)).tracking(1.3).foregroundStyle(Theme.muted)
                    HStack(spacing: 8) {
                        if !hasGoogle {
                            Button(action: { linkGoogle() }) {
                                HStack(spacing: 6) { GoogleGLogo(size: 13); Text("Link Google") }
                            }
                            .buttonStyle(.bordered).controlSize(.small).disabled(linking)
                        } else {
                            label("✓ Google linked")
                        }
                        if !hasEmail {
                            Button("Link email") { showSetPassword = true }
                                .buttonStyle(.bordered).controlSize(.small).disabled(linking)
                        } else {
                            label("✓ Email linked")
                        }
                    }
                    if let linkError {
                        Text(linkError).font(.system(size: 10)).foregroundStyle(Theme.err)
                    }
                }
                Divider().overlay(Theme.line)
            }

            Text("ACHIEVEMENTS")
                .font(.system(size: 9, weight: .bold)).tracking(1.3).foregroundStyle(Theme.muted)
            // 23 badges now — wrap in a ScrollView with a bounded height so the
            // popover never grows past the screen and the grid stays reachable.
            // Adaptive columns keep two per row at this width but widen
            // gracefully if the popover is made wider.
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                     GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(Achievement.allCases) { a in
                        AchievementBadge(achievement: a,
                                         unlocked: achievements.isUnlocked(a),
                                         stats: achievements.stats)
                    }
                }
            }
            .frame(maxHeight: 400)
        }
        .padding(14).frame(width: 440)
        .background(Theme.bg)
        .overlay {
            if linking {
                ZStack {
                    Theme.bg.opacity(0.6)
                    ProgressView().controlSize(.small)
                }
            }
        }
        .sheet(isPresented: $showSetPassword) {
            SetPasswordSheet(sync: sync, done: { showSetPassword = false })
        }
        .sheet(isPresented: $showLeaderboard) {
            LeaderboardSheet(sync: sync, achievements: achievements)
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.muted)
    }

    private func linkGoogle() {
        linking = true; linkError = nil
        Task {
            do {
                try await sync.linkGoogle()
            } catch let ex {
                linkError = ex.localizedDescription
            }
            linking = false
        }
    }
}

/// Sets a password on a Google-only account so email + password also works
/// (both identities → one user_id). Shown from the "Link email" button.
struct SetPasswordSheet: View {
    @ObservedObject var sync: SyncManager
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Link email").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16)).foregroundStyle(Theme.muted)
                }.buttonStyle(.plain)
            }.padding(.horizontal, 18).padding(.vertical, 12)
            Divider().overlay(Theme.line)

            VStack(alignment: .leading, spacing: 14) {
                Text("Set a password so you can also sign in with email + password. Both stay linked to one account.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 6) {
                    Text("New password").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder).onSubmit { submit() }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Confirm password").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    SecureField("Repeat password", text: $confirm)
                        .textFieldStyle(.roundedBorder).onSubmit { submit() }
                }
                HStack(spacing: 10) {
                    Button(action: { submit() }) {
                        Text("Set password")
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(busy || password.isEmpty || password != confirm)
                    if busy { Spacer(); ProgressView().controlSize(.small) }
                }
                if let err = error {
                    Text(err).font(.system(size: 11)).foregroundStyle(Theme.err)
                }
            }.padding(18)
            Spacer()
            Divider().overlay(Theme.line)
            HStack { Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.bordered).controlSize(.regular)
            }.padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 380, height: 320)
        .background(Theme.bg)
    }

    private func submit() {
        guard password == confirm else { error = "Passwords don't match."; return }
        busy = true; error = nil
        let p = password
        Task {
            do {
                try await sync.setPassword(p)
                busy = false
                dismiss(); done()
            } catch let ex {
                error = ex.localizedDescription; busy = false
            }
        }
    }
}

/// Sign-in / sign-up sheet opened from the top-right "Sign in" button. A
/// segmented control picks the mode (Sign in vs Create account) — clearer
/// than a toggle. Email + password, Google, then submit.
struct SignInSheet: View {
    @ObservedObject var sync: SyncManager
    @ObservedObject var achievements: AchievementsManager
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16)).foregroundStyle(Theme.muted)
                }.buttonStyle(.plain).help("Close")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider().overlay(Theme.line)

            VStack(alignment: .leading, spacing: 14) {
                Text("Sign in to sync your achievements across machines. Everything works without an account — sign in to unlock badges.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Email").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    TextField("you@example.com", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress).disableAutocorrection(true)
                        .onSubmit { submit() }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Password").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder).onSubmit { submit() }
                }

                HStack(spacing: 10) {
                    Button(action: { submit() }) {
                        Text("Continue")
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(busy || email.isEmpty || password.isEmpty)

                    Button(action: { google() }) {
                        HStack(spacing: 6) {
                            GoogleGLogo(size: 14)
                            Text("Google")
                        }
                    }
                    .buttonStyle(.bordered).disabled(busy)

                    if busy { Spacer(); ProgressView().controlSize(.small) }
                }

                if let err = error {
                    Text(err).font(.system(size: 11)).foregroundStyle(Theme.err)
                }
            }
            .padding(18)

            Spacer()
            Divider().overlay(Theme.line)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered).controlSize(.regular)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 400, height: 380)
        .background(Theme.bg)
    }

    private func submit() {
        busy = true; error = nil
        let e = email, p = password
        Task {
            do {
                try await sync.signInOrSignUp(email: e, password: p)
                if sync.isSignedIn {
                    achievements.activateUser(sync.userId)
                    await sync.pullAndMerge(into: achievements)
                }
                password = ""
                busy = false
                if sync.isSignedIn { dismiss() }
            } catch let ex {
                error = ex.localizedDescription
                busy = false
            }
        }
    }

    private func google() {
        busy = true; error = nil
        Task {
            do {
                try await sync.signInWithGoogle()
                if sync.isSignedIn {
                    achievements.activateUser(sync.userId)
                    await sync.pullAndMerge(into: achievements)
                }
                busy = false
                if sync.isSignedIn { dismiss() }
            } catch let ex {
                error = ex.localizedDescription
                busy = false
            }
        }
    }
}

/// The 4-color Google "G" drawn programmatically (no image asset).
struct GoogleGLogo: View {
    var size: CGFloat = 16

    var body: some View {
        Canvas { ctx, sz in
            let cx = sz.width / 2, cy = sz.height / 2
            let R = min(sz.width, sz.height) / 2 * 0.94
            let midR = R * 0.70
            let lw = R * 0.30
            let cap = StrokeStyle(lineWidth: lw, lineCap: .round)
            func arc(_ a0: Double, _ a1: Double, _ color: Color) {
                var p = Path()
                p.addArc(center: CGPoint(x: cx, y: cy), radius: midR,
                         startAngle: .degrees(a0), endAngle: .degrees(a1), clockwise: true)
                ctx.stroke(p, with: .color(color), style: cap)
            }
            let blue   = Color(red: 0.26, green: 0.52, blue: 0.96)
            let red    = Color(red: 0.92, green: 0.26, blue: 0.21)
            let yellow = Color(red: 0.98, green: 0.74, blue: 0.05)
            let green  = Color(red: 0.20, green: 0.66, blue: 0.33)
            arc(240, 330, blue)    // top
            arc(330, 350, red)     // upper-right
            arc(10, 120, yellow)   // lower-right + bottom
            arc(120, 240, green)   // left
            // blue crossbar from center to the right edge
            var bar = Path()
            bar.move(to: CGPoint(x: cx - midR * 0.10, y: cy))
            bar.addLine(to: CGPoint(x: cx + R, y: cy))
            ctx.stroke(bar, with: .color(blue),
                       style: StrokeStyle(lineWidth: lw, lineCap: .butt))
        }
        .frame(width: size, height: size)
    }
}

/// Global, opt-in leaderboard. Shows the user's opt-in toggle + display name,
/// their rank + composite score, and the top-100 board (their row
/// highlighted). Opting in exposes only display_name/score/total_completed via
/// the `leaderboard` view — full stats stay private.
struct LeaderboardSheet: View {
    @ObservedObject var sync: SyncManager
    @ObservedObject var achievements: AchievementsManager
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [LeaderboardEntry] = []
    @State private var nearAbove: [LeaderboardEntry] = []
    @State private var nearBelow: [LeaderboardEntry] = []
    @State private var myRank: Int?
    @State private var loading = true
    @State private var saving = false
    @State private var displayName = ""
    @State private var optIn = false
    @State private var mode = 0            // 0 = Top 100, 1 = Near you
    @State private var error: String?

    private var myId: String? { sync.userId }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Leaderboard", systemImage: "trophy")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16)).foregroundStyle(Theme.muted)
                }.buttonStyle(.plain).help("Close")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider().overlay(Theme.line)

            VStack(alignment: .leading, spacing: 14) {
                // Opt-in profile
                VStack(alignment: .leading, spacing: 8) {
                    Text("Show me on the board")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text)
                    HStack(spacing: 10) {
                        Toggle("", isOn: $optIn).toggleStyle(.switch).controlSize(.small).labelsHidden()
                        TextField("Display name", text: $displayName)
                            .textFieldStyle(.roundedBorder).controlSize(.small)
                            .disabled(!optIn)
                        Button(action: { saveProfile() }) {
                            if saving { ProgressView().controlSize(.small) } else { Text("Save") }
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                        .disabled(saving || (optIn && displayName.trimmingCharacters(in: .whitespaces).isEmpty))
                    }
                    Text("Only your display name, score, and download count are public. Everything else stays private.")
                        .font(.system(size: 9)).foregroundStyle(Theme.muted)
                }
                .padding(10)
                .background(Theme.panel2)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
                .clipShape(RoundedRectangle(cornerRadius: 9))

                // Your rank + score
                HStack(spacing: 18) {
                    stat("Your rank", myRank.map { "#\($0)" } ?? "—")
                    stat("Your score", "\(achievements.stats.score)")
                    stat("Downloads", "\(achievements.stats.totalCompleted)")
                    Spacer()
                    Button(action: { Task { await load() } }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }.buttonStyle(.plain).help("Refresh")
                }

                if let error {
                    Text(error).font(.system(size: 11)).foregroundStyle(Theme.err)
                }

                // Board: Top 100 or Near you.
                Picker("", selection: $mode) {
                    Text("Top 100").tag(0)
                    Text("Near you").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden()

                if loading {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        .padding(.vertical, 24)
                } else if mode == 0 && entries.isEmpty {
                    Text("No one's on the board yet — be the first.")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
                } else if mode == 1 && nearAbove.isEmpty && nearBelow.isEmpty {
                    Text("No one's on the board yet — be the first.")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            if mode == 0 {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { idx, e in
                                    leaderboardRow(rank: idx + 1, entry: e, isMe: e.userId == myId)
                                }
                            } else {
                                nearMeRows
                            }
                        }
                    }
                }
            }
            .padding(18)

            Spacer()
            Divider().overlay(Theme.line)
            HStack { Spacer()
                Button("Done") { dismiss() }.buttonStyle(.bordered).controlSize(.regular)
            }.padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 460, height: 560)
        .background(Theme.bg)
        .task { await load() }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
            Text(label).font(.system(size: 9)).foregroundStyle(Theme.muted)
        }
    }

    private func leaderboardRow(rank: Int, entry: LeaderboardEntry, isMe: Bool) -> some View {
        HStack(spacing: 10) {
            Text(rank > 0 ? "\(rank)" : "—").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(rank > 0 && rank <= 3 ? Theme.accent : Theme.muted).frame(width: 28, alignment: .leading)
            Text(entry.displayName).font(.system(size: 12, weight: isMe ? .bold : .medium))
                .foregroundStyle(isMe ? Theme.accent : Theme.text).lineLimit(1)
            Spacer()
            Text("\(entry.score)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text)
                .frame(width: 70, alignment: .trailing)
            Text("\(entry.totalCompleted) dl").font(.system(size: 10)).foregroundStyle(Theme.muted)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(isMe ? Theme.accent.opacity(0.12) : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isMe ? Theme.accent.opacity(0.4) : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// "Near you" rows: closest entries above (farthest-first so it reads
    /// top-to-bottom), then the user + entries below. Ranks derive from
    /// `myRank`; if the rank couldn't be determined we show "—".
    private var nearMeRows: some View {
        let r = myRank ?? 0
        let above = Array(nearAbove.reversed())
        let aboveStart = r - nearAbove.count   // rank of the farthest shown above
        return VStack(spacing: 4) {
            ForEach(Array(above.enumerated()), id: \.element.id) { i, e in
                leaderboardRow(rank: aboveStart + i, entry: e, isMe: false)
            }
            ForEach(Array(nearBelow.enumerated()), id: \.element.id) { i, e in
                leaderboardRow(rank: r + i, entry: e, isMe: e.userId == myId)
            }
        }
    }

    private func load() async {
        loading = true; error = nil
        displayName = achievements.stats.displayName
        optIn = achievements.stats.leaderboardOptIn
        let score = achievements.stats.score
        async let board = sync.fetchLeaderboard()
        async let rank = sync.fetchMyRank(myScore: score)
        async let near = sync.fetchNearMe(myScore: score)
        let (b, r, n) = await (board, rank, near)
        entries = b
        myRank = r
        nearAbove = n.above
        nearBelow = n.meAndBelow
        loading = false
    }

    private func saveProfile() {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !optIn || !name.isEmpty else { return }
        saving = true; error = nil
        achievements.setLeaderboardProfile(name: name, optIn: optIn)
        Task {
            await sync.pushAchievements(achievements.stats)
            await load()
            saving = false
        }
    }
}

/// One row in the Achievements grid: icon + title + subtitle + lock/check.
/// Shared by the profile popover (and previously the Settings panel).
struct AchievementBadge: View {
    let achievement: Achievement
    let unlocked: Bool
    let stats: AchievementStats

    /// Secret achievements hide their title/subtitle/symbol until unlocked.
    private var hidden: Bool { achievement.secret && !unlocked }
    private var accent: Color { unlocked ? (achievement.secret ? Color.purple : Theme.accent) : Theme.muted }
    /// Progress bar only on locked grindy badges (target >= 2).
    private var prog: (current: Double, target: Double, unit: String)? {
        guard !unlocked else { return nil }
        guard let p = achievement.progress(in: stats), p.target >= 2 else { return nil }
        return p
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: hidden ? "questionmark.circle" : achievement.symbol)
                .font(.system(size: 18))
                .foregroundStyle(accent)
                .opacity(unlocked ? 1 : 0.45)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(hidden ? "Secret" : achievement.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(unlocked ? (achievement.secret ? Color.purple : Theme.text) : Theme.muted)
                    if achievement.secret && unlocked {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9)).foregroundStyle(Color.purple)
                    }
                }
                .lineLimit(1)   // uniform title size — never scale or mid-word wrap
                if let prog {
                    // Grindy locked badge: 1-line description + a thin progress bar.
                    Text(hidden ? "Hidden — keep going to reveal." : achievement.subtitle)
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        ProgressView(value: min(max(prog.current / prog.target, 0), 1))
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                        Text("\(Int(prog.current))/\(Int(prog.target))\(prog.unit)")
                            .font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.muted)
                            .monospacedDigit()
                    }
                } else {
                    Text(hidden ? "Hidden — keep going to reveal." : achievement.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)   // full description, up to 2 lines
                }
            }
            Spacer()
            Image(systemName: unlocked ? "checkmark.circle.fill" : "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(unlocked ? Theme.ok : Theme.muted)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(height: 64, alignment: .top)   // uniform cell height → even grid spacing
        .background(Theme.panel2)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}
