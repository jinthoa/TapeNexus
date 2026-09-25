import Foundation
import AppKit

/// Status of an app self-update check (distinct from the yt-dlp updater).
struct AppUpdateStatus: Equatable {
    var currentVersion: String = ""
    var latestVersion: String = ""
    var state: State = .idle
    var message: String = ""
    enum State { case idle, checking, downloading, ready, upToDate, failed }
}

/// Checks GitHub for a newer Tape Nexus release and, on manual request,
/// downloads the `.pkg` asset, installs it with admin privileges (system
/// password prompt), then quits and relaunches the new version so the update
/// takes over in place (the yt-dlp updater only updates the bundled binary).
/// On-launch checks are notify-only until the user picks Download and install.
final class AppUpdater {
    static let repo = "jinthoa/TapeNexus"
    var onStatus: ((AppUpdateStatus) -> Void)?
    /// Fired on a launch (`auto`) check when a newer release is found, so the
    /// app can present a Skip / Download-and-install popup. (current, latest)
    var onUpdateAvailable: ((_ current: String, _ latest: String) -> Void)?

    /// Most recently fetched latest tag, cached so the popup's "Download and
    /// install" can act without re-fetching.
    private var lastTag: String?

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// `auto = true` (launch): notify only if a newer release exists — and fire
    /// `onUpdateAvailable` so the app can show a popup.
    /// `auto = false` (manual button): download the `.pkg` and open Installer.
    func check(auto: Bool) {
        report(.init(currentVersion: currentVersion, state: .checking,
                     message: "Checking for Tape Nexus updates…"))
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            guard let tag = self.fetchLatestTag() else {
                self.report(.init(currentVersion: self.currentVersion, state: .failed,
                                  message: "Could not reach GitHub."))
                return
            }
            self.lastTag = tag
            guard self.isNewer(latest: tag, current: self.currentVersion) else {
                self.report(.init(currentVersion: self.currentVersion, latestVersion: tag,
                                  state: .upToDate,
                                  message: "Tape Nexus \(self.currentVersion) · up to date"))
                return
            }
            if auto {
                self.report(.init(currentVersion: self.currentVersion, latestVersion: tag,
                                  state: .idle,
                                  message: "Tape Nexus \(tag) available."))
                let cur = self.currentVersion
                DispatchQueue.main.async { self.onUpdateAvailable?(cur, tag) }
                return
            }
            self.downloadAndInstall(tag: tag)
        }
    }

    /// Download the cached latest release's `.pkg` and open Installer. Falls
    /// back to a full check if we don't have a cached tag yet.
    func downloadAndInstallLatest() {
        if let tag = lastTag {
            downloadAndInstall(tag: tag)
        } else {
            check(auto: false)
        }
    }

    private func downloadAndInstall(tag: String) {
        report(.init(currentVersion: currentVersion, latestVersion: tag,
                     state: .downloading, message: "Downloading Tape Nexus \(tag)…"))
        // Asset filename is TapeNexus-<version>.pkg (build.sh stamps it from the
        // release tag), so the download URL is predictable — no API call needed.
        let ver = tag.drop(while: { $0 == "v" || $0 == "V" })
        guard let url = URL(string: "https://github.com/\(Self.repo)/releases/download/\(tag)/TapeNexus-\(ver).pkg") else {
            report(.init(currentVersion: currentVersion, latestVersion: tag,
                         state: .failed, message: "Bad download URL."))
            return
        }
        // Download + install off the main thread: the install blocks on the
        // system admin-password dialog and the installer run.
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            guard let data = try? Data(contentsOf: url) else {
                self.report(.init(currentVersion: self.currentVersion, latestVersion: tag,
                                  state: .failed, message: "Download failed."))
                return
            }
            // Save to ~/Downloads (stable, user-visible, matches the README's
            // install path) rather than the private temp dir, which can be
            // cleaned and is awkward to hand to installer.
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
            let dest = downloads.appendingPathComponent("TapeNexus-\(ver).pkg")
            try? FileManager.default.removeItem(at: dest)   // stale copy from a prior check
            do {
                try data.write(to: dest, options: .atomic)
            } catch {
                self.report(.init(currentVersion: self.currentVersion, latestVersion: tag,
                                  state: .failed, message: "Could not save installer: \(error.localizedDescription)"))
                return
            }
            // Install silently with admin privileges (the system shows a Mac
            // password dialog), then quit + relaunch so the new version takes
            // over in place — no manual Installer walk-through or relaunch.
            self.report(.init(currentVersion: self.currentVersion, latestVersion: tag,
                              state: .downloading,
                              message: "Installing Tape Nexus \(tag)… (enter your Mac password)"))
            // Marker the installer's preinstall script looks for: if present
            // and our PID is a live TapeNexus, preinstall must NOT kill us —
            // we're blocked on the installer's exit and will quit + relaunch
            // ourselves once it returns. Without it, preinstall kills the
            // orchestrating app mid-install and the installer aborts.
            self.writeSelfUpdateSentinel()
            if !self.runPrivilegedInstall(pkg: dest) {
                self.clearSelfUpdateSentinel()
                self.report(.init(currentVersion: self.currentVersion, latestVersion: tag,
                                  state: .failed,
                                  message: "Install cancelled or failed. \(dest.lastPathComponent) is in Downloads — double-click it to install manually."))
                return
            }
            self.report(.init(currentVersion: self.currentVersion, latestVersion: tag,
                              state: .ready, message: "Tape Nexus \(tag) installed — relaunching…"))
            self.relaunchAndQuit()
        }
    }

    /// Run `installer -pkg <pkg> -target /` with administrator privileges via
    /// `osascript`, which surfaces the native macOS admin-password dialog.
    /// Returns true on a successful (exit 0) install, false if the user cancelled
    /// the prompt or the installer failed.
    private func runPrivilegedInstall(pkg: URL) -> Bool {
        // Shell-single-quote the path, then embed the whole shell command in an
        // AppleScript double-quoted string (escaping \ and ").
        let shellSingle = pkg.path.replacingOccurrences(of: "'", with: "'\\''")
        let shellCmd = "installer -pkg '\(shellSingle)' -target /"
        let asString = shellCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let asLine = "do shell script \"\(asString)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", asLine]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Spawn a detached `sleep 3; open /Applications/TapeNexus.app` (reparented
    /// to launchd when we exit, so it survives our termination), then quit. The
    /// pkg always installs to /Applications/TapeNexus.app, so that's the path to
    /// relaunch. The 3s grace lets the old process fully terminate before the
    /// new bundle is opened.
    private func relaunchAndQuit() {
        clearSelfUpdateSentinel()
        let appPath = "/Applications/TapeNexus.app"
        let quoted = appPath.replacingOccurrences(of: "'", with: "'\\''")
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 3; open '\(quoted)'"]
        try? relaunch.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private func report(_ s: AppUpdateStatus) {
        DispatchQueue.main.async { self.onStatus?(s) }
    }

    /// Marker file (/tmp/tn-self-update) holding our PID, written before the
    /// privileged install so the installer's preinstall script can tell an
    /// in-app self-update (don't kill the orchestrating app) from a manual
    /// .pkg install (kill + relaunch the idle app). See preinstall in build.sh.
    private static let sentinelPath = "/tmp/tn-self-update"
    private func writeSelfUpdateSentinel() {
        try? "\(ProcessInfo.processInfo.processIdentifier)"
            .write(toFile: Self.sentinelPath, atomically: true, encoding: .utf8)
    }
    private func clearSelfUpdateSentinel() {
        try? FileManager.default.removeItem(atPath: Self.sentinelPath)
    }

    // MARK: - GitHub

    /// Resolve the latest release tag WITHOUT the GitHub REST API.
    ///
    /// `api.github.com/repos/.../releases/latest` is rate-limited to 60
    /// requests/hour per IP (unauthenticated), and a shared NAT/VPN exhausts
    /// that fast — a 403 returns a `{"message": "rate limit exceeded"}` body
    /// that fails to decode into a release, surfacing as a misleading
    /// "Could not reach GitHub." Instead hit the HTML endpoint
    /// `github.com/<repo>/releases/latest`, which 302-redirects to
    /// `.../releases/tag/<tag>` (NOT rate-limited). URLSession follows the
    /// redirect chain and the final URL's last path component is the tag.
    private func fetchLatestTag() -> String? {
        guard let url = URL(string: "https://github.com/\(Self.repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("TapeNexus", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let sem = DispatchSemaphore(value: 0)
        var finalURL: URL?
        URLSession.shared.dataTask(with: req) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 302,
               let loc = http.value(forHTTPHeaderField: "Location") {
                finalURL = URL(string: loc)
            } else {
                finalURL = response?.url
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 20)
        // Last path component of /releases/tag/<tag> is the tag ("v1.0.12").
        return finalURL?.lastPathComponent
    }

    /// Compare semver-ish tags: "v1.2.3" vs "1.2.3" — strip a leading "v".
    private func isNewer(latest: String, current: String) -> Bool {
        let l = latest.drop(while: { $0 == "v" || $0 == "V" }).split(separator: ".").compactMap { Int($0) }
        let c = current.drop(while: { $0 == "v" || $0 == "V" }).split(separator: ".").compactMap { Int($0) }
        let n = max(l.count, c.count)
        for i in 0..<n {
            let lv = i < l.count ? l[i] : 0
            let cv = i < c.count ? c[i] : 0
            if lv != cv { return lv > cv }
        }
        return false
    }
}