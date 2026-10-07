import AppKit
import SwiftUI

/// Right-click ▸ Find Sibling Names: every name of one file, as the search
/// outwards from its folder finds them.
struct SiblingsView: View {

    @State private var search: SiblingSearch
    @State private var chosen: URL?

    init(url: URL) {
        _search = State(initialValue: SiblingSearch(url: url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            List(search.found, id: \.self, selection: $chosen) { url in
                row(url)
            }
            .contextMenu(forSelectionType: URL.self) { urls in
                Button("Show in Diptych") { show(urls.first) }
            } primaryAction: { urls in
                show(urls.first)
            }
            Divider()
            footer
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(minWidth: 560, minHeight: 300)
        .navigationTitle("Names of \(search.url.lastPathComponent)")
        .background(WindowAccessor { window in
            guard let window else { return }
            AppWindows.shared.register(window)
            WindowSubjects.shared.register(window, kind: "siblings", description: search.url.path)
        })
        .onDisappear { search.abandon() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(search.url.lastPathComponent).font(.headline)
            if let target = search.target {
                Text("inode \(target.inode) \u{2014} \(target.links) names, hard links to "
                     + "the same file. Searched for outwards from its folder, up to the top of "
                     + "the volume.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This item could not be read.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func row(_ url: URL) -> some View {
        HStack(spacing: 6) {
            Text(url.path)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            if url.standardizedFileURL == search.url.standardizedFileURL {
                Text("(this one)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .help(url.path)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            status
            Spacer()
            Button("Copy") {
                let board = NSPasteboard.general
                board.clearContents()
                board.setString(search.found.map(\.path).joined(separator: "\n") + "\n",
                                forType: .string)
            }
            .disabled(search.found.isEmpty)
            Button("Show") { show(chosen) }
                .disabled(chosen == nil)
            if search.isSearching {
                Button("Stop") { search.stop() }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        let links = search.target?.links ?? 0
        if search.isSearching {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(search.found.count) of \(links) \u{2014} "
                     + "\(search.foldersRead) folders read, now \(search.folder)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else if search.allFound {
            Label("All \(links) names found in \(elapsed), \(search.foldersRead) folders read.",
                  systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if search.target != nil {
            Label(missing, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                // The first few: a whole disk has over a thousand, mostly
                // the system's own.
                .help(search.unreadable.prefix(20).joined(separator: "\n")
                      + (search.unreadable.count > 20 ? "\n\u{2026}" : ""))
                .lineLimit(2)
        }
    }

    /// Why some are missing: stopped, or behind folders it could not open --
    /// or on no folder at all, the name of a file still open after deletion.
    private var missing: String {
        let links = search.target?.links ?? 0
        let count = "Found \(search.found.count) of \(links) names"
        if search.wasStopped { return count + " \u{2014} stopped." }
        let unread = search.unreadable.count
        return count + " in \(elapsed)."
            + (unread == 0 ? ""
               : " \(unread) folder\(unread == 1 ? "" : "s") could not be read; the rest may be "
                 + "in there.")
    }

    private var elapsed: String {
        let seconds = (search.endedAt ?? Date()).timeIntervalSince(search.startedAt)
        return seconds < 1 ? "under a second"
            : seconds < 60 ? String(format: "%.0f s", seconds)
            : "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
    }

    private func show(_ url: URL?) {
        guard let url else { return }
        FileViewer.shared.reveal([url])
    }
}
