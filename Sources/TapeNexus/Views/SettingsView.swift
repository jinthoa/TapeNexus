import SwiftUI

/// Settings presented as a modal sheet (opened from Tape Nexus ▸ Settings… ⌘,).
/// Edits a local draft; Save commits via `state.updateSettings`, Cancel drops.
struct SettingsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AppSettings = .default
    @State private var pickFolder = false

    var body: some View {
        VStack(spacing: 0) {
            // Sheet header
            HStack {
                Text("Settings").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16)).foregroundStyle(Theme.muted)
                }.buttonStyle(.plain).help("Close")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider().overlay(Theme.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("Downloads") {
                        row("Destination folder") {
                            HStack {
                                Text(draft.destinationFolder).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                                Button("Choose…") { pickFolder = true }.buttonStyle(.bordered).controlSize(.small)
                                Button("Reveal") {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: draft.destinationFolder)
                                }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        row("Default format") {
                            Picker("", selection: $draft.formatPreset) {
                                ForEach(AppSettings.formatPresets, id: \.key) { p in
                                    Text(p.label).tag(p.key)
                                }
                            }.pickerStyle(.menu).frame(width: 220)
                        }
                        if draft.formatPreset == "custom" {
                            row("Custom -f string") {
                                TextField("e.g. bestvideo*+bestaudio/best", text: $draft.customFormat)
                                    .textFieldStyle(.roundedBorder).frame(width: 320)
                            }
                        }
                        row("Concurrent downloads") {
                            Stepper(value: $draft.maxConcurrent, in: 1...4) {
                                Text("\(draft.maxConcurrent)").font(.system(size: 12, design: .monospaced))
                            }
                        }
                        toggle("Remove sponsor segments (SponsorBlock)", isOn: $draft.sponsorBlock)
                        toggle("Embed metadata", isOn: $draft.embedMetadata)
                        toggle("Embed subtitles (en)", isOn: $draft.embedSubs)
                    }

                    section("Clipboard") {
                        toggle("Auto-grab supported URLs from clipboard", isOn: $draft.autoGrabClipboard)
                        toggle("Start downloads automatically when a URL is detected", isOn: $draft.autoStartDownloads)
                        row("Poll interval") {
                            HStack {
                                Slider(value: $draft.pollIntervalSeconds, in: 0.5...3, step: 0.1).frame(width: 180)
                                Text(String(format: "%.1fs", draft.pollIntervalSeconds))
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                            }
                        }
                        if state.skippedCount > 0 {
                            Text("\(state.skippedCount) copied link(s) skipped — not supported by yt-dlp.")
                                .font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                    }

                    section("yt-dlp auto-update") {
                        toggle("Update yt-dlp automatically on launch", isOn: $draft.autoUpdateYTDLP)
                        row("Current version") {
                            Text(state.updateStatus.currentVersion.isEmpty ? "—" : state.updateStatus.currentVersion)
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text)
                        }
                        row("Status") {
                            Text(state.updateStatus.message.isEmpty ? "—" : state.updateStatus.message)
                                .font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                        Button(action: { state.checkForUpdatesNow() }) {
                            Label("Check for update now", systemImage: "arrow.clockwise.icloud")
                        }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(18)
                .frame(maxWidth: 560, alignment: .leading)
            }

            Divider().overlay(Theme.line)
            // Sheet footer
            HStack {
                Button("Reset to defaults") { draft = .default }
                    .buttonStyle(.bordered).controlSize(.small)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered).controlSize(.regular)
                Button("Save") {
                    state.updateSettings(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 600, height: 560)
        .background(Theme.bg)
        .onAppear { draft = state.settings }
        .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                var p = url.path
                if p.hasPrefix("/FileProvider") || url.startAccessingSecurityScopedResource() {
                    p = url.path
                    url.stopAccessingSecurityScopedResource()
                }
                draft.destinationFolder = p
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold)).tracking(1.4).foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.text).frame(width: 160, alignment: .leading)
            control()
            Spacer()
        }
    }

    private func toggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn).font(.system(size: 12.5)).tint(Theme.accent)
    }
}