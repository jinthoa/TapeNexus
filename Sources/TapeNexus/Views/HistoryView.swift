import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("History").font(.system(size: 16, weight: .semibold))
                    Text("\(state.history.count) completed downloads").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button(role: .destructive, action: { state.history.removeAll(); state.persist() }) {
                    Label("Clear history", systemImage: "trash").font(.system(size: 12))
                }.buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider().overlay(Theme.line)

            if state.history.isEmpty {
                EmptyState(icon: "checkmark.circle", title: "No history yet",
                           message: "Finished and cleared downloads show up here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(state.history) { item in
                            HistoryRow(item: item)
                        }
                    }.padding(14)
                }
            }
        }
    }
}

struct HistoryRow: View {
    @EnvironmentObject var state: AppState
    let item: DownloadItem
    var body: some View {
        HStack(spacing: 12) {
            ThumbView(url: item.thumbnailURL, duration: item.durationStr).frame(width: 96, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1).foregroundStyle(Theme.text)
                HStack(spacing: 8) {
                    Text(item.host).foregroundStyle(Theme.muted)
                    StatusBadge(status: item.status)
                    if !item.formatDesc.isEmpty { Chip(text: item.formatDesc) }
                }.font(.system(size: 11))
            }
            Spacer()
            if !item.outputFilePath.isEmpty {
                IconButton(system: "folder", help: "Reveal in Finder", tint: Theme.accent2) { state.reveal(item.id) }
                IconButton(system: "trash", help: "Delete file", tint: Theme.err) { state.deleteFile(item.id) }
            }
        }
        .padding(10)
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}