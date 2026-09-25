import Foundation

/// Fast local pre-filter for clipboard URLs.
/// The authoritative check is `yt-dlp --simulate`; this just avoids running
/// yt-dlp for arbitrary copied text. Covers the major yt-dlp extractors.
enum SupportedURLs {
    static let hosts: Set<String> = [
        "youtube.com", "m.youtube.com", "youtu.be", "music.youtube.com",
        "vimeo.com", "player.vimeo.com",
        "twitch.tv", "m.twitch.tv", "clips.twitch.tv",
        "twitter.com", "x.com", "mobile.twitter.com",
        "instagram.com",
        "tiktok.com", "vm.tiktok.com",
        "soundcloud.com",
        "bandcamp.com",
        "dailymotion.com", "dai.ly",
        "streamable.com",
        "reddit.com", "old.reddit.com", "v.redd.it", "redd.it",
        "facebook.com", "fb.watch", "m.facebook.com",
        "bilibili.com", "b23.tv",
        "pinterest.com", "pin.it",
        "tumblr.com",
        "dropbox.com",
        "mega.nz", "mega.co.nz",
        "open.spotify.com",
        "podcasts.apple.com",
        "nhentai.net",
        "patreon.com",
        "kick.com",
        "rumble.com",
        "bitchute.com",
        "media.ccc.de",
        "peertube.tv",
        "odysee.com",
        "media.giphy.com",
        "flickr.com",
        "artstation.com",
        "archive.org",
        "pornhub.com"
    ]

    /// Pulls candidate http(s) URLs out of an arbitrary clipboard string.
    static func extractURLs(from text: String) -> [String] {
        var found: [String] = []
        let pattern = #"https?://[^\s<>\"')\]]+"#
        if let re = try? NSRegularExpression(pattern: pattern, options: []) {
            let ns = text as NSString
            let matches = re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
            for m in matches {
                let s = ns.substring(with: m.range)
                found.append(s)
            }
        }
        return found
    }

    /// Cheap host check against the curated list.
    static func looksSupported(_ raw: String) -> Bool {
        guard let comps = URLComponents(string: raw),
              let host = comps.host?.lowercased() else { return false }
        let clean = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if hosts.contains(clean) || hosts.contains(host) { return true }
        // allow any subdomain match of a known host
        for h in hosts where clean.hasSuffix("." + h) { return true }
        return false
    }

    /// Hosts routed to the gallery-dl engine. yt-dlp handles Twitter video
    /// tweets but NOT tweet images or the X /media tab (login redirect), and
    /// only Reddit video — so images, the /media tab, and Reddit saved posts
    /// go through gallery-dl, which reads the same browser cookies. v.redd.it
    /// (raw CDN video) stays on yt-dlp.
    private static let galleryDLHosts: Set<String> = [
        "twitter.com", "x.com", "mobile.twitter.com",
        "reddit.com", "old.reddit.com", "redd.it",
    ]

    /// Resolve which engine should handle a URL, by host. Used at verify time
    /// to pick the simulator and at launch time to pick the downloader.
    static func engine(for url: String) -> DownloadEngine {
        guard let comps = URLComponents(string: url),
              let host = comps.host?.lowercased() else { return .ytDlp }
        let clean = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if galleryDLHosts.contains(clean) || galleryDLHosts.contains(host) {
            return .galleryDl
        }
        // subdomain match (e.g. i.redd.it is NOT gallery-dl; only exact + www)
        return .ytDlp
    }
}