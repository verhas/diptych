import XCTest
@testable import Diptych

/// Text Edit's window as it is used: keys through the text view, the tree
/// through its controller, Undo through the window's undo manager.
@MainActor
final class TextEditEditingTests: XCTestCase {

    private var folder: URL!
    private var window: NSWindow?
    private var coordinator: PlainTextEditor.Coordinator?
    /// As a SwiftUI window has: one undo manager for the window.
    @MainActor private final class Undoing: NSObject, NSWindowDelegate {
        let manager = UndoManager()
        func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { manager }
    }
    private let undoing = Undoing()
    private let board = NSPasteboard(name: NSPasteboard.Name("TextEditEditingTests-\(UUID().uuidString)"))

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextEditEditingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        window?.close()
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: folder)
    }

    private func editor(_ name: String, _ text: String) -> TextEditController {
        let document = TextEditDocument(url: folder.appendingPathComponent(name))
        let controller = TextEditController(document: document)
        let coordinator = PlainTextEditor.Coordinator(document: document)
        coordinator.controller = controller
        controller.textView.delegate = coordinator
        controller.pasteboard = board
        controller.textView.allowsUndo = true
        self.coordinator = coordinator
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.delegate = undoing
        undoing.manager.groupsByEvent = false
        controller.view.frame = window.contentLayoutRect
        window.contentView = controller.view
        self.window = window
        controller.loaded(text: text)
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        return controller
    }

    private func caret(_ controller: TextEditController, at location: Int) {
        controller.textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    func testLinesMoveAndAreDeletedAndUndone() throws {
        let controller = editor("a.txt", "one\ntwo\nthree\n")
        let view = controller.textView
        caret(controller, at: 5)
        view.moveToBeginningOfDocumentAndModifySelection(nil)
        XCTAssertEqual(view.string, "two\none\nthree\n")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
        view.moveToEndOfDocumentAndModifySelection(nil)
        view.moveToEndOfDocumentAndModifySelection(nil)
        XCTAssertEqual(view.string, "one\nthree\ntwo\n")
        view.deleteToBeginningOfLine(nil)
        XCTAssertEqual(view.string, "one\nthree\n")
        let undo = try XCTUnwrap(view.undoManager)
        undo.undo()
        XCTAssertEqual(view.string, "one\nthree\ntwo\n")
        undo.undo()
        undo.undo()
        undo.undo()
        XCTAssertEqual(view.string, "one\ntwo\nthree\n")
    }

    func testCopyAndCutWithNothingSelectedTakeTheLine() {
        let controller = editor("a.txt", "one\ntwo\nthree")
        let view = controller.textView
        caret(controller, at: 5)
        view.copy(nil)
        XCTAssertEqual(board.string(forType: .string), "two\n")
        XCTAssertEqual(view.string, "one\ntwo\nthree")
        caret(controller, at: 1)
        view.paste(nil)
        XCTAssertEqual(view.string, "two\none\ntwo\nthree", "above the caret's line")
        XCTAssertEqual(view.selectedRange().location, 5, "the caret stays with its text")
        caret(controller, at: 13)
        view.cut(nil)
        XCTAssertEqual(view.string, "two\none\ntwo")
        XCTAssertEqual(board.string(forType: .string), "three\n")
        view.setSelectedRange(NSRange(location: 0, length: 3))
        view.copy(nil)
        XCTAssertEqual(board.string(forType: .string), "two", "a selection is copied as it is")
        XCTAssertNil(board.string(forType: TextEditController.linePasteboardType))
    }

    func testTypingInJSON() {
        let controller = editor("a.json", "")
        let view = controller.textView
        // Typing groups its undo by the event, which a test has none of.
        view.allowsUndo = false
        view.insertText("{", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "{}")
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "{\n  \n}")
        view.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "{\n  \"a\"\n}", "the closing quote typed over")
        view.insertTab(nil)
        XCTAssertEqual(view.string, "{\n  \"a\"  \n}")
        view.deleteBackward(nil)
        XCTAssertEqual(view.string, "{\n  \"a\" \n}")
    }

    func testTheContextMenuHasTheClipboardAndTheLines() throws {
        let controller = editor("a.txt", "x")
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                     timestamp: 0, windowNumber: 0, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertEqual(controller.textView.menu(for: event)?.items.map(\.title),
                       ["Cut", "Copy", "Paste", "", "Move Lines Up", "Move Lines Down", "Delete Lines", "Go to Line\u{2026}"],
                       "no fonts, spelling or services")
    }

    func testFormatDocumentIsOneUndo() throws {
        let controller = editor("a.json", "{\"a\":[1,2]}")
        controller.textView.setSelectedRange(NSRange(location: 6, length: 0))
        controller.formatDocument()
        XCTAssertEqual(controller.textView.string, "{\n  \"a\": [\n    1,\n    2\n  ]\n}")
        XCTAssertEqual(controller.nsText.substring(from: controller.selectedRange.location).first, "1",
                       "the caret by what is written before it")
        try XCTUnwrap(controller.textView.undoManager).undo()
        XCTAssertEqual(controller.textView.string, "{\"a\":[1,2]}")
    }

    func testTheTreeEditsTheTextAndUndoTakesItBack() throws {
        let controller = editor("a.json", "{\n  \"a\": 1,\n  \"b\": [true]\n}\n")
        controller.setTreeShown(true)
        let tree = try XCTUnwrap(controller.tree)
        XCTAssertTrue(controller.scrollView.isHidden)
        XCTAssertEqual(tree.outline.numberOfRows, 4, "root, a, b and its item, open")
        tree.rename(try XCTUnwrap(tree.item(at: [0, 0])), to: "x")
        XCTAssertEqual(controller.textView.string, "{\n  \"x\": 1,\n  \"b\": [true]\n}\n")
        XCTAssertTrue(tree.move([0, 0], into: [0, 1], at: 1))
        XCTAssertEqual(controller.textView.string, "{\n  \"b\": [true, 1]\n}\n")
        XCTAssertEqual(tree.selectedItem?.path, [0, 0, 1], "the moved node chosen")
        tree.add(.string, into: [0], at: 1)
        XCTAssertEqual(controller.textView.string, "{\n  \"b\": [true, 1],\n  \"key\": \"\"\n}\n")
        let undo = try XCTUnwrap(controller.textView.undoManager)
        undo.undo()
        undo.undo()
        XCTAssertEqual(controller.textView.string, "{\n  \"x\": 1,\n  \"b\": [true]\n}\n", "a move is one step")
        XCTAssertNotNil(tree.item(at: [0, 0]), "the tree read again")
        XCTAssertEqual(tree.item(at: [0, 0])?.node.key, "x")
        controller.setTreeShown(false)
        XCTAssertFalse(controller.scrollView.isHidden)
    }

    func testTheXMLTreeTurnsElementsAndAttributesIntoEachOther() throws {
        let controller = editor("a.xml", "<a x=\"1\">\n    <b>2</b>\n</a>\n")
        controller.setTreeShown(true)
        let tree = try XCTUnwrap(controller.tree)
        let types = try XCTUnwrap(tree.outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("type")))
        XCTAssertEqual(types.isHidden, !controller.style.treeShowsTypes)
        XCTAssertFalse(tree.outline.allowsColumnReordering)

        let row = tree.outline.row(forItem: try XCTUnwrap(tree.item(at: [0, 0])))
        let cell = try XCTUnwrap(tree.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
        let field = try XCTUnwrap(cell.textField as? KeyField)
        XCTAssertEqual(field.editingText, "@x", "edited with its @")
        XCTAssertTrue(field.attributedStringValue.containsAttachments(in: NSRange(location: 0, length: 1)),
                      "shown with a badge")

        tree.rename(try XCTUnwrap(tree.item(at: [0, 0])), to: "x")
        XCTAssertEqual(controller.textView.string, "<a>\n    <x>1</x>\n    <b>2</b>\n</a>\n")
        tree.rename(try XCTUnwrap(tree.item(at: [0, 1])), to: "@c")
        XCTAssertEqual(controller.textView.string, "<a c=\"2\">\n    <x>1</x>\n</a>\n")
        try XCTUnwrap(controller.textView.undoManager).undo()
        XCTAssertEqual(controller.textView.string, "<a>\n    <x>1</x>\n    <b>2</b>\n</a>\n", "one step")

        tree.select([0], edit: nil)
        tree.addChild()
        XCTAssertEqual(controller.textView.string,
                       "<a>\n    <x>1</x>\n    <b>2</b>\n    <element></element>\n</a>\n", "like the last")
        tree.select([0, 0], edit: nil)
        tree.addAfter()
        XCTAssertEqual(controller.textView.string,
                       "<a>\n    <x>1</x>\n    <element></element>\n    <b>2</b>\n    <element></element>\n</a>\n")
    }

    /// Shift-Command-Up and -Down, or Command-Up and -Down, in the tree: the
    /// node and all it holds, past its neighbour, into an open container,
    /// out of its own at the end.
    func testTheTreeMovesNodesByTheStructure() throws {
        let controller = editor("a.json", "{\n  \"a\": 1,\n  \"b\": {\n    \"c\": 2\n  },\n  \"d\": 3\n}\n")
        controller.setTreeShown(true)
        let tree = try XCTUnwrap(controller.tree)
        func key(_ path: [Int]) -> String? { tree.item(at: path)?.node.key }

        tree.outline.collapseItem(tree.item(at: [0, 1]))
        tree.select([0, 0], edit: nil)
        controller.moveUp(false)
        XCTAssertEqual([key([0, 0]), key([0, 1]), key([0, 2])], ["b", "a", "d"], "past b, which is closed")

        tree.outline.expandItem(tree.item(at: [0, 0]))
        tree.moveSelected(up: true)
        XCTAssertEqual([key([0, 0, 0]), key([0, 0, 1])], ["c", "a"], "into b, which is open, at its end")
        XCTAssertEqual(tree.selectedItem?.path, [0, 0, 1], "and still selected")

        let up = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                timestamp: 0, windowNumber: 0, context: nil,
                                                characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}",
                                                isARepeat: false, keyCode: 126))
        tree.outline.keyDown(with: up)
        XCTAssertEqual([key([0, 0, 0]), key([0, 0, 1])], ["a", "c"], "Command-Up: past c")
        tree.outline.keyDown(with: up)
        XCTAssertEqual([key([0, 0]), key([0, 1]), key([0, 1, 0])], ["a", "b", "c"], "out of b, before it")
        let text = controller.textView.string
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(text.utf8)), "still JSON:\n\(text)")

        tree.moveSelected(up: true)
        XCTAssertEqual(controller.textView.string, text, "the top value has nowhere to go")
        try XCTUnwrap(controller.textView.undoManager).undo()
        XCTAssertEqual([key([0, 0]), key([0, 0, 0]), key([0, 0, 1])], ["b", "a", "c"], "one step of Undo")
    }

    func testAnElementDoesNotPassAnAttribute() throws {
        let controller = editor("a.xml", "<a x=\"1\">\n    <b>2</b>\n</a>\n")
        controller.setTreeShown(true)
        let tree = try XCTUnwrap(controller.tree)
        tree.select([0, 1], edit: nil)
        tree.moveSelected(up: true)
        XCTAssertEqual(controller.textView.string, "<a x=\"1\">\n    <b>2</b>\n</a>\n")
    }

    func testTheRightClickMenusHoldTheFormatMenu() throws {
        let controller = editor("a.json", "{\"a\": 1}")
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                     timestamp: 0, windowNumber: 0, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))
        let text = try XCTUnwrap(controller.textView.menu(for: event)).items.map(\.title)
        XCTAssertEqual(text, ["Cut", "Copy", "Paste", "", "Format Document", "Compact JSON",
                              "Move Lines Up", "Move Lines Down", "Delete Lines", "Go to Line\u{2026}", "Show as Tree"])

        controller.setTreeShown(true)
        let tree = try XCTUnwrap(controller.tree)
        let menu = NSMenu()
        tree.menuNeedsUpdate(menu)
        let titles = menu.items.map(\.title)
        for title in ["Format Document", "Compact JSON", "Move Up", "Move Down", "Show as Text"] {
            XCTAssertTrue(titles.contains(title), "\(title) in \(titles)")
        }
        XCTAssertFalse(titles.contains("Move Lines Up"))
    }

    /// The tree's gutter: the line each node starts on, the same for nodes
    /// that share a line.
    func testTheTreeShowsTheLineEachNodeStartsOn() throws {
        let controller = editor("a.xml", "<a>\n  <b/><c/>\n  <d>\n    text\n  </d>\n</a>\n")
        controller.setTreeShown(true)
        let tree = try XCTUnwrap(controller.tree)
        XCTAssertTrue(tree.scrollView.rulersVisible, "the text has line numbers")
        func line(_ path: [Int]) throws -> Int? { tree.line(of: try XCTUnwrap(tree.item(at: path))) }
        XCTAssertEqual(try line([0]), 1)
        XCTAssertEqual(try line([0, 0]), 2)
        XCTAssertEqual(try line([0, 1]), 2, "on the same line as <b/>")
        XCTAssertEqual(try line([0, 2]), 3)
        controller.lineNumbers = .off
        XCTAssertFalse(tree.scrollView.rulersVisible)
    }

    /// Reported: typing in a row and clicking elsewhere left the text in the
    /// row, unsaved.
    func testClickingAwayKeepsWhatWasTypedInARow() throws {
        let controller = editor("a.xml", "<a>\n  <c>x</c>\n</a>\n")
        let window = try XCTUnwrap(self.window)
        window.makeKeyAndOrderFront(nil)
        controller.setTreeShown(true)
        let tree = try XCTUnwrap(controller.tree)
        let row = tree.outline.row(forItem: try XCTUnwrap(tree.item(at: [0, 0])))
        tree.outline.selectRowIndexes([row], byExtendingSelection: false)
        tree.outline.editColumn(2, row: row, with: nil, select: true)
        let typing = try XCTUnwrap(window.firstResponder as? NSTextView)
        typing.insertText("y", replacementRange: NSRange(location: 0, length: typing.string.utf16.count))
        window.makeFirstResponder(tree.outline)
        XCTAssertEqual(controller.textView.string, "<a>\n  <c>y</c>\n</a>\n")
    }

    /// A value over several lines, the DOCTYPE: in a text area, not a row.
    func testValuesOverSeveralLinesAreEditedInATextArea() throws {
        let text = "<!DOCTYPE a [\n  <!ENTITY e \"x\">\n]>\n<a>\n  <!-- one\n  two -->\n</a>\n"
        let controller = editor("a.xml", text)
        controller.setTreeShown(true)
        let tree = try XCTUnwrap(controller.tree)
        let comment = try XCTUnwrap(tree.item(at: [1, 0]))
        XCTAssertTrue(tree.needsTextArea(comment.node))
        tree.beginEditing(comment, .value)
        var area = try XCTUnwrap(tree.textArea)
        _ = area.view
        XCTAssertEqual(area.text, "one\n  two")
        area.text = "one\ntwo\nthree"
        area.finish()
        XCTAssertTrue(controller.textView.string.contains("<!-- one\ntwo\nthree -->"), controller.textView.string)

        let doctype = try XCTUnwrap(tree.item(at: [0]))
        XCTAssertTrue(tree.needsTextArea(doctype.node), "the DOCTYPE, even on one line")
        tree.beginEditing(doctype, .value)
        area = try XCTUnwrap(tree.textArea)
        _ = area.view
        area.text = "<!DOCTYPE a [\n  <!ENTITY e \"y\">\n]>"
        area.finish()
        XCTAssertTrue(controller.textView.string.hasPrefix("<!DOCTYPE a [\n  <!ENTITY e \"y\">\n]>\n<a>"))

        let before = controller.textView.string
        tree.beginEditing(try XCTUnwrap(tree.item(at: [0])), .value)
        area = try XCTUnwrap(tree.textArea)
        _ = area.view
        area.text = "<!DOCTYPE a [ broken"
        area.cancel()
        XCTAssertEqual(controller.textView.string, before, "Escape leaves it")
        tree.setValue(try XCTUnwrap(tree.item(at: [0])), to: "<!DOCTYPE a [ <!ELEMENT>")
        XCTAssertEqual(controller.textView.string, before, "what does not read back is not made")
    }

    /// Reported: clicking a comment over several lines gave a one-line
    /// field in the row. Only the text area edits it.
    func testAValueOverSeveralLinesHasNoFieldInItsRow() throws {
        let controller = editor("a.xml", "<a>\n  <!-- one\n  two -->\n  <!-- one line -->\n</a>\n")
        controller.setTreeShown(true)
        let tree = try XCTUnwrap(controller.tree)
        func field(_ path: [Int]) throws -> NSTextField {
            let row = tree.outline.row(forItem: try XCTUnwrap(tree.item(at: path)))
            let cell = try XCTUnwrap(tree.outline.view(atColumn: 2, row: row, makeIfNecessary: true) as? NSTableCellView)
            return try XCTUnwrap(cell.textField)
        }
        XCTAssertFalse(try field([0, 0]).isEditable, "two lines")
        XCTAssertTrue(try field([0, 1]).isEditable, "one line")
    }

    /// Reported: Cancel in the text area still turned the value's line
    /// breaks into ↩. A row edit already open on it -- showing the row's one
    /// line -- was kept as the area took the keyboard.
    func testOpeningTheTextAreaNeverKeepsTheRowsOneLine() throws {
        let text = "<a>\n  <c>one\ntwo</c>\n</a>\n"
        let controller = editor("a.xml", text)
        let window = try XCTUnwrap(self.window)
        window.makeKeyAndOrderFront(nil)
        controller.setTreeShown(true)
        let tree = try XCTUnwrap(controller.tree)
        let item = try XCTUnwrap(tree.item(at: [0, 0]))
        let row = tree.outline.row(forItem: item)
        let field = try XCTUnwrap((tree.outline.view(atColumn: 2, row: row, makeIfNecessary: true)
            as? NSTableCellView)?.textField)
        field.isEditable = true
        tree.outline.selectRowIndexes([row], byExtendingSelection: false)
        tree.outline.editColumn(2, row: row, with: nil, select: true)
        let typing = try XCTUnwrap(window.firstResponder as? NSTextView)
        typing.string = StructureTreeController.oneLine("one\ntwo")
        tree.beginEditing(item, .value)
        try XCTUnwrap(tree.textArea).cancel()
        window.makeFirstResponder(tree.outline)
        XCTAssertEqual(controller.textView.string, text)
    }

    func testTheTextAreaSaysItsKeyAndResizes() throws {
        let area = TreeTextArea(text: "a\nb", font: .systemFont(ofSize: 12)) { _ in }
        let titles = area.view.subviews.compactMap { ($0 as? NSButton)?.title }
        XCTAssertTrue(titles.contains("Done \u{2318}\u{21A9}"), "\(titles)")
        XCTAssertTrue(area.view.subviews.contains { $0 is ResizeGrip })
        let saved = TreeTextArea.size
        defer { TreeTextArea.size = saved }
        area.resize(to: NSSize(width: 700, height: 500))
        XCTAssertEqual(area.popover.contentSize, NSSize(width: 700, height: 500))
        XCTAssertEqual(TreeTextArea.size, NSSize(width: 700, height: 500), "the next one opens this size")
        area.resize(to: NSSize(width: 10, height: 10))
        XCTAssertEqual(area.popover.contentSize, TreeTextArea.minimumSize)
    }

    func testGoToLineInTheTextAndTheTree() throws {
        let text = "{\n  \"a\": 1,\n  \"b\": {\n    \"c\": 2\n  }\n}\n"
        let controller = editor("a.json", text)
        controller.goToLine(4)
        XCTAssertEqual(controller.selectedRange.location, (text as NSString).range(of: "    \"c\"").location)
        XCTAssertEqual(controller.currentLine, 4)
        controller.goToLine(99)
        XCTAssertEqual(controller.currentLine, controller.lineIndex.count, "past the end: the last line")

        controller.setTreeShown(true)
        let tree = try XCTUnwrap(controller.tree)
        tree.outline.collapseItem(nil, collapseChildren: true)
        controller.goToLine(4)
        XCTAssertEqual(tree.selectedItem?.path, [0, 1, 0], "c, opened up to")
        XCTAssertEqual(controller.currentLine, 4)
        controller.goToLine(2)
        XCTAssertEqual(tree.selectedItem?.path, [0, 0])
    }

    func testFindInTheTree() throws {
        let controller = editor("a.json", #"{"apple": 1, "b": {"pineapple": "x", "c": "Apple pie"}}"#)
        controller.setTreeShown(true)
        let tree = try XCTUnwrap(controller.tree)
        tree.outline.collapseItem(nil, collapseChildren: true)
        let finder = FindTrigger()
        finder.textView = controller.textView
        finder.show()
        XCTAssertFalse(tree.findBar.isHidden, "Command-F in the tree is the tree's")
        tree.findBar.field.stringValue = "apple"
        tree.findChanged()
        XCTAssertEqual(tree.matches, [[0, 0], [0, 1, 0], [0, 1, 1]], "names and values, folded or not")
        XCTAssertEqual(tree.selectedItem?.path, [0, 0])
        XCTAssertEqual(tree.findBar.count.stringValue, "1 of 3")
        tree.findNext(forward: true)
        XCTAssertEqual(tree.selectedItem?.path, [0, 1, 0])
        tree.findNext(forward: true)
        tree.findNext(forward: true)
        XCTAssertEqual(tree.selectedItem?.path, [0, 0], "round to the first")
        tree.findNext(forward: false)
        XCTAssertEqual(tree.selectedItem?.path, [0, 1, 1])
        XCTAssertEqual(tree.findBar.count.stringValue, "3 of 3")
        tree.findBar.field.stringValue = "nothing"
        tree.findChanged()
        XCTAssertEqual(tree.findBar.count.stringValue, "Not found")
        tree.closeFind()
        XCTAssertTrue(tree.findBar.isHidden)
    }

    func testTheTreeCopiesANodesPath() throws {
        let controller = editor("a.json", #"{"a": [1, {"b c": 2}]}"#)
        controller.setTreeShown(true)
        let tree = try XCTUnwrap(controller.tree)
        XCTAssertEqual(tree.copyPath(of: try XCTUnwrap(tree.item(at: [0, 0, 1, 0]))), "$.a[1]['b c']")
        XCTAssertEqual(board.string(forType: .string), "$.a[1]['b c']")
    }

    /// The n-th smallest structure around the caret, by its lines.
    func testStructureEmphasisFollowsTheLevel() throws {
        let text = "{\n  \"a\": {\n    \"b\": [\n      1\n    ]\n  }\n}\n"
        let controller = editor("a.json", text)
        // The folds are worked out off the main thread.
        let deadline = Date().addingTimeInterval(15)
        while controller.foldRegions.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        caret(controller, at: (text as NSString).range(of: "1").location)
        XCTAssertNil(controller.emphasizedLines(), "0: none")
        controller.emphasis = 1
        XCTAssertEqual(controller.emphasizedLines(), 2 ... 4, "the array")
        controller.emphasis = 2
        XCTAssertEqual(controller.emphasizedLines(), 1 ... 5, "the object around it")
        controller.emphasis = 3
        XCTAssertEqual(controller.emphasizedLines(), 0 ... 6)
        controller.emphasis = 4
        XCTAssertNil(controller.emphasizedLines(), "nothing that far out")
    }

    /// A start tag over several lines: the element from its `<`, wherever in
    /// the tag the caret is.
    func testEmphasisTakesAStartTagFromItsFirstLine() throws {
        let text = "<catalog version=\"2.1\"\n         xmlns=\"urn:a\"\n         xmlns:x=\"urn:x\">\n"
            + "  <book>\n    <title>A</title>\n  </book>\n</catalog>\n"
        let controller = editor("a.xml", text)
        let deadline = Date().addingTimeInterval(15)
        while controller.foldRegions.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        controller.emphasis = 1
        caret(controller, at: (text as NSString).range(of: "xmlns=").location)
        XCTAssertEqual(controller.emphasizedLines(), 0 ... 6, "in the tag's second line")
        caret(controller, at: (text as NSString).range(of: "<title>").location)
        XCTAssertEqual(controller.emphasizedLines(), 3 ... 5, "the book")
        controller.emphasis = 2
        XCTAssertEqual(controller.emphasizedLines(), 0 ... 6, "the catalog, from its first line")
    }

    func testABinaryPlistIsEditedAsXMLAndSavedAsBinary() throws {
        let url = folder.appendingPathComponent("a.plist")
        let binary = try PropertyListSerialization.data(fromPropertyList: ["name": "Diptych", "n": 1],
                                                        format: .binary, options: 0)
        try binary.write(to: url)
        let document = TextEditDocument(url: url)
        document.load()
        XCTAssertNil(document.failure)
        XCTAssertEqual(document.plistEncoding, .binary)
        XCTAssertTrue(document.saved.contains("<key>name</key>"), document.saved)
        XCTAssertNotNil(StructureTree.parse(document.saved as NSString, as: .plist), "a tree")

        let edited = document.saved.replacingOccurrences(of: "Diptych", with: "Tychedit")
        document.currentText = { edited }
        document.noteEdit()
        XCTAssertEqual(document.save(overwriting: true), .saved)
        var written = try Data(contentsOf: url)
        XCTAssertTrue(written.starts(with: Array("bplist".utf8)), "binary, as it came")
        let read = try PropertyListSerialization.propertyList(from: written, format: nil) as? [String: Any]
        XCTAssertEqual(read?["name"] as? String, "Tychedit")

        XCTAssertEqual(document.save(overwriting: true, as: .xml), .saved, "written though nothing was typed")
        written = try Data(contentsOf: url)
        XCTAssertTrue(written.starts(with: Array("<?xml".utf8)))
        XCTAssertEqual(document.plistEncoding, .xml, "and XML from now on")

        document.currentText = { "<plist><dict><key>a</key></dict></plist>" }
        document.noteEdit()
        if case .failed = document.save(overwriting: true, as: .binary) {} else {
            XCTFail("no binary from what is not a property list")
        }
    }

    func testTheTreeIsNoPaneTable() throws {
        let controller = editor("a.json", "{\"a\": 1}")
        controller.setTreeShown(true)
        XCTAssertEqual(TableFinder.tables(in: try XCTUnwrap(window)), [],
                       "its columns are not the panes' to rearrange or size")
    }

    func testTheTreeSaysWhenItCannotRead() throws {
        let controller = editor("a.json", "{\"a\": }")
        controller.setTreeShown(true)
        let tree = try XCTUnwrap(controller.tree)
        XCTAssertFalse(tree.message.isHidden)
        XCTAssertTrue(tree.message.stringValue.contains("valid JSON"))
    }
}
