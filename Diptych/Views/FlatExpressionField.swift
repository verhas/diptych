import AppKit
import SwiftUI

/// The flat view's expression, edited: what does not parse is underlined in
/// red as it is typed, what cannot be meant in orange, Control-Space offers
/// what can come next, and Return runs it. Brown once the list no longer
/// matches it: something listed has changed since it was run.
struct FlatExpressionField: NSViewRepresentable {

    @Binding var text: String
    /// Where the caret is, in UTF-16 units, for the hint under the field.
    @Binding var caret: Int
    let problem: FlatQuery.Problem?
    var warnings: [FlatQuery.Problem] = []
    var stale = false
    /// How tall it wants to be: one line, or -- while it is being edited and
    /// the expression is longer than it is wide -- every line of it.
    @Binding var height: CGFloat
    /// Saving what is typed under a name; nil when it does not parse.
    var onSave: ((String) -> Void)? = nil
    let onRun: () -> Void

    static let lineHeight: CGFloat = 22

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        field.placeholderString = "name = \"*.swift\" and size > 10KB \u{2014} "
            + "Control-Space for what can come next"
        // Wrapping, but one line shown -- until it is edited: then all of it.
        field.usesSingleLineMode = false
        field.cell?.isScrollable = false
        field.cell?.wraps = true
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.bezelStyle = .roundedBezel
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    /// As wide as it is offered, not as wide as its placeholder.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Field,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: height)
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        let colour: NSColor = stale ? .brown : .labelColor
        if field.textColor != colour {
            field.textColor = colour
            (field.currentEditor() as? NSTextView)?.textColor = colour
        }
        (field.currentEditor() as? Editor).map { context.coordinator.underline($0) }
        context.coordinator.fit(field)
    }

    final class Field: NSTextField {
        override class var cellClass: AnyClass? {
            get { Cell.self }
            set {}
        }

        /// Wrapping before the editor is set up: it takes its lines from the
        /// field as it is at that moment.
        override func becomeFirstResponder() -> Bool {
            maximumNumberOfLines = 0
            lineBreakMode = .byWordWrapping
            return super.becomeFirstResponder()
        }
    }

    /// Gives the field an editor of its own, which completes and tracks the
    /// caret.
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

    final class Editor: NSTextView {
        var onCaret: (Int) -> Void = { _ in }
        /// The items the right-click menu starts with.
        var extraMenu: (NSTextView) -> [NSMenuItem] = { _ in [] }

        override func keyDown(with event: NSEvent) {
            // Control-Space: what can come next, as in an IDE -- and when
            // only one thing can, that, without a list to pick it from.
            if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == " " {
                let found = FlatQuery.completions(in: string, at: selectedRange().location)
                if found.words.count == 1 {
                    insertCompletion(found.words[0], forPartialWordRange: found.range,
                                     movement: NSTextMovement.other.rawValue, isFinal: true)
                } else {
                    complete(nil)
                }
                return
            }
            if typeInAccessPattern(event) { return }
            super.keyDown(with: event)
        }

        /// In the quotes of `access = "rwx------"` typing overwrites, as in
        /// the pane's permission editor: the nine places stay nine.
        private func typeInAccessPattern(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection([.command, .control, .shift, .option])
            guard !flags.contains(.command), !flags.contains(.control),
                  selectedRange().length == 0,
                  let places = FlatQuery.accessPlaces(in: string, at: selectedRange().location)
            else { return false }
            let caret = selectedRange().location - places.location
            let current = (string as NSString).substring(with: places)

            let edit: (String, Int)?
            switch event.keyCode {
            case 51:    // backspace: the place before back to either
                guard caret > 0 else { return false }
                var slots = Array(current)
                slots[caret - 1] = "*"
                edit = (String(slots), caret - 1)
            case 117:   // forward delete: the place under the caret
                guard caret < 9 else { return false }
                var slots = Array(current)
                slots[caret] = "*"
                edit = (String(slots), caret)
            default:
                // Arrows, Return, Tab: as anywhere.
                guard let key = event.charactersIgnoringModifiers?.first,
                      !key.isNewline, key != "\t",
                      key.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0xF700 })
                else { return false }
                edit = FlatQuery.typeAccess(key, in: current, at: caret,
                                            shift: flags.contains(.shift),
                                            option: flags.contains(.option))
            }
            guard let (updated, moved) = edit else {
                NSSound.beep()
                return true
            }
            if updated != current, shouldChangeText(in: places, replacementString: updated) {
                replaceCharacters(in: places, with: updated)
                didChangeText()
            }
            setSelectedRange(NSRange(location: places.location + moved, length: 0))
            return true
        }

        /// The word the caret is in, as the expression's words go -- `size`,
        /// `10KB`, `2026-01-31` -- not as prose splits them.
        override var rangeForUserCompletion: NSRange {
            FlatQuery.completions(in: string, at: selectedRange().location).range
        }

        /// A keyword chosen gets the space after it, ready for what follows.
        override func insertCompletion(_ word: String, forPartialWordRange range: NSRange,
                                       movement: Int, isFinal: Bool) {
            let spaced = isFinal && word.first?.isLetter == true ? word + " " : word
            super.insertCompletion(spaced, forPartialWordRange: range, movement: movement,
                                   isFinal: isFinal)
            // An access pattern: the caret on its first place, to type over.
            if isFinal, word == "\"\(FlatQuery.anyAccess)\"" {
                setSelectedRange(NSRange(location: range.location + 1, length: 0))
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = super.menu(for: event) ?? NSMenu()
            let extra = extraMenu(self)
            guard !extra.isEmpty else { return menu }
            for (index, item) in extra.enumerated() { menu.insertItem(item, at: index) }
            menu.insertItem(.separator(), at: extra.count)
            return menu
        }

        override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity,
                                        stillSelecting: Bool) {
            super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
            if !stillSelecting { onCaret(selectedRange().location) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FlatExpressionField

        init(_ parent: FlatExpressionField) { self.parent = parent }

        private var editing = false

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let editor = notification.userInfo?["NSFieldEditor"] as? Editor else { return }
            editor.onCaret = { [weak self] caret in
                guard let self, self.parent.caret != caret else { return }
                DispatchQueue.main.async { self.parent.caret = caret }
            }
            editor.extraMenu = { [weak self] editor in
                guard let self else { return [] }
                return self.expandMenu(editor) + self.saveMenu()
            }
            editing = true
            (notification.object as? NSTextField).map(fit)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            if let editor = notification.userInfo?["NSFieldEditor"] as? Editor {
                parent.caret = editor.selectedRange().location
            }
            fit(field)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            editing = false
            (notification.object as? NSTextField).map(fit)
        }

        /// Every line while it is edited, one otherwise.
        func fit(_ field: NSTextField) {
            var wanted = FlatExpressionField.lineHeight
            if editing, let cell = field.cell, field.bounds.width > 0 {
                field.maximumNumberOfLines = 0
                field.lineBreakMode = .byWordWrapping
                let bounds = NSRect(x: 0, y: 0, width: field.bounds.width, height: 10_000)
                wanted = max(wanted, ceil(cell.cellSize(forBounds: bounds).height))
            } else {
                field.maximumNumberOfLines = 1
                field.lineBreakMode = .byTruncatingTail
            }
            guard abs(parent.height - wanted) > 0.5 else { return }
            // Not during the update that asked: SwiftUI's state is changed
            // after it.
            let height = parent.$height
            Task { @MainActor in height.wrappedValue = wanted }
        }

        // MARK: Expanding

        /// Expand, when what is selected is a saved expression's name: the
        /// name replaced by what it stands for, to edit.
        private func expandMenu(_ editor: NSTextView) -> [NSMenuItem] {
            let range = editor.selectedRange()
            guard range.length > 0 else { return [] }
            let selected = (editor.string as NSString).substring(with: range)
            guard let expansion = FlatQuery.expansion(of: selected) else { return [] }
            let item = NSMenuItem(title: "Expand", action: #selector(expand(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = Expansion(editor: editor, range: range, text: expansion)
            item.toolTip = expansion
            return [item]
        }

        private final class Expansion: NSObject {
            weak var editor: NSTextView?
            let range: NSRange
            let text: String
            init(editor: NSTextView, range: NSRange, text: String) {
                self.editor = editor
                self.range = range
                self.text = text
            }
        }

        @objc private func expand(_ sender: NSMenuItem) {
            guard let expansion = sender.representedObject as? Expansion,
                  let editor = expansion.editor,
                  NSMaxRange(expansion.range) <= (editor.string as NSString).length,
                  editor.shouldChangeText(in: expansion.range,
                                          replacementString: expansion.text) else { return }
            editor.replaceCharacters(in: expansion.range, with: expansion.text)
            editor.didChangeText()
            // What came in, selected: ready to edit, and plain to see.
            editor.setSelectedRange(NSRange(location: expansion.range.location,
                                            length: (expansion.text as NSString).length))
        }

        // MARK: Saving

        /// Save Expression: the names already in use, to replace one, and a
        /// new one. Only an expression that parses can be saved.
        private func saveMenu() -> [NSMenuItem] {
            let item = NSMenuItem(title: "Save Expression", action: nil, keyEquivalent: "")
            guard parent.onSave != nil else {
                item.isEnabled = false
                item.toolTip = "Only an expression that parses can be saved"
                return [item]
            }
            let menu = NSMenu()
            let fresh = NSMenuItem(title: "New Name\u{2026}", action: #selector(askForName),
                                   keyEquivalent: "")
            fresh.target = self
            menu.addItem(fresh)
            let names = FlatFilterStore.shared.names()
            if !names.isEmpty {
                menu.addItem(.separator())
                let heading = NSMenuItem(title: "Replace", action: nil, keyEquivalent: "")
                heading.isEnabled = false
                menu.addItem(heading)
            }
            for name in names {
                let replace = NSMenuItem(title: name, action: #selector(saveAs(_:)),
                                         keyEquivalent: "")
                replace.target = self
                replace.representedObject = name
                replace.toolTip = FlatFilterStore.shared.saved(name)?.expression
                menu.addItem(replace)
            }
            item.submenu = menu
            return [item]
        }

        @objc private func saveAs(_ sender: NSMenuItem) {
            guard let name = sender.representedObject as? String else { return }
            parent.onSave?(name)
        }

        @objc private func askForName() {
            let alert = NSAlert()
            alert.messageText = "Save Expression"
            alert.informativeText = "A name to use it by, alone or as part of another "
                + "expression: a letter, then letters, digits, _ or -."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
            alert.accessoryView = field
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            while alert.runModal() == .alertFirstButtonReturn {
                let name = field.stringValue.trimmingCharacters(in: .whitespaces)
                if let problem = FlatFilterStore.problem(with: name) {
                    alert.informativeText = problem + "."
                    continue
                }
                parent.onSave?(name)
                return
            }
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = textView.string
                parent.onRun()
                return true
            }
            return false
        }

        func control(_ control: NSControl, textView: NSTextView,
                     completions words: [String], forPartialWordRange range: NSRange,
                     indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
            index.pointee = -1
            return FlatQuery.completions(in: textView.string,
                                         at: textView.selectedRange().location).words
        }

        /// The problem's place underlined in red -- or, with none, the
        /// warnings' in orange -- without touching the text itself; at the
        /// very end, where something is missing, the last character carries
        /// it.
        func underline(_ editor: NSTextView) {
            guard let layout = editor.layoutManager else { return }
            let length = (editor.string as NSString).length
            let all = NSRange(location: 0, length: length)
            layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: all)
            layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: all)
            guard length > 0 else { return }
            let marks: [(FlatQuery.Problem, NSColor)] = parent.problem.map { [($0, .systemRed)] }
                ?? parent.warnings.map { ($0, .systemOrange) }
            for (problem, colour) in marks {
                var range = problem.range
                if range.length == 0 || NSMaxRange(range) > length {
                    range = NSRange(location: max(min(range.location, length) - 1, 0), length: 1)
                }
                layout.addTemporaryAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue
                        | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: colour,
                ], forCharacterRange: range)
            }
        }
    }
}
