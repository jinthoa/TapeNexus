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
                }
                Spacer()
                Button("Sign out") { Task { await sync.signOut() } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
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
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Achievement.allCases) { a in
                    AchievementBadge(achievement: a,
                                     unlocked: achievements.isUnlocked(a))
                }
            }
        }
        .padding(14).frame(width: 320)
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
                if sync.isSignedIn { await sync.pullAndMerge(into: achievements) }
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
                if sync.isSignedIn { await sync.pullAndMerge(into: achievements) }
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

/// One row in the Achievements grid: icon + title + subtitle + lock/check.
/// Shared by the profile popover (and previously the Settings panel).
struct AchievementBadge: View {
    let achievement: Achievement
    let unlocked: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: achievement.symbol)
                .font(.system(size: 17))
                .foregroundStyle(unlocked ? Theme.accent : Theme.muted)
                .opacity(unlocked ? 1 : 0.45)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(achievement.title).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(unlocked ? Theme.text : Theme.muted)
                Text(achievement.subtitle).font(.system(size: 10))
                    .foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            Image(systemName: unlocked ? "checkmark.circle.fill" : "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(unlocked ? Theme.ok : Theme.muted)
        }
        .padding(10)
        .background(Theme.panel2)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}