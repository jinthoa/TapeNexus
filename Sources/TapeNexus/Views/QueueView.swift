import SwiftUI
import UniformTypeIdentifiers

/// The whole single-page UI: header, filter bar with bulk actions, and the
/// scrollable queue list. Done/failed items stay in the list until "Clear
/// done" removes them.
struct QueueView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            Divider().overlay(Theme.line)
            queueList
        }
        .onDrop(of: [UTType.text, UTType.url, UTType.fileURL],
                delegate: URLDropDelegate(state: state))
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

    // MARK: Filter bar — segmented All/Active/Done/Failed + status chips + bulk actions

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

            Button(action: { state.startAll() }) {
                Label("Start all", systemImage: "play.fill").font(.system(size: 12))
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(state.items.allSatisfy { $0.status != .queued })

            Button(action: { state.retryAll() }) {
                Label("Retry all", systemImage: "arrow.clockwise").font(.system(size: 12))
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(state.count(for: .failed) == 0)

            Button(action: { state.clearFinished() }) {
                Label("Clear done", systemImage: "checkmark.broom").font(.system(size: 12))
            }.buttonStyle(.bordered).controlSize(.small)

            Button(action: { state.pauseAll() }) {
                Label("Pause all", systemImage: "pause.fill").font(.system(size: 12))
            }.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    // MARK: Queue list

    @ViewBuilder private var queueList: some View {
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
        case .done: return "Completed downloads show up here. Use “Clear done” to remove them."
        case .failed: return "Nothing has failed. Failed and stopped downloads collect here."
        }
    }
}

struct QueueRow: View {
    @EnvironmentObject var state: AppState
    let item: DownloadItem
    @State private var clipStart: String = ""
    @State private var clipEnd: String = ""
    @State private var showClip: Bool = false
    @State private var showSchedule: Bool = false
    @State private var scheduleDate: Date = Date()
    @State private var showFormats: Bool = false

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
                    if item.hasClip {
                        Chip(text: "clip \(clipRangeLabel)")
                    }
                    if item.hasSchedule, let s = item.startAt {
                        Chip(text: "starts \(s.formatted(date: .abbreviated, time: .shortened))",
                             color: Theme.accent)
                    }
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
                    if item.status == .queued, let launchAt = item.launchAt {
                        // Deferred by the start-delay: show a live countdown to
                        // the scheduled launch time. TimelineView ticks each
                        // second so the number stays accurate.
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let remaining = launchAt.timeIntervalSince(ctx.date)
                            HStack(spacing: 6) {
                                Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(Theme.accent)
                                Text(remaining > 0
                                     ? "Starting in \(max(1, Int(ceil(remaining))))s"
                                     : "Starting…")
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.accent)
                            }
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
        .onAppear { clipStart = item.clipStart; clipEnd = item.clipEnd; scheduleDate = item.startAt ?? Date().addingTimeInterval(60 * 60) }
        .sheet(isPresented: $showFormats) {
            FormatsSheet(item: item)
        }
    }

    private var percentLabel: String {
        if item.status == .paused { return "paused · \(Int(item.progress*100))%" }
        return "\(Int(item.progress*100))%"
    }

    private var clipRangeLabel: String {
        let s = item.clipStart.isEmpty ? "0" : item.clipStart
        let e = item.clipEnd.isEmpty ? "end" : item.clipEnd
        return "\(s)→\(e)"
    }

    /// Per-row format picker (queued items only). "Default" clears the override
    /// so the item follows the global setting.
    private var formatMenu: some View {
        Menu {
            Button("Default (\(state.settings.formatLabel()))") {
                state.setItemFormat(item.id, preset: "", custom: "")
            }
            Divider()
            ForEach(AppSettings.formatPresets, id: \.key) { p in
                Button(p.label) { state.setItemFormat(item.id, preset: p.key, custom: "") }
            }
            Divider()
            Button("Show available formats…") { state.loadFormats(for: item.id); showFormats = true }
        } label: {
            Label(item.formatPreset.isEmpty ? "Format" : "Format ✓",
                  systemImage: "slider.horizontal.3")
                .font(.system(size: 11)).labelStyle(.titleAndIcon)
        }.menuStyle(.borderlessButton).fixedSize()
    }

    /// Time-range clip editor presented as a popover.
    private var clipButton: some View {
        Button(action: { showClip = true }) {
            Label("Clip", systemImage: "scissors")
                .font(.system(size: 11)).labelStyle(.titleAndIcon)
        }.buttonStyle(.borderless).popover(isPresented: $showClip, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Download a clip").font(.system(size: 12, weight: .semibold))
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Start").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        TextField("0:00", text: $clipStart).textFieldStyle(.roundedBorder)
                            .frame(width: 90).onSubmit { commitClip() }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("End").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        TextField("e.g. 1:30", text: $clipEnd).textFieldStyle(.roundedBorder)
                            .frame(width: 90).onSubmit { commitClip() }
                    }
                }
                Text("Timestamps like 1:23 or 83 (seconds). Leave end blank to grab to the end.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).frame(width: 230)
                HStack {
                    if item.hasClip {
                        Button("Clear") {
                            clipStart = ""; clipEnd = ""; commitClip()
                        }.buttonStyle(.bordered).controlSize(.small)
                    }
                    Spacer()
                    Button("Done") { commitClip(); showClip = false }
                        .buttonStyle(.borderedProminent).controlSize(.small).tint(Theme.accent)
                }
            }.padding(14).frame(width: 260)
        }
    }

    /// Scheduled-start editor presented as a popover.
    private var scheduleButton: some View {
        Button(action: { showSchedule = true }) {
            Label("Schedule", systemImage: "calendar")
                .font(.system(size: 11)).labelStyle(.titleAndIcon)
        }.buttonStyle(.borderless).popover(isPresented: $showSchedule, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Start later").font(.system(size: 12, weight: .semibold))
                DatePicker("Start at", selection: $scheduleDate,
                           in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .environment(\.locale, Locale.current)
                Text("The download won't begin until this time. Quiet hours still apply.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).frame(width: 240)
                HStack {
                    if item.hasSchedule {
                        Button("Clear") {
                            state.setItemSchedule(item.id, startAt: nil)
                            showSchedule = false
                        }.buttonStyle(.bordered).controlSize(.small)
                    }
                    Spacer()
                    Button("Schedule") {
                        state.setItemSchedule(item.id, startAt: scheduleDate)
                        showSchedule = false
                    }.buttonStyle(.borderedProminent).controlSize(.small).tint(Theme.accent)
                }
            }.padding(14).frame(width: 260)
        }
    }

    private func commitClip() {
        state.setItemClip(item.id,
                          start: clipStart.trimmingCharacters(in: .whitespaces),
                          end: clipEnd.trimmingCharacters(in: .whitespaces))
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
                    formatMenu
                    clipButton
                    scheduleButton
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

/// Format-preview sheet: runs `yt-dlp -F` for the item's URL and shows the
/// available streams so the user can pick an exact format_id instead of
/// guessing with a preset. Picking a row applies it as a custom -f override.
struct FormatsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let item: DownloadItem

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Available formats").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.muted)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider().overlay(Theme.line)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Theme.line)
            HStack {
                Text(item.displayTitle).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.bordered).controlSize(.small)
            }.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 560, height: 460)
        .background(Theme.bg)
        .onAppear { if state.formatLists[item.id] == nil { state.loadFormats(for: item.id) } }
    }

    @ViewBuilder private var content: some View {
        if state.formatsLoading.contains(item.id) {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Asking yt-dlp for available formats…").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = state.formatsError[item.id], !err.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(Theme.err)
                Text(err).font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                Button("Try again") { state.loadFormats(for: item.id) }.buttonStyle(.bordered).controlSize(.small)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let rows = state.formatLists[item.id] {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(rows) { f in
                        Button {
                            state.applyFormat(f, to: item.id)
                            dismiss()
                        } label: {
                            HStack {
                                Text(f.id).font(.system(size: 11, design: .monospaced))
                                    .frame(width: 70, alignment: .leading)
                                    .foregroundStyle(Theme.accent2)
                                Text(f.ext).font(.system(size: 11, design: .monospaced))
                                    .frame(width: 56, alignment: .leading)
                                    .foregroundStyle(Theme.text)
                                Text(f.resolution.isEmpty ? "audio" : f.resolution)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 110, alignment: .leading)
                                    .foregroundStyle(Theme.text)
                                Text(f.tbr).font(.system(size: 11, design: .monospaced))
                                    .frame(width: 64, alignment: .leading)
                                    .foregroundStyle(Theme.muted)
                                Text(f.sizeStr).font(.system(size: 11, design: .monospaced))
                                    .frame(width: 80, alignment: .leading)
                                    .foregroundStyle(Theme.muted)
                                Spacer()
                                Text(f.kindLabel).font(.system(size: 10))
                                    .foregroundStyle(f.kind == .mixed ? Theme.ok : Theme.muted)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Theme.panel)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }.padding(12)
            }
        } else {
            Color.clear.onAppear { state.loadFormats(for: item.id) }
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

/// Accepts dragged URLs (or a .txt file of URLs) anywhere on the window and
/// queues each one. Text drops are scanned for http(s) links the same way the
/// clipboard/paste field is.
struct URLDropDelegate: DropDelegate {
    let state: AppState
    func performDrop(info: DropInfo) -> Bool {
        var collected: [String] = []
        let group = DispatchGroup()
        let providers = info.itemProviders(for: [UTType.text, UTType.url, UTType.fileURL])
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        if url.pathExtension.lowercased() == "txt",
                           let s = try? String(contentsOf: url, encoding: .utf8) {
                            collected += SupportedURLs.extractURLs(from: s)
                        } else {
                            collected += SupportedURLs.extractURLs(from: url.absoluteString)
                        }
                    }
                    group.leave()
                }
            } else if p.canLoadObject(ofClass: NSString.self) {
                group.enter()
                _ = p.loadObject(ofClass: NSString.self) { s, _ in
                    if let s = s as? String { collected += SupportedURLs.extractURLs(from: s) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            if !collected.isEmpty { state.addURLs(collected) }
        }
        return true
    }
}