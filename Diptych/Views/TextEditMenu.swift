import AppKit

/// The Format menu's items for a right-click: in the text or in the tree,
/// those that apply there, with the keys the Format menu gives them.
extension TextEditController {

    func formatMenuItems() -> [NSMenuItem] {
        let editable = textView.isEditable
        var items: [NSMenuItem] = []
        func add(_ title: String, _ action: Selector, key: String = "",
                 _ modifiers: NSEvent.ModifierFlags = .command, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            item.isEnabled = enabled
            items.append(item)
        }
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)

        if StructuredFormatter.canFormat(format) {
            add("Format Document", #selector(menuFormatDocument), key: "l", [.command, .option], enabled: editable)
        }
        if format == .json { add("Compact JSON", #selector(menuCompactJSON), enabled: editable) }
        if showsTree {
            add("Move Up", #selector(menuMoveUp), key: up, [.command, .shift], enabled: editable)
            add("Move Down", #selector(menuMoveDown), key: down, [.command, .shift], enabled: editable)
        } else {
            if [.xml, .yaml, .toml].contains(format?.markup) {
                add("Comment Lines", #selector(menuComment), key: "/", enabled: editable)
            }
            add("Move Lines Up", #selector(menuMoveUp), key: up, [.command, .shift], enabled: editable)
            add("Move Lines Down", #selector(menuMoveDown), key: down, [.command, .shift], enabled: editable)
            add("Delete Lines", #selector(menuDeleteLines), enabled: editable)
        }
        add("Go to Line\u{2026}", #selector(menuGoToLine), key: "g")
        if StructureTree.supports(format) {
            add(showsTree ? "Show as Text" : "Show as Tree", #selector(menuToggleTree), key: "t",
                [.command, .control])
        }
        return items
    }

    @objc private func menuFormatDocument() { formatDocument() }
    @objc private func menuCompactJSON() { formatDocument(compact: true) }
    @objc private func menuComment() { toggleComment() }
    @objc private func menuMoveUp() { moveUp(true) }
    @objc private func menuMoveDown() { moveUp(false) }
    @objc private func menuDeleteLines() { deleteLines() }
    @objc private func menuGoToLine() { askForLine() }
    @objc private func menuToggleTree() { link?.showsTree.toggle() }

    /// ⌘G: a line, in the text or the tree. The caret goes to its start;
    /// the tree selects the node on it and scrolls to it.
    func goToLine(_ line: Int) {
        if showsTree, let tree {
            tree.reveal(line: line)
            return
        }
        let index = min(max(line - 1, 0), lineIndex.count - 1)
        textView.setSelectedRange(NSRange(location: lineIndex.starts[index], length: 0))
        revealSelection()
        textView.scrollRangeToVisible(selectedRange)
        textView.window?.makeFirstResponder(textView)
    }

    /// The line the caret is on, or the selected node starts on.
    var currentLine: Int {
        if showsTree, let item = tree?.selectedItem { return tree?.line(of: item) ?? 1 }
        return lineIndex.line(containing: min(selectedRange.location, nsText.length)) + 1
    }

    /// A small sheet asking for the line: Go or Return jumps, Cancel or
    /// Escape does not.
    func askForLine() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "A line from 1 to \(lineIndex.count)."
        let field = NSTextField(string: String(currentLine))
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 22)
        field.alignment = .right
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
            MainActor.assumeIsolated {
                guard let line = Int(typed), line > 0 else { return NSSound.beep() }
                self?.goToLine(line)
            }
        }
    }

    /// The lines in the text; the selected node in the tree.
    func moveUp(_ up: Bool) {
        if showsTree, let tree { tree.moveSelected(up: up) } else { moveLines(up: up) }
    }
}
