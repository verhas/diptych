import AppKit

extension NSAlert {

    /// `runModal()`, with the title and the message selectable, so what an
    /// alert says can be copied -- an error passed on, a path looked up.
    /// NSAlert has no setting for it: its labels are found once it is laid out.
    @discardableResult
    func runSelectable() -> NSApplication.ModalResponse {
        layout()
        if let content = window.contentView { Self.makeSelectable(content) }
        // Command-C and Command-A on the text selected: the menu bar's Copy
        // is the Files menu's, which copies the files selected in the pane
        // behind the alert -- or, while the alert is modal, nothing at all.
        let alertWindow = window
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === alertWindow,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  let text = alertWindow.firstResponder as? NSText else { return event }
            switch event.charactersIgnoringModifiers {
            case "c": text.copy(nil)
            case "a": text.selectAll(nil)
            default:  return event
            }
            return nil
        }
        defer { monitor.map(NSEvent.removeMonitor) }
        return runModal()
    }

    private static func makeSelectable(_ view: NSView) {
        if let label = view as? NSTextField, !label.isEditable {
            label.isSelectable = true
        }
        view.subviews.forEach(makeSelectable)
    }
}
