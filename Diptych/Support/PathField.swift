import SwiftUI
import AppKit

/// The path bar's editor, with shell-style completion.
///
/// AppKit rather than a SwiftUI `TextField` for the same reason as
/// `RenameField`: this needs a selection range and a per-range text colour, and
/// SwiftUI offers neither. The completion is inserted into the field and left
/// *selected*, so the next keystroke replaces it -- which is what makes typing
/// straight through a suggestion behave the way a shell does -- and the
/// selection is drawn in grey rather than the usual blue, so it reads as a
/// suggestion rather than as text you have chosen.
struct PathField: NSViewRepresentable {

    @Binding var text: String
    /// Select the whole path rather than putting the caret at its end.
    let selectsAll: Bool
    /// Where the pane is standing. Anything typed that does not start with `/`
    /// or `~` is resolved against it, so a bare name is a child of here.
    let base: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = CompletingTextField(string: text)
        field.delegate = context.coordinator
        field.coordinator = context.coordinator
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingHead
        field.focusRingType = .exterior

        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            // AppKit selects everything by default, which is right for "go
            // somewhere else" and wrong for "go somewhere below here": the path
            // bar opens holding the current directory and a trailing slash, so
            // for the latter the caret belongs at the end, ready for a child's
            // name rather than poised to wipe the lot.
            let length = (field.stringValue as NSString).length
            field.currentEditor()?.selectedRange = selectsAll
                ? NSRange(location: 0, length: length)
                : NSRange(location: length, length: 0)
            context.coordinator.styleEditor(of: field)
            context.coordinator.recolour(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Never while the user is typing: assigning stringValue would drop the
        // selection, and the selection is where the pending completion lives.
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
            context.coordinator.recolour(field)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {

        var parent: PathField
        /// Set while a delete is being handled, so the suggestion does not grow
        /// straight back. Without it every backspace put the completion it had
        /// just removed back on the end, and the text could not be shortened.
        var suppressSuggestion = false

        init(_ parent: PathField) {
            self.parent = parent
        }

        /// Grey on a soft background rather than white on blue: a pending
        /// completion is a suggestion, not a selection the user made.
        func styleEditor(of field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .foregroundColor: NSColor.secondaryLabelColor,
                .backgroundColor: NSColor.quaternaryLabelColor,
            ]
        }

        /// Red while the text does not name a directory that exists, so a typo
        /// is visible before Return rather than after it.
        ///
        /// Judged on the *whole* field, suggestion included, because that is
        /// what Return commits. Judging only the typed part left `~/Dow` red
        /// while the field plainly read `~/Downloads/` and Return would have
        /// worked -- and left it red after a click moved the cursor, since the
        /// text had not changed and nothing recoloured it.
        func recolour(_ field: NSTextField) {
            let whole = field.stringValue
            let valid = whole.isEmpty || PathCompletion.isDirectory(whole, base: parent.base)
            let colour: NSColor = valid ? .labelColor : .systemRed
            field.textColor = colour
            if let editor = field.currentEditor() as? NSTextView {
                editor.textColor = colour
                // The suggestion keeps its own colour whatever the rest is.
                styleEditor(of: field)
            }
        }

        /// What the user has actually typed: the field's text without any
        /// completion still sitting selected at the end of it.
        func committedText(of field: NSTextField) -> String {
            guard let editor = field.currentEditor() else { return field.stringValue }
            let all = field.stringValue as NSString
            let selected = editor.selectedRange
            guard selected.length > 0, selected.upperBound == all.length else {
                return field.stringValue
            }
            return all.substring(to: selected.location)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = committedText(of: field)
            // Deliberately no recolour here. The suggestion lands a runloop
            // turn later and usually makes the path valid, so colouring now
            // would flash red on every keystroke of a name that completes.
            // Whoever settles the text does the colouring.
        }

        /// Tab completes, and completes again inside what it just completed.
        func complete(in field: NSTextField) {
            let typed = committedText(of: field)
            guard let completed = PathCompletion.complete(typed, base: parent.base) else {
                NSSound.beep()
                return
            }

            field.stringValue = completed
            parent.text = completed
            if let editor = field.currentEditor() {
                editor.selectedRange = NSRange(location: (completed as NSString).length, length: 0)
            }
            recolour(field)
        }

        /// Shows what Tab would add, without committing to it.
        func suggest(in field: NSTextField) {
            let typed = committedText(of: field)
            let suffix = PathCompletion.suffix(for: typed, base: parent.base)
            guard !suffix.isEmpty else {
                if field.stringValue != typed {
                    field.stringValue = typed
                    if let editor = field.currentEditor() {
                        editor.selectedRange = NSRange(location: (typed as NSString).length,
                                                       length: 0)
                    }
                }
                recolour(field)
                return
            }
            field.stringValue = typed + suffix
            if let editor = field.currentEditor() {
                editor.selectedRange = NSRange(location: (typed as NSString).length,
                                               length: (suffix as NSString).length)
            }
            styleEditor(of: field)
            // The suggestion usually makes the path valid, so the colour has to
            // be reconsidered after it lands, not before.
            recolour(field)
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            guard let field = control as? NSTextField else { return false }
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                complete(in: field)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                // Take the suggestion with it: what is on screen is what was
                // meant, and leaving it selected would submit only the typed
                // part.
                parent.text = field.stringValue
                parent.onCommit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.moveRight(_:)),
                 #selector(NSResponder.moveToEndOfLine(_:)):
                // Right arrow accepts the suggestion, as it does in a browser
                // address bar.
                if textView.selectedRange.length > 0 {
                    parent.text = field.stringValue
                    textView.selectedRange = NSRange(location: (field.stringValue as NSString).length,
                                                     length: 0)
                    recolour(field)
                    return true
                }
                return false
            case #selector(NSResponder.deleteBackward(_:)),
                 #selector(NSResponder.deleteForward(_:)),
                 #selector(NSResponder.deleteWordBackward(_:)),
                 #selector(NSResponder.deleteToBeginningOfLine(_:)):
                suppressSuggestion = true
                return false
            default:
                return false
            }
        }
    }
}

/// An NSTextField that offers a suggestion after every keystroke.
///
/// Done here rather than in `controlTextDidChange`, because that fires *before*
/// the field editor has settled and inserting text from inside it re-enters the
/// notification.
private final class CompletingTextField: NSTextField {

    weak var coordinator: PathField.Coordinator?

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        // Only when adding to the end. Suggesting while someone is deleting
        // fights them: every backspace would grow the text back.
        guard let coordinator else { return }
        guard !coordinator.suppressSuggestion else {
            coordinator.suppressSuggestion = false
            coordinator.recolour(self)
            return
        }
        guard let editor = currentEditor(),
              editor.selectedRange.length == 0,
              editor.selectedRange.location == (stringValue as NSString).length else {
            // Typing in the middle: no suggestion, but the text changed and the
            // colour still has to follow it.
            coordinator.recolour(self)
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.coordinator?.suggest(in: self)
        }
    }
}
