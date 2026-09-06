import SwiftUI

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
            if isActive { beginPathEdit() }
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
                TextField("Path", text: $pathText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .focused($pathFieldFocused)
                    .onSubmit { commitPath() }
                    .onExitCommand { endPathEdit() }
                    .onAppear { pathFieldFocused = true }
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

    private func beginPathEdit() {
        activate()
        pathText = pane.directory.path
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
        let expanded = (pathText as NSString).expandingTildeInPath

        // Navigating to a path that is not there used to leave the pane looking
        // like an empty folder. Refuse instead, and stay in the editor so the
        // typo can be corrected -- Escape still backs out to where we were.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            model.flash("\u{201C}\(pathText)\u{201D} does not exist")
            pathFieldFocused = true
            return
        }
        guard isDirectory.boolValue else {
            model.flash("\u{201C}\(pathText)\u{201D} is a file, not a folder")
            pathFieldFocused = true
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
                // a gesture inside a cell does. NSItemProvider(contentsOf:)
                // vends a real file reference, which is what Finder and other
                // apps expect -- a plain URL would arrive as a link.
                TableRow(item)
                    .itemProvider {
                        guard !item.isParent,
                              let provider = NSItemProvider(contentsOf: item.url) else { return nil }
                        // Without a suggested name the promise has none and
                        // Finder invents one from the content type -- "text.log".
                        // The extension is appended from that type, so this is
                        // the stem only; passing the full name yields
                        // "item-003.log.log".
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
    }

    /// While permissions are being edited the heading names the field the caret
    /// sits in, so you can see whether you are changing user, group or other.
    private func title(for column: FileColumn) -> String {
        if column == .permissions, let scope = model.permissionScope { return scope }
        return column.title
    }

    @ViewBuilder
    private func rowMenu(for ids: Set<FileItem.ID>) -> some View {
        if ids.isEmpty {
            Button("New Folder") { activate(); model.requestNewFolder() }
            Button("Paste") { activate(); model.pasteIntoActivePane() }
            Button("Refresh") { pane.reload() }
        } else {
            Button("Open") {
                activate()
                if let id = ids.first { model.open(id: id, in: pane) }
            }
            Button("Get Info") { activate(); model.showInfo() }
            Divider()
            // A menu with a primary action: clicking "Copy" copies the files,
            // exactly as Cmd-C does, while the submenu offers the text forms.
            Menu("Copy") {
                Button("File Name") { activate(); model.copySelectionNames(fullPath: false) }
                Button("Full Path") { activate(); model.copySelectionNames(fullPath: true) }
            } primaryAction: {
                activate()
                model.copySelectionToClipboard()
            }
            Button("Cut") { activate(); model.cutSelectionToClipboard() }
            Button("Paste") { activate(); model.pasteIntoActivePane() }

            Divider()
            Button("Copy to Other Pane") { activate(); model.copySelection() }
            Button("Move to Other Pane") { activate(); model.moveSelection() }
            Button("Rename...")          { activate(); model.requestRename() }
            Divider()
            Button("Reveal in Finder")   { activate(); model.revealSelection() }
            Divider()
            Button("Move to Trash", role: .destructive) { activate(); model.requestTrash() }
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
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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
