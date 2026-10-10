import AppKit
import SwiftUI

/// A text field whose Control-Space offers values from a list -- the EXIF
/// editor's camera and lens makes and models. What is typed narrows the
/// list: the values that start with it first, then those that hold it.
struct SuggestingField: NSViewRepresentable {

    let text: String
    let prompt: String
    var dimmed = false
    let onChange: (String) -> Void
    /// Clicked or tabbed into.
    var onFocus: () -> Void = {}
    /// Asked at each Control-Space, so it follows the field beside it.
    let values: () -> [String]

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
        field.placeholderString = prompt
        field.toolTip = "Control-Space for the usual values"
        field.textColor = dimmed ? .secondaryLabelColor : .labelColor
        if field.stringValue != text { field.stringValue = text }
    }

    /// `values` that go with `typed`: all of them for nothing typed; else
    /// those starting with it, then those holding it, case aside.
    nonisolated static func matches(_ typed: String, in values: [String]) -> [String] {
        let typed = typed.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return values }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let starting = values.filter {
            $0.range(of: typed, options: options.union(.anchored)) != nil
        }
        let holding = values.filter {
            $0.range(of: typed, options: options) != nil && !starting.contains($0)
        }
        return starting + holding
    }

    final class Field: NSTextField {
        var onFocus: () -> Void = {}

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

    final class Cell: NSTextFieldCell {
        private var editor: Editor?

        override func fieldEditor(for controlView: NSView) -> NSTextView? {
            if editor == nil {
                let editor = Editor()
                editor.isFieldEditor = true
                self.editor = editor
            }
            return editor
        }
    }

    /// The whole field is the word completed: a model is `Canon EOS R5`,
    /// spaces and all.
    final class Editor: NSTextView {
        override func keyDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == " " {
                var chosen = -1
                let words = completions(forPartialWordRange: rangeForUserCompletion,
                                        indexOfSelectedItem: &chosen) ?? []
                if words.count == 1 {
                    insertCompletion(words[0], forPartialWordRange: rangeForUserCompletion,
                                     movement: NSTextMovement.other.rawValue, isFinal: true)
                } else {
                    complete(nil)
                }
                return
            }
            super.keyDown(with: event)
        }

        override var rangeForUserCompletion: NSRange {
            NSRange(location: 0, length: (string as NSString).length)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SuggestingField

        init(_ parent: SuggestingField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView,
                     completions words: [String], forPartialWordRange range: NSRange,
                     indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
            index.pointee = -1
            return SuggestingField.matches(textView.string, in: parent.values())
        }
    }
}
