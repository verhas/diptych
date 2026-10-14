import AppKit
import SwiftUI

/// File ▸ Find Duplicates: the files holding the same bytes as one file, or
/// every set of them in one folder -- to select the ones to throw away.
struct DuplicatesView: View {

    @State private var search: DuplicateSearch
    @State private var window: NSWindow?
    /// The full list behind a warning line too long to read in the footer.
    @State private var details: Details?

    private enum Details: String, Identifiable {
        case orphans, unkept
        var id: String { rawValue }
    }

    init(url: URL) {
        _search = State(initialValue: DuplicateSearch(url: url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            results
            Divider()
            footer
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(minWidth: 640, minHeight: 360)
        .navigationTitle("Duplicates of \(search.url.lastPathComponent)")
        .background(WindowAccessor { found in
            guard let found else { return }
            if window !== found { window = found }
            // On every update, as every other window does: a window shown
            // again by its `WindowGroup` is put back on the list this way.
            AppWindows.shared.register(found)
            WindowSubjects.shared.register(found, kind: "duplicates", description: search.url.path)
        })
        // Closing the window stops the search: `onDisappear` alone is not
        // sure to come, a `WindowGroup` can keep a closed window's view.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) {
            if let closing = $0.object as? NSWindow, closing === window { search.abandon() }
        }
        .onDisappear { search.abandon() }
        .sheet(item: $details) { which in
            DuplicateWarningDetails(search: search, showsOrphans: which == .orphans)
        }
    }

    // MARK: - Header and options

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: search.url.path))
                    .resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(search.url.lastPathComponent).font(.headline)
                    Text(NamingTemplate.tilde(search.url.path))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Text(search.isFolder
                 ? "Files inside this folder that hold the same bytes, in groups. A level at "
                   + "a time, the folder's own files first."
                 : "Files holding the same bytes as this one, nearest first: its folder, the "
                   + "folders under it, then further out.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 18) {
                options
                Spacer()
                if search.isSearching {
                    Button("Stop") { search.stop() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button(search.hasSearched ? "Start Again" : "Start") { search.start() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// Fixed while a search runs: what is found is what they asked for.
    private var options: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Display links as duplicates", isOn: $search.options.includeLinks)
                    .help("Hard links -- other names of the same file -- and symbolic links "
                          + "leading to a file of the same content, listed with the file "
                          + "they lead to")
                Toggle("Search in subfolders too", isOn: subfolders)
                    .disabled(search.options.wholeVolume && !search.isFolder)
            }
            if !search.isFolder {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Search the whole volume", isOn: $search.options.wholeVolume)
                        .help("Then the folder above, without the part already read, and "
                              + "so on up to the top of the volume")
                }
                if !search.volumes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Then these volumes too:")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(search.volumes) { volume in
                            Toggle(volume.name, isOn: Binding(
                                get: { search.options.volumes.contains(volume.path) },
                                set: {
                                    if $0 { search.options.volumes.insert(volume.path) }
                                    else { search.options.volumes.remove(volume.path) }
                                }))
                            .help("\(volume.path) -- searched after this volume, in the order "
                                  + "listed; a network volume can take long")
                        }
                    }
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(search.isSearching)
    }

    /// The whole volume takes in the folders under this one.
    private var subfolders: Binding<Bool> {
        Binding(get: { search.options.subfolders || (search.options.wholeVolume && !search.isFolder) },
                set: { search.options.subfolders = $0 })
    }

    // MARK: - What was found

    @ViewBuilder
    private var results: some View {
        if search.groups.isEmpty {
            VStack {
                Spacer()
                Text(emptyText).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List {
                ForEach(search.groups) { group in
                    Section {
                        ForEach(group.files) { file in
                            row(file)
                        }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var emptyText: String {
        if !search.hasSearched { return "Choose what to search, then Start." }
        if search.isSearching { return "Searching\u{2026}" }
        return search.isFolder ? "No two files here hold the same bytes."
            : "No other file holds the same bytes."
    }

    private func groupHeader(_ group: DuplicateSearch.Group) -> some View {
        let all = group.files.allSatisfy { search.chosen.contains($0.id) }
        let unkept = search.unkept.contains { $0.id == group.id }
        return HStack(spacing: 6) {
            Button {
                search.toggleAll(in: group)
            } label: {
                Image(systemName: all ? "checkmark.square.fill" : "checkmark.square")
            }
            .buttonStyle(.borderless)
            .help(all ? "Deselect every file of this group" : "Select every file of this group")
            Text("\(group.files.count) file\(group.files.count == 1 ? "" : "s"), "
                 + "\(BinaryComparison.bytes(group.size)) each")
            if unkept {
                Text("\u{2014} every copy selected: deselect one to keep it")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
    }

    private func row(_ file: DuplicateSearch.File) -> some View {
        let item = file.found.item
        return HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { search.chosen.contains(file.id) },
                set: { if $0 { search.chosen.insert(file.id) } else { search.chosen.remove(file.id) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(nsImage: IconCache.icon(for: item))
            Button {
                show(file.id)
            } label: {
                Text(file.id.path)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.link)
            .help("Show \(file.id.lastPathComponent) in its folder, in the browser window")

            if item.hardLinkCount > 1 {
                Text("(\(item.hardLinkCount))")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("\(item.hardLinkCount) hard links: this file has \(item.hardLinkCount) names")
            }
            if item.isSymlink {
                Image(systemName: "arrowshape.turn.up.right")
                    .foregroundStyle(.secondary)
                    .help(item.linkTarget.isEmpty ? "Symbolic link"
                          : "Symbolic link to \(item.linkTarget)")
                LinkSteps(item: item)
            }
            if item.isExecutable {
                Image(systemName: "terminal.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Executable")
            }
            if let note = note(file.found.kind) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                ForEach(DirectoryDiffView.badgeSpecs.filter {
                    file.found.differences.contains($0.kind)
                }, id: \.letter) { spec in
                    DirectoryDiffView.badge(spec.letter, color: spec.color,
                                            help: spec.help + " from the group's first file")
                }
            }
        }
    }

    private func note(_ kind: DuplicateFinder.Kind) -> String? {
        switch kind {
        case .original: "the selected file"
        case .copy: nil
        case .hardLink: "hard link: the same file"
        case .symbolicLink: "symbolic link"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !search.groups.isEmpty {
                legend
            }
            if !search.failures.isEmpty {
                Text("Not moved to the Trash: " + search.failures.joined(separator: "; "))
                    .font(.caption).foregroundStyle(.red)
                    .lineLimit(3)
            }
            if !search.chosen.isEmpty, !search.unkept.isEmpty {
                warning(unkeptText, symbol: "exclamationmark.triangle.fill", color: .orange,
                        details: .unkept)
            }
            let orphans = search.orphans
            if !orphans.isEmpty {
                warning(orphanText(orphans), symbol: "link.badge.plus", color: .purple,
                        details: .orphans)
            }
            HStack(spacing: 10) {
                status
                Spacer()
                Button("Move Selected to Trash") {
                    Task { await search.trashChosen() }
                }
                .disabled(!search.canTrash)
                .help(search.chosen.isEmpty ? "Select the files to throw away first"
                      : search.canTrash ? "Undo puts them back, from the browser window"
                      : unkeptText)
            }
        }
    }

    /// Two lines at most, and a click for all of it.
    private func warning(_ text: String, symbol: String, color: Color,
                         details: Details) -> some View {
        Button {
            self.details = details
        } label: {
            Label(text, systemImage: symbol)
                .font(.caption).foregroundStyle(color)
                .lineLimit(2).truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click for the whole list")
    }

    private func orphanText(_ orphans: [(link: URL, target: URL)]) -> String {
        if orphans.count == 1, let one = orphans.first {
            return "\u{201C}\(one.link.lastPathComponent)\u{201D} links to "
                + "\(NamingTemplate.tilde(one.target.path)), which is selected for the Trash: "
                + "the link will lead nowhere."
        }
        return "\(orphans.count) links will lead nowhere -- what they lead to is selected for "
            + "the Trash: " + orphans.map {
                "\u{201C}\($0.link.lastPathComponent)\u{201D} \u{2192} "
                    + "\u{201C}\($0.target.lastPathComponent)\u{201D}"
            }.joined(separator: ", ") + "."
    }

    /// Why the button is greyed although something is selected.
    private var unkeptText: String {
        let count = search.unkept.count
        let which = search.isFolder
            ? (count == 1 ? "In one group every copy is" : "In \(count) groups every copy is")
            : "Every copy is"
        return which + " selected, so Move Selected to Trash is off: nothing would be left of "
            + "that content. Deselect at least one file in each group marked in orange -- a "
            + "symbolic link does not count, it keeps nothing once its file is gone. This is "
            + "for getting rid of the extra copies, not of all of them."
    }

    /// Only the letters a duplicate can carry.
    private var legend: some View {
        let kinds: DirectoryComparison.Difference = [.name, .permissions, .attributes, .acl,
                                                     .modified, .created, .ownership]
        return FlowLayout(spacing: 10) {
            ForEach(DirectoryDiffView.badgeSpecs.filter { kinds.contains($0.kind) },
                    id: \.letter) { spec in
                HStack(spacing: 4) {
                    DirectoryDiffView.badge(spec.letter, color: spec.color, help: spec.help)
                    Text(spec.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        let count = search.duplicateCount
        let found = search.isFolder
            ? "\(count) file\(count == 1 ? "" : "s") in \(search.groups.count) "
              + "group\(search.groups.count == 1 ? "" : "s")"
            : "\(count) duplicate\(count == 1 ? "" : "s")"
        if let stage = search.stage {
            Text(stageText(stage))
                .font(.caption.weight(.medium))
                .lineLimit(1).truncationMode(.middle)
                .help(stageHelp)
        }
        if search.isSearching {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(found) \u{2014} \(search.foldersRead) folders read, now "
                     + NamingTemplate.tilde(search.folder))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        } else if search.hasSearched {
            Text(found + (search.wasStopped ? ", stopped" : "") + " \u{2014} "
                 + "\(search.foldersRead) folders read in \(elapsed)"
                 + (search.unreadable.isEmpty ? "."
                    : "; \(search.unreadable.count) could not be read."))
                .font(.caption).foregroundStyle(.secondary)
                .help(search.unreadable.prefix(20).joined(separator: "\n"))
        }
    }

    private func stageText(_ stage: DuplicateFinder.Stage) -> String {
        let prefix = search.isSearching ? "" : "Stopped while searching: "
        let text = switch stage {
        case .folder:
            search.isFolder ? "The folder itself" : "Its own folder"
        case .subfolders:
            "Subfolders, a level at a time"
        case .up(let path):
            "Wider: everything under " + NamingTemplate.tilde(path)
        case .volume(let name, _):
            "Another volume: \u{201C}\(name)\u{201D}"
        }
        return prefix.isEmpty ? text : prefix + text.prefix(1).lowercased() + text.dropFirst()
    }

    private var stageHelp: String {
        "How wide the search has gone. Stop it once it is wide enough: what was found stays."
    }

    private var elapsed: String {
        let seconds = (search.endedAt ?? Date()).timeIntervalSince(search.startedAt)
        return seconds < 1 ? "under a second"
            : seconds < 60 ? String(format: "%.0f s", seconds)
            : "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
    }

    /// The file's folder in the active pane of the window the search came
    /// from, the file selected.
    private func show(_ url: URL) {
        guard let model = DuplicateOrigins.shared.origin(for: search.url),
              let browser = model.window,
              AppWindows.shared.live.contains(where: { $0 === browser }) else {
            FileViewer.shared.reveal([url])
            return
        }
        let pane = model.active
        pane.pendingSelection = [url.standardizedFileURL]
        pane.navigate(to: url.deletingLastPathComponent())
        if browser.isMiniaturized { browser.deminiaturize(nil) }
        browser.orderFront(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Everything a warning line in the duplicates window could not fit.
private struct DuplicateWarningDetails: View {

    let search: DuplicateSearch
    let showsOrphans: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(showsOrphans ? "Links that will lead nowhere"
                 : "Groups with every copy selected")
                .font(.headline)
            Text(showsOrphans
                 ? "Each of these links is not selected, but what it leads to is. Moved to the "
                   + "Trash, it leaves the link pointing at nothing. Move Selected to Trash "
                   + "still works; Undo brings the files back, and the links work again."
                 : "Nothing of these would be left, so Move Selected to Trash is off. Deselect "
                   + "at least one file in each -- a symbolic link does not count, it keeps "
                   + "nothing once its file is gone.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                if showsOrphans {
                    Section("The links") {
                        ForEach(search.orphans, id: \.link) { orphan in
                            VStack(alignment: .leading, spacing: 2) {
                                path(orphan.link)
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.turn.down.right")
                                        .foregroundStyle(.secondary)
                                    path(orphan.target).foregroundStyle(.purple)
                                }
                            }
                        }
                    }
                    Section("Going to the Trash, that they lead to") {
                        ForEach(Array(Set(search.orphans.map(\.target))).sorted { $0.path < $1.path },
                                id: \.self) { target in
                            path(target)
                        }
                    }
                } else {
                    ForEach(search.unkept) { group in
                        Section("\(group.files.count) files, "
                                + "\(BinaryComparison.bytes(group.size)) each") {
                            ForEach(group.files) { file in
                                HStack(spacing: 4) {
                                    path(file.id)
                                    if file.found.kind == .symbolicLink {
                                        Text("symbolic link").font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 320, idealHeight: 440)
    }

    private func path(_ url: URL) -> some View {
        Text(url.path)
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1).truncationMode(.middle)
            .textSelection(.enabled)
            .help(url.path)
    }
}
