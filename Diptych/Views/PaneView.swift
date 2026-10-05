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

    var body: some View {
        VStack(spacing: 0) {
            toolRow
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

            Button {
                activate()
                pane.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(!pane.canGoForward)
            .help("Forward")

            Spacer(minLength: 6)

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
        .padding(.horizontal, 8)
        .padding(.top, 6)
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

            if pane.isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    /// `/Users/verhasp/Documents` shown as `~/Documents`.
    private var displayPath: String {
        (pane.directory.path as NSString).abbreviatingWithTildeInPath
    }

    private func beginPathEdit(selectingAll: Bool = false) {
        activate()
        pathSelectsAll = selectingAll
        // With the separator already there, typing a child's name works
        // straight away and Tab completes inside this directory rather than
        // re-completing its own name. "/" is the one path that already ends in
        // one.
        let path = pane.directory.path
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

    private func commitPath() {
        // Resolved against the pane, so a bare name or a "../" means what it
        // says in a shell: relative to where you are, not to wherever the
        // process happens to think it is standing.
        let expanded = PathCompletion.resolve(pathText, base: pane.directory.path)

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
        Table(of: FileItem.self, selection: $pane.selection, sortOrder: $pane.sortOrder) {
            TableColumnForEach(ConfigStore.shared.configuration.columns) { column in
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
        .disabled(pane.isNavigating)
        .overlay { loadingNotice }
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
                Text("A volume that is spinning up can take several seconds.")
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
            }
            .padding(22)
            .frame(maxWidth: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 12, y: 3)
            .allowsHitTesting(pane.errorIsPermission)
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

    @ViewBuilder
    private func rowMenu(for ids: Set<FileItem.ID>) -> some View {
        if ids.isEmpty {
            Button("New Folder") { activate(); model.requestNewFolder() }
                .keyboardShortcut(.newFolder)
            Button("New File") { activate(); model.requestNewFile() }
                .keyboardShortcut(.newFile)
            newFromClipboard
            scripts(for: [])
            Button("Paste") { activate(); model.pasteIntoActivePane() }
                .keyboardShortcut(.paste)
            Button("Paste as Link") { activate(); model.pasteAsLink() }
                .keyboardShortcut(.pasteAsLink)
            Button("Refresh") { pane.reload() }
                .keyboardShortcut(.refresh)
        } else {
            Button("Open") {
                act(ids) {
                    if let id = ids.first { model.open(id: id, in: pane) }
                }
            }
            .keyboardShortcut(.open)
            Button("Get Info") { act(ids) { model.showInfo() } }
                .keyboardShortcut(.getInfo)

            // An application is enterable now, like any other folder, so
            // opening it -- Return, double-click, "Open" above -- walks into
            // its bundle instead of launching it. This is the deliberate way
            // to launch one instead, offered only where it means something.
            if ids.count == 1, let item = pane.rows.first(where: { ids.contains($0.id) }),
               item.isApplication {
                Button("Run App") { act(ids) { NSWorkspaceOpener.open(item.url) } }
            }
            if ids.count == 1, let item = pane.rows.first(where: { ids.contains($0.id) }),
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
            if ids.count == 1, let item = pane.rows.first(where: { ids.contains($0.id) }),
               !item.isDirectory, !item.isParent {
                Button("Text Edit") { act(ids) { model.showTextEditor() } }
                Button("Bin Edit") { act(ids) { model.showBinaryView() } }
            }
            scripts(for: targets(of: ids))

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
            Button("Paste") { activate(); model.pasteIntoActivePane() }
                .keyboardShortcut(.paste)
            Button("Paste as Link") { activate(); model.pasteAsLink() }
                .keyboardShortcut(.pasteAsLink)

            Divider()

            Button("New File") { activate(); model.requestNewFile() }
                .keyboardShortcut(.newFile)
            Button("New Folder") { activate(); model.requestNewFolder() }
                .keyboardShortcut(.newFolder)
            newFromClipboard

            Divider()

            Button("Copy to Other Pane") { act(ids) { model.copySelection() } }
                .keyboardShortcut(.copyToOtherPane)
            Button("Move to Other Pane") { act(ids) { model.moveSelection() } }
                .keyboardShortcut(.moveToOtherPane)
            Button("Rename...") { act(ids) { model.requestRename() } }
                .keyboardShortcut(.rename)
            Button("Rename Many\u{2026}") { activate(); model.requestRenameMany() }
                .keyboardShortcut(.renameMany)
            if ids.count == 1, model.namesCanBeSuggested {
                Button("Rename with Suggested Name...") {
                    act(ids) { model.renameWithSuggestion() }
                }
                .keyboardShortcut(.renameSuggested)
                .disabled(model.isSuggestingName)
            }

            Divider()

            Button("Reveal in Finder") { act(ids) { model.revealSelection() } }
                .keyboardShortcut(.revealInFinder)

            Divider()

            Button("Move to Trash", role: .destructive) { act(ids) { model.requestTrash() } }
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
                ForEach(history, id: \.self) { arguments in
                    Button(arguments) {
                        if NSEvent.modifierFlags.contains(.option) {
                            model.deleteRunHistory(arguments, for: item.url)
                        } else {
                            model.run(item.url, arguments: arguments, in: directory)
                        }
                    }
                }
                Divider()
                Button("\u{2325}-click an entry to delete it") {}
                    .disabled(true)
            }
        }
    }

    /// The rows a menu was opened on, as a script sees them.
    private func targets(of ids: Set<FileItem.ID>) -> [ScriptTarget] {
        pane.rows.filter { ids.contains($0.id) && !$0.isParent }.map {
            ScriptTarget(url: $0.url,
                         kind: $0.isSymlink ? .link : ($0.isDirectory ? .directory : .file))
        }
    }

    /// The same command the File menu offers, where a right click expects to
    /// find it. Absent when the setting switches it off, and greyed when there
    /// is nothing on the clipboard to make a file from.
    @ViewBuilder
    private var newFromClipboard: some View {
        if model.clipboardCommandIsOffered {
            Button("New from Clipboard") { activate(); model.newFromClipboard() }
                .keyboardShortcut(.newFromClipboard)
                .disabled(ClipboardWatcher.shared.kind == .empty)
        }
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
        let bytes = selected.filter { !$0.isEnterable }.reduce(Int64(0)) { $0 + $1.byteSize }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(selected.count) of \(visible.count) selected  --  \(size)"
    }
}
