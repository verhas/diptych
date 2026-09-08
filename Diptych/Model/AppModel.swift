import Foundation
import AppKit
import Observation


/// Owns both panes, which one is active, and every command the UI can issue.
///
/// One instance per window. SwiftUI creates it in `ContentView`, not in the
/// `App`: `@State` on an `App` is created once for the whole process, so a model
/// declared there would be shared by every window and tab.
@MainActor
@Observable
final class AppModel {

    enum Side { case left, right }

    /// Anything presented over the window. A single optional drives a single
    /// presentation modifier. Stacking several `.alert`s on one view -- which is
    /// what this replaced -- is unreliable in SwiftUI: only one of them
    /// actually works, and which one is undefined.
    enum Dialog: Identifiable, Equatable {
        case newFolder
        case trash
        case authorizeOwner
        case conflict
        case message(String)

        var id: String {
            switch self {
            case .newFolder:      return "newFolder"
            case .trash:          return "trash"
            case .authorizeOwner: return "authorizeOwner"
            case .conflict:       return "conflict"
            case .message:   return "message"
            }
        }
    }

    // `var`, not `let`, so the two can be exchanged wholesale. Swapping the
    // references rather than copying directory-and-selection across is the
    // whole point: a PaneModel is the unit of "what a pane is", so anything
    // added to it later -- a filter, a search term, a history stack, a set of
    // tabs -- travels with the swap for free, with no code change here.
    private(set) var left: PaneModel
    private(set) var right: PaneModel
    var activeSide: Side = .left { didSet { persist() } }

    /// Toolbar state.
    var isSinglePane = false { didSet { persist() } }
    var sidebarVisible = false { didSet { persist() } }

    /// The sidebar row the keyboard would act on, so Cmd-Delete removes a
    /// favourite rather than trashing files when the sidebar has the selection.
    var selectedSidebarEntry: SidebarEntry.ID?
    var showHidden = false {
        didSet {
            left.showHidden = showHidden
            right.showHidden = showHidden
            persist()
        }
    }

    /// Bumped to ask the active pane to open its path editor. A token rather
    /// than a Bool so two consecutive requests both register as a change.
    private(set) var pathEditToken = 0

    var dialog: Dialog?

    /// A brief, self-dismissing message. For things that are worth seeing but
    /// not worth a dialog you have to acknowledge.
    /// Replaces the Permissions column heading while editing, so the caret's
    /// position is legible: "user", "group", "other".
    var permissionScope: String?

    var toast: String?
    private(set) var toastIsError = true
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Text backing the New Folder sheet.
    var textInput = ""

    /// The window this model belongs to, so the shared key handler can tell
    /// which window's model should receive a keystroke.
    @ObservationIgnored weak var window: NSWindow? {
        didSet {
            guard let window, window !== oldValue else { return }
            // Your macOS setting "Prefer tabs when opening documents" is what
            // decides whether a new window becomes a tab, and its default --
            // In Full Screen Only -- means Cmd-N opens a separate window. A
            // file manager wants tabs, so ask for them explicitly; dragging a
            // tab out still gives a separate window.
            window.tabbingMode = .preferred
            window.tabbingIdentifier = "dev.verhas.Diptych.pane-window"

            restoreFrame(on: window)
            observeFrameChanges(of: window)
            ColumnWidths.startObserving()
            applyColumnWidths()
            // The window resolves after start(), so the first save had no frame
            // to record. Record it now.
            persist()
        }
    }

    /// Which slot in ~/.diptych this window owns. Windows take slots in the
    /// order they are created, and reopen into the same order next launch.
    @ObservationIgnored let slot: Int
    @ObservationIgnored private static var nextSlot = 0
    /// Guards against writing defaults over the saved file before restore runs.
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var frameRestored = false
    /// The slot as it was on disk at launch. `start()` persists before the
    /// window exists, which overwrites the stored frame; keep our own copy so
    /// the frame can still be restored afterwards.
    @ObservationIgnored private var launchState: WindowState?

    /// The pane table that had focus when a rename started, so focus can be put
    /// back afterwards -- otherwise the row stays selected but dead, and Down
    /// then F2 does nothing until you click.
    @ObservationIgnored private weak var renameTable: NSTableView?
    @ObservationIgnored private weak var lastTable: NSTableView?
    @ObservationIgnored private var pendingClickEdit: Task<Void, Never>?
    @ObservationIgnored private let picker = PopupMenu()
    @ObservationIgnored var openNewWindow: (() -> Void)?
    @ObservationIgnored var openInfoWindow: ((URL) -> Void)?
    @ObservationIgnored private var pendingOwnerChange: (owner: String, group: String?, urls: [URL])?

    init() {
        slot = Self.nextSlot
        Self.nextSlot += 1

        let home = FileManager.default.homeDirectoryForCurrentUser
        left = PaneModel(directory: home)
        right = PaneModel(directory: home.appendingPathComponent("Documents"))
        left.owner = self
        right.owner = self
    }

    var active: PaneModel { activeSide == .left ? left : right }
    var inactive: PaneModel { activeSide == .left ? right : left }

    /// Window and tab title.
    var title: String {
        let name = active.directory.lastPathComponent
        return name.isEmpty ? "/" : name
    }

    func start() {
        launchState = StateStore.shared.window(slot)
        if let saved = launchState {
            left.restore(saved.left)
            right.restore(saved.right)
            activeSide = (saved.activeSide == "right") ? .right : .left
            isSinglePane = saved.singlePane
            sidebarVisible = saved.sidebarVisible
            showHidden = saved.showHidden
        }
        restored = true

        left.reload()
        right.reload()
        KeyRouter.shared.register(self)
        ClickRouter.shared.register(self)

        // An Info window edits attributes, which a directory watch never sees:
        // kqueue reports entries appearing and vanishing, not a chmod.
        NotificationCenter.default.addObserver(
            forName: FileInfoModel.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.left.reload()
                self?.right.reload()
            }
        }

        // Write a slot on first launch, so ~/.diptych exists and is editable
        // before the user has changed anything.
        persist()
    }

    // MARK: - Persistence

    func persist() {
        guard restored else { return }
        StateStore.shared.update(slot, WindowState(
            frame: window.map { NSStringFromRect($0.frame) },
            left: left.snapshot,
            right: right.snapshot,
            activeSide: activeSide == .right ? "right" : "left",
            singlePane: isSinglePane,
            sidebarVisible: sidebarVisible,
            showHidden: showHidden))
    }

    /// Applied on a delay, and only at these two moments -- window appears, and
    /// the column set changes. Doing it on every SwiftUI update would snap a
    /// column back to its saved width in the middle of a drag.
    func applyColumnWidths() {
        guard let window else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            ColumnWidths.apply(in: window)
        }
    }

    private func restoreFrame(on window: NSWindow) {
        guard !frameRestored else { return }
        guard let saved = launchState?.frame, !saved.isEmpty else { return }

        let frame = NSRectFromString(saved)
        guard frame.width > 200, frame.height > 200 else { return }
        // Constrain to the screens actually attached now: a frame saved on a
        // monitor that is no longer here would put the window out of reach.
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return }

        frameRestored = true
        // SwiftUI applies its own restored geometry after the window appears,
        // which would overwrite an immediate setFrame. Land after it.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            window.setFrame(frame, display: true)
            persist()
        }
    }

    private func observeFrameChanges(of window: NSWindow) {
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.persist() }
            }
        }
    }

    // MARK: - Commands

    func toggleActiveSide() {
        activeSide = (activeSide == .left) ? .right : .left
    }

    func focus(_ side: Side) {
        activeSide = side
    }

    /// Commands that act on exactly one item refuse a multiple selection rather
    /// than silently picking the first. With five files highlighted, "open the
    /// one that happens to sort first" is never what was meant.
    private func singleSelection(_ verb: String, includingParent: Bool = false) -> FileItem? {
        let rows = includingParent ? active.selectedRows : active.selectedItems
        if rows.count == 1 { return rows[0] }
        dialog = .message(rows.isEmpty
            ? "Select an item to \(verb)."
            : "\(rows.count) items are selected. Select a single item to \(verb).")
        return nil
    }

    func openSelection() {
        // includingParent: opening `..` is legitimate.
        guard let item = singleSelection("open", includingParent: true) else { return }
        active.open(item)
    }

    func open(id: FileItem.ID, in pane: PaneModel) {
        guard pane.selection.count <= 1 else {
            dialog = .message("\(pane.selection.count) items are selected. Select a single item to open.")
            return
        }
        guard let item = pane.rows.first(where: { $0.id == id }) else { return }
        pane.open(item)
    }

    /// Cmd-I. Exactly one item: an Info window describes one file, and picking
    /// the first of several silently would be a guess.
    func showInfo() {
        guard let item = singleSelection("show info for", includingParent: false) else { return }
        openInfoWindow?(item.url)
    }

    /// Space, as in Finder.
    func toggleQuickLook() {
        QuickLookController.shared.toggle(active.selectedItems.map(\.url), owner: self)
    }

    /// Move the cursor one row, keeping any open preview in step. Used when the
    /// Quick Look panel holds key focus and forwards its arrow keys to us.
    func moveCursor(by delta: Int) {
        let rows = active.rows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { active.selection.contains($0.id) } ?? 0
        moveCursor(to: current + delta)
    }

    /// Steps past rows the filter greyed out, so Down never lands on one.
    func moveCursorSkippingFiltered(by delta: Int) {
        let rows = active.rows
        guard !rows.isEmpty else { return }

        let current = rows.firstIndex { active.selection.contains($0.id) }
            ?? (delta > 0 ? -1 : rows.count)
        var index = current + delta

        while index >= 0 && index < rows.count {
            if active.matchesFilter(rows[index]) {
                moveCursor(to: index)
                return
            }
            index += delta
        }
    }

    func moveCursor(to index: Int) {
        let rows = active.rows
        guard !rows.isEmpty else { return }
        let clamped = min(max(index, 0), rows.count - 1)
        active.selection = [rows[clamped].id]
        scrollSelectionIntoView()
    }

    /// How many rows a Page Up / Page Down should travel: one screenful of the
    /// table, minus a row of overlap so you keep your place visually.
    private var pageStride: Int {
        guard let table = window?.firstResponder as? NSTableView else { return 20 }
        let visible = table.rows(in: table.visibleRect).length
        return max(1, visible - 1)
    }

    func viewSelection() {
        active.selectedItems.filter { !$0.isEnterable }.map(\.url).forEach(NSWorkspaceOpener.open)
    }

    func copySelection()  { transfer(.copy) }
    func moveSelection()  { transfer(.move) }

    private func transfer(_ kind: FileOperations.Transfer) {
        let urls = active.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        performTransfer(urls, to: inactive.directory, kind: kind,
                        into: inactive, from: kind == .move ? active : nil)
    }

    func flash(_ message: String, error: Bool = true) {
        toastIsError = error
        toast = message
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    func requestTrash() {
        guard !active.selectedItems.isEmpty else { return }
        dialog = .trash
    }

    /// Trash with no confirmation. Bound to Command-Delete, which nobody
    /// presses by accident, and which Finder treats the same way.
    func trashNow() {
        confirmTrash()
    }

    func confirmTrash() {
        let pane = active
        let urls = pane.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }

        // Where the cursor should land afterwards: the row below the last one
        // being deleted, or -- if the deletion runs to the end of the listing --
        // the row above the first.
        let rows = pane.rows
        let selected = rows.indices.filter { pane.selection.contains(rows[$0].id) }
        var successor: FileItem.ID?
        if let last = selected.last, rows.indices.contains(last + 1) {
            successor = rows[last + 1].id
        } else if let first = selected.first, first > 0, !rows[first - 1].isParent {
            successor = rows[first - 1].id
        }

        Task {
            let outcome = await FileOperations.shared.trash(urls)
            if !outcome.succeeded.isEmpty {
                Sounds.playIfEnabled(ConfigStore.shared.configuration.trashSound)
            }
            pane.pendingSelection = successor.map { [$0] } ?? []
            pane.reload()
            inactive.reload()   // the other pane may be showing the same folder
            report(outcome, verb: "move to Trash")
        }
    }

    func requestNewFolder() {
        textInput = "untitled folder"
        dialog = .newFolder
    }

    func confirmNewFolder() {
        let name = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let parent = active.directory
        Task {
            do {
                let url = try await FileOperations.shared.createDirectory(named: name, in: parent)
                active.pendingSelection = [url]
                active.reload()
            } catch {
                dialog = .message(error.localizedDescription)
            }
        }
    }

    /// Rename happens in the row itself, as in Finder -- no dialog.
    func requestRename() {
        guard let item = singleSelection("rename") else { return }

        // With the Quick Look panel up it holds key focus, so a text field in
        // this window could never receive typing. Take key back; the panel stays
        // on screen, which is the whole point -- look at the scan, name it,
        // move on.
        if QuickLookController.shared.isVisible {
            window?.makeKeyAndOrderFront(nil)
        }

        renameTable = currentTable
        active.renameText = item.name
        active.renamingID = item.id
    }

    func cancelInlineRename() {
        active.renamingID = nil
        restoreTableFocus()
    }

    /// `advance` (Shift-Return) leaves the cursor on the row that followed this
    /// one *before* the rename. Using the row after the renamed file would jump
    /// somewhere arbitrary, because the new name usually sorts elsewhere.
    func commitInlineRename(advance: Bool = false) {
        guard let id = active.renamingID,
              let item = active.rows.first(where: { $0.id == id }) else { return }

        let pane = active
        let rowsBefore = pane.rows
        let successor: FileItem.ID? = rowsBefore.firstIndex { $0.id == id }
            .flatMap { rowsBefore.indices.contains($0 + 1) ? rowsBefore[$0 + 1].id : nil }

        let newName = pane.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        pane.renamingID = nil
        restoreTableFocus()

        guard !newName.isEmpty, newName != item.name else {
            // Nothing to rename, but Shift-Return still means "move on".
            if advance, let successor {
                pane.selection = [successor]
                scrollSelectionIntoView()
            }
            return
        }

        Task {
            do {
                let url = try await FileOperations.shared.rename(item.url, to: newName)
                // Renaming the last row leaves no successor; stay on the file.
                pane.pendingSelection = [advance ? (successor ?? url) : url]
                pane.reload()
            } catch {
                dialog = .message(error.localizedDescription)
            }
        }
    }

    // MARK: - Clicks

    /// Called by ClickRouter for every click on a pane table, before the table
    /// has processed it -- so `pane.selection` here is still the selection as it
    /// was when the button went down. That is what makes "was this row already
    /// selected?" exact, instead of a guess based on elapsed time.
    func cancelPendingClickEdit() {
        pendingClickEdit?.cancel()
    }

    func tableClicked(pane: PaneModel, rowID: FileItem.ID?, column: FileColumn?, clickCount: Int) {
        pendingClickEdit?.cancel()
        endPermissionEdit()
        endRename(unless: rowID)

        guard clickCount == 1, let rowID, let column else { return }

        let selectionBeforeClick = pane.selection

        switch column {
        case .name:
            // Renaming needs exactly one target.
            guard selectionBeforeClick == [rowID] else { return }
            scheduleClickEdit { [weak self] in
                self?.activate(pane)
                self?.requestRename()
            }

        case .permissions:
            // Permissions can be edited for a whole selection, so clicking any
            // already-selected row starts the edit.
            guard selectionBeforeClick.contains(rowID) else { return }
            scheduleClickEdit { [weak self] in
                self?.activate(pane)
                self?.requestPermissionEdit(anchor: rowID)
            }

        case .owner:
            guard selectionBeforeClick.contains(rowID) else { return }
            scheduleClickEdit { [weak self] in
                self?.activate(pane)
                self?.requestOwnerEdit(anchor: rowID)
            }

        case .group:
            guard selectionBeforeClick.contains(rowID) else { return }
            scheduleClickEdit { [weak self] in
                self?.activate(pane)
                self?.requestGroupEdit(anchor: rowID)
            }

        default:
            break
        }
    }

    /// A click on the path bar, the toolbar, the other pane's chrome...
    func clickedAwayFromTable() {
        pendingClickEdit?.cancel()
        endPermissionEdit()
        endRename(unless: nil)
    }

    /// Commit any rename in progress, unless the click landed on the very row
    /// being renamed. Without this a row could be left showing an editor that
    /// no longer had focus and could not be dismissed.
    private func endRename(unless rowID: FileItem.ID?) {
        for pane in [left, right] {
            guard let editing = pane.renamingID, editing != rowID else { continue }
            let previous = activeSide
            activeSide = (pane === left) ? .left : .right
            commitInlineRename()
            activeSide = previous
        }
    }

    private func scheduleClickEdit(_ action: @escaping @MainActor () -> Void) {
        pendingClickEdit = Task { @MainActor in
            // Long enough for a double-click to arrive and cancel this first.
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.05))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private func activate(_ pane: PaneModel) {
        activeSide = (pane === left) ? .left : .right
    }

    // MARK: - Name conflicts

    /// What to do with one clashing item. Kept separate from "apply this to
    /// everything else too", which used to be baked into the verb (skipAll) and
    /// meant a separate button per verb.
    enum ConflictAction: Equatable {
        case overwrite
        case rename
        case skip
    }

    enum ConflictOutcome {
        case proceed(ConflictAction, name: String, applyToAll: Bool)
        case abort
    }

    struct Conflict {
        let sourceName: String
        let folderName: String
        /// How many items are still queued behind this one. Abort is only
        /// offered when stopping actually saves the user something.
        let remaining: Int
    }

    private(set) var conflict: Conflict?

    /// Which option is selected, the name typed into the Keep Both field, and
    /// whether the choice should stand for the rest of the operation.
    var conflictAction: ConflictAction = .rename
    var conflictName = ""
    var conflictApplyToAll = false

    @ObservationIgnored private var conflictContinuation: CheckedContinuation<ConflictOutcome, Never>?

    func resolveConflict() {
        finishConflict(.proceed(conflictAction,
                                name: conflictName,
                                applyToAll: conflictApplyToAll))
    }

    func abortConflict() {
        finishConflict(.abort)
    }

    private func finishConflict(_ outcome: ConflictOutcome) {
        conflict = nil
        dialog = nil
        let continuation = conflictContinuation
        conflictContinuation = nil
        continuation?.resume(returning: outcome)
    }

    private func askAboutConflict(source: URL, target: URL, remaining: Int) async -> ConflictOutcome {
        conflictAction = .rename
        conflictName = FileOperations.uniqueURL(for: target).lastPathComponent
        conflictApplyToAll = false
        conflict = Conflict(sourceName: source.lastPathComponent,
                            folderName: target.deletingLastPathComponent().lastPathComponent,
                            remaining: remaining)
        dialog = .conflict

        return await withCheckedContinuation { continuation in
            conflictContinuation = continuation
        }
    }

    /// The one path every copy and move goes through -- F5/F6, paste, and drops
    /// alike -- so a name clash is handled the same way whichever started it.
    private func performTransfer(_ urls: [URL], to destination: URL,
                                 kind: FileOperations.Transfer,
                                 into destinationPane: PaneModel,
                                 from sourcePane: PaneModel?) {
        guard !urls.isEmpty else { return }

        // Serialised. Every transfer shares one conflict continuation, so a
        // second operation started while a clash dialog is open would overwrite
        // it -- stranding the first task for ever, or answering the wrong one.
        enqueueTransfer { [weak self] in
            guard let self else { return }
            await self.runTransfer(urls, to: destination, kind: kind,
                                   into: destinationPane, from: sourcePane)
        }
    }

    @ObservationIgnored private var transferChain: Task<Void, Never>?

    private func enqueueTransfer(_ work: @escaping @MainActor () async -> Void) {
        let previous = transferChain
        transferChain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func runTransfer(_ urls: [URL], to destination: URL,
                             kind: FileOperations.Transfer,
                             into destinationPane: PaneModel,
                             from sourcePane: PaneModel?) async {
        var outcome = FileOperations.Outcome()
        var aborted = false
        /// Set once "apply to all" is ticked; every later clash takes it
        /// without asking.
        var standingAction: ConflictAction?

        for (index, source) in urls.enumerated() {
            var target = destination.appendingPathComponent(source.lastPathComponent)
            var overwrite = false

            // The destination is where the item already is. Copying then means
            // "make a copy beside it", as Finder does; moving means nothing at
            // all. Neither should raise a clash dialog whose Replace would
            // delete the item itself.
            if FileOperations.samePath(source, target) {
                guard kind == .copy else { continue }
                target = FileOperations.uniqueURL(for: target)

            } else if FileOperations.exists(target) {
                // Loop: a name typed into "keep both" can clash in its own
                // right, and answering one dialog with a name that is also
                // taken should ask again rather than fail.
                var skipItem = false

                while FileOperations.exists(target) {
                    var action: ConflictAction
                    var chosenName: String?

                    if let standingAction {
                        action = standingAction
                    } else {
                        switch await askAboutConflict(source: source, target: target,
                                                      remaining: urls.count - index - 1) {
                        case .abort:
                            aborted = true
                            action = .skip
                        case .proceed(let chosen, let name, let applyToAll):
                            action = chosen
                            chosenName = name
                            if applyToAll { standingAction = chosen }
                        }
                    }
                    if aborted { break }

                    switch action {
                    case .overwrite:
                        overwrite = true

                    case .rename:
                        // A typed name applies to this item only; everything
                        // after it under "apply to all" gets an automatic one,
                        // since one name cannot serve several files.
                        if let chosenName {
                            guard let named = FileOperations.safeChild(named: chosenName,
                                                                       in: destination) else {
                                outcome.failures.append(
                                    (source, "\u{201C}\(chosenName)\u{201D} is not a usable name."))
                                skipItem = true
                                break
                            }
                            target = named
                        } else {
                            target = FileOperations.uniqueURL(for: target)
                        }

                    case .skip:
                        skipItem = true
                    }

                    if skipItem || overwrite { break }
                }

                if aborted { break }
                if skipItem { continue }
            }

            if let message = await FileOperations.shared.transferOne(source, to: target,
                                                                     kind: kind,
                                                                     overwrite: overwrite) {
                outcome.failures.append((source, message))
            } else {
                outcome.succeeded.append(target)
            }
        }

        sourcePane?.reload()
        // Leave the moved or copied files selected where they landed.
        destinationPane.pendingSelection = Set(outcome.succeeded)
        destinationPane.reload()

        if outcome.isCompleteSuccess {
            if !outcome.succeeded.isEmpty {
                let configuration = ConfigStore.shared.configuration
                Sounds.playIfEnabled(kind == .move ? configuration.moveSound
                                                   : configuration.copySound)
                let verb = kind == .move ? "Moved" : "Copied"
                flash("\(verb) \(outcome.succeeded.count) item"
                      + (outcome.succeeded.count == 1 ? "" : "s"), error: false)
            }
        } else {
            report(outcome, verb: kind == .move ? "move" : "copy")
        }
    }

    // MARK: - Sidebar

    var favourites: [SidebarEntry] {
        ConfigStore.shared.configuration.favourites.map { path in
            let url = URL(fileURLWithPath: path)
            return SidebarEntry(kind: .favourite, url: url,
                                name: url.lastPathComponent.isEmpty ? path : url.lastPathComponent)
        }
    }

    func openSidebarEntry(_ entry: SidebarEntry) {
        active.navigate(to: entry.url)
    }

    /// Ejects the whole device, as Finder's eject does.
    func eject(_ entry: SidebarEntry) {
        let name = entry.name
        let mountPoint = entry.url.path

        FileManager.default.unmountVolume(at: entry.url,
                                          options: [.allPartitionsAndEjectDisk]) { [weak self] error in
            // Error is not Sendable; the message is.
            let message = error?.localizedDescription

            // A Task, not MainActor.assumeIsolated: this callback arrives on
            // NSFileManager's own unmount queue, and assuming main-actor
            // isolation there traps. assumeIsolated is only safe for callbacks
            // that are guaranteed to be delivered on the main thread.
            Task { @MainActor in
                guard let self else { return }

                if let message {
                    self.flash("Could not eject \(name): \(message)")
                    return
                }

                // A pane left sitting on the volume would be showing a path
                // that no longer exists.
                for pane in [self.left, self.right]
                where pane.directory.path == mountPoint
                    || pane.directory.path.hasPrefix(mountPoint + "/") {
                    pane.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
                }

                VolumeList.shared.reload()
                self.flash("Ejected \(name)", error: false)
            }
        }
    }

    func addFavourites(_ urls: [URL]) {
        // A favourite is somewhere to go, so only folders qualify.
        let folders = urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard !folders.isEmpty else {
            flash("Only folders can be favourites")
            return
        }

        var list = ConfigStore.shared.configuration.favourites
        let before = list.count
        for url in folders where !list.contains(url.path) {
            list.append(url.path)
        }
        guard list.count > before else { return }

        ConfigStore.shared.configuration.favourites = list
        let added = list.count - before
        flash("Added \(added) favourite\(added == 1 ? "" : "s")", error: false)
    }

    func removeFavourite(path: String) {
        var list = ConfigStore.shared.configuration.favourites
        list.removeAll { $0 == path }
        ConfigStore.shared.configuration.favourites = list
        if selectedSidebarEntry == "f:\(path)" { selectedSidebarEntry = nil }
    }

    /// True when the pointer is left of the first pane, which is where the
    /// sidebar is. Used instead of a second drop destination: SwiftUI gives
    /// each one a window-sized platform view, and two of them overlap.
    func pointerIsOverSidebar() -> Bool {
        guard sidebarVisible, let window, let first = TableFinder.tables(in: window).first
        else { return false }
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return point.x < first.convert(first.bounds, to: nil).minX
    }

    // MARK: - Tabs

    /// Opens a sibling window and joins it to this window's tab group.
    ///
    /// Setting `tabbingMode = .preferred` is not enough on its own: macOS
    /// decides tab membership when a window is ordered in, which is before our
    /// model ever sees it -- measured, two windows and `tabbedWindows == 0`.
    /// Adding it to the group afterwards is explicit and always works, whatever
    /// the "Prefer tabs when opening documents" setting says.
    func newTab() {
        guard let window, let openNewWindow else { return }

        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        openNewWindow()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard let created = NSApp.windows.first(where: {
                !before.contains(ObjectIdentifier($0)) && $0.isVisible
            }) else { return }

            window.addTabbedWindow(created, ordered: .above)
            created.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Clipboard

    func copySelectionToClipboard() {
        guard !forwardToTextEditor(#selector(NSText.copy(_:))) else { return }
        let urls = active.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        Clipboard.copy(urls)
        flash("Copied \(urls.count) item\(urls.count == 1 ? "" : "s")", error: false)
    }

    func cutSelectionToClipboard() {
        guard !forwardToTextEditor(#selector(NSText.cut(_:))) else { return }
        let urls = active.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        Clipboard.cut(urls)
        flash("Cut \(urls.count) item\(urls.count == 1 ? "" : "s")", error: false)
    }

    func pasteIntoActivePane() {
        guard !forwardToTextEditor(#selector(NSText.paste(_:))) else { return }

        let urls = Clipboard.fileURLs()
        guard !urls.isEmpty else { return }

        let destination = active.directory
        let move = Clipboard.holdsCut
        // Moving a file into the folder it already sits in is a no-op, and
        // moveItem would fail on it.
        let sources = move
            ? urls.filter { $0.deletingLastPathComponent().path != destination.path }
            : urls
        guard !sources.isEmpty else { return }

        // A cut is consumed by the paste that acts on it.
        if move { Clipboard.clearCutIntent() }

        // The source may be this window's other pane, another window, or
        // Finder; refreshing the other pane covers the case we can see.
        performTransfer(sources, to: destination, kind: move ? .move : .copy,
                        into: active, from: inactive)
    }

    /// Names or paths as shell arguments, space separated, for pasting into a
    /// terminal as arguments to a command.
    func copySelectionNames(fullPath: Bool) {
        let items = active.selectedItems
        guard !items.isEmpty else { return }

        let values = items.map { fullPath ? $0.url.path : $0.name }
        Clipboard.copyText(Shell.arguments(values))
        flash("Copied \(values.count) \(fullPath ? "path" : "name")\(values.count == 1 ? "" : "s")",
              error: false)
    }

    /// Cmd-A. Without a menu item bound to it, the shortcut matches nothing and
    /// even a focused text field never sees it -- which is why Select All had
    /// stopped working in the path box once the Edit menu was replaced.
    func selectAll() {
        guard !forwardToTextEditor(#selector(NSText.selectAll(_:))) else { return }
        active.selection = Set(active.rows.filter { !$0.isParent }.map(\.id))
    }

    /// Whether something that edits text owns the keyboard right now.
    ///
    /// The permissions grid counts: it is a plain NSView rather than a text
    /// view, but it is an editor, and a menu shortcut must not act on the file
    /// list while it is open.
    private var editorHasKeyboardFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder is NSText
            || responder.isKind(of: NSTextView.self)
            || responder is PermissionEditorView
    }

    /// Menu key equivalents are matched before the responder chain, so Cmd-C
    /// inside the rename field would land here instead of copying text. Hand it
    /// back when an editor has focus.
    private func forwardToTextEditor(_ selector: Selector) -> Bool {
        guard editorHasKeyboardFocus else { return false }
        NSApp.sendAction(selector, to: nil, from: nil)
        return true
    }

    /// Cmd-Delete from the menu bar.
    ///
    /// In a text field that combination means "delete to the beginning of the
    /// line". Because a menu key equivalent is matched before the responder
    /// chain, the shortcut reached this command and trashed the selected file
    /// while the user was part-way through typing a new name for it.
    func trashFromMenu() {
        guard !forwardToTextEditor(#selector(NSResponder.deleteToBeginningOfLine(_:)))
        else { return }
        trashNow()
    }

    /// Cmd-Down from the menu bar. In text, that is "move to end of document".
    func openFromMenu() {
        guard !forwardToTextEditor(#selector(NSResponder.moveToEndOfDocument(_:)))
        else { return }
        openSelection()
    }

    /// Cmd-Up from the menu bar. In text, that is "move to beginning of
    /// document" -- so while renaming it must move the caret, not the pane.
    func goUpFromMenu() {
        guard !forwardToTextEditor(#selector(NSResponder.moveToBeginningOfDocument(_:)))
        else { return }
        active.goUp()
    }

    // MARK: - Drag and drop

    /// SwiftUI's URL importer hands over only the first item of a multi-item
    /// drag -- measured, not assumed. The drag pasteboard has them all.
    func dragPasteboardURLs() -> [URL] {
        NSPasteboard(name: .drag)
            .readObjects(forClasses: [NSURL.self],
                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Whether a drop happening right now would move rather than copy. The drag
    /// badge is drawn from this, so it has to use exactly the same rule the
    /// drop itself does.
    func dropWouldMove() -> Bool {
        // Dropping on the sidebar adds a favourite; nothing is moved.
        if pointerIsOverSidebar() { return false }
        let pane = paneUnderPointer() ?? active
        return shouldMove(dragPasteboardURLs(), to: pane.directory)
    }

    @discardableResult
    func performPasteboardDrop() -> Bool {
        let urls = dragPasteboardURLs()
        guard !urls.isEmpty else { return false }

        if pointerIsOverSidebar() {
            addFavourites(urls)
            return true
        }
        drop(urls, into: paneUnderPointer() ?? active)
        return true
    }

    private func shouldMove(_ urls: [URL], to destination: URL) -> Bool {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.option) { return false }   // Option forces a copy
        if modifiers.contains(.command) { return true }   // Command forces a move
        // Finder's rule: within a volume a drag moves, across volumes it copies.
        return onSameVolume(urls, as: destination)
    }

    private func paneUnderPointer() -> PaneModel? {
        guard let window else { return nil }
        let tables = TableFinder.tables(in: window)
        guard tables.count > 1 else { return active }

        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        for (index, table) in tables.enumerated() {
            if table.convert(table.bounds, to: nil).contains(point) {
                return index == 0 ? left : right
            }
        }
        // Dropped on a pane's chrome rather than its list: fall back to which
        // side of the divider the pointer is on.
        let divider = tables[1].convert(tables[1].bounds, to: nil).minX
        return point.x < divider ? left : right
    }

    /// Files dropped onto a pane, from the other pane, from Finder, from another
    /// Diptych window, or from any app that vends file URLs.
    func drop(_ urls: [URL], into pane: PaneModel) {
        let destination = pane.directory
        // Dropping something back into the folder it already lives in.
        let sources = urls.filter { $0.deletingLastPathComponent().path != destination.path }
        guard !sources.isEmpty else {
            // Say so rather than appearing to ignore the drop entirely.
            flash("Already in \u{201C}\(destination.lastPathComponent)\u{201D}")
            return
        }

        activate(pane)

        let move = shouldMove(sources, to: destination)

        performTransfer(sources, to: destination, kind: move ? .move : .copy,
                        into: pane, from: pane === left ? right : left)
    }

    private func onSameVolume(_ urls: [URL], as destination: URL) -> Bool {
        guard let target = try? destination.resourceValues(forKeys: [.volumeIdentifierKey])
            .volumeIdentifier else { return false }

        return urls.allSatisfy { url in
            guard let identifier = try? url.resourceValues(forKeys: [.volumeIdentifierKey])
                .volumeIdentifier else { return false }
            return identifier.isEqual(target)
        }
    }

    // MARK: - Owner and group

    func requestOwnerEdit(anchor: FileItem.ID? = nil) {
        guard let target = ownershipTarget(anchor, column: "Owner") else { return }
        picker.show(sections: [.init(title: "Users", items: AccountLookup.users())],
                    current: target.owner) { [weak self] name in
            self?.applyOwnership(owner: name, group: nil)
        }
    }

    func requestGroupEdit(anchor: FileItem.ID? = nil) {
        guard let target = ownershipTarget(anchor, column: "Group") else { return }

        // Your own groups first: they are the only ones a chgrp will accept
        // without root.
        let own = AccountLookup.ownGroups()
        let rest = AccountLookup.groups().filter { !own.contains($0) }
        picker.show(sections: [.init(title: "Your groups", items: own),
                               .init(title: "All groups", items: rest)],
                    current: target.group) { [weak self] name in
            self?.applyOwnership(owner: nil, group: name)
        }
    }

    private func ownershipTarget(_ anchor: FileItem.ID?, column: String) -> FileItem? {
        let items = active.selectedItems
        guard !items.isEmpty else {
            dialog = .message("Select one or more items first.")
            return nil
        }
        let target = anchor.flatMap { id in items.first { $0.id == id } } ?? items[0]
        guard !target.owner.isEmpty else {
            dialog = .message("Switch on the \(column) column in Settings to edit it.")
            return nil
        }
        return target
    }

    private func applyOwnership(owner: String?, group: String?) {
        let pane = active
        let urls = pane.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }

        Task {
            let outcome = await FileOperations.shared.setOwnership(owner: owner, group: group,
                                                                   for: urls)
            pane.reload()
            inactive.reload()
            guard !outcome.isCompleteSuccess else { return }

            // Changing an owner is refused for everyone but root, so offer the
            // authenticated route rather than just reporting a failure.
            if let owner {
                pendingOwnerChange = (owner, group, urls)
                dialog = .authorizeOwner
            } else {
                report(outcome, verb: "change the group of")
            }
        }
    }

    func confirmPrivilegedOwnerChange() {
        guard let pending = pendingOwnerChange else { return }
        pendingOwnerChange = nil

        switch Privileged.chown(owner: pending.owner, group: pending.group, urls: pending.urls) {
        case .succeeded:
            flash("Owner changed for \(pending.urls.count) item"
                  + (pending.urls.count == 1 ? "" : "s"), error: false)
        case .cancelled:
            // Cancelling the password prompt used to be reported as success.
            flash("Cancelled. The owner was not changed.")
        case .failed(let message):
            dialog = .message("Could not change the owner.\n\n" + message)
        }
        left.reload()
        right.reload()
    }

    var pendingOwnerName: String { pendingOwnerChange?.owner ?? "" }
    var pendingOwnerCount: Int { pendingOwnerChange?.urls.count ?? 0 }

    // MARK: - Permissions

    /// `anchor` is the row whose cell hosts the editor; the edit still applies
    /// to the whole selection.
    func requestPermissionEdit(anchor: FileItem.ID? = nil) {
        let items = active.selectedItems
        guard !items.isEmpty else {
            dialog = .message("Select one or more items to change permissions.")
            return
        }

        let target = anchor.flatMap { id in items.first { $0.id == id } } ?? items[0]
        guard target.permissions.count == 10 else {
            dialog = .message("Switch on the Permissions column in Settings to edit permissions.")
            return
        }

        renameTable = currentTable
        active.permissionMode = target.mode
        active.permissionEditAnchor = target.id
        permissionScope = PermissionEditorView.scope(at: 0)
    }

    /// Ends an edit in whichever pane has one open, applying it.
    private func endPermissionEdit() {
        for pane in [left, right] where pane.permissionEditAnchor != nil {
            commitPermissionEdit(pane.permissionMode, in: pane)
        }
    }

    func permissionCursorMoved(to index: Int) {
        permissionScope = PermissionEditorView.scope(at: index)
    }

    func cancelPermissionEdit() {
        for pane in [left, right] { pane.permissionEditAnchor = nil }
        permissionScope = nil
        restoreTableFocus()
    }

    func commitPermissionEdit(_ mode: mode_t, in pane: PaneModel? = nil) {
        let pane = pane ?? active
        let urls = pane.selectedItems.map(\.url)
        pane.permissionEditAnchor = nil
        permissionScope = nil
        restoreTableFocus()

        guard !urls.isEmpty else { return }

        Task {
            // All twelve bits: the editor can now express setuid, setgid and
            // sticky, so it owns them rather than having them preserved behind
            // its back.
            let outcome = await FileOperations.shared.setPermissions(mode, mask: 0o7777,
                                                                     for: urls)
            pane.reload()
            report(outcome, verb: "change permissions for")
        }
    }

    private func restoreTableFocus() {
        guard let table = renameTable ?? currentTable else { return }
        window?.makeFirstResponder(table)
    }

    func requestPathEdit() {
        pathEditToken += 1
    }

    func revealSelection() {
        let urls = active.selectedItems.map(\.url)
        NSWorkspaceOpener.revealInFinder(urls.isEmpty ? [active.directory] : urls)
    }

    func openTerminal() {
        NSWorkspaceOpener.openTerminal(at: active.directory)
    }

    /// Exchange the two panes wholesale, with everything they contain.
    func goBack()    { active.goBack() }
    func goForward() { active.goForward() }

    func refreshPanes() {
        left.reload()
        right.reload()
    }

    func swapPanes() {
        swap(&left, &right)
        persist()
        // Follow the content, not the position: the pane you were working in is
        // now on the other side, and the cursor stays on the file you were on.
        activeSide = (activeSide == .left) ? .right : .left
    }

    /// Point the inactive pane at the active pane's directory.
    func syncPanes() {
        inactive.navigate(to: active.directory)
    }

    private func report(_ outcome: FileOperations.Outcome, verb: String) {
        guard !outcome.isCompleteSuccess else { return }
        let lines = outcome.failures.prefix(10).map { "\($0.url.lastPathComponent): \($0.message)" }
        var text = "Could not \(verb) \(outcome.failures.count) item(s).\n\n"
            + lines.joined(separator: "\n")

        if let hint = Self.accessControlHint(for: outcome.failures.map(\.url)) {
            text += hint
        }
        dialog = .message(text)
    }

    /// "Permission denied" on a file whose bits look fine is almost always an
    /// ACL, and the reason is rarely obvious, so say it.
    static func accessControlHint(for urls: [URL]) -> String? {
        guard urls.contains(where: { AccessControl.text(of: $0.path) != nil }) else { return nil }
        return "\n\nOne of these items has an access control list. An ACL entry "
            + "overrides the permission bits, and entries are matched top to bottom "
            + "with the first match winning -- so a \u{201C}deny\u{201D} above an "
            + "\u{201C}allow\u{201D} wins, even for the owner. Renaming needs "
            + "\u{201C}delete\u{201D}, because it removes the old name. "
            + "The Info window\u{2019}s Access tab shows and edits the list."
    }

    // MARK: - Type-ahead

    private var typeAhead = ""
    private var typeAheadAt = Date.distantPast

    /// Finder-style type-select: typing "rea" moves the cursor to the first row
    /// starting with those letters. Keystrokes within a second of each other
    /// extend the search string; a pause starts a new one.
    func typeAhead(_ text: String) -> Bool {
        let now = Date()
        if now.timeIntervalSince(typeAheadAt) > 1.0 { typeAhead = "" }
        typeAheadAt = now

        let pane = active
        let extended = typeAhead + text.lowercased()

        // Try the accumulated prefix first; if nothing matches, fall back to
        // treating this keystroke as the start of a new search, which is what
        // makes fast typing over a mismatch feel right rather than dead.
        for candidate in [extended, text.lowercased()] {
            if let match = pane.rows.first(where: {
                !$0.isParent && $0.name.lowercased().hasPrefix(candidate)
            }) {
                typeAhead = candidate
                pane.selection = [match.id]
                scrollSelectionIntoView()
                return true
            }
        }

        typeAhead = ""
        return false
    }

    /// SwiftUI's Table has no API to scroll a programmatic selection into view,
    /// so reach through to the NSTableView underneath.
    ///
    /// The focused pane's table *is* the window's first responder -- verified
    /// while debugging the focus wiring -- so no view-hierarchy search is
    /// needed, and this can only ever scroll the pane the user is working in.
    /// The focused pane's table. Remembered, because during a rename the first
    /// responder is the text field, not the table -- which is why scrolling to a
    /// renamed file used to silently do nothing.
    private var currentTable: NSTableView? {
        if let table = window?.firstResponder as? NSTableView {
            lastTable = table
            return table
        }
        return lastTable
    }

    func scrollSelectionIntoView() {
        guard let table = currentTable else { return }
        let rows = active.rows
        guard let index = rows.firstIndex(where: { active.selection.contains($0.id) }) else { return }
        // One turn later, so SwiftUI has pushed the new selection and row set
        // into the table before we ask it to scroll.
        DispatchQueue.main.async { table.scrollRowToVisible(index) }
    }

    // MARK: - Keyboard

    /// Called by `KeyRouter` for the window that owns this model.
    /// Returns true when the key was consumed.
    func handle(key: KeyRouter.Key, modifiers: NSEvent.ModifierFlags) -> Bool {
        // Command-Delete trashes straight away, no dialog.
        if modifiers.contains(.command) {
            switch key {
            case .delete, .forwardDelete:
                if let selected = selectedSidebarEntry, selected.hasPrefix("f:") {
                    removeFavourite(path: String(selected.dropFirst(2)))
                } else {
                    trashNow()
                }
                return true
            default:
                // Let the system keep its own shortcuts (Cmd-Q, Cmd-W, ...).
                return false
            }
        }
        // Never act while a sheet is up; the sheet owns the keyboard.
        if dialog != nil { return false }

        switch key {
        case .tab:            toggleActiveSide()
        case .ret, .enter:    openSelection()
        case .f2:             requestRename()
        // F4 as well as F9: on many setups F9 is taken by Mission Control.
        case .f4, .f9:        requestPermissionEdit()
        case .f3:             viewSelection()
        case .f5:             copySelection()
        case .f6:             moveSelection()
        case .f7:             requestNewFolder()
        case .f8, .delete, .forwardDelete: requestTrash()
        // Only taken over while rows are greyed out; otherwise the table's own
        // arrow handling is better than anything we would write.
        case .upArrow, .downArrow:
            guard active.hasFilter, active.filterIsValid, !active.filterHidesOthers else {
                return false
            }
            moveCursorSkippingFiltered(by: key == .downArrow ? 1 : -1)

        case .home:           moveCursor(to: 0)
        case .end:            moveCursor(to: Int.max)
        case .pageUp:         moveCursor(by: -pageStride)
        case .pageDown:       moveCursor(by: pageStride)
        case .space:          toggleQuickLook()
        case .escape:
            if QuickLookController.shared.isVisible {
                QuickLookController.shared.close()
            } else {
                active.selection = []
            }
        default:              return false
        }
        return true
    }
}
