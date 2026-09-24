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
            Button("Copy URL") { copyURL() }
            Button("Open in browser") { openInBrowser() }
            Divider()
            Button("Move file to Trash", role: .destructive) { state.library.deleteFile(entry.id) }
            Button("Remove from library") { state.library.remove(entry.id) }
        }
    }

    private func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.url, forType: .string)
    }
    private func openInBrowser() {
        if let u = URL(string: entry.url) { NSWorkspace.shared.open(u) }
    }
}