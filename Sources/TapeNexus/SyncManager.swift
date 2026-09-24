import Foundation
import AppKit
import Combine
import CommonCrypto
import AuthenticationServices

/// Optional cloud sync: Supabase Auth (email + Google) + a single
/// `achievements` row per user so badges follow you across machines.
///
/// No Supabase SDK — we call the GoTrue Auth REST + PostgREST APIs directly
/// with URLSession. The anon key is public by design; Row Level Security on
/// the `achievements` table is the real boundary (a user can only read/write
/// their own row). When `sync.json` is empty/absent, sync is disabled and the
/// app stays fully local — account is strictly opt-in.
@MainActor
final class SyncManager: ObservableObject {
    @Published private(set) var isSignedIn = false
    @Published private(set) var email: String?
    @Published private(set) var isConfigured = false

    private let url: String        // e.g. https://xxxx.supabase.co
    private let anonKey: String
    private let supportDir: URL
    private var session: SyncSession?
    private let sessionURL: URL
    private let presenter = WebAuthPresenter()
    private var authSession: ASWebAuthenticationSession?   // retained during Google sign-in

    /// Returns nil (sync disabled) when no URL/anonKey are configured.
    init?(supportDir: URL) {
        let cfg = SyncConfig.load()
        guard let url = cfg.url, let key = cfg.anonKey,
              !url.isEmpty, !key.isEmpty else { return nil }
        self.url = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.anonKey = key
        self.supportDir = supportDir
        self.sessionURL = supportDir.appendingPathComponent("sync_session.json")
        self.isConfigured = true
        restoreSession()
    }

    // MARK: - Email

    func signUp(email: String, password: String) async throws {
        let body: [String: Any] = ["email": email, "password": password]
        let json = try await authPost("signup", body: body)
        try applySession(json)
    }

    func signIn(email: String, password: String) async throws {
        let body: [String: Any] = ["email": email, "password": password]
        let json = try await authPost("token?grant_type=password", body: body)
        try applySession(json)
    }

    /// Auto-detects existing vs new accounts — one form, no mode toggle, like
    /// Google. Tries sign-in first; on an invalid-credentials error (the
    /// account may not exist yet) falls back to sign-up. If sign-up then
    /// reports the email is already registered, the password was wrong.
    func signInOrSignUp(email: String, password: String) async throws {
        do {
            try await signIn(email: email, password: password)
        } catch SyncError.server(let msg) where msg.lowercased().contains("invalid") {
            do {
                try await signUp(email: email, password: password)
            } catch SyncError.server(let m) where m.lowercased().contains("already") {
                throw SyncError.server("Incorrect password for that email.")
            }
        }
    }

    // MARK: - Google (system browser via ASWebAuthenticationSession + PKCE)

    /// Signs in with Google using ASWebAuthenticationSession: the system opens
    /// the user's DEFAULT browser (so existing Google cookies/sessions are
    /// reused — no re-typing), and the session auto-completes the moment
    /// Supabase redirects to the `tapenexus://auth/callback` scheme, returning
    /// focus to the app. The returned auth code is exchanged for a session via
    /// PKCE. Throws on cancel/error. Requires `tapenexus://auth/callback` in
    /// Supabase's Redirect URLs.
    func signInWithGoogle() async throws {
        let verifier = Self.randomCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let scheme = "tapenexus"
        let redirect = "\(scheme)://auth/callback"
        var comps = URLComponents(string: "\(url)/auth/v1/authorize")!
        comps.queryItems = [
            "provider": "google",
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "redirect_to": redirect,
            "scopes": "email profile",
        ].map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let authURL = comps.url else { throw SyncError.badConfig }

        let callbackURL = try await runAuthSession(url: authURL, scheme: scheme)
        guard let cbComps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = cbComps.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw SyncError.googleCancelled
        }
        let body: [String: Any] = ["auth_code": code, "code_verifier": verifier]
        let json = try await authPost("token?grant_type=pkce", body: body)
        try applySession(json)
    }

    /// Opens `url` in the user's default browser via ASWebAuthenticationSession
    /// (reusing existing cookies) and resumes when the browser redirects back
    /// to `scheme://...`. Shared by sign-in and identity linking.
    private func runAuthSession(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            var resumed = false
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { cb, err in
                guard !resumed else { return }; resumed = true
                if let cb { cont.resume(returning: cb) }
                else if let err { cont.resume(throwing: err) }
                else { cont.resume(throwing: SyncError.googleCancelled) }
            }
            session.presentationContextProvider = self.presenter
            session.prefersEphemeralWebBrowserSession = false  // reuse browser cookies
            self.authSession = session
            if !session.start() {
                guard !resumed else { return }; resumed = true
                cont.resume(throwing: SyncError.googleCancelled)
            }
        }
    }

    func signOut() async {
        guard let token = session?.accessToken else { return }
        _ = try? await authPost("logout", body: [:], bearer: token)
        session = nil
        saveSession()
        isSignedIn = false
        email = nil
    }

    // MARK: - Identity linking

    /// Links Google to the currently signed-in user (email→google or
    /// google→email both map to ONE user_id, so achievements share one row).
    /// Calls GoTrue's authorize-link endpoint WITH the user's bearer token;
    /// it returns a 302 to Google. We capture that Location (a bearer header
    /// can't be sent from the browser), open it in the default browser via
    /// ASWebAuthenticationSession, and exchange the returned code for a new
    /// linked session via PKCE. Requires Manual Linking enabled in Supabase.
    func linkGoogle() async throws {
        guard let token = session?.accessToken else { throw SyncError.noSession }
        let verifier = Self.randomCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let scheme = "tapenexus"
        let redirect = "\(scheme)://auth/callback"
        var comps = URLComponents(string: "\(url)/auth/v1/user/identities/authorize")!
        comps.queryItems = [
            "provider": "google",
            "scopes": "email profile",
            "redirect_to": redirect,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
        ].map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let linkURL = comps.url else { throw SyncError.badConfig }

        // The endpoint needs the bearer token, so we can't just hand the URL to
        // the browser. Fetch it with URLSession, stopping at the 302 to grab
        // Google's authorize URL (which carries no secret — it's the public
        // OAuth consent screen).
        let capturer = RedirectCapturer()
        var req = URLRequest(url: linkURL)
        req.httpMethod = "GET"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let cfg = URLSessionConfiguration.default
        cfg.httpShouldSetCookies = false
        let urlSession = URLSession(configuration: cfg, delegate: capturer, delegateQueue: nil)
        let googleURL = await capturer.captureRedirect(for: req, session: urlSession)
        urlSession.finishTasksAndInvalidate()
        guard let googleURL else { throw SyncError.server("Could not start Google linking.") }

        let callbackURL = try await runAuthSession(url: googleURL, scheme: scheme)
        guard let cbComps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = cbComps.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw SyncError.googleCancelled
        }
        let body: [String: Any] = ["auth_code": code, "code_verifier": verifier]
        let json = try await authPost("token?grant_type=pkce", body: body)
        try applySession(json)
        await refreshUser()
    }

    /// Sets a password on an OAuth-only (Google) account so the user can also
    /// sign in with email + password. Both identities share one user_id.
    func setPassword(_ password: String) async throws {
        guard let token = session?.accessToken else { throw SyncError.noSession }
        var req = URLRequest(url: URL(string: "\(url)/auth/v1/user")!)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["password": password])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["msg"] as? String
                ?? "HTTP \(http.statusCode)"
            throw SyncError.server(msg)
        }
        await refreshUser()
    }

    /// Re-fetches the user object so `providers` reflects the just-linked
    /// identity, and re-publishes so the avatar menu updates live.
    func refreshUser() async {
        guard let token = session?.accessToken else { return }
        var req = URLRequest(url: URL(string: "\(url)/auth/v1/user")!)
        req.httpMethod = "GET"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // GET /user returns no token; keep the existing access/refresh tokens.
        if var s = session {
            s.user = SyncUser(id: s.user.id,
                              email: user["email"] as? String ?? s.user.email,
                              providers: Self.providers(from: user))
            session = s
            saveSession()
            email = s.user.email
            objectWillChange.send()
        }
    }

    // MARK: - Session restore / refresh

    private func restoreSession() {
        guard let data = try? Data(contentsOf: sessionURL),
              let s = try? JSONDecoder().decode(SyncSession.self, from: data) else { return }
        session = s
        if Date().timeIntervalSince1970 > Double(s.expiresAt) - 60 {
            Task { await refresh() }
        } else {
            isSignedIn = true
            email = s.user.email
        }
    }

    private func refresh() async {
        guard let refresh = session?.refreshToken else { return }
        let body: [String: Any] = ["refresh_token": refresh]
        guard let json = try? await authPost("token?grant_type=refresh_token", body: body) else {
            session = nil; saveSession(); isSignedIn = false; email = nil; return
        }
        try? applySession(json)
    }

    private func applySession(_ json: [String: Any]) throws {
        guard let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? Int,
              let user = json["user"] as? [String: Any],
              let uid = user["id"] as? String else {
            // Signup with email confirmation ON returns no session — surface a
            // clear message rather than a generic failure.
            if let msg = json["message"] as? String { throw SyncError.server(msg) }
            throw SyncError.noSession
        }
        let now = Date().timeIntervalSince1970
        let s = SyncSession(
            accessToken: access, refreshToken: refresh,
            expiresAt: now + Double(expiresIn),
            user: SyncUser(id: uid,
                           email: user["email"] as? String ?? "",
                           providers: Self.providers(from: user)))
        session = s
        saveSession()
        isSignedIn = true
        email = s.user.email
    }

    /// Auth providers linked to the current user (e.g. ["email"], ["google"],
    /// or both). Used by the avatar menu to show "Link Google" / "Link email".
    var providers: [String] { session?.user.providers ?? [] }

    /// Extract linked provider names from a GoTrue user object.
    private static func providers(from user: [String: Any]) -> [String] {
        var out: [String] = []
        if let idents = user["identities"] as? [[String: Any]] {
            out = idents.compactMap { $0["provider"] as? String }
        }
        if out.isEmpty, let am = user["app_metadata"] as? [String: Any] {
            if let p = am["provider"] as? String { out = [p] }
            if let ps = am["providers"] as? [String] { out = ps }
        }
        return out
    }

    // MARK: - Achievements sync

    /// Push the local stats snapshot to this user's row (upsert).
    func pushAchievements(_ stats: AchievementStats) async {
        guard let s = session else { return }
        guard let row = Self.achievementRow(for: s.user.id, stats: stats) else { return }
        var req = URLRequest(url: URL(string: "\(url)/rest/v1/achievements?on_conflict=user_id")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(s.accessToken)", forHTTPHeaderField: "Authorization")
        // Upsert: merge on conflict, return the resulting row.
        req.setValue("return=representation,resolution=merge-duplicates",
                     forHTTPHeaderField: "Prefer")
        req.httpBody = try? JSONSerialization.data(withJSONObject: row)
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Pull the user's server row and merge it into the local manager, then
    /// push the merged snapshot back so other devices converge.
    func pullAndMerge(into manager: AchievementsManager) async {
        guard let s = session else { return }
        var req = URLRequest(url: URL(string: "\(url)/rest/v1/achievements?select=*&limit=1")!)
        req.httpMethod = "GET"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(s.accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let row = rows.first,
              let remote = Self.stats(from: row) else { return }
        manager.merge(remote)
        await pushAchievements(manager.stats)
    }

    // MARK: - HTTP

    private func authPost(_ path: String, body: [String: Any], bearer: String? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "\(url)/auth/v1/\(path)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["msg"] as? String
                ?? (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                ?? "HTTP \(http.statusCode)"
            throw SyncError.server(msg)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func saveSession() {
        guard let s = session,
              let data = try? JSONEncoder().encode(s) else { try? FileManager.default.removeItem(at: sessionURL); return }
        try? data.write(to: sessionURL, options: .atomic)
    }

    // MARK: - PKCE

    static let loopbackPort: UInt16 = 47823

    static func randomCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    static func codeChallenge(for verifier: String) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let data = Data(verifier.utf8)
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(ptr.count), &hash)
        }
        return Data(hash).base64URLEncodedString()
    }

    static func achievementRow(for uid: String, stats: AchievementStats) -> [String: Any]? {
        let iso = ISO8601DateFormatter().string(from: Date())
        let firstISO: String?
        if let d = stats.firstCompletedAt {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; firstISO = f.string(from: d)
        } else { firstISO = nil }
        var row: [String: Any] = [
            "user_id": uid,
            "total_completed": stats.totalCompleted,
            "total_bytes": stats.totalBytes,
            "unlocked_ids": Array(stats.unlockedIDs),
            "night_owl": stats.nightOwl,
            "early_bird": stats.earlyBird,
            "updated_at": iso,
        ]
        if let firstISO { row["first_completed_at"] = firstISO }
        return row
    }

    static func stats(from row: [String: Any]) -> AchievementStats? {
        var s = AchievementStats()
        s.totalCompleted = (row["total_completed"] as? Int) ?? 0
        s.totalBytes = Int64(row["total_bytes"] as? Int ?? 0)
        if let arr = row["unlocked_ids"] as? [String] { s.unlockedIDs = Set(arr) }
        else if let raw = row["unlocked_ids"] as? String,
                let d = raw.data(using: .utf8),
                let arr = try? JSONSerialization.jsonObject(with: d) as? [String] {
            s.unlockedIDs = Set(arr)
        }
        s.nightOwl = (row["night_owl"] as? Bool) ?? false
        s.earlyBird = (row["early_bird"] as? Bool) ?? false
        if let str = row["first_completed_at"] as? String {
            let f = ISO8601DateFormatter(); s.firstCompletedAt = f.date(from: str)
        }
        return s
    }
}

// MARK: - Config + session models

struct SyncConfig {
    let url: String?
    let anonKey: String?

    /// Bundled Resources/sync.json (shipped, anon key is public) overridden by
    /// TN_SUPABASE_URL / TN_SUPABASE_ANON_KEY env vars for dev.
    static func load() -> SyncConfig {
        var url = ProcessInfo.processInfo.environment["TN_SUPABASE_URL"]
        var key = ProcessInfo.processInfo.environment["TN_SUPABASE_ANON_KEY"]
        if url == nil || key == nil,
           let bundleURL = Bundle.main.url(forResource: "sync", withExtension: "json"),
           let data = try? Data(contentsOf: bundleURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            url = url ?? (json["url"] as? String)
            key = key ?? (json["anonKey"] as? String)
        }
        return SyncConfig(url: url, anonKey: key)
    }
}

struct SyncSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Double
    var user: SyncUser
}

struct SyncUser: Codable {
    var id: String
    var email: String
    var providers: [String]

    init(id: String, email: String, providers: [String] = []) {
        self.id = id; self.email = email; self.providers = providers
    }

    /// Backward-compat: older sync_session.json files have no `providers` key,
    /// so decode it as [] when absent rather than failing the whole restore.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = try c.decode(String.self, forKey: .email)
        providers = (try? c.decode([String].self, forKey: .providers)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(email, forKey: .email)
        try c.encode(providers, forKey: .providers)
    }

    enum CodingKeys: String, CodingKey { case id, email, providers }
}

enum SyncError: LocalizedError {
    case badConfig, noSession, googleCancelled, server(String)
    var errorDescription: String? {
        switch self {
        case .badConfig: return "Sync isn't configured."
        case .noSession: return "No session returned — if email confirmation is on, check your inbox first."
        case .googleCancelled: return "Google sign-in timed out or was cancelled."
        case .server(let m): return m
        }
    }
}

private extension Data {
    /// RFC 7636 / RFC 4648 §5 base64url encoding (no padding) for PKCE.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Captures the Location header of a 302 the way GoTrue's link-authorize
/// endpoint returns one (it redirects to Google's consent URL). We must stop
/// the redirect chain ourselves (a bearer header can't ride along into the
/// browser), so the delegate cancels the task and resumes with the Location.
/// The task is started INSIDE the continuation closure so `cont` is set before
/// any delegate callback can fire.
final class RedirectCapturer: NSObject, URLSessionTaskDelegate {
    private var cont: CheckedContinuation<URL?, Never>?
    private(set) var location: URL?

    func captureRedirect(for req: URLRequest, session: URLSession) async -> URL? {
        await withCheckedContinuation { c in
            self.cont = c
            session.dataTask(with: req).resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let loc = response.value(forHTTPHeaderField: "Location"), let u = URL(string: loc) {
            location = u
        }
        completionHandler(nil)  // stop following the redirect; task ends with the 302
        cont?.resume(returning: location); cont = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // If the task ended without a redirect, unblock the awaiter.
        if location == nil { cont?.resume(returning: nil); cont = nil }
    }
}

/// Provides the window ASWebAuthenticationSession anchors its browser sheet to.
@MainActor
final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let w = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            return w
        }
        // Menu-bar-only mode with no visible window: a transient anchor.
        return NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                        styleMask: [], backing: .buffered, defer: false)
    }
}