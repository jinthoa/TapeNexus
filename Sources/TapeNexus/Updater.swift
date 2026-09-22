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
            guard let release = self.fetchLatestRelease() else {
                self.report(.init(currentVersion: current, state: .failed,
                                  message: "Could not reach GitHub."))
                return
            }
            let latest = release.tagName
            if self.isNewer(latest: latest, current: current) {
                if auto {
                    self.performUpdate(current: current, latest: latest, release: release)
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

    private func performUpdate(current: String, latest: String, release: Release) {
        report(.init(currentVersion: current, latestVersion: latest,
                     state: .downloading, message: "Downloading yt-dlp \(latest)…"))
        guard let asset = release.assets.first(where: { $0.name == "yt-dlp_macos" })
                ?? release.assets.first(where: { $0.name == "yt-dlp" }) else {
            report(.init(currentVersion: current, latestVersion: latest,
                         state: .failed, message: "No macOS asset in latest release."))
            return
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("yt-dlp-\(UUID().uuidString)")
        guard let url = URL(string: asset.browserDownloadURL),
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
        guard let url = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("TapeNexus", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            result = data
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 20)
        guard let data = result else { return nil }
        return try? JSONDecoder().decode(Release.self, from: data)
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