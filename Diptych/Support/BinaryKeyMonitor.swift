import AppKit

/// Keyboard for the binary view, over AppKit rather than SwiftUI.
///
/// Three attempts with `onKeyPress` produced three different failures: the plain
/// form never delivered Delete at all; the explicit key set rejected every arrow
/// because macOS stamps `.numericPad` on all four of them; and once that was
/// fixed the enclosing `ScrollView` took the arrows for its own scrolling before
/// the handler ever saw them. A local key-down monitor sees the event first and
/// answers for itself, which is the same conclusion `KeyRouter` reached for the
/// panes.
///
/// Keys are matched by virtual key code, positional and so independent of the
/// keyboard layout -- the reason `KeyRouter` does the same.
@MainActor
final class BinaryKeyMonitor {

    private var monitor: Any?
    private weak var window: NSWindow?
    private weak var model: BinaryViewModel?

    func start(window: NSWindow?, model: BinaryViewModel) {
        self.window = window
        self.model = model
        guard monitor == nil, window != nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // NSEvent is not Sendable, so only plain values cross the boundary.
            let code = event.keyCode
            let flags = event.modifierFlags
            let characters = event.charactersIgnoringModifiers ?? ""

            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                // Only while this window is the one being typed into: the
                // monitor is process-wide, and a second binary view -- or the
                // main window -- must not see these keys.
                guard let window = self.window, NSApp.keyWindow === window else { return false }
                // Never steal keys from a text field: the find box has to be
                // able to receive the very hex digits this monitor consumes.
                if let responder = window.firstResponder,
                   responder is NSText || responder.isKind(of: NSTextView.self) {
                    return false
                }
                return self.handle(code: code, flags: flags, characters: characters)
            }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(code: UInt16, flags: NSEvent.ModifierFlags, characters: String) -> Bool {
        guard let model else { return false }

        let command = flags.contains(.command)

        // The two structural commands are the only ones here that take a
        // modifier, and both are destructive enough to want one.
        if command, !flags.contains(.control), !flags.contains(.option) {
            switch code {
            case 51, 117: model.removeSelection(); return true       // Cmd-Delete
            case 44:      model.insertZeros(); return true           // Cmd-slash
            case 0:       model.selectAll(); return true             // Cmd-A
            case 6:                                                  // Cmd-Z
                guard !flags.contains(.shift) else { return false }
                model.undo()
                return true
            case 5:                                                  // Cmd-G
                flags.contains(.shift) ? model.findPrevious() : model.findNext()
                return true
            default:      return false
            }
        }

        // Control and Option mean some other command, so those go to the menu
        // bar untouched. Shift does not -- it extends the selection -- and
        // neither does the numeric-pad flag AppKit stamps on every arrow key.
        guard flags.isDisjoint(with: [.command, .control, .option]) else { return false }

        let extending = flags.contains(.shift)
        let perLine = model.columns
        switch code {
        case 123: model.moveCursor(by: -1, extending: extending)              // left
        case 124: model.moveCursor(by: 1, extending: extending)               // right
        case 126: model.moveCursor(by: -perLine, extending: extending)        // up
        case 125: model.moveCursor(by: perLine, extending: extending)         // down
        case 116: model.moveCursor(by: -perLine * 16, extending: extending)   // page up
        case 121: model.moveCursor(by: perLine * 16, extending: extending)    // page down
        case 115: model.moveCursor(to: 0, extending: extending)               // home
        case 119: model.moveCursor(to: model.count - 1, extending: extending) // end
        case 53:  model.clearTyping()                                         // escape
        // 51 is the key marked "delete" on an Apple keyboard, 117 the one
        // marked "Delete" on a PC keyboard. Both revert -- which is why only
        // one of them worked while this was matched on characters.
        case 51, 117: model.revert()
        default:
            guard let character = characters.first else { return false }
            // Leave anything that is not a digit in this base to the responder
            // chain, so Space, Tab and the rest keep their meanings.
            guard model.accepts(character) else { return false }
            model.type(character)
        }
        return true
    }
}
