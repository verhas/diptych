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
        case newFile
        case trash
        case authorizeOwner
        case conflict
        case message(String)
        /// Something worth reading that is *not* a failure. `message` is drawn
        /// under the heading "Operation failed", which is right for the errors
        /// it was written for and was quietly wrong the moment it was reused to
        /// report success.
        case notice(title: String, text: String)
        case sendWork
        case gitConflict
        case gitNotSent
        case gitClash
        case stopTracking

        var id: String {
            switch self {
            case .newFolder:      return "newFolder"
            case .newFile:        return "newFile"
            case .trash:          return "trash"
            case .authorizeOwner: return "authorizeOwner"
            case .conflict:       return "conflict"
            case .message:   return "message"
            case .notice:    return "notice"
            case .gitClash:       return "gitClash"
            case .stopTracking:   return "stopTracking"
            case .sendWork:       return "sendWork"
            case .gitConflict:    return "gitConflict"
            case .gitNotSent:     return "gitNotSent"
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

    /// Which sidebar row the active pane is standing in, if any.
    ///
    /// Derived from the pane rather than stored, for two reasons. The highlight
    /// then cannot lie about where the pane is. And clicking a row you have
    /// already clicked works: with stored selection, going into a subfolder left
    /// the row highlighted, so clicking it again assigned the value it already
    /// held -- not a change, no navigation, nothing happened.
    var selectedSidebarEntry: SidebarEntry.ID? {
        get {
            let path = active.directory.path
            // Favourites first: a favourite naming a volume root is the more
            // specific answer, and it is the row the user put there.
            if favourites.contains(where: { $0.url.path == path }) { return "f:\(path)" }
            if VolumeList.shared.volumes.contains(where: { $0.url.path == path }) {
                return "v:\(path)"
            }
            return nil
        }
        set {
            guard let newValue,
                  let entry = (favourites + VolumeList.shared.volumes)
                      .first(where: { $0.id == newValue })
            else { return }
            openSidebarEntry(entry)
        }
    }
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
    @ObservationIgnored var openBinaryWindow: ((URL) -> Void)?
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
        ) { [weak self] note in
            // Notification is not Sendable; the URL inside it is.
            let changed = note.object as? URL
            MainActor.assumeIsolated {
                // A folder's icon is cached by path, so the cache has to be
                // told: reloading the pane alone redraws the same stale image.
                IconCache.forget(changed)
                self?.left.reload()
                self?.right.reload()
            }
        }

        // Whether Git is available decides whether the panes have colours, and
        // a pane drawn before it was resolved has none. Nothing else would
        // tell it to look again.
        NotificationCenter.default.addObserver(
            forName: GitService.availabilityChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.left.reload()
                self?.right.reload()
            }
        }
        // A check -- pressed, or the automatic one on first opening a folder --
        // has just changed what the rows should be coloured.
        NotificationCenter.default.addObserver(
            forName: GitService.checkCompleted, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.left.reload()
                self?.right.reload()
            }
        }
        Task { await GitService.shared.locateIfNeeded() }

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
            RowHeights.apply(in: window)
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
            dialog = .notice(title: "More than one item is selected",
                         text: "\(pane.selection.count) items are selected. Select a single "
                             + "item to open.")
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

    /// The hex editor. Never for a directory: a directory's bytes are the file
    /// system's own bookkeeping, and on APFS opening one for update is not
    /// something a file manager should offer to do.
    @ObservationIgnored var openDiffWindow: ((DiffPair) -> Void)?

    /// Two files, side by side.
    ///
    /// Either two ticked in one pane, or one in each -- both are natural in a
    /// two-pane file manager and guessing wrongly between them would be worse
    /// than accepting both. When it comes from the two panes the left pane's
    /// file goes on the left, which is the only arrangement that would not
    /// surprise anybody.
    func showDiff() {
        guard let pair = pairToCompare() else { return }
        guard !pair.hasFolder else {
            flash("Comparing folders is not built yet", error: true)
            return
        }
        openDiffWindow?(DiffPair(left: pair.left, right: pair.right))
    }

    private func pairToCompare() -> (left: URL, right: URL, hasFolder: Bool)? {
        let here = active.selectedItems.filter { !$0.isParent }
        if here.count == 2 {
            // Row order, not selection order: what the user sees top to bottom.
            let ordered = active.rows.filter { item in here.contains { $0.id == item.id } }
            guard ordered.count == 2 else { return nil }
            return (ordered[0].url, ordered[1].url,
                    ordered.contains { $0.isDirectory })
        }

        let other = (active === left ? right : self.left).selectedItems.filter { !$0.isParent }
        guard here.count == 1, other.count == 1 else {
            flash("Select two files, or one in each pane", error: true)
            return nil
        }
        let leftItem = active === left ? here[0] : other[0]
        let rightItem = active === left ? other[0] : here[0]
        return (leftItem.url, rightItem.url, leftItem.isDirectory || rightItem.isDirectory)
    }

    func showBinaryView() {
        guard let item = singleSelection("open in the binary view",
                                         includingParent: false) else { return }
        guard !item.isDirectory else {
            flash("\(item.name) is a folder. The binary view opens files.", error: true)
            return
        }
        openBinaryWindow?(item.url)
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
        textInput = suggestedName("untitled folder")
        dialog = .newFolder
    }

    func requestNewFile() {
        textInput = suggestedName("untitled.txt")
        dialog = .newFile
    }

    /// "untitled folder", then "untitled folder 2", and so on.
    ///
    /// Finder's numbering rather than `FileOperations.uniqueURL`'s "-1", and
    /// deliberately: that one exists to stop a copy clobbering something, where
    /// this is a name a person is about to read and quite possibly keep.
    private func suggestedName(_ base: String) -> String {
        let directory = active.directory
        let stem = (base as NSString).deletingPathExtension
        let suffix = (base as NSString).pathExtension
        func name(_ number: Int) -> String {
            let stem = number == 1 ? stem : "\(stem) \(number)"
            return suffix.isEmpty ? stem : "\(stem).\(suffix)"
        }
        for number in 1...9999 {
            let candidate = name(number)
            if !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(candidate).path) {
                return candidate
            }
        }
        return base
    }

    func confirmNewFile() {
        let name = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let parent = active.directory
        Task {
            do {
                let url = try await FileOperations.shared.createFile(named: name, in: parent)
                active.pendingSelection = [url]
                active.reload()
            } catch {
                dialog = .message(error.localizedDescription)
            }
        }
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
        //
        // Serialised, however, is not the same as ignored: asking for a second
        // transfer while one is running used to look exactly like nothing
        // happening, until it began minutes later of its own accord.
        if transferProgress != nil || queuedTransfers > 0 {
            queuedTransfers += 1
            let verb = kind == .move ? "Move" : "Copy"
            flash("\(verb) of \(urls.count) item\(urls.count == 1 ? "" : "s") queued",
                  error: false)
        }

        enqueueTransfer { [weak self] in
            guard let self else { return }
            if self.queuedTransfers > 0 { self.queuedTransfers -= 1 }
            await self.runTransfer(urls, to: destination, kind: kind,
                                   into: destinationPane, from: sourcePane)
        }
    }

    @ObservationIgnored private var transferChain: Task<Void, Never>?

    /// The sheet, while there is one. nil means nothing is being shown.
    var transferProgress: TransferProgress?
    /// Transfers asked for while another was running.
    private(set) var queuedTransfers = 0
    @ObservationIgnored private var transferMonitor: TransferMonitor?
    /// What had already arrived when the user pressed Cancel.
    @ObservationIgnored private var cancelledTargets: [URL] = []

    func cancelTransfer() {
        transferProgress?.markCancelling()
        transferMonitor?.cancel()
    }

    /// After a cancelled transfer: keep what arrived, or clear it away.
    private func askAboutPartialTransfer(kind: FileOperations.Transfer,
                                         landed: [URL], into pane: PaneModel) {
        guard !landed.isEmpty else {
            flash("Cancelled. Nothing was \(kind == .move ? "moved" : "copied").", error: false)
            return
        }
        partialTransfer = PartialTransfer(kind: kind, targets: landed, pane: pane)
    }

    struct PartialTransfer: Identifiable {
        let kind: FileOperations.Transfer
        let targets: [URL]
        let pane: PaneModel
        var id: String { targets.first?.path ?? "" }
    }

    var partialTransfer: PartialTransfer?

    func keepPartialTransfer() {
        let count = partialTransfer?.targets.count ?? 0
        partialTransfer = nil
        flash("Cancelled. \(count) item\(count == 1 ? "" : "s") kept.", error: false)
    }

    func discardPartialTransfer() {
        guard let partial = partialTransfer else { return }
        partialTransfer = nil
        Task {
            let outcome = await FileOperations.shared.deleteOutright(partial.targets)
            partial.pane.reload()
            if outcome.isCompleteSuccess {
                flash("Cancelled. What had arrived was removed.", error: false)
            } else {
                report(outcome, verb: "remove")
            }
        }
    }

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

        // Measured before anything is copied, off the main actor: on a large
        // tree the walk is not free, and a bar without a total is just a
        // spinner.
        let monitor = TransferMonitor()
        let totalBytes = await BlockingWork.run { FileOperations.totalBytes(of: urls) }
        let progress = TransferProgress(verb: kind == .move ? "Moving" : "Copying",
                                        itemCount: urls.count, bytesTotal: totalBytes)
        monitor.onProgress = { [weak progress] bytes, item in
            Task { @MainActor in progress?.update(bytes: bytes, item: item) }
        }
        transferMonitor = monitor

        // Shown only if the transfer outlives the delay. Most are over long
        // before it, and a sheet that flashes up and vanishes is worse than
        // none at all.
        let reveal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: TransferProgress.showAfter)
            guard !Task.isCancelled else { return }
            self?.transferProgress = progress
        }
        defer {
            reveal.cancel()
            transferProgress = nil
            transferMonitor = nil
        }
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

            progress.update(bytes: monitor.completedBytes, item: source.lastPathComponent)

            if let message = await FileOperations.shared.transferOne(source, to: target,
                                                                     kind: kind,
                                                                     overwrite: overwrite,
                                                                     monitor: monitor) {
                // Cancellation is not a failure to report item by item; the
                // user knows what they did.
                if monitor.isCancelled { cancelledTargets = outcome.succeeded; break }
                outcome.failures.append((source, message))
            } else {
                outcome.succeeded.append(target)
                progress.finishedItem()
            }
            if monitor.isCancelled { cancelledTargets = outcome.succeeded; break }
        }

        // Awaited, not fired and forgotten. The next transfer in the chain
        // starts the moment this function returns, and an un-awaited reload
        // queued behind it only landed when *that* one finished -- so a moved
        // item sat visibly in the source pane until an unrelated copy was done.
        destinationPane.pendingSelection = Set(outcome.succeeded)
        await sourcePane?.reloadAndWait()
        await destinationPane.reloadAndWait()

        if monitor.isCancelled {
            // What has already landed is real. Whether to keep it is a
            // judgement -- a half-copied folder may be worth keeping or may be
            // clutter -- so it is asked rather than decided.
            askAboutPartialTransfer(kind: kind, landed: cancelledTargets,
                                    into: destinationPane)
            return
        }

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

    /// Builds a question about the selection and puts it on the clipboard.
    ///
    /// Nothing is sent anywhere: this writes text. The care that would normally
    /// go into a network call goes into what the text contains instead --
    /// metadata only, paths abbreviated, provenance attributes withheld, and
    /// names fenced as data rather than instructions. See `PromptBuilder`.
    // MARK: - Version tracking

    /// Everything the send and conflict sheets are looking at, so the views
    /// stay declarative and the work stays here.
    var gitChanges = GitService.Changes()
    var gitSendMessage = ""
    var gitSending: Set<String> = []
    var gitIncluding: Set<String> = []
    var gitConflictPaths: [String] = []
    var gitConflictHasOwnVersions = false
    /// What is happening, while it is happening. Empty means nothing is.
    ///
    /// A push crosses a network and can take a long time or fail, and the panes
    /// carried on looking ordinary and editable throughout -- so a folder was
    /// being rewritten underneath someone who had no reason to think anything
    /// was going on.
    var gitBusy = false
    private(set) var gitBusyMessage = ""
    /// Git's own words, kept for the Copy Details button. The recovery path for
    /// this audience is forwarding the failure to whoever set the repository
    /// up, so nothing may be paraphrased away.
    private(set) var gitLastDetails = ""
    private(set) var gitNotSentReason = ""
    /// Files both sides changed. Empty when the shared copy has merely moved
    /// on, which needs no decision from anybody -- so the dialog can offer to
    /// do the whole thing rather than to start a conversation.
    private(set) var gitNotSentConflicts: [String] = []

    /// Git's own words, for forwarding to whoever set the repository up.
    func copyGitDetails() {
        Clipboard.copyText(gitLastDetails)
        flash("Details copied", error: false)
    }

    /// Straight from the failed-send dialog into the flow that fixes it.
    ///
    /// And straight *through* it: having chosen to get the latest knowing the
    /// send was refused, being asked again about the clash is a second
    /// confirmation for a decision already made. Keeping copies never loses
    /// anything, so it happens, and the user is told what was set aside
    /// afterwards rather than asked beforehand.
    func getLatestAfterFailedSend() {
        dialog = nil
        getLatest(keepingCopiesWithoutAsking: true)
    }

    /// The whole job in one press, for the common case: nobody contests any of
    /// these files, the shared copy has simply moved on. A push is refused
    /// whenever that is true, whatever was ticked -- so deselecting a file
    /// cannot help, and asking the user to send again by hand is asking them
    /// to repeat themselves.
    func getLatestAndSendAgain() {
        dialog = nil
        // A contested file blocks the update whether or not it was ticked, so
        // dealing with it is part of the same press. Deselecting it in the send
        // dialog said "do not send this"; it did not, and could not, say "leave
        // this folder out of date".
        let clashing = gitNotSentConflicts
        let message = gitSendMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        // What is left to send afterwards. A contested file now matches the
        // shared version -- the user's own is beside it -- so sending it would
        // mean sending back what just arrived.
        let paths = gitChanges.sending.map(\.path)
            .filter { gitSending.contains($0) && !clashing.contains($0) }
        let new = gitChanges.new.map(\.path)
            .filter { gitIncluding.contains($0) && !clashing.contains($0) }
        guard let root = active.gitRoot else { return }

        Task {
            var kept: [String] = []

            if clashing.isEmpty {
                beginGit("Getting the latest\u{2026}")
                let update = await GitService.shared.getLatest(inRepository: root)
                guard case .updated = update else {
                    endGit()
                    active.reload()
                    // Anything other than a clean update needs the ordinary
                    // path, which knows how to explain itself.
                    handleGetResult(update, root: root, keepingCopiesWithoutAsking: false)
                    return
                }
            } else {
                beginGit("Keeping your copies and updating\u{2026}")
                let update = await GitService.shared.keepCopiesAndTakeShared(paths: clashing,
                                                                            inRepository: root)
                guard case .keptCopies(let names) = update else {
                    endGit()
                    active.reload()
                    handleGetResult(update, root: root, keepingCopiesWithoutAsking: false)
                    return
                }
                kept = names
            }

            guard !paths.isEmpty || !new.isEmpty else {
                endGit()
                active.reload()
                // Everything that was ticked turned out to be contested, so
                // there is nothing left to send -- but plenty to report.
                reportKeptCopies(kept)
                return
            }

            gitBusyMessage = "Sending your work\u{2026}"
            let result = await GitService.shared.send(paths: paths, newPaths: new,
                                                     message: message, inRepository: root)
            endGit()
            active.reload()
            handleSendResult(result, alsoKept: kept)
        }
    }

    var gitRepositoryRoot: URL? { active.gitRoot }

    private func beginGit(_ message: String) {
        gitBusyMessage = message
        gitBusy = true
    }

    private func endGit() {
        gitBusy = false
        gitBusyMessage = ""
    }

    func trackSelection() {
        guard let root = active.gitRoot else { return }
        let paths = relativeSelection(under: root)
        guard !paths.isEmpty else { return }
        Task {
            let outcome = await GitService.shared.track(paths, inRepository: root)
            finishGit(outcome, success: "\(paths.count) now tracked", root: root)
        }
    }

    func neverTrackSelection() {
        guard let root = active.gitRoot else { return }
        let paths = relativeSelection(under: root)
        guard !paths.isEmpty else { return }
        Task {
            let outcome = await GitService.shared.neverTrack(paths, inRepository: root)
            finishGit(outcome, success: "\(paths.count) will never be sent", root: root)
        }
    }

    func requestStopTracking() {
        guard active.gitRoot != nil, !relativeSelectionIsEmpty else { return }
        dialog = .stopTracking
    }

    func confirmStopTracking() {
        dialog = nil
        guard let root = active.gitRoot else { return }
        let paths = relativeSelection(under: root)
        guard !paths.isEmpty else { return }
        Task {
            let outcome = await GitService.shared.stopTracking(paths, inRepository: root)
            // `git rm --cached` fails on a file it was never tracking, which is
            // the likeliest way to arrive here by mistake: the menu cannot tell
            // a tracked unchanged file from an ignored one without asking Git,
            // and asking Git is not something a menu can wait for.
            if case .failed = outcome {
                dialog = .message("\(paths.count == 1 ? "That file is" : "Those files are") "
                                  + "not being tracked, so there is nothing to stop.")
                return
            }
            finishGit(outcome, success: "\(paths.count) no longer tracked", root: root)
        }
    }

    private var relativeSelectionIsEmpty: Bool {
        active.selectedItems.allSatisfy(\.isParent)
    }

    private func relativeSelection(under root: URL) -> [String] {
        active.selectedItems
            .filter { !$0.isParent }
            .compactMap { GitStatus.relativePath(of: $0.url, under: root) }
            .filter { !$0.isEmpty }
    }

    private func finishGit(_ outcome: GitTool.Outcome, success: String, root: URL) {
        GitService.shared.invalidate(root)
        active.reload()
        switch outcome {
        case .ok:
            flash(success, error: false)
        case .failed(_, let text), .couldNotRun(let text):
            gitLastDetails = text
            flash("That did not work. Settings has a Copy Details button.", error: true)
        case .timedOut:
            flash("Git took too long and was stopped.", error: true)
        }
    }

    /// Opens the review sheet. Nothing is committed or sent until it is
    /// accepted -- and then both happen together.
    func requestSendWork() {
        guard let root = active.gitRoot else {
            flash("This folder is not tracked", error: true)
            return
        }
        Task {
            beginGit("Looking at what has changed\u{2026}")
            gitChanges = await GitService.shared.changes(inRepository: root)
            endGit()
            guard !gitChanges.isEmpty else {
                flash("Nothing has changed here", error: false)
                return
            }
            // Everything already known to Git starts ticked; new files do not.
            // The recovery from forgetting one is a click; the recovery from
            // sending a private draft to everyone is a phone call.
            gitSending = Set(gitChanges.sending.map(\.path))
            gitIncluding = []
            gitSendMessage = ""
            dialog = .sendWork
        }
    }

    func sendWork() {
        guard let root = active.gitRoot else { return }
        let paths = gitChanges.sending.map(\.path).filter { gitSending.contains($0) }
        let new = gitChanges.new.map(\.path).filter { gitIncluding.contains($0) }
        let message = gitSendMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        dialog = nil
        // A fresh send starts with nothing settled; a retry after the clash
        // dialog keeps what was settled there.
        gitKeepingMine = []
        attemptSend(paths: paths, newPaths: new, message: message, root: root)
    }

    private func attemptSend(paths: [String], newPaths: [String], message: String, root: URL) {
        gitPendingSend = (paths, newPaths, message, root)
        Task {
            beginGit("Sending your work\u{2026}")
            let result = await GitService.shared.send(paths: paths, newPaths: newPaths,
                                                     message: message, inRepository: root,
                                                     decided: gitKeepingMine)
            endGit()
            active.reload()

            handleSendResult(result)
        }
    }

    // MARK: - Files nobody ticked, that both sides changed

    /// The clash dialog walks these one at a time, unless the user says to do
    /// the same for the rest.
    private(set) var gitClashPaths: [String] = []
    var gitClashApplyToAll = false
    private var gitKeepingMine: Set<String> = []
    private var gitTakingTheirs: [String] = []
    private var gitPendingSend: (paths: [String], newPaths: [String],
                                 message: String, root: URL)?

    var gitClashCurrent: String { gitClashPaths.first ?? "" }
    var gitClashRemaining: Int { max(0, gitClashPaths.count - 1) }

    private func askAboutClashes(_ paths: [String]) {
        gitClashPaths = paths
        gitClashApplyToAll = false
        gitTakingTheirs = []
        dialog = .gitClash
    }

    /// Keep a copy of my version and take the shared one.
    func clashTakeTheirs() { decideClash { gitTakingTheirs.append($0) } }

    /// My version stays and wins. It is not sent, and it no longer counts as a
    /// clash -- which is exactly what Diptych used to do without asking.
    func clashKeepMine() { decideClash { gitKeepingMine.insert($0) } }

    private func decideClash(_ record: (String) -> Void) {
        guard !gitClashPaths.isEmpty else { return }
        if gitClashApplyToAll {
            gitClashPaths.forEach(record)
            gitClashPaths = []
        } else {
            record(gitClashPaths.removeFirst())
        }
        guard gitClashPaths.isEmpty else { return }
        dialog = nil
        applyClashDecisions()
    }

    func cancelClashes() {
        dialog = nil
        gitClashPaths = []
        gitTakingTheirs = []
        gitKeepingMine = []
        gitPendingSend = nil
        flash("Nothing was sent", error: false)
    }

    private func applyClashDecisions() {
        guard let pending = gitPendingSend else { return }
        let takingTheirs = gitTakingTheirs
        gitTakingTheirs = []
        Task {
            var kept: [String] = []
            if !takingTheirs.isEmpty {
                beginGit("Keeping your versions\u{2026}")
                kept = await GitService.shared.setAsideMyVersion(takingTheirs,
                                                                 inRepository: pending.root)
                endGit()
            }
            gitClashKept = kept
            attemptSend(paths: pending.paths, newPaths: pending.newPaths,
                        message: pending.message, root: pending.root)
        }
    }

    /// Reported alongside the send that follows, so the user is told once.
    private var gitClashKept: [String] = []

    private func handleSendResult(_ result: GitService.SendResult,
                                  alsoKept kept: [String] = []) {
            switch result {
            case .needsDecision(let paths):
                askAboutClashes(paths)
            case .sent(let count):
                let kept = kept + gitClashKept
                gitClashKept = []
                guard kept.isEmpty else {
                    // Both things happened, and the renamed copies are the half
                    // nothing else would point out.
                    dialog = .notice(title: "Sent",
                                     text: "\(count) file\(count == 1 ? " was" : "s were") "
                                         + "sent.\n\nYour own version of "
                                         + "\(kept.count == 1 ? "this file was" : "these files were") "
                                         + "kept beside the original:\n\n"
                                         + kept.map { "\u{2022} " + $0 }.joined(separator: "\n")
                                         + "\n\nThey are not sent to anyone. Delete them once "
                                         + "you have taken what you need.")
                    return
                }
                flash("Sent \(count) file\(count == 1 ? "" : "s")", error: false)
            case .nothingSelected:
                flash("Nothing was ticked", error: true)
            case .notSent(let reason, let details, let conflicts):
                // Not a dead end. A rejected push almost always means someone
                // else went first, and the answer to that is Get the Latest --
                // so the dialog offers it rather than handing over git's own
                // paragraph and leaving the user to work out what to do.
                gitNotSentReason = reason
                gitNotSentConflicts = conflicts
                gitLastDetails = details
                dialog = .gitNotSent
            case .sentDespiteError(let details):
                gitLastDetails = details
                dialog = .notice(title: "Sent, but the reply was lost",
                                 text: "Your work did reach the shared copy. The answer went "
                                     + "missing on the way back, so it is worth checking."
                                     + "\n\n" + details)
        }
    }

    /// Ask the server what it has, and say so plainly.
    ///
    /// Nothing else in Diptych reaches the network unasked, and this does not
    /// either: it runs when the user presses it. The answer is a snapshot, so
    /// what it produces on screen always carries its own age.
    func checkForChanges() {
        guard let root = active.gitRoot else {
            flash("This folder is not tracked", error: true)
            return
        }
        Task {
            beginGit("Checking for changes\u{2026}")
            let result = await GitService.shared.checkForChanges(inRepository: root)
            endGit()
            // The panes redraw from the checkCompleted notification, which the
            // automatic check raises too.
            switch result {
            case .checked(let behind, let contested):
                report(behind: behind, contested: contested)
            case .failed(let details):
                gitLastDetails = details
                dialog = .message("The shared copy could not be reached."
                                  + (details.isEmpty ? "" : "\n\n" + details))
            }
        }
    }

    private func report(behind: Int, contested: [String]) {
        guard behind > 0 || !contested.isEmpty else {
            flash("Nothing new \u{2014} you are up to date", error: false)
            return
        }
        let waiting = behind == 1 ? "1 change is waiting" : "\(behind) changes are waiting"
        guard !contested.isEmpty else {
            flash("\(waiting) for you", error: false)
            return
        }
        // Worth a dialog rather than a flash: it names files, and it is the one
        // answer that changes what the user should do next.
        dialog = .notice(title: "Checked",
                         text: "\(waiting) for you on the shared copy.\n\n"
                             + "\(contested.count == 1 ? "This file has" : "These files have") "
                             + "been changed here and by someone else as well, so "
                             + "\(contested.count == 1 ? "it is" : "they are") shown in red:\n\n"
                             + contested.map { "\u{2022} " + $0 }.joined(separator: "\n")
                             + "\n\nGet the Latest will offer to keep your own version "
                             + "beside theirs.")
    }

    func getLatest(keepingCopiesWithoutAsking: Bool = false) {
        guard let root = active.gitRoot else {
            flash("This folder is not tracked", error: true)
            return
        }
        Task {
            beginGit("Getting the latest\u{2026}")
            let result = await GitService.shared.getLatest(inRepository: root)
            endGit()
            active.reload()
            handleGetResult(result, root: root,
                            keepingCopiesWithoutAsking: keepingCopiesWithoutAsking)
        }
    }

    private func handleGetResult(_ result: GitService.GetResult, root: URL,
                                 keepingCopiesWithoutAsking: Bool) {
        switch result {
        case .upToDate:
            flash("Already up to date", error: false)
        case .updated(let count):
            flash("Updated \(count) change\(count == 1 ? "" : "s")", error: false)
        case .conflicting(let paths, let hasOwn):
            gitConflictPaths = paths
            guard !keepingCopiesWithoutAsking else {
                keepMyCopiesAndUpdate()
                return
            }
            gitConflictHasOwnVersions = hasOwn
            dialog = .gitConflict
        case .keptCopies(let names):
            reportKeptCopies(names)
        case .failed(let reason, let details):
            gitLastDetails = details
            dialog = .message(reason + (details.isEmpty ? "" : "\n\n" + details))
        }
    }

    /// Told, not asked. The files have been renamed, and they are excluded from
    /// Git, so nothing in the pane would otherwise point them out.
    private func reportKeptCopies(_ names: [String]) {
        guard !names.isEmpty else {
            flash("Updated", error: false)
            return
        }
        dialog = .notice(title: "Updated",
                         text: "This folder now matches the shared version.\n\nYour own "
                             + "version of \(names.count == 1 ? "this file was" : "these files were") "
                             + "kept beside the original:\n\n"
                             + names.map { "\u{2022} " + $0 }.joined(separator: "\n")
                             + "\n\nThey are not sent to anyone. Delete them once you have "
                             + "taken what you need.")
    }

    func keepMyCopiesAndUpdate() {
        guard let root = active.gitRoot else { return }
        let paths = gitConflictPaths
        dialog = nil
        Task {
            beginGit("Keeping your copies and updating\u{2026}")
            let result = await GitService.shared.keepCopiesAndTakeShared(paths: paths,
                                                                        inRepository: root)
            endGit()
            active.reload()
            switch result {
            case .keptCopies(let names):
                reportKeptCopies(names)
            case .updated(let count):
                flash("Updated \(count) change\(count == 1 ? "" : "s")", error: false)
            case .failed(let reason, let details):
                gitLastDetails = details
                dialog = .message(reason + (details.isEmpty ? "" : "\n\n" + details))
            default:
                break
            }
        }
    }

    func copyPromptToClipboard() {
        let items = active.selectedItems.filter { !$0.isParent }
        guard !items.isEmpty else {
            flash("Select something to ask about", error: true)
            return
        }

        let prompt = PromptBuilder.prompt(for: items, in: active.directory)
        Clipboard.copyText(prompt.text)

        // A name that needed escaping is worth saying out loud. It is either a
        // curiosity or an attempt at one, and the difference is not ours to
        // judge -- but it should not go past silently.
        guard prompt.warnings.isEmpty else {
            flash("Prompt copied, but a name contained \(prompt.warnings.first!). "
                  + "It has been escaped.", error: true)
            return
        }
        flash("Prompt about \(items.count) item\(items.count == 1 ? "" : "s") copied "
              + "\u{2014} nothing was sent", error: false)
    }

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

    /// Symbolic links to whatever was copied, rather than copies of it.
    ///
    /// A cut on the clipboard is left alone: linking to something is not moving
    /// it, so the pending move stays pending and Paste can still perform it.
    func pasteAsLink() {
        let urls = Clipboard.fileURLs()
        guard !urls.isEmpty else {
            flash("The clipboard holds no files", error: true)
            return
        }

        let destination = active.directory
        Task {
            let outcome = await FileOperations.shared.createLinks(to: urls, in: destination)
            active.reload()
            inactive.reload()

            if outcome.isCompleteSuccess {
                let count = outcome.succeeded.count
                flash("Linked \(count) item\(count == 1 ? "" : "s")", error: false)
            } else {
                report(outcome, verb: "link")
            }
        }
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
            dialog = .notice(title: "Nothing is selected",
                         text: "Select one or more items first.")
            return nil
        }
        let target = anchor.flatMap { id in items.first { $0.id == id } } ?? items[0]
        guard !target.owner.isEmpty else {
            dialog = .notice(title: "That column is switched off",
                         text: "Switch on the \(column) column in Settings to edit it.")
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
            dialog = .notice(title: "Nothing is selected",
                         text: "Select one or more items to change permissions.")
            return
        }

        let target = anchor.flatMap { id in items.first { $0.id == id } } ?? items[0]
        guard target.permissions.count == 10 else {
            dialog = .notice(title: "That column is switched off",
                         text: "Switch on the Permissions column in Settings to edit "
                             + "permissions.")
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

    /// Opens the path bar on the active pane.
    ///
    /// `selectingAll` is the difference between the two ways in. Going somewhere
    /// *below* here wants the caret after the separator, ready for a child's
    /// name; going somewhere else entirely wants the path selected, so the
    /// first keystroke replaces it.
    func requestPathEdit(selectingAll: Bool = false) {
        pathEditSelectsAll = selectingAll
        pathEditToken += 1
    }

    private(set) var pathEditSelectsAll = false

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
                // Always the pane, never the sidebar. Cmd-Delete used to remove
                // the selected favourite whenever one was selected -- which,
                // since selecting a favourite is how you navigate, was most of
                // the time. Both outcomes were wrong: a favourite vanished when
                // files were meant to go, and files survived when they were
                // meant to go. Removing a favourite is rare and undoable only by
                // hand, so it lives in the context menu alone.
                trashNow()
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
        case .f1:             copyPromptToClipboard()
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
            } else if active.isNavigating {
                // Escape is what everyone presses at a spinner. The button's
                // own shortcut never fires, because this router sees the key
                // first.
                active.cancelLoad()
            } else {
                active.selection = []
            }
        default:              return false
        }
        return true
    }
}
