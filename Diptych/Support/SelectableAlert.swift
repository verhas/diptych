import AppKit

extension NSAlert {

    /// `runModal()`, with the title and the message selectable, so what an
    /// alert says can be copied -- an error passed on, a path looked up.
    /// NSAlert has no setting for it: its labels are found once it is laid out.
    @discardableResult
    func runSelectable() -> NSApplication.ModalResponse {
        layout()
        if let content = window.contentView { Self.makeSelectable(content) }
        return runModal()
    }

    private static func makeSelectable(_ view: NSView) {
        if let label = view as? NSTextField, !label.isEditable {
            label.isSelectable = true
        }
        view.subviews.forEach(makeSelectable)
    }
}
