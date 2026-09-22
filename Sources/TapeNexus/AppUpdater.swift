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

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// `auto = true` (launch): notify only if a newer release exists.
    /// `auto = false` (manual button): download the `.pkg` and open Installer.
    func check(auto: Bool) {
        report(.init(currentVersion: currentVersion, state: .checking,
                     message: "Checking for Tape Nexus updates…"))
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            guard let release = self.fetchLatestRelease() else {
                self.report(.init(currentVersion: self.currentVersion, state: .failed,
                                  message: "Could not reach GitHub."))
                return
            }
            let latest = release.tagName
            guard self.isNewer(latest: latest, current: self.currentVersion) else {
                self.report(.init(currentVersion: self.currentVersion, latestVersion: latest,
                                  state: .upToDate,
                                  message: "Tape Nexus \(self.currentVersion) · up to date"))
                return
            }
            if auto {
                self.report(.init(currentVersion: self.currentVersion, latestVersion: latest,
                                  state: .idle,
                                  message: "Tape Nexus \(latest) available — check Settings to install."))
                return
            }
            self.downloadAndInstall(release: release, latest: latest)
        }
    }

    private func downloadAndInstall(release: Release, latest: String) {
        report(.init(currentVersion: currentVersion, latestVersion: latest,
                     state: .downloading, message: "Downloading Tape Nexus \(latest)…"))
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".pkg") }) else {
            report(.init(currentVersion: currentVersion, latestVersion: latest,
                         state: .failed, message: "No .pkg asset in latest release."))
            return
        }
        guard let url = URL(string: asset.browserDownloadURL),
              let data = try? Data(contentsOf: url) else {
            report(.init(currentVersion: currentVersion, latestVersion: latest,
                         state: .failed, message: "Download failed."))
            return
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TapeNexus-\(UUID().uuidString).pkg")
        do {
            try data.write(to: tmp, options: .atomic)
            // Hand off to Installer.app; it prompts for admin and replaces
            // /Applications/TapeNexus.app. The user quits + relaunches after.
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/System/Applications/Utilities/Installer.app"),
                configuration: NSWorkspace.OpenConfiguration())
            // Hand the downloaded .pkg to Installer once it's launched.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSWorkspace.shared.open(tmp)
            }
            report(.init(currentVersion: currentVersion, latestVersion: latest,
                         state: .ready,
                         message: "Opened installer for \(latest). Quit Tape Nexus to install."))
        } catch {
            report(.init(currentVersion: currentVersion, latestVersion: latest,
                         state: .failed, message: "Could not open installer: \(error.localizedDescription)"))
        }
    }

    private func report(_ s: AppUpdateStatus) {
        DispatchQueue.main.async { self.onStatus?(s) }
    }

    // MARK: - GitHub

    struct Release: Codable {
        var tagName: String
        var assets: [Asset]
        enum CodingKeys: String, CodingKey { case tagName = "tag_name"; case assets }
    }
    struct Asset: Codable {
        var name: String
        var browserDownloadURL: String
        enum CodingKeys: String, CodingKey { case name; case browserDownloadURL = "browser_download_url" }
    }

    private func fetchLatestRelease() -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("TapeNexus", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            result = data; sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 20)
        guard let data = result else { return nil }
        return try? JSONDecoder().decode(Release.self, from: data)
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