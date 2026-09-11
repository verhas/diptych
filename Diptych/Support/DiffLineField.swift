import SwiftUI
import AppKit

/// One editable line of a comparison.
///
/// AppKit rather than a SwiftUI `TextField` for the same reason `RenameField`
/// is: the caret. `control(_:textView:doCommandBy:)` hands over the text view,
/// and its selected range is the only way to know *where* in the line Return
/// was pressed -- without which Return can only append a line rather than split
/// the one you are in, and Backspace at the start of a line cannot join it to
/// the one above.
struct DiffLineField: NSViewRepresentable {

    @Binding var text: String
    /// The caret left the line: this is the moment the document is changed and
    /// the alignment recomputed, never on a keystroke -- rows shifting under a
    /// moving cursor make the window unusable.
    let onFinish: (String) -> Void
    /// Return, with where the caret was.
    let onSplit: (String, Int) -> Void
    /// Backspace with the caret at the very start and nothing selected.
    let onJoin: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        // No makeFirstResponder here, unlike RenameField: every visible line of
        // the editable side is one of these, and a field that grabs focus on
        // creation would fight every other one for it while scrolling.
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Never overwrite what is being typed.
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {

        var parent: DiffLineField
        private var handled = false

        init(_ parent: DiffLineField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            // The binding follows every keystroke so the field keeps its own
            // text; the *document* is only told when editing ends.
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertLineBreak(_:)):
                handled = true
                parent.onSplit(control.stringValue, textView.selectedRange().location)
                return true

            case #selector(NSResponder.deleteBackward(_:)):
                let range = textView.selectedRange()
                guard range.location == 0, range.length == 0 else { return false }
                handled = true
                parent.onJoin()
                return true

            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            guard !handled else {
                handled = false
                return
            }
            guard let field = note.object as? NSTextField else { return }
            parent.onFinish(field.stringValue)
        }
    }
}
