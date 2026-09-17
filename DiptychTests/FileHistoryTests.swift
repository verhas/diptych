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
        history.recordCopy([(folder.appendingPathComponent("from/copy.txt"), copy)])

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
        history.recordCreation(.newFolder, of: [made])
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
        history.recordCopy([(folder.appendingPathComponent("from/copy.txt"), copy)])
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
        history.recordCopy([(folder.appendingPathComponent("from/copy.txt"), copy)], replacing: [copy])

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
        history.recordMove([(original, elsewhere)])

        let plan = await step(.undo)

        XCTAssertTrue(plan?.explanation.contains("was moved from") ?? false, plan?.explanation ?? "")
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
        history.recordRename(from: old, to: new)

        let plan = await step(.undo)

        XCTAssertTrue(plan?.explanation.contains("was renamed to") ?? false, plan?.explanation ?? "")
        XCTAssertTrue(exists(old))
        XCTAssertFalse(exists(new))
    }

    func testUndoingARenameThatOnlyChangedCase() async throws {
        let old = try file("Notes.txt")
        let new = try await FileOperations.shared.rename(old, to: "notes.txt")
        history.recordRename(from: old, to: new)

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
        history.recordMove([(original, elsewhere)])
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
        history.recordMove([(original, elsewhere)])

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
        history.recordMove([(one, oneThere), (two, twoThere)])
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

    // MARK: - The Trash

    func testUndoingATrashTakesItBackOutAndRedoPutsItThere() async throws {
        let url = try file("wanted.txt", "keep me")
        let (_, moved) = await FileOperations.shared.trashRecording([url])
        trashed += moved.map(\.trashed)
        history.recordTrash(moved)

        let plan = await step(.undo)

        XCTAssertEqual(plan?.title, "Undo Move to Trash")
        XCTAssertTrue(plan?.entry.told.contains("was moved to the Trash") ?? false,
                      plan?.entry.told ?? "")
        XCTAssertTrue(exists(url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "keep me")

        await step(.redo)
        XCTAssertFalse(exists(url), "back in the Trash")
    }

    func testATrashedItemEmptiedFromTheTrashCannotComeBack() async throws {
        let url = try file("gone.txt")
        let (_, moved) = await FileOperations.shared.trashRecording([url])
        history.recordTrash(moved)
        // As emptying the Trash would leave it.
        for item in moved { try manager.removeItem(at: item.trashed) }

        let plan = await step(.undo)

        XCTAssertTrue(plan?.doable.isEmpty ?? false)
        XCTAssertTrue(plan?.problems.first?.contains("Trash") ?? false,
                      plan?.problems.first ?? "")
    }

    // MARK: - Owner and group

    func testUndoingAGroupChangePutsTheOldGroupBack() async throws {
        let mine = AccountLookup.ownGroups()
        let url = try file("owned.txt")
        let was = try XCTUnwrap(manager.attributesOfItem(atPath: url.path)[.groupOwnerAccountName]
                                    as? String)
        guard let other = mine.first(where: { $0 != was }) else {
            throw XCTSkip("this account is in only one group, so there is nothing to change to")
        }

        let outcome = await FileOperations.shared.setOwnership(owner: nil, group: other,
                                                              for: [url])
        try XCTSkipUnless(outcome.isCompleteSuccess, "the group could not be changed here")
        history.recordOwnership([(url, was, was, nil, other)])

        let plan = await step(.undo)

        XCTAssertEqual(plan?.title, "Undo Group Change")
        XCTAssertEqual(try manager.attributesOfItem(atPath: url.path)[.groupOwnerAccountName]
                           as? String, was)

        await step(.redo)
        XCTAssertEqual(try manager.attributesOfItem(atPath: url.path)[.groupOwnerAccountName]
                           as? String, other)
    }

    func testAnOwnerChangeThatCannotBeUndoneIsReportedNotHidden() async throws {
        // Giving a file to root is refused for an ordinary user, which is
        // exactly the shape of "the change put it beyond reach".
        let url = try file("owned.txt")
        history.recordOwnership([(url, "root", nil, NSUserName(), nil)])

        let result = await history.perform(.undo) { _ in true }

        XCTAssertEqual(result.failures.count, 1, "\(result.failures)")
        XCTAssertTrue(result.failures[0].contains("administrator"), result.failures[0])
        XCTAssertTrue(result.carriedOut.isEmpty)
        XCTAssertNil(history.undoName, "and it does not sit there blocking the next undo")
    }

    // MARK: - Several at once

    func testSeveralStepsCanBeUndoneAtOnce() async throws {
        let one = try file("one.txt")
        let two = try file("two.txt")
        history.recordCreation(.newFile, of: [one])
        history.recordCreation(.newFile, of: [two])

        let result = await history.performMany(undo: [0, 1], redo: [])
        noteTrash()

        XCTAssertEqual(result.carriedOut.count, 2)
        XCTAssertFalse(exists(one))
        XCTAssertFalse(exists(two))
        XCTAssertTrue(history.undoable.isEmpty)
        XCTAssertEqual(history.redoable.count, 2)

        let back = await history.performMany(undo: [], redo: [0, 1])
        XCTAssertEqual(back.carriedOut.count, 2)
        XCTAssertTrue(exists(one))
        XCTAssertTrue(exists(two))
    }

    func testOneStepThatFailsDoesNotStopTheOthers() async throws {
        let created = try file("new.txt")
        history.recordCreation(.newFile, of: [created])

        // A move whose way back leads into a folder nothing may be written to.
        let locked = folder.appendingPathComponent("locked")
        try manager.createDirectory(at: locked, withIntermediateDirectories: true)
        let source = locked.appendingPathComponent("moved.txt")
        try Data("x".utf8).write(to: source)
        let target = folder.appendingPathComponent("moved.txt")
        try manager.moveItem(at: source, to: target)
        history.recordMove([(source, target)])
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700],
                                           ofItemAtPath: locked.path) }

        let result = await history.performMany(undo: [0, 1], redo: [])
        noteTrash()

        XCTAssertEqual(result.failures.count, 1, "\(result.failures)")
        XCTAssertEqual(result.carriedOut, ["New File"], "the other one still went ahead")
        XCTAssertFalse(exists(created))
        XCTAssertTrue(history.undoable.isEmpty, "neither step is left blocking the way")
    }

    // MARK: - What the question says

    func testARenameIsToldInOneSentenceInTheRightOrder() throws {
        let old = try file("draft.txt")
        let new = folder.appendingPathComponent("final.txt")
        try manager.moveItem(at: old, to: new)
        history.recordRename(from: old, to: new)

        let told = try XCTUnwrap(history.plan(.undo)?.explanation)

        XCTAssertEqual(told, "\u{201C}draft.txt\u{201D} was renamed to \u{201C}final.txt\u{201D} "
                       + "in \u{201C}\(NamingTemplate.tilde(folder.path))\u{201D}.")
        XCTAssertFalse(told.contains("\""), "one kind of quotation mark only")
    }

    func testARedoSaysThatItWasUndone() async throws {
        let url = try file("one.txt")
        history.recordCreation(.newFile, of: [url])
        await step(.undo)

        let told = try XCTUnwrap(history.plan(.redo)?.explanation)

        XCTAssertTrue(told.hasSuffix("That was undone."), told)
        XCTAssertEqual(history.plan(.redo)?.title, "Redo New File")
    }

    func testAPermissionChangeIsToldWithBothModes() throws {
        let url = try file("run.sh")
        history.recordPermissions([(url, 0o644, 0o755)])

        let told = try XCTUnwrap(history.plan(.undo)?.entry.told)

        XCTAssertTrue(told.contains("from rw-r--r-- to rwxr-xr-x"), told)
    }

    // MARK: - The history itself

    func testCancellingLeavesTheStepWhereItWas() async throws {
        let copy = try file("copy.txt")
        history.recordCopy([(folder.appendingPathComponent("from/copy.txt"), copy)])

        await step(.undo, answer: false)

        XCTAssertTrue(exists(copy))
        XCTAssertEqual(history.undoName, "Copy")
        XCTAssertNil(history.redoName)
    }

    func testTheTestsCleanUpTheTrash() async throws {
        // The cleanup itself is what is checked, in tearDown.
        let copy = try file("copy.txt")
        history.recordCopy([(folder.appendingPathComponent("from/copy.txt"), copy)])
        await step(.undo)
        XCTAssertFalse(trashed.isEmpty, "the trashed copy is known, so it can be removed")
    }

    func testANewOperationEndsWhatCouldBeRedone() async throws {
        let copy = try file("copy.txt")
        history.recordCopy([(folder.appendingPathComponent("from/copy.txt"), copy)])
        await step(.undo)
        XCTAssertEqual(history.redoName, "Copy")

        history.recordCreation(.newFile, of: [try file("new.txt")])

        XCTAssertNil(history.redoName)
        XCTAssertEqual(history.undoName, "New File")
    }

    func testOnlySoManyStepsAreKept() throws {
        let url = try file("a.txt")
        for _ in 0 ..< FileHistory.depth + 10 {
            history.recordCreation(.newFile, of: [url])
        }
        XCTAssertEqual(history.undoable.count, FileHistory.depth)
    }

    func testNamesAreListedUpToEightThenCounted() {
        let urls = (1...11).map { URL(fileURLWithPath: "/tmp/f\($0).txt") }
        let names = FileHistory.Plan.names(urls)
        XCTAssertTrue(names.hasSuffix("and 3 more"), names)
    }
}
