import SwiftUI
import UniformTypeIdentifiers

/// One half of the window: path bar, file table, status line.
struct PaneView: View {


    /// `@Bindable` unlocks `$pane.selection` -- a two-way binding into an
    /// `@Observable` class.
    @Bindable var pane: PaneModel

    /// Needed for the row context menu, whose commands act across both panes.
    let model: AppModel
    let side: AppModel.Side
    let isActive: Bool
    let activate: () -> Void

    /// Real keyboard focus, shared with ContentView. Binding it to the Table is
    /// what makes clicking a pane switch to it, and what lets the arrow keys and
    /// type-select work after Tab -- previously `activeSide` was just a colour,
    /// with no connection to which view AppKit was actually sending keys to.
    @FocusState.Binding var focusedSide: AppModel.Side?

    @State private var pathText = ""
    /// Whether opening the editor selects the whole path or puts the caret at
    /// its end. Set by whichever command opened it.
    @State private var pathSelectsAll = false
    @FocusState private var pathFieldFocused: Bool
    /// The mouse is over the path bar: Option then shows the links too,
    /// without clicking into the text first.
    @State private var pathBarHovered = false
    /// The loading spinner, once a listing has taken half a second.
    @State private var showsSpinner = false
    /// Where the caret is in the flat view's expression, for its hint.
    @State private var flatCaret = 0
    @State private var flatFieldHeight = FlatExpressionField.lineHeight

    var body: some View {
        VStack(spacing: 0) {
            toolRow
            if pane.isFlat { flatStatus }
            pathBar
            Divider()
            table
            Divider()
            statusBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) {
            // The active pane gets a coloured top edge. In a two-pane manager
            // "which side am I on" has to be readable at a glance, because every
            // command means "from here to there".
            Rectangle()
                .fill(isActive ? Color.accentColor : Color.clear)
                .frame(height: 2)
        }
        // "Go to Folder" from the menu bar targets the active pane.
        .onChange(of: model.pathEditToken) { _, _ in
            if isActive { beginPathEdit(selectingAll: model.pathEditSelectsAll) }
        }
        .simultaneousGesture(TapGesture().onEnded { activate() })
        .onAppear { pathText = pane.directory.path }
        // Keep the editor's text in step with the pane. Navigating by any other
        // means -- double-click, Return, the menu -- also closes the editor;
        // without this it stayed open forever showing a stale path, since only
        // Return and Escape ever dismissed it.
        .onChange(of: pane.directory) { _, new in
            pathText = new.path
            if pane.isEditingPath { endPathEdit(returnFocus: false) }
        }
        // Clicking anywhere else is a cancel. Focus has already moved, so this
        // must not try to move it again.
        .onChange(of: pathFieldFocused) { _, focused in
            if !focused && pane.isEditingPath { endPathEdit(returnFocus: false) }
        }
    }

    // MARK: - Pieces

    /// History on the left, filter on the right.
    private var toolRow: some View {
        HStack(spacing: 6) {
            Button {
                activate()
                pane.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(!pane.canGoBack)
            .help("Back")

            recentMenu

            Button {
                activate()
                pane.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(!pane.canGoForward)
            .help("Forward")

            flatButton

            if pane.isFlat {
                flatExpression
            } else {
                Spacer(minLength: 6)
                filterControls
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    // MARK: - Flat view

    /// Flat or not, at a glance: the stacked list lit up while the pane is
    /// one list of its folder and everything under it.
    private var flatButton: some View {
        Button {
            activate()
            model.toggleFlatView()
        } label: {
            Image(systemName: pane.isFlat ? "list.bullet.rectangle.fill" : "list.bullet.indent")
                .foregroundStyle(pane.isFlat ? Color.accentColor : Color.primary)
                .frame(width: 18)
        }
        .buttonStyle(.borderless)
        .help(pane.isFlat
              ? "Flat view: this folder and everything under it, as one list. Click to go "
                + "back to the folder (\u{21E7}\u{2318}F)"
              : "Flat view: list this folder and everything under it as one list, filtered "
                + "by an expression (\u{21E7}\u{2318}F)")
    }

    private var flatProblem: FlatQuery.Problem? {
        if case .failure(let problem) = FlatQuery.parse(pane.flatDraft) { return problem }
        return nil
    }

    private var flatWarnings: [FlatQuery.Problem] {
        (try? FlatQuery.parse(pane.flatDraft).get())?.warnings ?? []
    }

    /// The list was made by this very expression, and something in it no
    /// longer passes: only running it again puts that right.
    private var flatIsStale: Bool {
        pane.flatStale && pane.flat?.expression == pane.flatDraft
    }

    private var flatExpression: some View {
        HStack(alignment: .top, spacing: 6) {
            FlatExpressionField(text: $pane.flatDraft, caret: $flatCaret, problem: flatProblem,
                                warnings: flatWarnings, stale: flatIsStale,
                                height: $flatFieldHeight,
                                onSave: flatProblem == nil ? { name in
                                    model.saveFlatExpression(pane.flatDraft, as: name)
                                } : nil,
                                knownValues: { field in
                                    // What it has found: nothing before it ran.
                                    guard pane.isFlat, !pane.items.isEmpty
                                            || pane.flatProgress == nil else { return nil }
                                    return MediaInfo.values(
                                        of: field,
                                        in: pane.items.filter { !$0.isDirectory }.map(\.url))
                                },
                                onRun: { runFlat() })
                .frame(height: flatFieldHeight)
                .frame(maxWidth: .infinity)
            if pane.flatProgress != nil {
                Button("Stop") { pane.stopFlatScan() }
                    .controlSize(.small)
                    .help("Stop walking the tree; what was found so far stays")
            } else {
                Button { runFlat() } label: {
                    Image(systemName: "play.fill")
                }
                .controlSize(.small)
                .disabled(flatProblem != nil)
                .help("Walk the tree again with this expression (Return)")
            }
        }
    }

    private func runFlat() {
        activate()
        guard flatProblem == nil else { return }
        pane.runFlat()
        model.persist()
    }

    /// Under the expression: what is wrong with it, or what the word at the
    /// caret takes -- and how the walk is going.
    private var flatStatus: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let problem = flatProblem {
                Text(problem.message)
                    .foregroundStyle(.red)
            } else if let warning = flatWarnings.first {
                Text(warning.message)
                    .foregroundStyle(.orange)
            } else if let hint = FlatQuery.hint(in: pane.flatDraft, at: flatCaret) {
                Text(hint)
                    .foregroundStyle(.secondary)
            }
            if let progress = pane.flatProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                    Text("\(progress.found.formatted()) found among "
                         + "\(progress.walk.seen.formatted()) items in "
                         + "\(progress.walk.folders.formatted()) folders \u{2014} "
                         + (progress.walk.current.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
            } else if flatIsStale {
                Text("Some rows no longer pass the expression since they were changed; they "
                     + "stay until it is run again (\u{25B6})")
                    .foregroundStyle(.brown)
            } else if pane.flatStopped {
                Text("Stopped: \(pane.items.count) found before that \u{2014} the list is not "
                     + "complete")
                    .foregroundStyle(.orange)
            } else if pane.items.isEmpty, !pane.isLoading, pane.flat?.expression == pane.flatDraft,
                      flatWarnings.isEmpty {
                Text("Nothing here passes the expression")
                    .foregroundStyle(.secondary)
            }
            if !pane.flatUnreadable.isEmpty {
                Text("\(pane.flatUnreadable.count) folder"
                     + (pane.flatUnreadable.count == 1 ? "" : "s") + " could not be read")
                    .foregroundStyle(.orange)
                    .help(pane.flatUnreadable.prefix(20)
                        .map { ($0.path as NSString).abbreviatingWithTildeInPath }
                        .joined(separator: "\n"))
            }
        }
        .font(.system(size: 11))
        .lineLimit(2)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, 3)
    }

    /// The ordinary filter: a pattern, and how it is read and shown.
    @ViewBuilder
    private var filterControls: some View {
            TextField("Filter", text: $pane.filterText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(minWidth: 70, idealWidth: 120, maxWidth: 160)
                // Red while a regular expression will not compile, so a
                // half-typed pattern is obviously half-typed rather than
                // looking like a filter that matches nothing.
                .foregroundStyle(pane.filterIsValid ? Color.primary : Color.red)
                .help(pane.filterIsRegex
                      ? "Regular expression, anchored: .*\\.txt"
                      : "Shell pattern: *.txt")
                // Only while there is something to clear, as a search field
                // does -- a permanently visible button would read as part of
                // the field's furniture rather than as something to press.
                .overlay(alignment: .trailing) {
                    if !pane.filterText.isEmpty {
                        Button {
                            activate()
                            pane.filterText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                // The whole circle is the target, not just the
                                // glyph: an 11pt hit area is a dart throw.
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 4)
                        .help("Clear the filter")
                    }
                }

            Toggle("RegEx", isOn: $pane.filterIsRegex)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help("Read the filter as a regular expression instead of a shell pattern")

            Toggle("Hide", isOn: $pane.filterHidesOthers)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help("Leave non-matching items out of the list entirely, "
                      + "instead of greying them out")
    }

    /// The folders this pane has been in, most recent first -- also the ones
    /// Back and Forward have lost after going back and then somewhere new.
    private var recentMenu: some View {
        Menu {
            ForEach(pane.recentElsewhere, id: \.self) { folder in
                Button((folder.path as NSString).abbreviatingWithTildeInPath) {
                    activate()
                    pane.navigate(to: folder)
                }
            }
        } label: {
            Image(systemName: "circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(pane.recentElsewhere.isEmpty)
        .help("Recent folders")
    }

    private var pathBar: some View {
        HStack(spacing: 6) {
            Button {
                activate()
                pane.goUp()
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .help("Go to parent directory")
            .disabled(pane.directory.pathComponents.count <= 1)

            // A permanently-editable TextField here was a focus magnet: AppKit
            // hands first responder to the first text field in the key view
            // loop, so the table never got focus and the arrow keys typed into
            // the path bar. Showing a button until you ask to edit -- Finder's
            // "Go to Folder" model -- leaves the table as the only focus target.
            // Option over the bar, or while typing in it, turns the path
            // into links to the folders above -- the text stays underneath,
            // with whatever was typed and selected, for when Option is let go.
            ZStack(alignment: .leading) {
                if pane.isEditingPath {
                    // AppKit, for Tab completion and a coloured suggestion --
                    // neither of which a SwiftUI TextField can express.
                    PathField(text: $pathText,
                              selectsAll: pathSelectsAll,
                              base: pane.directory.path,
                              onCommit: { commitPath() },
                              onCancel: { endPathEdit() })
                        .frame(height: 21)
                } else {
                    Button {
                        beginPathEdit()
                    } label: {
                        Text(displayPath)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Without this the button only responds where glyphs are
                            // actually drawn, so a short path like "~" left almost
                            // the whole bar dead. contentShape makes the full frame
                            // clickable -- this is the legitimate use of it, on a
                            // button's own label rather than over a table row.
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Click to type a path (Cmd-Shift-G)")
                    // A plain button with no menu of its own passes a right-click
                    // straight through to whatever is behind it -- which, without
                    // this, was the pane's own empty-space menu. This is also the
                    // only way to favourite "/" itself: nothing about the root
                    // directory can be dragged into the sidebar the way a row
                    // inside a pane can.
                    .contextMenu {
                        Button("Add to Favourites") { model.addFavourites([pane.directory]) }
                            .disabled(ConfigStore.shared.configuration.favourites
                                        .contains(pane.directory.path))
                    }
                }
            }
            .opacity(showsCrumbs ? 0 : 1)
            .allowsHitTesting(!showsCrumbs)
            .overlay(alignment: .leading) {
                if showsCrumbs {
                    let crumbs = crumbTarget
                    PathCrumbs(directory: crumbs.url, lastIsLink: crumbs.lastIsLink) { folder, cameFrom in
                        goToCrumb(folder, cameFrom: cameFrom)
                    }
                }
            }
            .onHover { pathBarHovered = $0 }

            // A fixed place, drawn whether or not it spins: a spinner that
            // came and went made the bar taller -- scaleEffect shrinks only
            // the drawing -- and the rows jumped down and back on every
            // Refresh. And only for a listing that takes a while: one back
            // within half a second is not worth a flicker.
            Color.clear
                .frame(width: 12, height: 12)
                .overlay {
                    if showsSpinner {
                        ProgressView().controlSize(.mini)
                    }
                }
                .task(id: pane.isLoading) {
                    guard pane.isLoading else { showsSpinner = false; return }
                    try? await Task.sleep(for: .milliseconds(500))
                    if !Task.isCancelled, pane.isLoading { showsSpinner = true }
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var showsCrumbs: Bool {
        OptionKey.shared.isDown && (pane.isEditingPath || pathBarHovered)
    }

    /// What the links lead along: while a path is typed or pasted in the
    /// bar, that path -- its folders all links, its file's name the end of
    /// them -- so a path to a file is one click from its folder.
    private var crumbTarget: (url: URL, lastIsLink: Bool) {
        let here = ArchiveBrowsing.shown(pane.directory).standardizedFileURL.path
        guard pane.isEditingPath else { return (ArchiveBrowsing.shown(pane.directory), pane.isFlat) }
        // A server's folder is typed as its address, which is not a local path:
        // nothing is previewed from it while it is being typed.
        if RemoteBrowsing.isInside(pane.directory) { return (ArchiveBrowsing.shown(pane.directory), pane.isFlat) }
        if let inside = ArchiveBrowsing.actual(URL(fileURLWithPath: PathCompletion.resolve(
            pathText, base: ArchiveBrowsing.shown(pane.directory).path))) {
            let shown = ArchiveBrowsing.shown(inside)
            return (shown, shown.standardizedFileURL.path != here || pane.isFlat)
        }
        let typed = URL(fileURLWithPath: PathCompletion.resolve(pathText, base: pane.directory.path))
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: typed.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { return (typed, false) }
            return (typed, typed.standardizedFileURL.path != here || pane.isFlat)
        }
        let existing = PaneModel.nearestExistingAncestor(of: typed)
        return (existing, existing.standardizedFileURL.path != here || pane.isFlat)
    }

    /// A folder above, from the links: the folder it came out of is selected,
    /// as going up does, and any typing in the path bar is given up.
    /// Inside an opened archive, the links name the archive and its
    /// folders; each leads to where it was unpacked.
    private func goToCrumb(_ folder: URL, cameFrom: URL?) {
        activate()
        endPathEdit()
        pane.navigate(to: ArchiveBrowsing.actual(folder) ?? folder)
        if let cameFrom {
            // Up out of an archive the archive itself is selected, a file.
            let from = ArchiveBrowsing.actual(cameFrom).flatMap { inside in
                ArchiveBrowsing.opened(containing: inside)?.root == inside ? nil : inside
            } ?? cameFrom
            pane.pendingSelection = [from]
        }
    }

    /// `/Users/verhasp/Documents` shown as `~/Documents`; a folder inside an
    /// opened archive as inside the archive.
    private var displayPath: String {
        let shown = ArchiveBrowsing.shown(pane.directory)
        // A server's folder reads as its address, which is what it is.
        if shown.scheme == "sftp" {
            return shown.absoluteString.removingPercentEncoding ?? shown.absoluteString
        }
        return (shown.path as NSString).abbreviatingWithTildeInPath
    }

    private func beginPathEdit(selectingAll: Bool = false) {
        activate()
        pathSelectsAll = selectingAll
        // With the separator already there, typing a child's name works
        // straight away and Tab completes inside this directory rather than
        // re-completing its own name. "/" is the one path that already ends in
        // one. A server's folder is edited as its whole address.
        let path = RemoteBrowsing.isInside(pane.directory)
            ? displayPath : ArchiveBrowsing.shown(pane.directory).path
        pathText = path.hasSuffix("/") ? path : path + "/"
        pane.isEditingPath = true
    }

    /// `returnFocus` is false when focus has already gone somewhere else --
    /// pulling it back to this pane's table would steal it from whatever the
    /// user just clicked.
    private func endPathEdit(returnFocus: Bool = true) {
        guard pane.isEditingPath else { return }
        pane.isEditingPath = false
        pathFieldFocused = false

        // If the folder vanished while the path was being edited, the move was
        // deferred until now.
        if !FileManager.default.fileExists(atPath: pane.directory.path) {
            model.flash("\u{201C}\(pane.directory.lastPathComponent)\u{201D} is no longer there")
            pane.navigate(to: PaneModel.nearestExistingAncestor(of: pane.directory))
        }
        if returnFocus {
            // Otherwise focus lands nowhere and the arrow keys stop working
            // after a cancelled path edit.
            focusedSide = side
        }
    }

    /// The path bar's commit for a server folder. The text is an sftp:// address,
    /// which opens that server, or a path on this server: absolute, or relative
    /// to the folder being shown. A path the server does not have keeps the
    /// editor open, as a local typo does.
    private func commitServerPath() {
        let typed = pathText.trimmingCharacters(in: .whitespaces)
        if typed.lowercased().hasPrefix("sftp://") {
            guard let address = URL(string: typed) else {
                model.flash("\u{201C}\(typed)\u{201D} is not an address")
                pathFieldFocused = true
                return
            }
            endPathEdit()
            model.connect(to: address, in: pane)
            return
        }

        let current = ArchiveBrowsing.shown(pane.directory)
        let remote = PathCompletion.resolve(typed, base: current.path)
        var components = URLComponents(url: current, resolvingAgainstBaseURL: false)
        components?.path = remote
        guard let target = components?.url, let local = ArchiveBrowsing.actual(target) else {
            model.flash("\u{201C}\(typed)\u{201D} is not a place on the server")
            pathFieldFocused = true
            return
        }
        Task { @MainActor in
            do {
                try await RemoteBrowsing.refresh(local)
                endPathEdit()
                pane.navigate(to: local)
            } catch {
                model.flash("\u{201C}\(remote)\u{201D} could not be listed on the server: "
                            + error.localizedDescription)
                pathFieldFocused = true
            }
        }
    }

    private func commitPath() {
        if RemoteBrowsing.isInside(pane.directory) {
            commitServerPath()
            return
        }
        // Resolved against the pane, so a bare name or a "../" means what it
        // says in a shell: relative to where you are, not to wherever the
        // process happens to think it is standing.
        var expanded = PathCompletion.resolve(pathText, base: ArchiveBrowsing.shown(pane.directory).path)
        // A path into an opened archive, as the path bar shows it.
        if let inside = ArchiveBrowsing.actual(URL(fileURLWithPath: expanded)) { expanded = inside.path }

        // Navigating to a path that is not there used to leave the pane looking
        // like an empty folder. Refuse instead, and stay in the editor so the
        // typo can be corrected -- Escape still backs out to where we were.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            model.flash("\u{201C}\(pathText)\u{201D} does not exist")
            pathFieldFocused = true
            return
        }
        // A file: its folder, with it selected and opened -- what Return on its
        // row would have done. A path pasted from a log or a message is then
        // one keystroke from the file itself.
        guard isDirectory.boolValue else {
            let file = URL(fileURLWithPath: expanded)
            pane.pendingSelection = [file]
            pane.openAfterLoading = true
            pane.navigate(to: file.deletingLastPathComponent())
            endPathEdit()
            return
        }

        pane.navigate(to: URL(fileURLWithPath: expanded))
        endPathEdit()
    }

    private var table: some View {
        // Columns come from configuration, so they are built with
        // TableColumnForEach rather than written out. That in turn is why
        // sorting uses one FileComparator for every column: SwiftUI needs a
        // single concrete comparator type across a dynamic column set.
        // No sort arrow while the rows are in an order of the user's own;
        // clicking a header sorts again.
        let sortOrder = Binding(get: { pane.manualOrder == nil ? pane.sortOrder : [] },
                                set: { pane.sort(by: $0) })
        // The columns for this pane -- the Original Location column among them
        // only when this is a Trash listing (and its setting is on).
        let columns = ConfigStore.shared.configuration.columns(inTrash: pane.isTrashListing)
        return Table(of: FileItem.self, selection: $pane.selection, sortOrder: sortOrder) {
            TableColumnForEach(columns) { column in
                TableColumn(title(for: column), sortUsing: FileComparator(column: column)) { item in
                    CellView(column: column, item: item, pane: pane, model: model,
                             activate: activate)
                }
                .width(min: column.width.min, ideal: column.width.ideal, max: column.width.max)
            }
        } rows: {
            ForEach(pane.rows) { item in
                // Dragging is declared on the row, not on a cell. The table owns
                // the drag, so it cannot interfere with click selection the way
                // a gesture inside a cell does.
                TableRow(item)
                    .itemProvider {
                        guard !item.isParent else { return nil }
                        model.dragStarted(from: pane, url: item.url)
                        // Deliberately not `NSItemProvider(contentsOf:)`, and
                        // not `registerFileRepresentation` either -- both set
                        // up real file-*promise* machinery (visible on the
                        // drag pasteboard as a pile of
                        // com.apple.NSFilePromiseItemMetaData /
                        // promised-file-* types), which exists for content
                        // that does not exist as a file yet and has to be
                        // produced on demand. This is an existing file with a
                        // stable path, which is exactly what Finder drags:
                        // measured with a throwaway pasteboard-sniffing tool,
                        // Finder's own drag for an existing file carries none
                        // of that -- just the URL and the POSIX path, nothing
                        // promised. Whatever receives a promise-laden drag
                        // seemingly takes a different path than it does for
                        // Finder's plain one: a promise-free drag from here
                        // landed in Terminal exactly as Finder's own does,
                        // where every promise-based attempt before it landed
                        // as the file's own file:// URL, stringified as-is.
                        let provider = NSItemProvider()
                        provider.registerObject(item.url.path as NSString, visibility: .all)
                        // Not `registerObject(item.url as NSURL)`: `NSURL`'s
                        // own conformance bundles "public.file-url" together
                        // with the generic "public.url" -- a type Finder's own
                        // drag never carries at all for an existing file, sniffed
                        // the same way the file-promise metadata above was.
                        // Something downstream treats the presence of a plain,
                        // not-specifically-a-file URL type as "this is a link",
                        // and a file already has a good deal more to say for
                        // itself than that.
                        provider.registerDataRepresentation(
                            forTypeIdentifier: UTType.fileURL.identifier, visibility: .all
                        ) { completion in
                            completion(item.url.absoluteString.data(using: .utf8), nil)
                            return nil
                        }
                        // Without a suggested name Finder invents one from
                        // the content type -- "text.log". The extension is
                        // appended from that type, so this is the stem only;
                        // passing the full name yields "item-003.log.log".
                        provider.suggestedName = item.url.deletingPathExtension().lastPathComponent
                        return provider
                    }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .focused($focusedSide, equals: side)
        // The supported way to get a double-click out of a Table:
        // `primaryAction` fires for the whole row, anywhere in it, and the menu
        // closure gives the right-click menu for free.
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            rowMenu(for: ids)
        } primaryAction: { ids in
            activate()
            guard let id = ids.first else { return }
            model.open(id: id, in: pane)
        }
        .overlay { unreadableNotice }
        // Belt and braces with the cleared rows: while a navigation is in
        // flight the table takes no clicks at all, so a double-click cannot be
        // aimed at a listing that is on its way out.
        //
        // Applied to the table and *then* overlaid, not the other way round:
        // `.disabled` reaches everything inside the view it modifies, and an
        // overlay added first would have had its Cancel button disabled too.
        .disabled(pane.isNavigating || pane.openingArchive != nil)
        .overlay { loadingNotice }
        .overlay { openingArchiveNotice }
        // A fresh table identity when the Original Location column comes or goes
        // -- entering or leaving a Trash listing. Changing a Table's column
        // *count* in place is what AppKit crashes on; rebuilding sidesteps it.
        .id(columns.contains(.originalLocation))
    }

    /// An archive being unpacked to be shown: how far, and Stop.
    @ViewBuilder
    private var openingArchiveNotice: some View {
        if let opening = pane.openingArchive {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let progress = opening.job.snapshot()
                VStack(spacing: 10) {
                    Text("Opening \u{201C}\(opening.name)\u{201D}\u{2026}")
                        .font(.system(size: 12))
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction).frame(width: 220)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(progress.totalBytes > 0
                         ? "\(ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file)) of "
                           + ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
                         : "Reading what it holds\u{2026}")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("Unpacked once, read-only, until Diptych quits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Stop") { opening.job.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Shown only while moving to a *different* directory. A refresh in place
    /// keeps its rows and needs no notice.
    @ViewBuilder
    private var loadingNotice: some View {
        if let target = pane.loadingDirectory {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Opening \u{201C}\(target.lastPathComponent)\u{201D}\u{2026}")
                    .font(.system(size: 12))
                if pane.loadedCount > 0 {
                    Text("\(pane.loadedCount.formatted()) items read so far")
                        .font(.caption)
                        .monospacedDigit()
                }
                // What the folder's path says it is on; the pane's own facts
                // are still those of where it came from.
                Text(VolumeList.shared.volume(containing: target)?.isNetwork
                     ?? pane.volume.isNetwork
                     ? "A folder on a server can take a while over the network."
                     : "A volume that is spinning up can take several seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") { pane.cancelLoad() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A directory that cannot be read looks exactly like an empty one, which
    /// is how a Time Machine volume reads without Full Disk Access. Say so.
    @ViewBuilder
    private var unreadableNotice: some View {
        if let error = pane.errorText {
            VStack(spacing: 10) {
                Image(systemName: pane.errorIsPermission ? "lock.slash" : "exclamationmark.triangle")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)

                Text(error)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if pane.errorIsPermission {
                    Text("macOS protects this location. Time Machine volumes and some "
                         + "system folders need Full Disk Access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Open Full Disk Access Settings") {
                        NSWorkspaceOpener.openFullDiskAccessSettings()
                    }
                }

                if pane.awaitingServer != nil {
                    if model.connectingTo != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Connect") { model.reconnect(pane) }
                        Button("Go Home") {
                            pane.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 12, y: 3)
            .allowsHitTesting(pane.errorIsPermission || pane.awaitingServer != nil)
        }
    }

    /// While permissions are being edited the heading names the field the caret
    /// sits in, so you can see whether you are changing user, group or other.
    private func title(for column: FileColumn) -> String {
        if column == .permissions, let scope = model.permissionScope { return scope }
        return column.title
    }

    /// Right-clicking a row that is not part of the selection should act on
    /// that row, not on whatever was selected before. SwiftUI hands the menu
    /// the ids it applies to, so adopt them as the selection first.
    private func act(_ ids: Set<FileItem.ID>, _ body: @escaping () -> Void) {
        activate()
        if !ids.isEmpty, pane.selection != ids {
            pane.selection = ids
        }
        body()
    }

    /// Create Archive for anything; Extract only when an archive is among
    /// the rows.
    @ViewBuilder
    private func archiveMenu(for ids: Set<FileItem.ID>) -> some View {
        let archives = pane.rows.filter {
            ids.contains($0.id) && !$0.isDirectory && Archiving.isExtractable($0.url)
        }
        Menu("Archive") {
            Button("Create Archive\u{2026}") { act(ids) { model.requestCreateArchive() } }
            if ids.count == 1, let item = pane.rows.first(where: { ids.contains($0.id) }),
               !item.isDirectory, AppModel.opensAsFolder(item.url) {
                Divider()
                Button(DiskImaging.isDiskImage(item.url) ? "Mount in Pane" : "Open as Folder") {
                    act(ids) { model.openSelectionAsFolder() }
                }
            }
            if !archives.isEmpty {
                Divider()
                Button("Extract Here") { act(ids) { model.extractHere() } }
                    .disabled(pane.volume.isReadOnly)
                Button("Extract to Other Pane") { act(ids) { model.extractToOtherPane() } }
                    .disabled(model.otherPaneFolder == nil || model.inactive.volume.isReadOnly)
            }
            if ids.count == 1, let item = pane.rows.first(where: { ids.contains($0.id) }),
               !item.isDirectory, item.url.pathExtension.lowercased() == "zip" {
                Divider()
                Button("Recover ZIP Password\u{2026}") { act(ids) { model.recoverPassword() } }
            }
        }
    }

    /// Checksum ▸ Create ▸ a kind, and Check -- offered when any plain file is
    /// selected.
    @ViewBuilder
    private func checksumMenu(for ids: Set<FileItem.ID>) -> some View {
        if pane.rows.contains(where: { ids.contains($0.id) && !$0.isDirectory && !$0.isParent }) {
            Menu("Checksum") {
                Menu("Create") {
                    Button("MD5") { act(ids) { model.createChecksums(.md5) } }
                    Button("SHA-1") { act(ids) { model.createChecksums(.sha1) } }
                    Button("SHA-256") { act(ids) { model.createChecksums(.sha256) } }
                    Button("SHA-512") { act(ids) { model.createChecksums(.sha512) } }
                }
                Button("Check") { act(ids) { model.checkChecksums() } }
            }
        }
    }

    /// The right-click menu in a Trash listing: what Finder's own Trash menu
    /// offers -- put a file back, rename it, look at it, or get rid of it for
    /// good -- but not the file-making and transforming tools, which have no
    /// place in the Trash.
    @ViewBuilder
    private func trashRowMenu(for ids: Set<FileItem.ID>) -> some View {
        if ids.isEmpty {
            Button("Refresh") { pane.reload() }
                .keyboardShortcut(.refresh)
            if pane.rows.contains(where: { !$0.isParent }) {
                Divider()
                Button("Empty Bin", role: .destructive) { activate(); model.requestEmptyBin() }
            }
        } else {
            let single = ids.count == 1 ? pane.rows.first(where: { ids.contains($0.id) }) : nil
            if let item = single, !item.isParent, !item.originalLocation.isEmpty {
                Button("Put Back") { act(ids) { model.restoreFromTrash() } }
                if !item.isDirectory,
                   FileManager.default.fileExists(atPath: item.originalLocation) {
                    Button("Compare with the Original\u{2026}") {
                        act(ids) { model.compareTrashedWithOriginal() }
                    }
                }
                Divider()
            }
            // Ways to look at a trashed item and find it.
            Button("Open") { act(ids) { if let id = ids.first { model.open(id: id, in: pane) } } }
                .keyboardShortcut(.open)
            Button("Get Info") { act(ids) { model.showInfo() } }
                .keyboardShortcut(.getInfo)
            Button("Reveal in Finder") { act(ids) { model.revealSelection() } }
                .keyboardShortcut(.revealInFinder)
            if let item = single, !item.isParent {
                Button("Rename\u{2026}") { act(ids) { model.requestRename() } }
                    .keyboardShortcut(.rename)
            }
            Divider()
            Menu("Copy") {
                Button("File Name") { act(ids) { model.copySelectionNames(fullPath: false) } }
                    .keyboardShortcut(.copyNames)
                Button("Full Path") { act(ids) { model.copySelectionNames(fullPath: true) } }
                    .keyboardShortcut(.copyPaths)
            }
            Divider()
            // The two ways things leave the Trash for good. Delete Immediately
            // acts on the selection; Empty Bin clears the lot.
            Button("Delete Immediately\u{2026}", role: .destructive) {
                act(ids) { model.requestDeleteImmediately() }
            }
            .keyboardShortcut(.trash)
            Button("Empty Bin", role: .destructive) { activate(); model.requestEmptyBin() }
        }
    }

    @ViewBuilder
    private func rowMenu(for ids: Set<FileItem.ID>) -> some View {
        if pane.isTrashListing {
            // A Trash listing is not a place to make, paste or transform files
            // -- what you do with a trashed one is put it back, rename it, look
            // at it or delete it for good, so the menu is trimmed to that.
            trashRowMenu(for: ids)
        } else if ids.isEmpty {
            newMenu
            if ConfigStore.shared.menuItemShown(.scripts) { scripts(for: []) }
            pasteMenu(for: ids)
            Button("Refresh") { pane.reload() }
                .keyboardShortcut(.refresh)
        } else {
            // A broken link can be renamed, moved, trashed or repaired in Get
            // Info -- but nothing that has to reach its target can work, so
            // those commands are not offered rather than offered to fail.
            let reachesNothing = pane.rows.contains { ids.contains($0.id) && $0.isBrokenLink }
            // First for a link, and only when there is something to go to --
            // a link to a link leading nowhere still has its first step.
            if ids.count == 1, let item = pane.rows.first(where: { ids.contains($0.id) }),
               item.isSymlink, item.linkTargetExists {
                Button("Go to Link Target") { act(ids) { model.goToLinkTarget(of: item, in: pane) } }
                // Past every link on the way, when there is more than one and
                // they end at something real. A loop has no end to go to.
                if let chain = item.linkChain, chain.length > 1, chain.finalTarget != nil {
                    Button("Go to Final Target") {
                        act(ids) { model.goToFinalTarget(of: item, in: pane) }
                    }
                }
                Divider()
            }
            if !reachesNothing {
                Button("Open") {
                    act(ids) {
                        if let id = ids.first { model.open(id: id, in: pane) }
                    }
                }
                .keyboardShortcut(.open)
            }
            if ConfigStore.shared.menuItemShown(.getInfo) {
                Button("Get Info") { act(ids) { model.showInfo() } }
                    .keyboardShortcut(.getInfo)
            }
            // Only for a file with more than one name: for any other, there
            // is nothing to find.
            if ConfigStore.shared.menuItemShown(.findSiblings),
               ids.count == 1, let item = pane.rows.first(where: { ids.contains($0.id) }),
               item.hardLinkCount > 1 {
                Button("Find Sibling Names (Hard Links to the Same File)\u{2026}") {
                    act(ids) { model.findSiblingNames(of: item) }
                }
            }
            if ConfigStore.shared.menuItemShown(.findDuplicates), ids.count == 1 {
                Button("Find Duplicates\u{2026}") { act(ids) { model.findDuplicates() } }
            }
            // A single folder: what is taking up the room under it.
            if ConfigStore.shared.menuItemShown(.diskUsage),
               ids.count == 1, let item = pane.rows.first(where: { ids.contains($0.id) }),
               item.isDirectory, !item.isParent {
                Button("Disk Usage\u{2026}") { act(ids) { model.showDiskUsage() } }
            }
            // A real file's earlier selves, from this Mac's APFS snapshots.
            if ConfigStore.shared.menuItemShown(.previousVersions),
               ids.count == 1, let item = pane.rows.first(where: { ids.contains($0.id) }),
               !item.isDirectory, !item.isParent, !ArchiveBrowsing.isInside(item.url) {
                Button("Previous Versions\u{2026}") { act(ids) { model.showPreviousVersions() } }
            }
            if ConfigStore.shared.menuItemShown(.archive) { archiveMenu(for: ids) }
            if ConfigStore.shared.menuItemShown(.checksum) { checksumMenu(for: ids) }
            // Split a single ordinary file, or join when the selection is a set
            // of parts (any of them) or a manifest. Offered even on read-only
            // media: the output then goes to the other pane.
            if ConfigStore.shared.menuItemShown(.splitJoin) {
                let urls = pane.rows.filter { ids.contains($0.id) && !$0.isParent
                                              && !$0.isDirectory
                                              && !ArchiveBrowsing.isInside($0.url) }.map(\.url)
                if FileSplitting.joinSource(for: urls) != nil {
                    Button("Join Parts") { act(ids) { model.joinParts() } }
                } else if urls.count == 1, let url = urls.first,
                          !FileSplitting.isPart(url), !FileSplitting.isManifest(url) {
                    Button("Split File\u{2026}") { act(ids) { model.requestSplitFile() } }
                }
            }
            // Photos, PNGs and PDFs among the rows: they can be made smaller.
            if ConfigStore.shared.menuItemShown(.optimize),
               pane.rows.contains(where: { ids.contains($0.id) && !$0.isDirectory
                                           && Optimizing.kind(of: $0.url) != nil }) {
                Button("Optimize File Size\u{2026}") { act(ids) { model.requestOptimize() } }
                    .disabled(pane.volume.isReadOnly)
            }
            // Only when an image whose EXIF can be changed is selected; the
            // editor takes those and leaves anything else out.
            // Any picture; the EXIF items only for the ones whose EXIF can be
            // changed -- JPEG and HEIC.
            let selectedRows = pane.rows.filter { ids.contains($0.id) }
            let pictures = AppModel.imageFiles(selectedRows)
            let images = AppModel.exifEditable(selectedRows)
            let videos = AppModel.videoEditable(selectedRows)
            if !videos.isEmpty, ConfigStore.shared.menuItemShown(.video) {
                Menu("Video") {
                    Button(videos.count == 1 ? "Edit Metadata\u{2026}"
                                             : "Edit Metadata of \(videos.count) Videos\u{2026}") {
                        act(ids) { model.editVideoMetadata(of: videos) }
                    }
                }
            }
            if !pictures.isEmpty, ConfigStore.shared.menuItemShown(.image) {
                Menu("Image") {
                    if !images.isEmpty {
                        Button(images.count == 1 ? "Edit EXIF\u{2026}"
                                                 : "Edit EXIF of \(images.count) Images\u{2026}") {
                            act(ids) { model.editExif(of: images) }
                        }
                        Button(images.count == 1 ? "Delete All EXIF Data"
                                                 : "Delete All EXIF Data of \(images.count) Images") {
                            act(ids) { model.eraseExif(of: images) }
                        }
                        Button(images.count == 1 ? "Remove Location"
                                                 : "Remove Location of \(images.count) Images") {
                            act(ids) { model.removeLocation(of: images) }
                        }
                        Divider()
                    }
                    // JPEG and HEIC by their orientation alone; the rest by
                    // their pixels, losslessly for PNG and TIFF.
                    Button("Rotate Left") { act(ids) { model.turn(pictures, .left) } }
                    Button("Rotate Right") { act(ids) { model.turn(pictures, .right) } }
                    Button("Flip Horizontally") {
                        act(ids) { model.turn(pictures, .flipHorizontal) }
                    }
                    Button("Flip Vertically") { act(ids) { model.turn(pictures, .flipVertical) } }
                    Divider()
                    // New images beside the originals; these are untouched.
                    Button(pictures.count == 1 ? "Convert\u{2026}"
                                             : "Convert \(pictures.count) Images\u{2026}") {
                        act(ids) { model.requestConvert(pictures, resizing: false) }
                    }
                    Button(pictures.count == 1 ? "Resize\u{2026}"
                                             : "Resize \(pictures.count) Images\u{2026}") {
                        act(ids) { model.requestConvert(pictures, resizing: true) }
                    }
                    Button(pictures.count == 1 ? "Make PDF\u{2026}"
                                               : "Make PDF of \(pictures.count) Images\u{2026}") {
                        act(ids) { model.requestMakePDF(pictures) }
                    }
                    Button("Remove Background") {
                        act(ids) { model.removeBackground(of: pictures) }
                    }
                    Button(pictures.count == 1 ? "Recognize Text\u{2026}"
                                               : "Recognize Text of \(pictures.count) Images\u{2026}") {
                        act(ids) { model.requestRecognizeText(pictures) }
                    }
                    if pictures.count == 1 {
                        Divider()
                        Button("Set as Desktop Picture") {
                            act(ids) { model.setDesktopPicture(pictures[0]) }
                        }
                    }
                }
            }

            // An application is enterable now, like any other folder, so
            // opening it -- Return, double-click, "Open" above -- walks into
            // its bundle instead of launching it. This is the deliberate way
            // to launch one instead, offered only where it means something.
            if ConfigStore.shared.menuItemShown(.run),
               ids.count == 1, let item = pane.rows.first(where: { ids.contains($0.id) }),
               item.isApplication {
                Button("Run App") { act(ids) { NSWorkspaceOpener.open(item.url) } }
            }
            if ConfigStore.shared.menuItemShown(.run),
               ids.count == 1, let item = pane.rows.first(where: { ids.contains($0.id) }),
               model.isRunnable(item) {
                runMenu(for: item)
            }

            // Only for files Git does not know about: for anything else the
            // two entries would be permanently meaningless.
            if pane.gitRoot != nil,
               pane.rows.contains(where: { ids.contains($0.id) && $0.gitState == .untracked }) {
                Button("Track \(ids.count == 1 ? "This File" : "These Files")") {
                    act(ids) { model.trackSelection() }
                }
                Button("Never Track \(ids.count == 1 ? "This" : "These")") {
                    act(ids) { model.neverTrackSelection() }
                }
            }

            // The other direction, and only where it could mean anything: a
            // brown file is not tracked, so there is nothing to stop.
            if pane.gitRoot != nil,
               pane.rows.contains(where: { ids.contains($0.id) && !$0.isParent
                                           && $0.gitState != .untracked }) {
                Button("Stop Tracking \(ids.count == 1 ? "This File" : "These Files")") {
                    act(ids) { model.requestStopTracking() }
                }
            }

            // Hidden rather than disabled for a folder: the entry would be
            // permanently greyed out on half the rows in every listing.
            if ConfigStore.shared.menuItemShown(.edit),
               ids.count == 1, let item = pane.rows.first(where: { ids.contains($0.id) }),
               !item.isDirectory, !item.isParent, !item.isBrokenLink {
                // Named for the format Text Edit will open it as: JSON Edit.
                let format = TextFormat.of(item.url, extensions: ConfigStore.shared.configuration.textFormats)
                Button(format.map { "\($0.title) Edit" } ?? "Text Edit") {
                    act(ids) { model.showTextEditor() }
                }
                Button("Bin Edit") { act(ids) { model.showBinaryView() } }
            }
            if ConfigStore.shared.menuItemShown(.scripts) {
                scripts(for: targets(of: ids))
            }

            Divider()

            Menu("Copy") {
                Button("File Name") { act(ids) { model.copySelectionNames(fullPath: false) } }
                    .keyboardShortcut(.copyNames)
                Button("Full Path") { act(ids) { model.copySelectionNames(fullPath: true) } }
                    .keyboardShortcut(.copyPaths)
                if model.canCopyContents(of: pane.rows.filter { ids.contains($0.id) }) {
                    Button("Content") { act(ids) { model.copySelectionContents() } }
                        .keyboardShortcut(.copyContent)
                }
            } primaryAction: {
                act(ids) { model.copySelectionToClipboard() }
            }
            .keyboardShortcut(.copy)
            Button("Cut") { act(ids) { model.cutSelectionToClipboard() } }
                .keyboardShortcut(.cut)
            pasteMenu(for: ids)

            Divider()

            newMenu

            Divider()

            // Disabled when there is no other pane to reach -- single-pane mode,
            // or a flat view on the other side.
            Button("Copy to Other Pane") { act(ids) { model.copySelection() } }
                .keyboardShortcut(.copyToOtherPane)
                .disabled(model.otherPaneFolder == nil)
            Button("Move to Other Pane") { act(ids) { model.moveSelection() } }
                .keyboardShortcut(.moveToOtherPane)
                .disabled(model.otherPaneFolder == nil)
            // Rename as a submenu, like Copy: the label itself renames inline,
            // the arrow opens the variants and the one-click transforms.
            Menu("Rename") {
                Button("Rename Many\u{2026}") { activate(); model.requestRenameMany() }
                    .keyboardShortcut(.renameMany)
                if ids.count == 1, model.namesCanBeSuggested, !reachesNothing {
                    Button("Suggest Name\u{2026}") {
                        act(ids) { model.renameWithSuggestion() }
                    }
                    .keyboardShortcut(.renameSuggested)
                    .disabled(model.isSuggestingName)
                }
                Divider()
                Button("Lower Case") { act(ids) { model.renameLowercased() } }
                Button("Upper Case") { act(ids) { model.renameUppercased() } }
                Button("Spaces to Underscores") { act(ids) { model.renameSpacesToUnderscores() } }
                Button("Spaces to Dashes") { act(ids) { model.renameSpacesToDashes() } }
                Divider()
                Button("Replace\u{2026}") { act(ids) { model.requestRenameReplace() } }
            } primaryAction: {
                act(ids) { model.requestRename() }
            }
            .keyboardShortcut(.rename)

            Divider()

            Button("Reveal in Finder") { act(ids) { model.revealSelection() } }
                .keyboardShortcut(.revealInFinder)

            Divider()

            // A server has no Trash: its items are deleted, and the name says so.
            Button(ids.contains(where: { RemoteBrowsing.isInside($0) }) ? "Delete Permanently\u{2026}"
                   : "Move to Trash", role: .destructive) { act(ids) { model.requestTrash() } }
                .keyboardShortcut(.trash)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let error = pane.errorText {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error).lineLimit(1).truncationMode(.middle)
            } else {
                Text(summary)
            }
            if let at = pane.listedEarlier {
                Text("as listed at \(at.formatted(date: .omitted, time: .shortened)), "
                     + "reading it again\u{2026}")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer()
            gitSummary
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// Branch, and how far this folder is from the shared copy. Phrased as
    /// what it means rather than as "ahead 2, behind 3", and nudging towards
    /// getting the latest first -- most conflicts never happen if you do.
    /// Whatever suits these items, under one heading.
    ///
    /// Asked of *this* pane rather than of the active one. A context menu is
    /// built before any of its buttons run, so a right click on the other pane
    /// was offering the scripts that suited the pane just left behind -- and
    /// then running them against that pane's files.
    @ViewBuilder
    private func scripts(for chosen: [ScriptTarget]) -> some View {
        let applicable = ScriptCatalogue.shared.applicable(to: chosen, in: pane.directory)
        if !applicable.isEmpty {
            Menu("Scripts") {
                ForEach(applicable) { script in
                    Button(script.name) {
                        activate()
                        model.runScript(script, on: chosen, in: pane.directory)
                    }
                    .help(script.summary)
                }
            }
        }
    }

    /// Run ▸ for a command-line program: the arguments sheet first, then the
    /// argument lines it was run with before, most recent first.
    ///
    /// It runs in the *active* pane's folder -- usually the program's own --
    /// and the item says so when that is the other pane's. Read at the moment
    /// the menu opens, before choosing an item activates this pane.
    ///
    /// ⌥-click on an entry deletes it instead of running it. Read when the
    /// entry is chosen, not when the menu opens: SwiftUI builds the submenu at
    /// a moment of its own choosing, and ⌥ held "as the menu opened" was not
    /// reliably seen. The hint at the bottom says so.
    @ViewBuilder
    private func runMenu(for item: FileItem) -> some View {
        let directory = model.active.directory
        let elsewhere = directory.standardizedFileURL
            != item.url.deletingLastPathComponent().standardizedFileURL
        let history = model.runHistory(for: item.url)
        Menu("Run") {
            Button(elsewhere
                   ? "Run with Arguments\u{2026} in \u{201C}\(directory.lastPathComponent)\u{201D}"
                   : "Run with Arguments\u{2026}") {
                model.requestRun(item.url, in: directory)
            }
            .keyboardShortcut(.runWithArguments)
            if !history.isEmpty {
                Divider()
                // By position: two entries can read the same and differ only in
                // their variables.
                ForEach(Array(history.enumerated()), id: \.offset) { _, entry in
                    Button(Self.menuTitle(of: entry)) {
                        if NSEvent.modifierFlags.contains(.option) {
                            model.deleteRunHistory(entry, for: item.url)
                        } else if entry.isTemplate {
                            // A template is a starting point: the window, filled in.
                            model.requestRun(item.url, in: directory, prefill: entry)
                        } else {
                            model.run(item.url, arguments: entry.arguments,
                                      environment: entry.variables, in: directory)
                        }
                    }
                }
                Divider()
                Button("\u{2325}-click an entry to delete it") {}
                    .disabled(true)
            }
        }
    }

    /// "dmg", "release  Ⓣ Ⓔ": the arguments, then Ⓣ for a template and Ⓔ
    /// for an entry that sets variables -- a menu item has room for one image,
    /// and these need two.
    static func menuTitle(of entry: RunHistory.File.Entry) -> String {
        var title = entry.arguments.isEmpty ? "(no arguments)" : entry.arguments
        var marks: [String] = []
        if entry.isTemplate { marks.append("\u{24C9}") }
        if !entry.variables.isEmpty { marks.append("\u{24BA}") }
        if !marks.isEmpty { title += "   " + marks.joined(separator: " ") }
        return title
    }

    /// The rows a menu was opened on, as a script sees them.
    private func targets(of ids: Set<FileItem.ID>) -> [ScriptTarget] {
        pane.rows.filter { ids.contains($0.id) && !$0.isParent }.map(ScriptTarget.init)
    }

    /// Making things, gathered under one "New" so the menu is not three entries
    /// longer for it: Folder, File, from Clipboard.
    @ViewBuilder
    private var newMenu: some View {
        Menu("New") {
            Button("Folder") { activate(); model.requestNewFolder() }
                .keyboardShortcut(.newFolder)
            Button("File") { activate(); model.requestNewFile() }
                .keyboardShortcut(.newFile)
            if model.clipboardCommandIsOffered {
                Button("from Clipboard") { activate(); model.newFromClipboard() }
                    .keyboardShortcut(.newFromClipboard)
                    .disabled(ClipboardWatcher.shared.kind == .empty)
            }
        }
    }

    /// Paste as a submenu, like Copy and Rename: the label pastes, the arrow
    /// opens the variants -- as Link, and the Paste Special properties, which no
    /// longer have a top-level entry of their own. Paste Special applies to the
    /// selected files, so it is offered only when there is a selection.
    @ViewBuilder
    private func pasteMenu(for ids: Set<FileItem.ID>) -> some View {
        let targets = ids.isEmpty ? nil
            : pane.rows.filter { ids.contains($0.id) && !$0.isParent }.map(\.url)
        Menu("Paste") {
            Button("as Link") { activate(); model.pasteAsLink() }
                .keyboardShortcut(.pasteAsLink)
            if !ids.isEmpty, model.canPasteSpecial(.permissions, targets: targets) {
                Divider()
                ForEach(Array(PasteSpecial.Part.menu.enumerated()), id: \.offset) { index, parts in
                    if index > 0 { Divider() }
                    ForEach(parts) { part in
                        Button(part.title) { act(ids) { model.pasteSpecial(part) } }
                            .disabled(!model.canPasteSpecial(part, targets: targets))
                    }
                }
            }
        } primaryAction: {
            activate()
            model.pasteIntoActivePane()
        }
        .keyboardShortcut(.paste)
    }

    @ViewBuilder
    private var gitSummary: some View {
        if let branch = pane.gitBranch {
            HStack(spacing: 6) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                Text(branch)
                if pane.gitBehind > 0 {
                    Text("\u{2022} \(pane.gitBehind) change\(pane.gitBehind == 1 ? "" : "s") "
                         + "you don't have")
                        .foregroundStyle(.orange)
                }
                if pane.gitAhead > 0 {
                    Text("\u{2022} \(pane.gitAhead) not sent")
                        .foregroundStyle(.blue)
                }
                // Everything to the left that mentions the shared copy is only
                // as true as the last time Diptych spoke to it, and none of it
                // can refresh itself. So the age travels with the numbers: a
                // count about a server with no age on it is a claim Diptych
                // cannot back up.
                // Ticking, not frozen. A stamp that said "just now" for an
                // hour would be the very bug this exists to prevent, so the
                // clock redraws it -- and retires the red along with it once
                // the answer is too old to stand behind.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("\u{2022} " + checked)
                        .foregroundStyle(.secondary)
                        .onChange(of: context.date) { _, _ in pane.retireStaleGitCheck() }
                }
            }
            .lineLimit(1)
        }
    }

    /// "checked 12 min ago", or an admission that we have not asked.
    private var checked: String {
        guard let at = pane.gitCheckedAt else { return "not checked" }
        let seconds = Date().timeIntervalSince(at)
        if seconds < 60 { return "checked just now" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds < 3600 ? [.minute] : [.hour, .minute]
        formatter.maximumUnitCount = 1
        guard let span = formatter.string(from: seconds) else { return "checked" }
        return "checked \(span) ago"
    }

    private var summary: String {
        let visible = pane.rows.filter { !$0.isParent }
        let selected = pane.selectedItems
        if selected.isEmpty {
            return "\(visible.count) items"
        }
        // A folder counts at its worked-out size, once Calculate Directory
        // Sizes has one -- as it stands, so the total grows with it.
        var bytes: Int64 = 0
        var growing = false
        var uncounted = 0
        for item in selected {
            // A size that is not known is not counted as zero: it is counted as not counted.
            if item.sizeIsUnknown { uncounted += 1; continue }
            guard item.isEnterable else { bytes += item.byteSize; continue }
            // A link to a folder is not what is in it: not counted, as before.
            if item.isSymlink { continue }
            switch DirectorySizes.shared.shown(for: item.url) {
            case .done(let size)?: bytes += size
            case .updating(let size)?: bytes += size; growing = true
            case .waiting?: growing = true
            case .unknown?, nil: uncounted += 1
            }
        }
        var size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        if growing { size += " so far" }
        if uncounted > 0, uncounted < selected.count {
            size += uncounted == 1 ? ", 1 folder not counted" : ", \(uncounted) folders not counted"
        }
        return "\(selected.count) of \(visible.count) selected  --  \(size)"
    }
}
