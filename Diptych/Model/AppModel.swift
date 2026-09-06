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
        case message(String)

        var id: String {
            switch self {
            case .newFolder: return "newFolder"
            case .trash:     return "trash"
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
    var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Text backing the New Folder sheet.
    var textInput = ""

    /// The window this model belongs to, so the shared key handler can tell
    /// which window's model should receive a keystroke.
    @ObservationIgnored weak var window: NSWindow? {
        didSet {
            guard let window, window !== oldValue else { return }
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
            showHidden = saved.showHidden
        }
        restored = true

        left.reload()
        right.reload()
        KeyRouter.shared.register(self)
        WidthProbe.run(self)

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
        let destination = inactive.directory
        let source = active

        Task {
            let outcome = await FileOperations.shared.transfer(urls, to: destination, kind: kind)
            report(outcome, verb: kind == .copy ? "copy" : "move")
            if kind == .move { source.reload() }
            inactive.reload()
        }
    }

    func flash(_ message: String) {
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
            pane.pendingReveal = successor
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
                active.pendingReveal = url
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
                pane.pendingReveal = advance ? (successor ?? url) : url
                pane.reload()
            } catch {
                dialog = .message(error.localizedDescription)
            }
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
        dialog = .message("Could not \(verb) \(outcome.failures.count) item(s).\n\n"
            + lines.joined(separator: "\n"))
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
        case .f2:             requestRename()
        case .f3:             viewSelection()
        case .f5:             copySelection()
        case .f6:             moveSelection()
        case .f7:             requestNewFolder()
        case .f8, .delete, .forwardDelete: requestTrash()
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
