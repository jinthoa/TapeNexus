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
/// downloads the `.pkg` asset and opens it in Installer.app so the user can
/// update the app itself (the yt-dlp updater only updates the bundled binary).
/// On-launch checks are notify-only — they never auto-install an app.
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
        guard let url = URL(string: "https://github.com/\(Self.repo)/releases/download/\(tag)/TapeNexus-\(ver).pkg"),
              let data = try? Data(contentsOf: url) else {
            report(.init(currentVersion: currentVersion, latestVersion: tag,
                         state: .failed, message: "Download failed."))
            return
        }
        // Save to ~/Downloads (stable, user-visible, matches the README's install
        // path) rather than the private temp dir, which can be cleaned and is
        // awkward to hand to Installer.
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        let dest = downloads.appendingPathComponent("TapeNexus-\(ver).pkg")
        try? FileManager.default.removeItem(at: dest)   // stale copy from a prior check
        do {
            try data.write(to: dest, options: .atomic)
            // Open the .pkg directly: macOS launches Installer.app with it as the
            // document to install. (Pre-launching Installer bare and then opening
            // the pkg on a delay is racy and surfaces a spurious "file can't be
            // found" alert before the package is handed over.)
            let opened = NSWorkspace.shared.open(dest)
            if opened {
                report(.init(currentVersion: currentVersion, latestVersion: tag,
                             state: .ready,
                             message: "Opened installer for \(tag). Quit Tape Nexus to install."))
            } else {
                report(.init(currentVersion: currentVersion, latestVersion: tag,
                             state: .failed,
                             message: "Saved \(dest.lastPathComponent) to Downloads but couldn't open Installer. Double-click it to install."))
            }
        } catch {
            report(.init(currentVersion: currentVersion, latestVersion: tag,
                         state: .failed, message: "Could not save installer: \(error.localizedDescription)"))
        }
    }

    private func report(_ s: AppUpdateStatus) {
        DispatchQueue.main.async { self.onStatus?(s) }
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