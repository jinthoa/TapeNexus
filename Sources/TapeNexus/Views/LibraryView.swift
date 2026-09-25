import SwiftUI
import AppKit

/// Persistent archive of completed downloads — survives "Clear done". The
/// Library tab: a search field + sort menu over a list of rows (thumbnail,
/// title, host · size · when) with Re-download / Reveal / Open / ✕ actions
/// and a Move-to-Trash context item.
struct LibraryView: View {
    @EnvironmentObject var state: AppState
    @State private var search: String = ""
    @State private var sort: LibrarySort = .newest

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.line)
            if let status = state.mediaToolStatus {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.circle")
                        .foregroundStyle(Theme.accent2)
                    Text(status).font(.system(size: 11)).foregroundStyle(Theme.text)
                    Spacer()
                    Button { state.mediaToolStatus = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(Theme.panel)
                .overlay(Divider().overlay(Theme.line), alignment: .bottom)
                .onChange(of: state.mediaToolStatus) { _, new in
                    guard new != nil else { return }
                    Task {
                        try? await Task.sleep(for: .seconds(6))
                        if state.mediaToolStatus == new { state.mediaToolStatus = nil }
                    }
                }
            }
            list
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Search library…", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .frame(width: 260)

            Picker("Sort", selection: $sort) {
                ForEach(LibrarySort.allCases) { s in Text(s.label).tag(s) }
            }
            .pickerStyle(.menu).controlSize(.small).labelsHidden()

            Spacer()
            Text("\(state.library.entries.count) item\(state.library.entries.count == 1 ? "" : "s")")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    @ViewBuilder private var list: some View {
        let shown = state.library.entries(matching: search, sortedBy: sort)
        if shown.isEmpty {
            EmptyState(icon: "books.vertical",
                       title: search.isEmpty ? "Library is empty" : "No matches",
                       message: search.isEmpty
                          ? "Completed downloads are archived here and survive “Clear done”."
                          : "Try a different search term.")
        } else {
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(shown) { entry in
                        LibraryRow(entry: entry)
                    }
                }
                .padding(14)
            }
        }
    }
}

struct LibraryRow: View {
    @EnvironmentObject var state: AppState
    let entry: LibraryEntry
    @State private var showTrim = false

    private var fileURL: URL? {
        entry.outputFilePath.isEmpty ? nil : URL(fileURLWithPath: entry.outputFilePath)
    }

    var body: some View {
        HStack(spacing: 14) {
            ThumbView(url: entry.thumbnailURL, duration: entry.durationStr)
                .frame(width: 132, height: 74)

            VStack(alignment: .leading, spacing: 7) {
                Text(entry.displayTitle).font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1).foregroundStyle(Theme.text)
                HStack(spacing: 7) {
                    Text(entry.host).foregroundStyle(Theme.muted)
                    Text("·").foregroundStyle(Theme.muted)
                    Text(entry.sizeStr).foregroundStyle(Theme.muted)
                    Text("·").foregroundStyle(Theme.muted)
                    Text(entry.completedAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(Theme.muted)
                }.font(.system(size: 11.5)).lineLimit(1)
                if !entry.formatDesc.isEmpty { Chip(text: entry.formatDesc) }
            }
            Spacer()

            HStack(spacing: 5) {
                IconButton(system: "arrow.clockwise", help: "Re-download", tint: Theme.ok) {
                    state.addCandidate(entry.url, startImmediately: true)
                }
                IconButton(system: "folder", help: "Reveal in Finder", tint: Theme.accent2) {
                    state.library.reveal(entry.id)
                }
                IconButton(system: "play.rectangle", help: "Open", tint: Theme.muted) {
                    state.library.open(entry.id)
                }
                IconButton(system: "xmark", help: "Remove from library", tint: Theme.muted) {
                    state.library.remove(entry.id)
                }
            }
        }
        .padding(12)
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button("Re-download") { state.addCandidate(entry.url, startImmediately: true) }
            Button("Reveal in Finder") { state.library.reveal(entry.id) }
            Button("Open") { state.library.open(entry.id) }
            Divider()
            if fileURL != nil {
                Button("Extract audio (MP3)") { runAudio(.mp3) }
                Button("Extract audio (AAC/m4a)") { runAudio(.aac) }
                Button("Transcode to MP4") { runTranscode() }
                Button("Trim / clip…") { showTrim = true }
                Divider()
            }
            Button("Copy URL") { copyURL() }
            Button("Open in browser") { openInBrowser() }
            Divider()
            Button("Move file to Trash", role: .destructive) { state.library.deleteFile(entry.id) }
            Button("Remove from library") { state.library.remove(entry.id) }
        }
        .sheet(isPresented: $showTrim) {
            if let f = fileURL { TrimSheet(input: f) { start, end in
                showTrim = false
                let r = MediaTools.trim(f, start: start, end: end)
                state.runMediaTool(args: r.args, out: r.out,
                                   doneMsg: "Clip saved to \(r.out.lastPathComponent).")
            } }
        }
    }

    // MARK: Media tools

    private enum AudioFmt { case mp3, aac }

    private func runAudio(_ fmt: AudioFmt) {
        guard let f = fileURL else { return }
        let r: (args: [String], out: URL)
        let msg: String
        if fmt == .mp3 {
            r = MediaTools.extractAudioMP3(f); msg = "MP3 extracted to \(r.out.lastPathComponent)."
        } else {
            r = MediaTools.extractAudioAAC(f); msg = "Audio extracted to \(r.out.lastPathComponent)."
        }
        state.runMediaTool(args: r.args, out: r.out, doneMsg: msg)
    }

    private func runTranscode() {
        guard let f = fileURL else { return }
        let r = MediaTools.transcodeMP4(f)
        state.runMediaTool(args: r.args, out: r.out,
                           doneMsg: "Transcoded to \(r.out.lastPathComponent).")
    }

    private func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.url, forType: .string)
    }
    private func openInBrowser() {
        if let u = URL(string: entry.url) { NSWorkspace.shared.open(u) }
    }
}

/// Small sheet to pick a start/end for trimming a Library file into a clip.
/// Times are HH:MM:SS or MM:SS (ffmpeg accepts both).
struct TrimSheet: View {
    let input: URL
    let onClip: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var start = "00:00:00"
    @State private var end = "00:00:30"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trim / clip").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            Text(input.lastPathComponent)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    TextField("00:00:00", text: $start)
                        .textFieldStyle(.roundedBorder).frame(width: 120)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("End").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    TextField("00:00:30", text: $end)
                        .textFieldStyle(.roundedBorder).frame(width: 120)
                }
            }
            Text("Times as HH:MM:SS or MM:SS. The clip is re-encoded for a frame-accurate cut.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                Button("Clip") {
                    onClip(start, end)
                }.buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(Theme.bg)
    }
}