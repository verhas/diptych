import XCTest
import AppKit
@testable import Diptych

/// The in-place permission editor's keys.
///
/// Every letter follows one rule -- bare sets, Shift clears, Option toggles --
/// and the value of that rule is that it is the *same* rule. `s` and `t` once
/// toggled unconditionally, which is the sort of exception nobody discovers
/// except by pressing keys until the right letter appears.
@MainActor
final class PermissionEditorTests: XCTestCase {

    private func editor(mode: mode_t, caret: Int) -> PermissionEditorView {
        let view = PermissionEditorView()
        view.mode = mode
        view.cursor = caret
        return view
    }

    private func type(_ letter: String, shift: Bool = false, option: Bool = false,
                      into view: PermissionEditorView,
                      file: StaticString = #filePath, line: UInt = #line) {
        var flags: NSEvent.ModifierFlags = []
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }

        // charactersIgnoringModifiers is what the editor reads, so Shift-S and
        // Option-S both arrive as "s" -- which is the point of using it.
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: letter, charactersIgnoringModifiers: letter,
                                     isARepeat: false, keyCode: 1)
        guard let event else {
            return XCTFail("the key event could not be synthesised", file: file, line: line)
        }
        view.keyDown(with: event)
    }

    // MARK: - One rule for every letter

    func testBareLetterSetsWhicheverBitItNames() {
        for (letter, caret, bit) in [("w", 0, mode_t(0o200)), ("x", 2, 0o100),
                                     ("s", 0, 0o4000), ("s", 4, 0o2000), ("t", 8, 0o1000)] {
            let view = editor(mode: 0o444, caret: caret)
            type(letter, into: view)
            XCTAssertEqual(view.mode & bit, bit, "\(letter) at \(caret) must set the bit")
        }
    }

    func testBareLetterIsIdempotent() {
        // Set means set, not "flip": pressing it twice must not undo it.
        for (letter, caret, mode) in [("x", 2, mode_t(0o744)), ("s", 0, 0o4744),
                                      ("s", 4, 0o2744), ("t", 8, 0o1744)] {
            let view = editor(mode: mode, caret: caret)
            type(letter, into: view)
            XCTAssertEqual(view.mode, mode, "\(letter) at \(caret) must leave a set bit alone")
        }
    }

    func testShiftClearsWhicheverBitItNames() {
        for (letter, caret, mode, expected) in [("w", 0, mode_t(0o644), mode_t(0o444)),
                                                ("s", 0, 0o4755, 0o755),
                                                ("s", 4, 0o2755, 0o755),
                                                ("t", 8, 0o1755, 0o755)] {
            let view = editor(mode: mode, caret: caret)
            type(letter, shift: true, into: view)
            XCTAssertEqual(view.mode, expected, "shift-\(letter) at \(caret) must clear the bit")
        }
    }

    func testOptionTogglesWhicheverBitItNames() {
        for (letter, caret, bit) in [("w", 0, mode_t(0o200)), ("s", 0, 0o4000),
                                     ("s", 4, 0o2000), ("t", 8, 0o1000)] {
            let view = editor(mode: 0o444, caret: caret)
            type(letter, option: true, into: view)
            XCTAssertEqual(view.mode & bit, bit)
            type(letter, option: true, into: view)
            XCTAssertEqual(view.mode & bit, 0, "option-\(letter) at \(caret) must toggle back")
        }
    }

    // MARK: - Where the special bits do not exist

    func testSpecialLettersDoNothingOutsideTheirGroup() {
        // sticky in the user group, setuid in the other group: no such bit.
        for (letter, caret) in [("t", 0), ("t", 4), ("s", 8)] {
            let view = editor(mode: 0o755, caret: caret)
            type(letter, into: view)
            XCTAssertEqual(view.mode, 0o755, "\(letter) at \(caret) must change nothing")
        }
    }

    func testSpecialBitsShareTheExecuteColumnWithoutTouchingIt() {
        // The two bits behind one column stay separately editable.
        let view = editor(mode: 0o4755, caret: 2)
        type("x", shift: true, into: view)
        XCTAssertEqual(view.mode, 0o4655, "clearing execute must leave setuid alone")
        XCTAssertEqual(FileOperations.rwxString(view.mode), "rwSr-xr-x")
    }

    // MARK: - The caret-scoped keys, for contrast

    func testCaretKeysActOnOneBitAndAdvance() {
        let view = editor(mode: 0o4755, caret: 2)
        type(" ", into: view)
        XCTAssertEqual(view.mode, 0o4655, "Space is the execute bit, never the setuid bit")
        XCTAssertEqual(view.cursor, 3, "and it advances, unlike the letters")
    }

    func testLettersLeaveTheCaretWhereItWas() {
        let view = editor(mode: 0o444, caret: 1)
        type("s", into: view)
        XCTAssertEqual(view.cursor, 1, "a letter acts on a bit the caret is not on")
    }
}
