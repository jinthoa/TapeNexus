import Foundation

/// Checks GitHub for a newer yt-dlp release and atomically swaps the
/// Application Support binary. Runs in the background; never throws.
final class Updater {
    let yt: YTDLPController
    var onStatus: ((UpdateStatus) -> Void)?

    init(yt: YTDLPController) { self.yt = yt }

    func checkAndUpdate(auto: Bool) {
        report(.init(state: .checking, message: "Checking yt-dlp version…"))
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let current = self.yt.currentVersion()
            guard let latest = self.fetchLatestTag() else {
                self.report(.init(currentVersion: current, state: .failed,
                                  message: "Could not reach GitHub."))
                return
            }
            if self.isNewer(latest: latest, current: current) {
                if auto {
                    self.performUpdate(current: current, latest: latest, tag: latest)
                } else {
                    self.report(.init(currentVersion: current, latestVersion: latest,
                                      state: .idle,
                                      message: "Update available: \(latest)"))
                }
            } else {
                self.report(.init(currentVersion: current, latestVersion: latest,
                                  state: .upToDate,
                                  message: "yt-dlp \(current) · up to date"))
            }
        }
    }

    private func performUpdate(current: String, latest: String, tag: String) {
        report(.init(currentVersion: current, latestVersion: latest,
                     state: .downloading, message: "Downloading yt-dlp \(latest)…"))
        // The yt-dlp_macos asset lives at a predictable URL under the tag — no
        // need to enumerate release assets via the (rate-limited) API.
        let assetName = "yt-dlp_macos"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("yt-dlp-\(UUID().uuidString)")
        guard let url = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/\(tag)/\(assetName)"),
              let data = try? Data(contentsOf: url) else {
            report(.init(currentVersion: current, latestVersion: latest,
                         state: .failed, message: "Download failed."))
            return
        }
        do {
            try data.write(to: tmp, options: .atomic)
            chmod(tmp.path, 0o755)
            // atomic swap into the AS home
            let target = SettingsStore.binURL
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: tmp, to: target)
            chmod(target.path, 0o755)
            let new = yt.currentVersion()
            report(.init(currentVersion: new, latestVersion: latest,
                         state: .updated, message: "yt-dlp updated to \(new)."))
        } catch {
            report(.init(currentVersion: current, latestVersion: latest,
                         state: .failed, message: "Install failed: \(error.localizedDescription)"))
        }
    }

    private func report(_ s: UpdateStatus) { DispatchQueue.main.async { self.onStatus?(s) } }

    // MARK: - GitHub

    /// Resolve the latest yt-dlp release tag WITHOUT the GitHub REST API.
    ///
    /// `api.github.com` is rate-limited to 60 req/hr per IP unauthenticated;
    /// a shared NAT/VPN exhausts that and a 403 fails to decode into a release
    /// ("Could not reach GitHub"). Instead hit the HTML endpoint
    /// `github.com/yt-dlp/yt-dlp/releases/latest`, which 302-redirects to
    /// `.../releases/tag/<tag>` (NOT rate-limited). URLSession follows the
    /// redirect and the final URL's last path component is the tag
    /// (e.g. "2026.08.19").
    private func fetchLatestTag() -> String? {
        guard let url = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest") else { return nil }
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
        return finalURL?.lastPathComponent
    }

    /// version strings look like "2026.03.17" — compare component-wise.
    private func isNewer(latest: String, current: String) -> Bool {
        let l = latest.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        let n = max(l.count, c.count)
        for i in 0..<n {
            let lv = i < l.count ? l[i] : 0
            let cv = i < c.count ? c[i] : 0
            if lv != cv { return lv > cv }
        }
        return false
    }
}