import SwiftUI

/// The whole single-page UI: brand strip + paste field, a segmented
/// All/Active/Done/Failed filter with live counts, a toolbar of status chips,
/// and the unified download list (done/failed stay in the list, filtered).
struct QueueView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            Divider().overlay(Theme.line)
            list
        }
    }

    // MARK: Header — brand, paste field, settings gear

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                if let appIcon = Bundle.main.image(forResource: "AppIcon") {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(LinearGradient(colors: [Theme.accent, Theme.accent2],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 26, height: 26)
                        .overlay(Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.white).font(.system(size: 14)))
                }
                Text("Tape Nexus").font(.system(size: 14, weight: .semibold))
            }

            Spacer()

            pasteBar

            IconButton(system: "gearshape", help: "Settings…  (⌘,)", tint: Theme.muted) {
                state.showSettings = true
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var pasteBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "link").foregroundStyle(Theme.muted)
                TextField("Paste a URL…", text: $state.pasteField)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onSubmit { state.addManualURL() }
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .frame(width: 240)

            Button(action: { state.addManualURL() }) {
                Label("Add", systemImage: "plus").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(state.pasteField.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: Filter bar — segmented All/Active/Done/Failed + status chips

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $state.filter) {
                ForEach(StatusFilter.allCases) { f in
                    Text("\(f.label) · \(state.count(for: f))").tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            .labelsHidden()

            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(Theme.muted)
                Text(state.settings.destinationFolder).foregroundStyle(Theme.text)
            }.chipStyle()

            HStack(spacing: 6) {
                Image(systemName: "point.3.connectedtriangle.bottomright.filled").foregroundStyle(Theme.muted)
                Text("\(state.settings.maxConcurrent)").foregroundStyle(Theme.text)
            }.chipStyle()

            Spacer()

            if state.settings.autoGrabClipboard {
                HStack(spacing: 6) {
                    Image(systemName: "clipboard.fill").foregroundStyle(Theme.ok)
                    Text("auto-grab").foregroundStyle(Theme.muted)
                }.chipStyle()
            }
            Button(action: { state.clearFinished() }) {
                Label("Clear done", systemImage: "checkmark.broom").font(.system(size: 12))
            }.buttonStyle(.bordered).controlSize(.small)
            Button(action: { state.pauseAll() }) {
                Label("Pause all", systemImage: "pause.fill").font(.system(size: 12))
            }.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        if state.items.isEmpty {
            EmptyState(icon: "arrow.down.circle", title: "Nothing here yet",
                       message: "Copy a video URL anywhere — supported links are added automatically. Or paste one above.")
        } else if state.filteredItems.isEmpty {
            EmptyState(icon: filterIcon, title: "No \(state.filter.label.lowercased()) downloads",
                       message: filterEmptyMessage)
        } else {
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(state.filteredItems) { item in
                        QueueRow(item: item)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(14)
            }
        }
    }

    private var filterIcon: String {
        switch state.filter {
        case .all: return "tray"
        case .active: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
    private var filterEmptyMessage: String {
        switch state.filter {
        case .all: return "Items you add will appear here."
        case .active: return "No downloads are running or queued."
        case .done: return "Completed downloads show up here. Use “Clear done” to tidy them away."
        case .failed: return "Nothing has failed. Failed and stopped downloads collect here."
        }
    }
}

struct QueueRow: View {
    @EnvironmentObject var state: AppState
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 14) {
            ThumbView(url: item.thumbnailURL, duration: item.durationStr)
                .frame(width: 132, height: 74)

            VStack(alignment: .leading, spacing: 7) {
                Text(item.displayTitle).font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1).foregroundStyle(Theme.text)
                HStack(spacing: 7) {
                    Text(item.host).foregroundStyle(Theme.muted)
                    if !item.uploader.isEmpty {
                        Text("·").foregroundStyle(Theme.muted)
                        Text(item.uploader).foregroundStyle(Theme.muted)
                    }
                }.font(.system(size: 11.5)).lineLimit(1)

                HStack(spacing: 8) {
                    StatusBadge(status: item.status)
                    if !item.formatDesc.isEmpty { Chip(text: item.formatDesc) }
                    if item.status == .downloading && item.totalBytes == 0 {
                        // yt-dlp re-extracts metadata before the first byte transfers;
                        // show an active spinner here instead of a dead 0% bar.
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Preparing download…").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                    } else if item.status == .downloading || item.status == .paused {
                        ProgressBar(value: item.progress,
                                    warn: item.status == .paused).frame(maxWidth: 320)
                        Text(percentLabel).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                    }
                    if item.status == .resolving {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Gathering metadata…").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                    }
                    if item.status == .failed && !item.errorMessage.isEmpty {
                        Text(item.errorMessage).font(.system(size: 10.5)).foregroundStyle(Theme.err).lineLimit(1)
                    }
                }
                if item.status == .downloading && item.totalBytes > 0 {
                    HStack(spacing: 10) {
                        Text(item.byteProgress).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.muted)
                        if !item.speedStr.isEmpty { Text(item.speedStr).foregroundStyle(Theme.accent2) }
                        if !item.etaStr.isEmpty { Text("ETA \(item.etaStr)").foregroundStyle(Theme.muted) }
                    }.font(.system(size: 10.5, design: .monospaced))
                }
            }
            Spacer()

            controls
        }
        .padding(12)
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var percentLabel: String {
        if item.status == .paused { return "paused · \(Int(item.progress*100))%" }
        return "\(Int(item.progress*100))%"
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 5) {
                switch item.status {
                case .resolving:
                    IconButton(system: "xmark", help: "Remove", tint: Theme.err) { state.remove(item.id) }
                case .downloading:
                    IconButton(system: "pause.fill", help: "Pause", tint: Theme.warn) { state.pause(item.id) }
                    IconButton(system: "stop.fill", help: "Stop", tint: Theme.err) { state.stop(item.id) }
                    IconButton(system: "arrow.clockwise", help: "Retry") { state.retry(item.id) }
                case .paused:
                    IconButton(system: "play.fill", help: "Resume", tint: Theme.ok) { state.resume(item.id) }
                    IconButton(system: "stop.fill", help: "Stop", tint: Theme.err) { state.stop(item.id) }
                    IconButton(system: "arrow.clockwise", help: "Retry") { state.retry(item.id) }
                case .queued:
                    IconButton(system: "play.fill", help: "Start now", tint: Theme.ok) { state.startNow(item.id) }
                    IconButton(system: "xmark", help: "Remove", tint: Theme.err) { state.remove(item.id) }
                case .failed, .stopped:
                    IconButton(system: "arrow.clockwise", help: "Retry", tint: Theme.ok) { state.retry(item.id) }
                    if !item.outputFilePath.isEmpty {
                        IconButton(system: "trash", help: "Delete downloaded file", tint: Theme.err) { state.deleteFile(item.id) }
                    } else {
                        IconButton(system: "xmark", help: "Remove", tint: Theme.err) { state.remove(item.id) }
                    }
                case .done:
                    IconButton(system: "folder", help: "Reveal in Finder", tint: Theme.accent2) { state.reveal(item.id) }
                    IconButton(system: "trash", help: "Delete file", tint: Theme.err) { state.deleteFile(item.id) }
                    IconButton(system: "xmark", help: "Remove from list", tint: Theme.muted) { state.remove(item.id) }
                }
            }
        }
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(Theme.line)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text(message).font(.system(size: 12)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension View {
    func chipStyle() -> some View {
        self.font(.system(size: 11.5))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}