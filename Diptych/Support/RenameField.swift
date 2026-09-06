import SwiftUI
import AppKit

/// The in-place editor that replaces a row's name while renaming.
///
/// AppKit rather than a SwiftUI TextField for one specific reason: Finder
/// pre-selects only the *base* name, leaving the extension intact, and SwiftUI
/// gives no way to set a selection range inside a text field.
struct RenameField: NSViewRepresentable {

    @Binding var text: String
    /// `advance` is true for Shift-Return: commit, then move to the next row.
    let onCommit: (_ advance: Bool) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 11)
        // A bezel would not fit the row height; a plain background with a focus
        // ring reads as an editor without making the row taller.
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .exterior
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail

        // The field has no window until it is in the hierarchy, one turn later.
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            if let editor = field.currentEditor() {
                let stem = (text as NSString).deletingPathExtension
                editor.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
            }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Never overwrite what the user is typing.
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {

        var parent: RenameField
        /// Return commits and also ends editing, which would otherwise fire the
        /// commit a second time through controlTextDidEndEditing.
        private var finished = false

        init(_ parent: RenameField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            // Shift-Return arrives as either of these depending on the field's
            // configuration, so both are handled and the modifier is read from
            // the event itself rather than inferred from the selector.
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertLineBreak(_:)):
                guard !finished else { return true }
                finished = true
                parent.text = control.stringValue
                let advance = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                parent.onCommit(advance)
                return true

            case #selector(NSResponder.cancelOperation(_:)):
                guard !finished else { return true }
                finished = true
                parent.onCancel()
                return true

            default:
                return false
            }
        }

        /// Clicking away commits, as Finder does.
        func controlTextDidEndEditing(_ note: Notification) {
            guard !finished else { return }
            finished = true
            if let field = note.object as? NSTextField { parent.text = field.stringValue }
            parent.onCommit(false)
        }
    }
}
