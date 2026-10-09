import AppKit
import SwiftUI

/// A latitude or longitude, where an o typed is the degree sign at once.
///
/// Not a SwiftUI `TextField`: one being typed into does not show a change
/// its binding makes until it loses the keyboard, so the o stayed an o on
/// screen. Here the o is replaced in the text being edited, the caret where
/// it was.
struct CoordinateField: NSViewRepresentable {

    let text: String
    let prompt: String
    var dimmed = false
    let onChange: (String) -> Void
    /// Clicked or tabbed into.
    var onFocus: () -> Void = {}
    /// Text pasted or dropped in: true when it was taken for something else
    /// -- a whole place -- and is not to be put in the field.
    var onPaste: (String) -> Bool = { _ in false }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.stringValue = text
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.onFocus = onFocus
        field.onPaste = onPaste
        field.placeholderString = prompt
        field.textColor = dimmed ? .secondaryLabelColor : .labelColor
        // The format going round changes it under the typing too.
        if field.stringValue != text { field.stringValue = text }
    }

    /// An o or an O as the degree sign. Both are one UTF-16 unit, as the
    /// sign is, so every place in the text stays where it was.
    nonisolated static func degrees(_ text: String) -> String {
        text.replacingOccurrences(of: "o", with: "\u{00B0}")
            .replacingOccurrences(of: "O", with: "\u{00B0}")
    }

    final class Field: NSTextField {
        var onFocus: () -> Void = {}
        var onPaste: (String) -> Bool = { _ in false }

        override class var cellClass: AnyClass? {
            get { Cell.self }
            set {}
        }

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { onFocus() }
            return became
        }
    }

    /// Gives the field an editor of its own, which has Paste.
    final class Cell: NSTextFieldCell {
        private var editor: PasteEditor?

        override func fieldEditor(for controlView: NSView) -> NSTextView? {
            if editor == nil {
                let editor = PasteEditor()
                editor.isFieldEditor = true
                self.editor = editor
            }
            return editor
        }
    }

    /// Edit ▸ Paste offers the text to the field's `onPaste` first: a place
    /// copied from a map is taken whole, not put in the field.
    final class PasteEditor: NSTextView {
        override func paste(_ sender: Any?) {
            if let text = NSPasteboard.general.string(forType: .string),
               let field = delegate as? Field, field.onPaste(text) {
                return
            }
            super.paste(sender)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CoordinateField

        init(_ parent: CoordinateField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView {
                let typed = editor.string
                let replaced = CoordinateField.degrees(typed)
                if replaced != typed {
                    let selection = editor.selectedRanges
                    editor.string = replaced
                    editor.selectedRanges = selection
                }
                parent.onChange(replaced)
            } else {
                parent.onChange(field.stringValue)
            }
        }
    }
}
