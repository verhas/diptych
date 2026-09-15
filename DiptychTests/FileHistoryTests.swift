import XCTest
@testable import Diptych

/// Undo and redo of file operations, against real files.
///
/// Undoing a copy uses the real Trash, so every test takes back out of it
/// whatever it put there -- a test run must not leave anything in yours.
@MainActor
final class FileHistoryTests: XCTestCase {

    private var folder: URL!
    private var history: FileHistory!
    private let manager = FileManager.default
    /// Where the Trash put things, to remove in tearDown.
    private var trashed: [URL] = []

    override func setUp() async throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychHistory-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        history = FileHistory()
    }

    override func tearDown() async throws {
        for url in Set(trashed) where manager.fileExists(atPath: url.path) {
            try? manager.removeItem(at: url)
            XCTAssertFalse(manager.fileExists(atPath: url.path), "left in the Trash: \(url.path)")
        }
        try? manager.removeItem(at: folder)
    }

    // MARK: - Helpers

    @discardableResult
    private func file(_ name: String, _ text: String = "text") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try manager.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func exists(_ url: URL) -> Bool { manager.fileExists(atPath: url.path) }

    /// Performs, answering the question with `answer`, and returns the plan asked about.
    @discardableResult
    private func step(_ direction: FileHistory.Direction, answer: Bool = true)
        async -> FileHistory.Plan? {
        var asked: FileHistory.Plan?
        await history.perform(direction) { plan in
            asked = plan
            return answer
        }
        noteTrash()
        return asked
    }

    private func noteTrash() {
        for entry in history.undoable + history.redoable {
            if case .relocate(let moves) = entry.action {
                trashed += moves.map(\.from).filter(FileHistory.isInTrash)
            }
        }
    }

    // MARK: - Copies and new items

    func testUndoingACopyPutsTheCopyInTheTrashAndRedoTakesItBack() async throws {
        let copy = try file("copy.txt", "copied")
        history.recordCreation("Copy", of: [copy])

        let plan = await step(.undo)

        XCTAssertEqual(plan?.title, "Undo Copy")
        XCTAssertFalse(exists(copy))
        XCTAssertEqual(history.redoName, "Copy")

        await step(.redo)

        XCTAssertTrue(exists(copy))
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "copied",
                       "the same file, out of the Trash, not a new one")
        XCTAssertEqual(history.undoName, "Copy")
    }

    func testANewFolderWithThingsAddedSinceStillGoesButSaysSo() async throws {
        let made = folder.appendingPathComponent("untitled folder")
        try manager.createDirectory(at: made, withIntermediateDirectories: false)
        history.recordCreation("New Folder", of: [made])
        try manager.setAttributes([.modificationDate: Date().addingTimeInterval(120)],
                                  ofItemAtPath: made.path)

        let plan = await step(.undo)

        XCTAssertEqual(plan?.warnings.count, 1, "\(plan?.warnings ?? [])")
        XCTAssertFalse(exists(made))
        await step(.redo)
        XCTAssertTrue(exists(made))
    }

    func testADifferentFileWithTheSameNameIsLeftAlone() async throws {
        let copy = try file("copy.txt", "copied")
        history.recordCreation("Copy", of: [copy])
        try manager.removeItem(at: copy)
        try file("copy.txt", "somebody else's")

        let plan = await step(.undo)

        XCTAssertEqual(plan?.problems.count, 1)
        XCTAssertTrue(plan?.doable.isEmpty ?? false)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "somebody else's")
        XCTAssertNil(history.undoName, "a step with nothing left to do is dropped")
    }

    func testReplacingSomethingIsSaidToBeBeyondUndoing() async throws {
        let copy = try file("copy.txt")
        history.recordCreation("Copy", of: [copy], replacing: [copy])

        let plan = history.plan(.undo)

        XCTAssertTrue(plan?.warnings.first?.contains("cannot be brought back") ?? false)
    }

    // MARK: - Moves and renames

    func testUndoingAMoveMovesItBackAndRedoMovesItAgain() async throws {
        let original = try file("a/notes.txt")
        let elsewhere = folder.appendingPathComponent("b/notes.txt")
        try manager.createDirectory(at: elsewhere.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        try manager.moveItem(at: original, to: elsewhere)
        history.recordRelocation("Move", [(original, elsewhere)])

        let plan = await step(.undo)

        XCTAssertTrue(plan?.explanation.contains("moves from") ?? false, plan?.explanation ?? "")
        XCTAssertTrue(exists(original))
        XCTAssertFalse(exists(elsewhere))

        await step(.redo)
        XCTAssertFalse(exists(original))
        XCTAssertTrue(exists(elsewhere))
    }

    func testUndoingARenameRenamesItBack() async throws {
        let old = try file("draft.txt")
        let new = folder.appendingPathComponent("final.txt")
        try manager.moveItem(at: old, to: new)
        history.recordRelocation("Rename", [(old, new)])

        let plan = await step(.undo)

        XCTAssertTrue(plan?.explanation.contains("is renamed") ?? false, plan?.explanation ?? "")
        XCTAssertTrue(exists(old))
        XCTAssertFalse(exists(new))
    }

    func testUndoingARenameThatOnlyChangedCase() async throws {
        let old = try file("Notes.txt")
        let new = try await FileOperations.shared.rename(old, to: "notes.txt")
        history.recordRelocation("Rename", [(old, new)])

        let plan = await step(.undo)

        XCTAssertTrue(plan?.problems.isEmpty ?? false, "\(plan?.problems ?? [])")
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: folder.path), ["Notes.txt"])
    }

    func testAMoveBackOntoAnOccupiedNameIsRefused() async throws {
        let original = try file("a/notes.txt", "moved")
        let elsewhere = folder.appendingPathComponent("b/notes.txt")
        try manager.createDirectory(at: elsewhere.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        try manager.moveItem(at: original, to: elsewhere)
        history.recordRelocation("Move", [(original, elsewhere)])
        try file("a/notes.txt", "a new one")

        let plan = await step(.undo)

        XCTAssertTrue(plan?.problems.first?.contains("already has") ?? false)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "a new one")
        XCTAssertTrue(exists(elsewhere), "nothing was moved")
    }

    func testAMoveWhoseFolderIsGoneIsRefused() async throws {
        let original = try file("a/notes.txt")
        let elsewhere = folder.appendingPathComponent("notes.txt")
        try manager.moveItem(at: original, to: elsewhere)
        try manager.removeItem(at: folder.appendingPathComponent("a"))
        history.recordRelocation("Move", [(original, elsewhere)])

        let plan = await step(.undo)

        XCTAssertTrue(plan?.problems.first?.contains("no longer exists") ?? false)
        XCTAssertTrue(exists(elsewhere))
    }

    func testPartOfAStepCanBeDoneWhenTheRestCannot() async throws {
        let one = try file("a/one.txt")
        let two = try file("a/two.txt")
        try manager.createDirectory(at: folder.appendingPathComponent("b"),
                                    withIntermediateDirectories: true)
        let oneThere = folder.appendingPathComponent("b/one.txt")
        let twoThere = folder.appendingPathComponent("b/two.txt")
        try manager.moveItem(at: one, to: oneThere)
        try manager.moveItem(at: two, to: twoThere)
        history.recordRelocation("Move", [(one, oneThere), (two, twoThere)])
        try manager.removeItem(at: twoThere)

        let plan = await step(.undo)

        XCTAssertEqual(plan?.doable.count, 1)
        XCTAssertEqual(plan?.problems.count, 1)
        XCTAssertTrue(plan?.explanation.contains("Left as it is") ?? false)
        XCTAssertTrue(exists(one))
        XCTAssertEqual(history.redoable.last?.action.count, 1, "redo covers what was undone")
    }

    // MARK: - Permissions

    func testUndoingAPermissionChangePutsTheOldOnesBack() async throws {
        let script = try file("run.sh")
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        history.recordPermissions([(script, 0o644, 0o755)])

        await step(.undo)
        XCTAssertEqual(try FileOperations.currentMode(of: script) & 0o7777, 0o644)

        await step(.redo)
        XCTAssertEqual(try FileOperations.currentMode(of: script) & 0o7777, 0o755)
    }

    func testPermissionsChangedSinceAreMentioned() async throws {
        let script = try file("run.sh")
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        history.recordPermissions([(script, 0o644, 0o755)])

        let plan = history.plan(.undo)

        XCTAssertEqual(plan?.warnings.count, 1)
        XCTAssertTrue(plan?.warnings.first?.contains("rwx------") ?? false)
    }

    func testAnUnchangedPermissionIsNotAStep() {
        history.recordPermissions([(folder, 0o755, 0o755)])
        XCTAssertNil(history.undoName)
    }

    // MARK: - The history itself

    func testCancellingLeavesTheStepWhereItWas() async throws {
        let copy = try file("copy.txt")
        history.recordCreation("Copy", of: [copy])

        await step(.undo, answer: false)

        XCTAssertTrue(exists(copy))
        XCTAssertEqual(history.undoName, "Copy")
        XCTAssertNil(history.redoName)
    }

    func testTheTestsCleanUpTheTrash() async throws {
        // The cleanup itself is what is checked, in tearDown.
        let copy = try file("copy.txt")
        history.recordCreation("Copy", of: [copy])
        await step(.undo)
        XCTAssertFalse(trashed.isEmpty, "the trashed copy is known, so it can be removed")
    }

    func testANewOperationEndsWhatCouldBeRedone() async throws {
        let copy = try file("copy.txt")
        history.recordCreation("Copy", of: [copy])
        await step(.undo)
        XCTAssertEqual(history.redoName, "Copy")

        history.recordCreation("New File", of: [try file("new.txt")])

        XCTAssertNil(history.redoName)
        XCTAssertEqual(history.undoName, "New File")
    }

    func testOnlySoManyStepsAreKept() throws {
        let url = try file("a.txt")
        for _ in 0 ..< FileHistory.depth + 10 {
            history.recordCreation("New File", of: [url])
        }
        XCTAssertEqual(history.undoable.count, FileHistory.depth)
    }

    func testNamesAreListedUpToEightThenCounted() {
        let urls = (1...11).map { URL(fileURLWithPath: "/tmp/f\($0).txt") }
        let names = FileHistory.Plan.names(urls)
        XCTAssertTrue(names.hasSuffix("and 3 more"), names)
    }
}
