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
            .overlay(alignment: .bottomTrailing) { transferOverlay }
            // The panes cannot be worked in while the repository is being
            // rewritten under them, and the reason is on screen rather than
            // left to be guessed at.
            .disabled(model.gitBusy)
            .overlay { gitOverlay }
            .animation(.easeInOut(duration: 0.15), value: model.transferProgress == nil)
            // Attached here rather than beside the .sheet above: one
            // presentation modifier per view is the rule this file already
            // learned the hard way.
            .confirmationDialog(partialTransferTitle,
                                isPresented: Binding(get: { model.partialTransfer != nil },
                                                     set: { if !$0 { model.partialTransfer = nil } }),
                                titleVisibility: .visible) {
                Button("Keep") { model.keepPartialTransfer() }
                Button("Remove", role: .destructive) { model.discardPartialTransfer() }
                Button("Cancel", role: .cancel) { model.keepPartialTransfer() }
            } message: {
                let count = model.partialTransfer?.targets.count ?? 0
                Text("\(count) item\(count == 1 ? "" : "s") had already arrived when you "
                     + "stopped. Removing them deletes them outright -- they are not put in "
                     + "the Trash, having been made moments ago.")
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
    private var gitOverlay: some View {
        if model.gitBusy {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.gitBusyMessage).font(.system(size: 12))
                // Push crosses a network. Saying so beforehand is better than
                // leaving someone to wonder whether it has hung.
                Text("This can take a while over a slow connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 12, y: 4)
        }
    }

    private var partialTransferTitle: String {
        let moved = model.partialTransfer?.kind == .move
        return "Keep what was already \(moved ? "moved" : "copied")?"
    }

    /// Progress is an **overlay**, not a second sheet. Only one presentation
    /// modifier on a view is reliable -- the comment above `.sheet` is there
    /// because stacking them once made the rename field come up empty -- and a
    /// clash dialog has to be able to appear *during* a transfer, which a
    /// second sheet on the same view would prevent. An overlay also leaves the
    /// panes visible, which is what you want while watching a copy.
    @ViewBuilder
    private var transferOverlay: some View {
        if let progress = model.transferProgress {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(progress.verb) \(progress.itemCount) item"
                     + (progress.itemCount == 1 ? "" : "s"))
                    .font(.system(size: 12, weight: .medium))

                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }

                Text(progress.currentItem.isEmpty ? " " : progress.currentItem)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)

                // Transfers run one at a time, so anything asked for meanwhile
                // is waiting rather than lost. Saying so is the difference
                // between "queued" and "ignored".
                if model.queuedTransfers > 0 {
                    Text("\(model.queuedTransfers) more waiting")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Text(progress.detail)
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if let remaining = progress.remaining {
                        Text("\u{2022} \(remaining)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(progress.isCancelling ? "Stopping\u{2026}" : "Cancel") {
                        model.cancelTransfer()
                    }
                    .disabled(progress.isCancelling)
                }
            }
            .padding(14)
            .frame(width: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 12, y: 4)
            .padding(20)
            .transition(.opacity)
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
        // Three groups, because that is what a macOS toolbar offers. Each is
        // drawn only if the user put something in it: an empty ToolbarItemGroup
        // still reserves space in the centre.
        let configuration = ConfigStore.shared.configuration

        ToolbarItemGroup(placement: .navigation) {
            ForEach(shown(configuration.toolbarButtons(on: .left)), id: \.self, content: button)
        }
        ToolbarItemGroup(placement: .principal) {
            ForEach(shown(configuration.toolbarButtons(on: .middle)), id: \.self, content: button)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ForEach(shown(configuration.toolbarButtons(on: .right)), id: \.self, content: button)
        }
    }

    /// Buttons that mean nothing here are left out rather than greyed out: a
    /// permanently disabled button in a folder that is not tracked teaches
    /// nobody anything.
    private func shown(_ buttons: [ToolbarButton]) -> [ToolbarButton] {
        buttons.filter { !$0.needsRepository || model.gitRepositoryRoot != nil }
    }

    @ViewBuilder
    private func button(_ kind: ToolbarButton) -> some View {
        switch kind {
        // The two that are toggles rather than actions, so they show their
        // state rather than just their name.
        case .singlePane:
            Button {
                model.isSinglePane.toggle()
            } label: {
                Label(model.isSinglePane ? "Show Both Panes" : "Show One Pane",
                      systemImage: model.isSinglePane ? "rectangle.split.2x1" : "rectangle")
            }
            .help(model.isSinglePane ? "Show both panes" : "Show only the active pane")

        case .hiddenFiles:
            Toggle(isOn: Bindable(model).showHidden) {
                Label("Hidden Files", systemImage: model.showHidden ? "eye" : "eye.slash")
            }
            .toggleStyle(.button)
            .help(model.showHidden ? "Hide hidden files" : "Show hidden files")

        default:
            Button { perform(kind) } label: {
                Label(kind.title, systemImage: kind.symbol)
            }
            .help(kind.explanation)
            .disabled(isDisabled(kind))
        }
    }

    /// Every button calls the same method the menu bar and the keyboard call.
    private func perform(_ kind: ToolbarButton) {
        switch kind {
        case .singlePane:      model.isSinglePane.toggle()
        case .hiddenFiles:     model.showHidden.toggle()
        case .refresh:         model.refreshPanes()
        case .swapPanes:       model.swapPanes()
        case .sameFolder:      model.syncPanes()
        case .back:            model.goBack()
        case .forward:         model.goForward()
        case .enclosingFolder: model.active.goUp()
        case .goToFolder:      model.requestPathEdit(selectingAll: true)
        case .newFolder:       model.requestNewFolder()
        case .newFile:         model.requestNewFile()
        case .view:            model.viewSelection()
        case .getInfo:         model.showInfo()
        case .rename:          model.requestRename()
        case .copyToOther:     model.copySelection()
        case .moveToOther:     model.moveSelection()
        case .permissions:     model.requestPermissionEdit()
        case .trash:           model.requestTrash()
        case .revealInFinder:  model.revealSelection()
        case .openTerminal:    model.openTerminal()
        case .copyPrompt:      model.copyPromptToClipboard()
        case .biggerText:      PaneFont.zoom(by: 1)
        case .smallerText:     PaneFont.zoom(by: -1)
        case .actualSize:      PaneFont.reset()
        case .sendWork:        model.requestSendWork()
        case .checkForChanges: model.checkForChanges()
        case .getLatest:       model.getLatest()
        }
    }

    /// Greyed out only where the answer changes moment to moment -- history
    /// that has run out, a text size already at its limit, a repository
    /// operation already running. Anything permanently inapplicable is left
    /// out of the toolbar instead.
    private func isDisabled(_ kind: ToolbarButton) -> Bool {
        switch kind {
        case .back:                     !model.active.canGoBack
        case .forward:                  !model.active.canGoForward
        case .enclosingFolder:          model.active.directory.pathComponents.count <= 1
        case .biggerText:               PaneFont.size >= Configuration.fontSizes.upperBound
        case .smallerText:              PaneFont.size <= Configuration.fontSizes.lowerBound
        case .actualSize:               PaneFont.size == Configuration.defaultFontSize
        case .sendWork, .getLatest,
             .checkForChanges:          model.gitBusy
        default:                        false
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

    /// A review step, not a confirmation: both lists are editable, so a partial
    /// send is a normal thing to do rather than something to work around.
    @ViewBuilder
    private var sendWork: some View {
        Text("Send my work").font(.headline)

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !model.gitChanges.sending.isEmpty {
                    group(title: "Changes to be sent",
                          items: model.gitChanges.sending,
                          selection: $model.gitSending)
                }
                if !model.gitChanges.unresolved.isEmpty {
                    // No checkboxes, deliberately: there is no tick that would
                    // make sending these safe.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cannot be sent").font(.subheadline).bold()
                            .foregroundStyle(.red)
                        Text("Another program left a merge half-finished in "
                             + "\(model.gitChanges.unresolved.count == 1 ? "this file" : "these files"). "
                             + "Finish it there first.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(model.gitChanges.unresolved) { item in
                            Text(item.path).lineLimit(1).truncationMode(.middle)
                                .font(.system(size: 11))
                                .padding(.leading, 16)
                        }
                    }
                }
                if !model.gitChanges.new.isEmpty {
                    // Loud when non-empty, so it reads as "these are being left
                    // behind" rather than as a quiet extra.
                    group(title: "New files not being sent",
                          items: model.gitChanges.new,
                          selection: $model.gitIncluding,
                          tint: .orange,
                          note: "Tick to include them, now and from now on.")
                }
            }
        }
        .frame(maxHeight: 260)

        Text("Describe what you changed:").font(.subheadline)
        TextField("", text: $model.gitSendMessage, axis: .vertical)
            .lineLimit(2 ... 4)
            .focused($fieldFocused)
            .onAppear { fieldFocused = true }

        HStack {
            Spacer()
            Button("Cancel") { model.dialog = nil }
                .keyboardShortcut(.cancelAction)
            Button("Send") { model.sendWork() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.gitSendMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                          || (model.gitSending.isEmpty && model.gitIncluding.isEmpty))
        }
    }

    private func group(title: String, items: [GitService.Change],
                       selection: Binding<Set<String>>,
                       tint: Color = .primary,
                       note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // Tri-state: ticked, empty, or dashed for a mixed selection.
                Toggle(isOn: Binding(
                    get: { selection.wrappedValue.count == items.count && !items.isEmpty },
                    set: { on in
                        selection.wrappedValue = on ? Set(items.map(\.path)) : []
                    })) { Text(title).font(.subheadline).bold().foregroundStyle(tint) }
                    .toggleStyle(.checkbox)
                Spacer()
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                Toggle(isOn: Binding(
                    get: { selection.wrappedValue.contains(item.path) },
                    set: { on in
                        if on { selection.wrappedValue.insert(item.path) }
                        else { selection.wrappedValue.remove(item.path) }
                    })) {
                    HStack(spacing: 6) {
                        Text(item.path).lineLimit(1).truncationMode(.middle)
                        Text("(\(item.describes))").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .padding(.leading, 16)
            }
        }
    }

    /// A push that was refused. Two quite different situations wear the same
    /// error from Git, so they are told apart here rather than left to the
    /// reader: either somebody simply sent something first, or the two of you
    /// changed the same files.
    @ViewBuilder
    private var gitNotSent: some View {
        Text(model.gitNotSentReason).font(.headline)

        if model.gitNotSentConflicts.isEmpty {
            Text("Someone else sent something first. Your changes are still here, exactly "
                 + "as they were.")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Getting the latest and sending again will do it \u{2014} a send is refused "
                 + "whenever the shared copy has moved on, whichever files you picked.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Someone else has changed these as well:")
                .font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.gitNotSentConflicts, id: \.self) { path in
                        Text(path).font(.system(size: 11, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
            Text("Your version of each of them will be kept beside the original, this "
                 + "folder brought up to date, and the rest of your changes sent. Nothing "
                 + "is lost \u{2014} and a contested file blocks the update whether or not "
                 + "you ticked it.")
                .font(.caption).foregroundStyle(.secondary)
        }

        DisclosureGroup("What Git said") {
            ScrollView {
                Text(model.gitLastDetails)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
        }

        HStack {
            Button("Copy Details") { model.copyGitDetails() }
                .help("To send to whoever set up your repository")
            Spacer()
            Button("Cancel") { model.dialog = nil }
                .keyboardShortcut(.cancelAction)
            // One press either way. A contested file has to be dealt with
            // before anything can be sent, so making that a separate errand
            // only means the user presses two buttons to say one thing.
            Button(model.gitNotSentConflicts.isEmpty
                   ? "Get the Latest and Send Again"
                   : "Keep My Copies, Update and Send") { model.getLatestAndSendAgain() }
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var gitConflict: some View {
        Text("Someone else has changed files that you have also changed.")
            .font(.headline)

        Text("These files are different in both places:")
            .font(.subheadline)
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.gitConflictPaths, id: \.self) { path in
                    Text(path).font(.system(size: 11, design: .monospaced))
                }
            }
        }
        .frame(maxHeight: 120)

        Text("Diptych can save your version of each one beside it \u{2014} for example "
             + "\u{201C}chapter3 (my version).md\u{201D} \u{2014} and then bring the folder "
             + "up to date with the shared version. Both versions will be on disk, side by "
             + "side.")
            .font(.subheadline).foregroundStyle(.secondary)

        if model.gitConflictHasOwnVersions {
            Text("Some of your changes had already been saved as versions. Those are kept, "
                 + "but will no longer be part of the shared history \u{2014} whoever set up "
                 + "your repository can bring them back if you need them.")
                .font(.caption).foregroundStyle(.secondary)
        }

        HStack {
            Spacer()
            Button("I will merge this myself") { model.dialog = nil }
            Button("Cancel") { model.dialog = nil }
                .keyboardShortcut(.cancelAction)
            Button("Save my copies and update") { model.keepMyCopiesAndUpdate() }
                .keyboardShortcut(.defaultAction)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch dialog {
            case .sendWork:
                sendWork

            case .gitConflict:
                gitConflict

            case .gitNotSent:
                gitNotSent

            case .newFolder:
                prompt(title: "New Folder",
                       detail: "Create a folder in \(model.active.directory.lastPathComponent)",
                       confirm: "Create") { model.confirmNewFolder() }

            case .newFile:
                prompt(title: "New File",
                       detail: "Create an empty file in "
                             + "\(model.active.directory.lastPathComponent)",
                       confirm: "Create") { model.confirmNewFile() }

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

            case .stopTracking:
                let items = model.active.selectedItems.filter { !$0.isParent }
                confirmation(
                    title: items.count == 1
                        ? "Stop tracking \u{201C}\(items.first?.name ?? "")\u{201D}?"
                        : "Stop tracking \(items.count) items?",
                    detail: "The \(items.count == 1 ? "file stays" : "files stay") on this Mac "
                        + "and will not be sent again when changed.\n\n"
                        + "This is a change like any other, so it waits in your next send. "
                        + "Once sent, everyone else loses "
                        + "\(items.count == 1 ? "their copy" : "their copies") the next time "
                        + "they get the latest. Only your copy is kept.",
                    confirm: "Stop Tracking",
                    destructive: true) { model.confirmStopTracking() }

            case .conflict:
                conflictPrompt

            case .message(let text):
                confirmation(title: "Operation failed",
                             detail: text,
                             confirm: "OK",
                             destructive: false,
                             showsCancel: false) { }

            case .notice(let title, let text):
                confirmation(title: title,
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
            key("F1", "Prompt")   { model.copyPromptToClipboard() }
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
