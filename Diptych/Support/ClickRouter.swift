import AppKit

/// Turns raw mouse clicks into "row R, column C of pane P was clicked".
///
/// Every previous attempt at click-again-to-rename attached a gesture to the
/// cell -- `onTapGesture`, then `simultaneousGesture` -- and each one broke row
/// selection, because a SwiftUI gesture inside a table cell takes part in hit
/// testing and can swallow the mouse-down the table needs.
///
/// This observes instead. A local NSEvent monitor sees the click, works out what
/// was hit from AppKit geometry, tells the model, and *always returns the event*
/// so NSTableView behaves exactly as if we were not here. It cannot break
/// selection, because it never intercepts anything.
///
/// It also runs before the table processes the click, so the selection it reads
/// is the selection as it was *before* this click -- which is precisely what
/// "was this row already selected?" needs, with no timing heuristics.
@MainActor
final class ClickRouter {

    static let shared = ClickRouter()

    private struct WeakModel { weak var model: AppModel? }
    private var models: [WeakModel] = []
    private var monitor: Any?

    func register(_ model: AppModel) {
        models.removeAll { $0.model == nil || $0.model === model }
        models.append(WeakModel(model: model))
        install()
    }

    private func install() {
        guard monitor == nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .rightMouseDown]
        ) { [weak self] event in
            // A drag begins with a mouse-down on a row that is usually already
            // selected -- which is exactly the gesture that starts a rename.
            // Dragging must cancel that, or the row is left in an editor that
            // nothing can dismiss.
            if event.type == .leftMouseDragged {
                MainActor.assumeIsolated { self?.cancelPendingEdits() }
                return event
            }

            // A right-click below the last row: the pane's own menu, which
            // SwiftUI never offers there. Consumed, so nothing else answers
            // the same click.
            if event.type == .rightMouseDown {
                let location = event.locationInWindow
                let number = event.windowNumber
                // On a pane's column headers: which columns to show.
                let onHeader = MainActor.assumeIsolated { () -> Bool in
                    guard let header = self?.paneHeader(windowNumber: number, location: location)
                    else { return false }
                    let rows = self?.pane(of: header, windowNumber: number)?.rows ?? []
                    ColumnArrangement.showMenu(for: event, in: header, rows: rows)
                    return true
                }
                if onHeader { return nil }
                let handled = MainActor.assumeIsolated {
                    self?.anticipateNewFromClipboard(windowNumber: number, location: location)
                    return self?.offerFolderMenu(windowNumber: number, location: location) ?? false
                }
                return handled ? nil : event
            }
            // Only Sendable values cross the boundary; NSEvent itself cannot.
            let location = event.locationInWindow
            let number = event.windowNumber
            let clicks = event.clickCount

            // A pane's column header dragged: Diptych moves the column, as
            // SwiftUI's table will not.
            if event.type == .leftMouseDown, clicks == 1 {
                let dragged = MainActor.assumeIsolated { () -> Bool in
                    guard let header = self?.paneHeader(windowNumber: number, location: location)
                    else { return false }
                    return ColumnArrangement.drag(from: event, in: header)
                }
                if dragged { return nil }
            }

            let consumed = MainActor.assumeIsolated {
                self?.dispatch(windowNumber: number, location: location, clickCount: clicks)
                    ?? false
            }
            // Consumed only for a double-click on a link's arrow, which goes
            // to the link's target: let through, the table's own double-click
            // would open the link as well.
            return consumed ? nil : event
        }
    }

    /// The pane whose table a click landed in, and the window's model.
    private func paneHit(windowNumber: Int, location: NSPoint)
        -> (model: AppModel, table: NSTableView, pane: PaneModel)? {
        guard let window = NSApp.window(withWindowNumber: windowNumber),
              let model = models.lazy.compactMap(\.model).first(where: { $0.window === window }),
              let content = window.contentView,
              let hit = Self.view(in: content, at: location),
              !isInsideEditor(hit),
              let table = enclosingTable(of: hit),
              let index = TableFinder.tables(in: window).firstIndex(of: table)
        else { return nil }
        let tables = TableFinder.tables(in: window)
        let pane = tables.count == 1 ? model.active : (index == 0 ? model.left : model.right)
        return (model, table, pane)
    }

    /// The header of a pane's table, when the point is on it.
    private func paneHeader(windowNumber: Int, location: NSPoint) -> NSTableHeaderView? {
        guard let window = NSApp.window(withWindowNumber: windowNumber) else { return nil }
        for table in TableFinder.tables(in: window) {
            guard let header = table.headerView, header.window === window else { continue }
            if header.bounds.contains(header.convert(location, from: nil)) { return header }
        }
        return nil
    }

    /// The pane whose table has this header.
    private func pane(of header: NSTableHeaderView, windowNumber: Int) -> PaneModel? {
        guard let window = NSApp.window(withWindowNumber: windowNumber),
              let model = models.lazy.compactMap(\.model).first(where: { $0.window === window }),
              let table = header.tableView else { return nil }
        let tables = TableFinder.tables(in: window)
        guard let index = tables.firstIndex(of: table) else { return nil }
        return tables.count == 1 ? model.active : (index == 0 ? model.left : model.right)
    }

    /// Every menu a right-click on a pane opens offers New from Clipboard, for
    /// the pane clicked -- so its name can start being worked out now.
    private func anticipateNewFromClipboard(windowNumber: Int, location: NSPoint) {
        guard let (_, table, pane) = paneHit(windowNumber: windowNumber, location: location),
              isInListing(table, location)
        else { return }
        ClipboardNamePrefetcher.shared.anticipate(in: pane.directory)
    }

    /// True when the click was in a pane's empty space and a menu was shown.
    private func offerFolderMenu(windowNumber: Int, location: NSPoint) -> Bool {
        guard let (model, table, pane) = paneHit(windowNumber: windowNumber, location: location)
        else { return false }

        // The column headers have their own menu: which columns to show.
        if let header = table.headerView, header.window != nil,
           header.bounds.contains(header.convert(location, from: nil)) {
            return false
        }
        if let window = NSApp.window(withWindowNumber: windowNumber),
           let content = window.contentView,
           let hit = Self.view(in: content, at: location), isInHeader(hit) {
            return false
        }

        let point = table.convert(location, from: nil)
        // `row(at:)` answers -1 for *any* point that is not exactly on a row --
        // below the last row, but also on the column headers. Only the visible
        // listing distinguishes "inside the list, past the last row" from
        // anywhere else, and it has to be the scroll view's, not the table's
        // own `visibleRect`, which ends at the last row of a short listing.
        guard isInListing(table, location) else { return false }

        // Below the last row. On a row, SwiftUI's own menu answers.
        guard table.row(at: point) < 0 else { return false }

        FolderMenu.shared.show(for: model, pane: pane)
        return true
    }

    private func cancelPendingEdits() {
        for model in models.compactMap(\.model) { model.cancelPendingClickEdit() }
    }

    /// True when the click was spent here and must not reach the table.
    private func dispatch(windowNumber: Int, location: NSPoint, clickCount: Int) -> Bool {
        guard let window = NSApp.window(withWindowNumber: windowNumber),
              let model = models.lazy.compactMap(\.model).first(where: { $0.window === window }),
              let content = window.contentView,
              let hit = Self.view(in: content, at: location)
        else { return false }

        // While the Quick Look panel is up it is the key window, so a click in
        // here is a click into a *background* window: AppKit spends it on
        // making the window key and only delivers it to views that take a
        // first mouse. A table row does; a SwiftUI button does not -- which is
        // why selecting a file still worked while Up, Back, Forward and the
        // path bar needed two clicks and looked broken.
        //
        // This monitor runs before the event is dispatched, so making the
        // window key here happens in time for the click itself to land. The
        // preview stays open, exactly as it does when a row is clicked.
        if !window.isKeyWindow { window.makeKey() }

        // A click inside an open editor belongs to that editor.
        if isInsideEditor(hit) { return false }

        // Into the agent terminal: the keyboard goes there, and neither pane
        // is the focused one any more.
        if let terminal = enclosingTerminal(of: hit) {
            model.clickedAwayFromTable()
            // The keyboard goes with the click, as it does into a list. Left
            // where it was, Command-C copied the pane's selected *files* while
            // the person was looking at text selected in the terminal.
            if window.firstResponder !== terminal { window.makeFirstResponder(terminal) }
            terminal.onFocus?()
            // And again a turn later, after SwiftUI has finished reacting to
            // the pane losing the keyboard -- it can take it back from
            // whatever holds it, which left the cursor hollow until a second
            // click.
            DispatchQueue.main.async { [weak terminal, weak window] in
                guard let terminal, let window, window.firstResponder !== terminal else { return }
                window.makeFirstResponder(terminal)
            }
            return false
        }

        let tables = TableFinder.tables(in: window)
        guard let table = enclosingTable(of: hit), let index = tables.firstIndex(of: table) else {
            // Clicked the path bar, the toolbar, the status line: still ends an
            // edit in progress.
            model.clickedAwayFromTable()
            return false
        }

        let pane = tables.count == 1 ? model.active : (index == 0 ? model.left : model.right)

        // The keyboard follows the click into the list.
        //
        // Typing in the filter box leaves it first responder, and clicking a
        // row did not take that back: the row went grey rather than blue --
        // the selection of a list nothing is typing into -- and F5, F6 and
        // every other key still belonged to the text field, which is where
        // the key router deliberately leaves them. Clicking the other pane
        // and back was the only way out.
        if window.firstResponder !== table { window.makeFirstResponder(table) }

        // And the pane you clicked in is the one commands act on. Which pane
        // is active follows SwiftUI's own focus state, and that does not
        // notice a first responder set from AppKit -- so the row went blue
        // while F5 still copied from the other pane, which had nothing
        // selected and so did nothing at all.
        model.activate(pane)

        let point = table.convert(location, from: nil)
        let row = table.row(at: point)
        let columnIndex = table.column(at: point)

        let columns = ConfigStore.shared.configuration.columns
        let column = columns.indices.contains(columnIndex) ? columns[columnIndex] : nil
        let rowID = pane.rows.indices.contains(row) ? pane.rows[row].id : nil

        // The second click of a double-click on a link's arrow: the arrow,
        // not the row, so Go to Link Target rather than Open.
        if clickCount == 2, column == .name, let rowID, row >= 0,
           let rowView = table.rowView(atRow: row, makeIfNecessary: false),
           LinkArrowMarkerView.contains(location, in: rowView) {
            model.tableClicked(pane: pane, rowID: rowID, column: column, clickCount: clickCount)
            model.linkArrowDoubleClicked(rowID: rowID, in: pane)
            return true
        }

        // Option-click on a folder before a flat view's name: go there, the
        // cursor on what led there. Back returns to the flat view.
        if clickCount == 1, column == .name, OptionKey.shared.isDown, let rowID, row >= 0,
           let rowView = table.rowView(atRow: row, makeIfNecessary: false),
           let folder = FolderLinkMarkerView.folder(at: location, in: rowView) {
            let below = rowID.pathComponents.dropFirst(folder.pathComponents.count)
            pane.navigate(to: folder)
            if let next = below.first {
                pane.pendingSelection = [folder.appendingPathComponent(next)]
            }
            return true
        }

        model.tableClicked(pane: pane, rowID: rowID, column: column, clickCount: clickCount)
        return false
    }

    /// The list a view is part of. A short listing does not reach the bottom
    /// of its pane: the space under its last row is the scroll view's, not
    /// the table's, so the table is found through the scroll view too -- or a
    /// right-click there finds no pane, and offers no menu at all.
    /// The view a click at `location` (window coordinates) lands on.
    ///
    /// `hitTest` takes its point in the coordinates of the view's *superview*,
    /// not its own -- and the window's content view is a SwiftUI hosting view,
    /// which counts y downwards where the window counts it upwards. Passing
    /// the content view's own coordinates mirrored every click top to bottom.
    /// While the panes filled the window that went unnoticed -- left and right
    /// still came out right, and the row is worked out separately -- but with
    /// the agent terminal under them, a click on the terminal was taken for a
    /// click on a pane and the other way round, and a right-click below the
    /// last row looked for empty space somewhere else entirely.
    static func view(in content: NSView, at location: NSPoint) -> NSView? {
        let point = content.superview.map { $0.convert(location, from: nil) } ?? location
        return content.hitTest(point)
    }

    private func enclosingTable(of view: NSView) -> NSTableView? {
        var candidate: NSView? = view
        while let current = candidate {
            if let table = current as? NSTableView { return table }
            if let clip = current as? NSClipView, let table = clip.documentView as? NSTableView {
                return table
            }
            if let scroll = current as? NSScrollView,
               let table = scroll.documentView as? NSTableView {
                return table
            }
            candidate = current.superview
        }
        return nil
    }

    /// Inside the part of the pane that shows rows -- including the empty
    /// space under the last one -- rather than the column headers or anything
    /// outside the list. The clip view is that part: the table itself ends at
    /// its last row, so its own bounds would leave the empty space out.
    private func isInListing(_ table: NSTableView, _ location: NSPoint) -> Bool {
        guard let clip = table.enclosingScrollView?.contentView else {
            return table.visibleRect.contains(table.convert(location, from: nil))
        }
        return clip.bounds.contains(clip.convert(location, from: nil))
    }

    private func isInHeader(_ view: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if current is NSTableHeaderView { return true }
            candidate = current.superview
        }
        return false
    }

    private func enclosingTerminal(of view: NSView) -> DiptychTerminalView? {
        var candidate: NSView? = view
        while let current = candidate {
            if let terminal = current as? DiptychTerminalView { return terminal }
            candidate = current.superview
        }
        return nil
    }

    private func isInsideEditor(_ view: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if current is PermissionEditorView || current is NSTextField || current is NSTextView {
                return true
            }
            candidate = current.superview
        }
        return false
    }
}
