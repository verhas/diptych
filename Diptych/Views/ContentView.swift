import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {

    /// One model per window. Declared here rather than on the `App`, because
    /// `@State` on an `App` is process-wide: every window and every tab would
    /// share it, which is exactly what made all the tabs identical.
    @State private var model = AppModel()

    /// Which pane's table actually holds keyboard focus.
    @FocusState private var focusedSide: AppModel.Side?

    /// SwiftUI focuses the first table on its own shortly after the window
    /// appears. Until the restored side has been applied, that assignment must
    /// not be allowed to drive `activeSide`, or a session saved with the right
    /// pane active always reopens on the left.
    @State private var focusFollowsUser = false
    @State private var isDropTarget = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    /// SwiftUI's own window opener, handed to the model so New Tab can create a
    /// sibling window without going through the menu bar by title.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // NavigationSplitView rather than an HStack: it is what gives a macOS
        // sidebar its full height, running to the top of the window under the
        // title bar rather than starting below the toolbar.
        //
        // No .defaultFocus anywhere here. It was once added to keep first
        // responder off the path text field, but the real fix for that was
        // making the path a button. With `.userInitiated` priority it does not
        // merely set the initial focus -- it re-asserts the value it captured,
        // so clicking the right pane was undone ~10ms later. Initial focus is
        // set once in .task below instead.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 300)
        } detail: {
            VStack(spacing: 0) {
                paneSplit
                Divider()
                FunctionBar(model: model)
            }
        }
        .navigationSplitViewStyle(.balanced)

        // One drop destination for the whole window, sidebar included; where it
        // lands is worked out from the pointer. SwiftUI gives every drop
        // destination a window-sized platform view, so two would overlap and
        // whichever sat on top would swallow the other's drops.
        //
        // A DropDelegate rather than .dropDestination, because only a delegate
        // can advertise *move* -- .dropDestination always shows the copy badge.
        .onDrop(of: [.fileURL],
                delegate: PaneDropDelegate(model: model, isTargeted: $isDropTarget))
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }

        // The split view owns the sidebar's visibility; the model owns it for
        // persistence and for the menu item. Kept in step both ways.
        .onChange(of: model.sidebarVisible) { _, visible in
            columnVisibility = visible ? .all : .detailOnly
        }
        .onChange(of: columnVisibility) { _, visibility in
            model.sidebarVisible = visibility != .detailOnly
        }
        .frame(minWidth: 420, minHeight: 460)

        // Transient errors: visible, but gone on their own. A dialog for a
        // broken symlink would be worse than the problem.
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(model.toastIsError
                                ? Color(nsColor: .systemRed).opacity(0.94)
                                : Color(nsColor: .controlAccentColor).opacity(0.94),
                                in: Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
                    .padding(.bottom, 58)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: model.toast)
        .task {
            model.openNewWindow = { openWindow(id: DiptychApp.windowGroupID) }
            model.openInfoWindow = { openWindow(id: DiptychApp.infoWindowID, value: $0) }
            model.openBinaryWindow = { openWindow(id: DiptychApp.binaryWindowID, value: $0) }
            model.start()
            columnVisibility = model.sidebarVisible ? .all : .detailOnly
            // Read the restored side *now*: SwiftUI's own focus assignment
            // lands during the sleep below, and would otherwise have already
            // overwritten activeSide by the time we read it.
            let restoredSide = model.activeSide
            try? await Task.sleep(for: .milliseconds(400))
            focusedSide = restoredSide
            model.activeSide = restoredSide
            focusFollowsUser = true
        }

        // Focus and "active pane" are two views of one thing, kept in step.
        // Clicking a table focuses it, which activates that pane -- so an
        // operation always applies to the pane you just clicked in.
        .onChange(of: focusedSide) { _, new in
            // nil means focus went to the path field or the toolbar; the active
            // pane should stay where it was.
            guard focusFollowsUser else { return }
            if let new { model.activeSide = new }
        }
        // ...and Tab, which changes activeSide, moves real focus with it.
        .onChange(of: model.activeSide) { _, new in
            focusedSide = new
        }

        // Window title, which is also the tab title -- so tabs are named after
        // the folder you are looking at instead of all reading "Diptych".
        .navigationTitle(model.title)

        .toolbar { toolbar }

        // Columns changed in Settings: reload so the loader fetches the
        // metadata the new set needs, and drop a sort that points at a column
        // no longer on screen.
        .onChange(of: ConfigStore.shared.configuration.columns) { _, columns in
            for pane in [model.left, model.right] {
                if let sort = pane.sortOrder.first, !columns.contains(sort.column) {
                    pane.sortOrder = [FileComparator(column: .name)]
                }
                pane.reload()
            }
            model.applyColumnWidths()
        }

        // Publishes this window's model to the menu bar. Scene-level `.commands`
        // cannot see per-window state any other way.
        .focusedSceneValue(\.appModel, model)

        // Learn which NSWindow we live in, so the shared key handler can route
        // keystrokes to the focused window's model only.
        .background(WindowAccessor { model.window = $0 })

        // ONE presentation modifier, driven by one optional. Stacking several
        // .alert modifiers on a single view is unreliable in SwiftUI -- only one
        // of them takes effect, which is why the rename field came up empty.
        .sheet(item: $model.dialog) { dialog in
            DialogSheet(model: model, dialog: dialog)
        }
    }

    @ViewBuilder
    private var paneSplit: some View {
        if model.isSinglePane {
            PaneView(pane: model.active,
                     model: model,
                     side: model.activeSide,
                     isActive: true,
                     activate: { },
                     focusedSide: $focusedSide)
        } else {
            HSplitView {
                PaneView(pane: model.left, model: model, side: .left,
                         isActive: model.activeSide == .left,
                         activate: { model.focus(.left) },
                         focusedSide: $focusedSide)
                    .frame(minWidth: 320)

                PaneView(pane: model.right, model: model, side: .right,
                         isActive: model.activeSide == .right,
                         activate: { model.focus(.right) },
                         focusedSide: $focusedSide)
                    .frame(minWidth: 320)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                model.isSinglePane.toggle()
            } label: {
                Label(model.isSinglePane ? "Show Both Panes" : "Show One Pane",
                      systemImage: model.isSinglePane
                          ? "rectangle.split.2x1"
                          : "rectangle")
            }
            .help(model.isSinglePane
                  ? "Show both panes"
                  : "Show only the active pane")
        }

        ToolbarItem {
            Button {
                model.refreshPanes()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Re-read both panes")
        }

        ToolbarItem {
            Button {
                model.swapPanes()
            } label: {
                Label("Swap Panes", systemImage: "arrow.left.arrow.right")
            }
            .help("Swap the left and right panes")
        }

        ToolbarItem {
            Toggle(isOn: Bindable(model).showHidden) {
                Label("Hidden Files",
                      systemImage: model.showHidden ? "eye" : "eye.slash")
            }
            .toggleStyle(.button)
            .help(model.showHidden ? "Hide hidden files" : "Show hidden files")
        }
    }
}

/// Routes drops for both panes.
struct PaneDropDelegate: DropDelegate {

    let model: AppModel
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            DropProposal(operation: model.dropWouldMove() ? .move : .copy)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        return MainActor.assumeIsolated { model.performPasteboardDrop() }
    }
}

/// Every modal in one place, selected by the model's `Dialog` case.
struct DialogSheet: View {

    @Bindable var model: AppModel
    let dialog: AppModel.Dialog

    /// Puts the caret in the text field the moment the sheet opens, so you can
    /// type straight away instead of clicking first.
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch dialog {
            case .newFolder:
                prompt(title: "New Folder",
                       detail: "Create a folder in \(model.active.directory.lastPathComponent)",
                       confirm: "Create") { model.confirmNewFolder() }

            case .trash:
                let items = model.active.selectedItems
                confirmation(
                    title: "Move \(items.count) item\(items.count == 1 ? "" : "s") to Trash?",
                    detail: items.prefix(5).map(\.name).joined(separator: "\n")
                        + (items.count > 5 ? "\n and \(items.count - 5) more" : ""),
                    confirm: "Move to Trash",
                    destructive: true) { model.confirmTrash() }

            case .authorizeOwner:
                confirmation(
                    title: "Change the owner as administrator?",
                    detail: "Only the system administrator can give a file to another "
                        + "user, so macOS will ask for a password.\n\n"
                        + "Set the owner of \(model.pendingOwnerCount) item(s) "
                        + "to \u{201C}\(model.pendingOwnerName)\u{201D}.",
                    confirm: "Authenticate...",
                    destructive: false) { model.confirmPrivilegedOwnerChange() }

            case .conflict:
                conflictPrompt

            case .message(let text):
                confirmation(title: "Operation failed",
                             detail: text,
                             confirm: "OK",
                             destructive: false,
                             showsCancel: false) { }
            }
        }
        .padding(20)
        .frame(width: 470)
    }

    /// The clash sheet.
    ///
    /// Radio options rather than a row of verbs, with the name field nested
    /// under the option it belongs to. Previously the field sat above a row of
    /// buttons with Overwrite next to it, which read as "overwrite, using this
    /// name" -- a value and a set of verbs put side by side imply a
    /// relationship that is not there.
    ///
    /// "Apply to all" as a checkbox rather than an "...All" variant of every
    /// button: three verbs would otherwise need six buttons.
    @ViewBuilder
    private var conflictPrompt: some View {
        if let conflict = model.conflict {
            Text("\u{201C}\(conflict.sourceName)\u{201D} already exists in \u{201C}\(conflict.folderName)\u{201D}")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                choice(.overwrite, "Replace the existing item")

                VStack(alignment: .leading, spacing: 6) {
                    choice(.rename, "Keep both, naming the new item:")
                    TextField("New name", text: $model.conflictName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.conflictAction != .rename)
                        .padding(.leading, 26)
                        .onSubmit { model.resolveConflict() }
                }

                choice(.skip, "Skip this item")
            }
            .padding(.vertical, 2)

            if conflict.remaining > 0 {
                Toggle("Apply to all \(conflict.remaining) remaining item\(conflict.remaining == 1 ? "" : "s")",
                       isOn: $model.conflictApplyToAll)
                    .toggleStyle(.checkbox)

                if model.conflictApplyToAll && model.conflictAction == .rename {
                    Text("Later items get automatic names -- one name cannot serve several files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }

            HStack {
                if conflict.remaining > 0 {
                    Button("Abort") { model.abortConflict() }
                        .help("Stop here and leave the remaining items alone")
                }
                Spacer()
                Button("Continue") { model.resolveConflict() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.conflictAction == .rename
                              && model.conflictName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func choice(_ action: AppModel.ConflictAction, _ title: String) -> some View {
        Button {
            model.conflictAction = action
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.conflictAction == action
                      ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(model.conflictAction == action ? Color.accentColor : .secondary)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func prompt(title: String, detail: String, confirm: String,
                        action: @escaping () -> Void) -> some View {
        Text(title).font(.headline)
        Text(detail).font(.subheadline).foregroundStyle(.secondary)

        TextField("Name", text: $model.textInput)
            .textFieldStyle(.roundedBorder)
            .focused($fieldFocused)
            .onSubmit { action(); model.dialog = nil }
            .onAppear { fieldFocused = true }

        HStack {
            Spacer()
            Button("Cancel") { model.dialog = nil }
                .keyboardShortcut(.cancelAction)
            Button(confirm) { action(); model.dialog = nil }
                .keyboardShortcut(.defaultAction)
                .disabled(model.textInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private func confirmation(title: String, detail: String, confirm: String,
                              destructive: Bool, showsCancel: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Text(title).font(.headline)
        if !detail.isEmpty {
            ScrollView {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
        }
        HStack {
            Spacer()
            if showsCancel {
                Button("Cancel") { model.dialog = nil }
                    .keyboardShortcut(.cancelAction)
            }
            Button(confirm, role: destructive ? .destructive : nil) {
                action()
                model.dialog = nil
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// The Norton Commander key bar. Every button calls the same method the
/// keyboard and the menu bar call.
struct FunctionBar: View {

    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            key("F2", "Rename")   { model.requestRename() }
            key("F3", "View")     { model.viewSelection() }
            key("F4", "Access")   { model.requestPermissionEdit() }
            key("F5", "Copy")     { model.copySelection() }
            key("F6", "Move")     { model.moveSelection() }
            key("F7", "Folder")   { model.requestNewFolder() }
            key("F8", "Trash")    { model.requestTrash() }
            Spacer()
            Text("Tab switches panes")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func key(_ fkey: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(fkey).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 11))
            }
            .frame(minWidth: 74)
        }
    }
}
