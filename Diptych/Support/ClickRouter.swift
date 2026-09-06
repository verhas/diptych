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

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] event in
            // A drag begins with a mouse-down on a row that is usually already
            // selected -- which is exactly the gesture that starts a rename.
            // Dragging must cancel that, or the row is left in an editor that
            // nothing can dismiss.
            if event.type == .leftMouseDragged {
                MainActor.assumeIsolated { self?.cancelPendingEdits() }
                return event
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

    private func cancelPendingEdits() {
        for model in models.compactMap(\.model) { model.cancelPendingClickEdit() }
    }

    private func dispatch(windowNumber: Int, location: NSPoint, clickCount: Int) {
        guard let window = NSApp.window(withWindowNumber: windowNumber),
              let model = models.lazy.compactMap(\.model).first(where: { $0.window === window }),
              let content = window.contentView,
              let hit = content.hitTest(content.convert(location, from: nil))
        else { return }

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
