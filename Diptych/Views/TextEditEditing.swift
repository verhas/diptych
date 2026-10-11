import AppKit

/// Text Edit's editing beyond typing: by lines, by indentation, in pairs,
/// formatting -- each an undoable change through the text view.
extension TextEditController {

    var style: TextStyle { ConfigStore.shared.configuration.textStyle }
    var indent: LineEditing.Indent { style.indent(for: format) }

    /// Replacements in the text as one step of Undo, then the selection.
    @discardableResult
    func change(_ changes: [TextChange], select selection: NSRange?, named name: String) -> Bool {
        guard textView.isEditable, !changes.isEmpty, let storage = textView.textStorage else { return false }
        let undo = textView.undoManager
        textView.breakUndoCoalescing()
        undo?.beginUndoGrouping()
        for change in changes.sorted(by: { $0.range.location > $1.range.location })
        where textView.shouldChangeText(in: change.range, replacementString: change.text) {
            storage.replaceCharacters(in: change.range, with: change.text)
            textView.didChangeText()
        }
        undo?.setActionName(name)
        undo?.endUndoGrouping()
        textView.breakUndoCoalescing()
        if let selection {
            let length = nsText.length
            let location = min(selection.location, length)
            let range = NSRange(location: location, length: min(selection.length, length - location))
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
        }
        return true
    }

    @discardableResult
    func perform(_ edit: LineEditing.Edit?, named name: String) -> Bool {
        guard let edit else { return false }
        return change([TextChange(range: edit.range, text: edit.replacement)], select: edit.selection, named: name)
    }

    /// A tab as wide as Settings' indentation for the format.
    func applyTabWidth() {
        guard let font = textView.font, let storage = textView.textStorage else { return }
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = space * CGFloat(indent.width)
        guard textView.defaultParagraphStyle?.defaultTabInterval != paragraph.defaultTabInterval else { return }
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes[.paragraphStyle] = paragraph
        storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
    }

    // MARK: - Lines

    func moveLines(up: Bool) {
        if !perform(LineEditing.move(selectedRange, in: nsText, up: up), named: "Move Lines") { NSSound.beep() }
    }

    func deleteLines() {
        perform(LineEditing.delete(selectedRange, in: nsText), named: "Delete Line")
    }

    static let linePasteboardType = NSPasteboard.PasteboardType("dev.verhas.diptych.line")

    /// Command-C or -X with nothing selected: the whole line, marked as one
    /// so that pasting it goes in above a line rather than into it.
    func copyLine(cutting: Bool) -> Bool {
        guard selectedRange.length == 0 else { return false }
        let line = LineEditing.wholeLine(at: selectedRange.location, in: nsText)
        let board = pasteboard
        board.clearContents()
        board.declareTypes([.string, Self.linePasteboardType], owner: nil)
        board.setString(line.text, forType: .string)
        board.setString(line.text, forType: Self.linePasteboardType)
        if cutting { deleteLines() }
        return true
    }

    func pasteLine() -> Bool {
        let board = pasteboard
        guard selectedRange.length == 0, let marked = board.string(forType: Self.linePasteboardType),
              board.string(forType: .string) == marked else { return false }
        return perform(LineEditing.pasteLine(marked, at: selectedRange.location, in: nsText), named: "Paste")
    }

    // MARK: - Indentation and pairs

    func newline() {
        perform(LineEditing.newline(at: selectedRange, in: nsText, format: format, indent: indent),
                named: "Typing")
    }

    func tab() {
        let selection = selectedRange
        let block = LineEditing.lines(of: selection, in: nsText)
        let spansLines = selection.length > 0
            && nsText.substring(with: selection).contains("\n")
            || (selection.length > 0 && selection == block)
        if spansLines {
            perform(LineEditing.shift(selection, in: nsText, by: indent, outwards: false), named: "Indent")
        } else {
            textView.insertText(indent.unit, replacementRange: selection)
        }
    }

    func backtab() {
        if !perform(LineEditing.shift(selectedRange, in: nsText, by: indent, outwards: true), named: "Outdent") {
            NSSound.beep()
        }
    }

    /// A character typed that closes a pair, steps over one, or takes the
    /// line a level out. False: type it as it is.
    func typed(_ text: String) -> Bool {
        perform(LineEditing.typing(text, at: selectedRange, in: nsText, format: format, indent: indent,
                                   pairs: style.closePairs), named: "Typing")
    }

    /// Delete between `{}` takes both; in the spaces that indent a line, back
    /// to the level before.
    func deleteBackward() -> Bool {
        if perform(LineEditing.deletingPair(at: selectedRange, in: nsText, pairs: style.closePairs && format != nil),
                   named: "Typing") {
            return true
        }
        let selection = selectedRange
        guard selection.length == 0, !indent.tabs, indent.width > 1 else { return false }
        let lineStart = nsText.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let before = nsText.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        guard before.count >= 2, before.allSatisfy({ $0 == " " }) else { return false }
        let remove = (before.count - 1) % indent.width + 1
        return perform(LineEditing.Edit(range: NSRange(location: selection.location - remove, length: remove),
                                        replacement: "",
                                        selection: NSRange(location: selection.location - remove, length: 0)),
                       named: "Typing")
    }

    func toggleComment() {
        if !perform(LineEditing.toggleComment(selectedRange, in: nsText, format: format), named: "Comment") {
            NSSound.beep()
        }
    }

    // MARK: - Format

    var canFormat: Bool { StructuredFormatter.canFormat(format) && textView.isEditable }

    /// Format ▸ Format Document, or Compact JSON. The caret stays by what is
    /// written before it, since only the spaces between change.
    func formatDocument(compact: Bool = false) {
        let text = textView.string
        let result = compact ? StructuredFormatter.compact(text)
            : StructuredFormatter.format(text, as: format, style: style)
        switch result {
        case .success(let formatted):
            guard formatted != text else { return }
            let caret = Self.significant(before: selectedRange.location, in: nsText)
            let length = (formatted as NSString).length
            change([TextChange(range: NSRange(location: 0, length: nsText.length), text: formatted)],
                   select: NSRange(location: 0, length: 0), named: compact ? "Compact" : "Format")
            let location = Self.location(afterSignificant: caret, in: formatted as NSString)
            textView.setSelectedRange(NSRange(location: min(location, length), length: 0))
            textView.scrollRangeToVisible(selectedRange)
        case .failure(.invalid(let problem)):
            let alert = NSAlert()
            alert.messageText = "Not formatted: the file is not valid \(format?.title ?? "")."
            alert.informativeText = "Line \(problem.line), column \(problem.column): \(problem.message)"
            alert.addButton(withTitle: "Show")
            alert.addButton(withTitle: "Cancel")
            if alert.runSelectable() == .alertFirstButtonReturn { revealProblem() }
        case .failure(.notFormattable):
            NSSound.beep()
        }
    }

    nonisolated static func significant(before location: Int, in text: NSString) -> Int {
        var count = 0
        for i in 0..<min(location, text.length) where !isSpace(text.character(at: i)) { count += 1 }
        return count
    }

    nonisolated static func location(afterSignificant count: Int, in text: NSString) -> Int {
        var seen = 0
        var i = 0
        while i < text.length, seen < count {
            if !isSpace(text.character(at: i)) { seen += 1 }
            i += 1
        }
        // Before what comes next, not at the end of the spaces after.
        while i < text.length, isSpace(text.character(at: i)) { i += 1 }
        return i
    }

    nonisolated static func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
}
