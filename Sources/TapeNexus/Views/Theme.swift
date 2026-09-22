import SwiftUI
import CryptoKit

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

enum Theme {
    static let bg       = Color(hex: 0x0e0f13)
    static let panel    = Color(hex: 0x16181f)
    static let panel2   = Color(hex: 0x1c1f28)
    static let line     = Color(hex: 0x2a2e3a)
    static let text     = Color(hex: 0xe7e9ee)
    static let muted    = Color(hex: 0x8b90a0)
    static let accent   = Color(hex: 0x7c5cff)
    static let accent2  = Color(hex: 0x22d3ee)
    static let ok       = Color(hex: 0x34d399)
    static let warn     = Color(hex: 0xfbbf24)
    static let err      = Color(hex: 0xfb7185)
    static let blue     = Color(hex: 0x60a5fa)

    static func badgeColor(_ s: DownloadStatus) -> Color {
        switch s {
        case .resolving: return muted
        case .queued: return blue
        case .downloading, .done: return ok
        case .paused: return warn
        case .failed, .stopped: return err
        }
    }
    static func badgeText(_ s: DownloadStatus) -> String {
        switch s {
        case .resolving: return "Resolving"
        case .queued: return "Queued"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .done: return "Done"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
}

struct ThumbView: View {
    let url: String
    let duration: String
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let u = URL(string: url), !url.isEmpty {
                CachedThumb(url: u)
            } else {
                Rectangle().fill(Theme.panel2)
                    .overlay(Image(systemName: "link").foregroundStyle(Theme.muted))
            }
            if !duration.isEmpty {
                Text(duration).font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.black.opacity(0.78)).foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Disk-cached remote image. First load fetches from the network and writes the
/// bytes to a per-URL cache file; later views (including across app launches)
/// render instantly from disk. Falls back to a muted panel + link glyph on error.
struct CachedThumb: View {
    let url: URL
    @State private var image: NSImage?

    private static var cacheDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = caches.appendingPathComponent("TapeNexus/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static func cacheFile(for url: URL) -> URL {
        // Stable filename from the URL; preserve extension when it's a known image type.
        let ext = url.pathExtension.lowercased()
        let known = ["jpg", "jpeg", "png", "webp", "gif"]
        let suffix = known.contains(ext) ? ext : "jpg"
        let stem = SHA256.hash(data: Data(url.absoluteString.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(stem).\(suffix)")
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Theme.panel2)
                    .overlay(Image(systemName: "link").foregroundStyle(Theme.muted))
            }
        }
        .task(id: url) { await load() }
    }

    @MainActor
    private func load() async {
        let file = Self.cacheFile(for: url)
        if FileManager.default.fileExists(atPath: file.path),
           let cached = NSImage(contentsOf: file) {
            image = cached
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            try? data.write(to: file, options: .atomic)
            if let img = NSImage(data: data) { image = img }
        } catch {
            // leave placeholder
        }
    }
}

struct StatusBadge: View {
    let status: DownloadStatus
    var body: some View {
        Text(Theme.badgeText(status))
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.badgeColor(status).opacity(0.16))
            .foregroundStyle(Theme.badgeColor(status))
            .clipShape(Capsule())
    }
}

struct Chip: View {
    let text: String
    var color: Color = Theme.muted
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Theme.panel2).foregroundStyle(color)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct IconButton: View {
    let system: String
    let help: String
    var tint: Color = Theme.muted
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(tint)
                .background(Theme.panel2)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct ProgressBar: View {
    let value: Double
    var warn: Bool = false
    var err: Bool = false
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 99).fill(Color(hex: 0x262a35))
                fillShape
                    .frame(width: geo.size.width * CGFloat(max(0.001, min(1, value))))
            }
        }
        .frame(height: 5)
    }

    @ViewBuilder private var fillShape: some View {
        if err {
            RoundedRectangle(cornerRadius: 99).fill(Theme.err)
        } else if warn {
            RoundedRectangle(cornerRadius: 99).fill(Theme.warn)
        } else {
            RoundedRectangle(cornerRadius: 99)
                .fill(LinearGradient(colors: [Theme.accent, Theme.accent2],
                                     startPoint: .leading, endPoint: .trailing))
        }
    }
}