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
                let handled = MainActor.assumeIsolated {
                    self?.offerFolderMenu(windowNumber: number, location: location) ?? false
                }
                return handled ? nil : event
            }
            // Only Sendable values cross the boundary; NSEvent itself cannot.
            let location = event.locationInWindow
            let number = event.windowNumber
            let clicks = event.clickCount

            MainActor.assumeIsolated {
                self?.dispatch(windowNumber: number, location: location, clickCount: clicks)
            }
            return event   // never consumed
        }
    }

    /// True when the click was in a pane's empty space and a menu was shown.
    private func offerFolderMenu(windowNumber: Int, location: NSPoint) -> Bool {
        guard let window = NSApp.window(withWindowNumber: windowNumber),
              let model = models.lazy.compactMap(\.model).first(where: { $0.window === window }),
              let content = window.contentView,
              let hit = content.hitTest(content.convert(location, from: nil)),
              !isInsideEditor(hit),
              let table = enclosingTable(of: hit),
              let index = TableFinder.tables(in: window).firstIndex(of: table)
        else { return false }

        // Below the last row. On a row, SwiftUI's own menu answers.
        guard table.row(at: table.convert(location, from: nil)) < 0 else { return false }

        let tables = TableFinder.tables(in: window)
        let pane = tables.count == 1 ? model.active : (index == 0 ? model.left : model.right)
        FolderMenu.shared.show(for: model, pane: pane)
        return true
    }

    private func cancelPendingEdits() {
        for model in models.compactMap(\.model) { model.cancelPendingClickEdit() }
    }

    private func dispatch(windowNumber: Int, location: NSPoint, clickCount: Int) {
        guard let window = NSApp.window(withWindowNumber: windowNumber),
              let model = models.lazy.compactMap(\.model).first(where: { $0.window === window }),
              let content = window.contentView,
              let hit = content.hitTest(content.convert(location, from: nil))
        else { return }

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
        if isInsideEditor(hit) { return }

        let tables = TableFinder.tables(in: window)
        guard let table = enclosingTable(of: hit), let index = tables.firstIndex(of: table) else {
            // Clicked the path bar, the toolbar, the status line: still ends an
            // edit in progress.
            model.clickedAwayFromTable()
            return
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

        model.tableClicked(pane: pane, rowID: rowID, column: column, clickCount: clickCount)
    }

    private func enclosingTable(of view: NSView) -> NSTableView? {
        var candidate: NSView? = view
        while let current = candidate {
            if let table = current as? NSTableView { return table }
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
