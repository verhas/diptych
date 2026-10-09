import XCTest
@testable import Diptych

/// The Rename Many window: what it shows, what it refuses, and what it does to
/// a real folder -- including putting all of it back with one undo.
@MainActor
final class RenameManyTests: XCTestCase {

    private var folder: URL!
    private let manager = FileManager.default

    override func setUp() async throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychRenameMany-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        FileHistory.shared.forgetEverything()
    }

    override func tearDown() async throws {
        FileHistory.shared.forgetEverything()
        try? manager.removeItem(at: folder)
    }

    private func make(_ names: [String]) throws {
        for name in names {
            try Data(name.utf8).write(to: folder.appendingPathComponent(name))
        }
    }

    private func names() throws -> [String] {
        try manager.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func loaded(_ names: [String]) async throws -> RenameManyModel {
        try make(names)
        let model = RenameManyModel(folder: folder)
        model.load()
        for _ in 0 ..< 100 where model.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.entries.count, names.count)
        return model
    }

    // MARK: - What it shows

    func testTheSearchIsAlwaysAWholeNameMatch() async throws {
        let model = try await loaded(["invoice.pdf", "my invoice.pdf"])

        model.search = "invoice\\.pdf"

        XCTAssertEqual(model.matching, ["invoice.pdf"], "not the one with a prefix")
        XCTAssertTrue(model.searchIsValid)
    }

    func testNonMatchingFilesAreDimmedOrHidden() async throws {
        let model = try await loaded(["a.txt", "b.md"])
        model.search = ".*\\.txt"

        let text = try XCTUnwrap(model.entries.first { $0.name == "a.txt" })
        let other = try XCTUnwrap(model.entries.first { $0.name == "b.md" })
        XCTAssertTrue(model.matches(text))
        XCTAssertFalse(model.matches(other), "dimmed, and still listed")
        XCTAssertEqual(model.listed.count, 2)

        model.hidesOthers = true
        XCTAssertEqual(model.listed.map(\.name), ["a.txt"])
    }

    func testAHalfTypedExpressionIsNotValidAndStopsNothingElse() async throws {
        let model = try await loaded(["a.txt"])

        model.search = "(unclosed"

        XCTAssertFalse(model.searchIsValid)
        XCTAssertTrue(model.matching.isEmpty)
        XCTAssertTrue(model.matches(model.entries[0]), "nothing is dimmed by a broken pattern")
        XCTAssertFalse(model.canRename)
    }

    func testTheNewNamesAreShownBeforeAnythingHappens() async throws {
        let model = try await loaded(["2024-03-12 invoice.pdf"])

        model.search = #"(\d{4})-(\d{2})-(\d{2}) invoice\.pdf"#
        model.replacement = "Invoice $3.$2.$1.pdf"

        XCTAssertEqual(model.newNames["2024-03-12 invoice.pdf"], "Invoice 12.03.2024.pdf")
        XCTAssertTrue(model.canRename)
        XCTAssertEqual(try names(), ["2024-03-12 invoice.pdf"], "and nothing has happened yet")
    }

    // MARK: - What it refuses

    func testTwoFilesLandingOnOneNameIsRefusedBeforeStarting() async throws {
        let model = try await loaded(["one.txt", "two.txt"])

        model.search = "(one|two)\\.txt"
        model.replacement = "same.txt"

        XCTAssertFalse(model.canRename)
        XCTAssertEqual(model.plan.problems.count, 1)
        await model.rename()
        XCTAssertEqual(try names(), ["one.txt", "two.txt"], "untouched")
    }

    func testTakingTheNameOfAFileThatIsStayingIsRefused() async throws {
        let model = try await loaded(["draft.txt", "final.txt"])

        model.search = "draft\\.txt"
        model.replacement = "final.txt"

        XCTAssertFalse(model.canRename)
        XCTAssertTrue(model.plan.problems[0].contains("not being renamed"))
    }

    // MARK: - Doing it

    func testAWholeFolderIsRenamedAndUndoneInOneStep() async throws {
        let model = try await loaded(["a.txt", "b.txt", "c.md"])

        model.search = #"(.*)\.txt"#
        model.replacement = "$1.text"
        await model.rename()

        XCTAssertEqual(try names(), ["a.text", "b.text", "c.md"])
        XCTAssertEqual(FileHistory.shared.undoName, "Rename Many")

        let result = await FileHistory.shared.perform(.undo) { _ in true }

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(try names(), ["a.txt", "b.txt", "c.md"])
    }

    func testAChainIsRenamedInTheRightOrderAndUndoneInOneStep() async throws {
        // 1.txt -> 2.txt while 2.txt -> 3.txt: the second has to move first,
        // and undoing has to run the same chain backwards.
        let model = try await loaded(["1.txt", "2.txt"])

        model.search = #"(\d)\.txt"#
        model.replacement = "$1x.txt"
        await model.rename()
        XCTAssertEqual(try names(), ["1x.txt", "2x.txt"])

        let renamed = RenameManyModel(folder: folder)
        renamed.load()
        for _ in 0 ..< 100 where renamed.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        renamed.search = #"1x\.txt|2x\.txt"#
        renamed.replacement = "done.txt"
        XCTAssertFalse(renamed.canRename, "two into one is still refused")

        let result = await FileHistory.shared.perform(.undo) { _ in true }
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(try names(), ["1.txt", "2.txt"])
    }

    func testARealChainAcrossNamesThatCollide() async throws {
        // b -> c while c -> d: done in the wrong order, b would refuse.
        try make(["b", "c"])
        let model = RenameManyModel(folder: folder)
        model.load()
        for _ in 0 ..< 100 where model.isLoading { try await Task.sleep(for: .milliseconds(20)) }

        model.search = "b|c"
        model.replacement = "x$0"   // b -> xb, c -> xc: no chain
        XCTAssertTrue(model.canRename)

        // The chain proper: rename each letter to the next one.
        model.search = "(b)"
        model.replacement = "c"
        XCTAssertFalse(model.canRename, "c is here and is not being renamed")

        model.search = "(b|c)"
        model.replacement = "$1$1"
        await model.rename()
        XCTAssertEqual(try names(), ["bb", "cc"])
    }

    func testTwoFilesCanSwapNamesInOneGo() async throws {
        // A real swap through one expression: "a-b" and "b-a" with the two
        // halves turned round. Neither name is free, so one file steps aside.
        try Data("first".utf8).write(to: folder.appendingPathComponent("a-b"))
        try Data("second".utf8).write(to: folder.appendingPathComponent("b-a"))
        let model = RenameManyModel(folder: folder)
        model.load()
        for _ in 0 ..< 100 where model.isLoading { try await Task.sleep(for: .milliseconds(20)) }

        model.search = "(.*)-(.*)"
        model.replacement = "$2-$1"

        XCTAssertEqual(model.plan.renames, 2)
        XCTAssertTrue(model.plan.steps.contains { $0.isTemporary }, "\(model.plan.steps)")
        XCTAssertTrue(model.canRename)

        await model.rename()

        XCTAssertEqual(try names(), ["a-b", "b-a"], "the same two names")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("a-b"),
                                  encoding: .utf8), "second", "and the files really swapped")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("b-a"),
                                  encoding: .utf8), "first")
        XCTAssertFalse(try names().contains { $0.hasPrefix(RenamePlan.temporaryPrefix) },
                       "nothing is left under a temporary name")
    }

    func testASwapIsUndoneInOneStep() async throws {
        try Data("first".utf8).write(to: folder.appendingPathComponent("a-b"))
        try Data("second".utf8).write(to: folder.appendingPathComponent("b-a"))
        let model = RenameManyModel(folder: folder)
        model.load()
        for _ in 0 ..< 100 where model.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        model.search = "(.*)-(.*)"
        model.replacement = "$2-$1"
        await model.rename()

        let result = await FileHistory.shared.perform(.undo) { _ in true }

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("a-b"),
                                  encoding: .utf8), "first", "back as they were")
        XCTAssertEqual(try names(), ["a-b", "b-a"])
    }

    // MARK: - The selection, and flat views

    private func opened(_ request: RenameManyRequest) async throws -> RenameManyModel {
        let model = RenameManyModel(request)
        model.load()
        for _ in 0 ..< 100 where model.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        return model
    }

    func testOnlyTheSelectionIsRenamedUnlessToldOtherwise() async throws {
        try make(["a.txt", "b.txt", "c.txt"])
        let model = try await opened(RenameManyRequest(
            folder: folder, selected: [folder.appendingPathComponent("b.txt")]))
        XCTAssertTrue(model.selectionOnly, "on, as something was selected")
        model.search = #"(.*)\.txt"#
        model.replacement = "$1.text"
        XCTAssertEqual(model.matching, ["b.txt"])
        XCTAssertEqual(model.plan.renames, 1)
        XCTAssertFalse(model.matches(model.entries.first { $0.name == "a.txt" }!))

        model.selectionOnly = false
        XCTAssertEqual(model.plan.renames, 3)

        model.selectionOnly = true
        await model.rename()
        XCTAssertEqual(try names(), ["a.txt", "b.text", "c.txt"])
        XCTAssertEqual(model.selected, ["b.text"], "still selected, under its new name")
    }

    func testANameOutsideTheSelectionIsStillTaken() async throws {
        try make(["a.txt", "b.txt"])
        let model = try await opened(RenameManyRequest(
            folder: folder, selected: [folder.appendingPathComponent("a.txt")]))
        model.search = "a\\.txt"
        model.replacement = "b.txt"
        XCTAssertFalse(model.canRename)
    }

    func testNothingSelectedMeansEverything() async throws {
        try make(["a.txt"])
        let model = try await opened(RenameManyRequest(folder: folder))
        XCTAssertFalse(model.selectionOnly)
        XCTAssertFalse(model.hasSelection)
    }

    func testAFlatViewsRowsAcrossFolders() async throws {
        let one = folder.appendingPathComponent("one")
        let two = folder.appendingPathComponent("two")
        for sub in [one, two] {
            try manager.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data().write(to: sub.appendingPathComponent("x.txt"))
            try Data().write(to: sub.appendingPathComponent("y.txt"))
        }
        // The rows as listed -- y.txt in two is not among them, as if the
        // view were stale or the expression had left it out.
        let rows = [one.appendingPathComponent("x.txt"), one.appendingPathComponent("y.txt"),
                    two.appendingPathComponent("x.txt")]
        let model = try await opened(RenameManyRequest(folder: folder, flatRows: rows,
                                                       flatExpression: "name = \"*.txt\""))
        XCTAssertTrue(model.isFlat)
        XCTAssertEqual(model.entries.map(\.id), ["one/x.txt", "one/y.txt", "two/x.txt"])
        model.search = #"(.*)\.txt"#
        model.replacement = "$1.md"
        XCTAssertEqual(model.plan.renames, 3)
        XCTAssertEqual(model.newNames["two/x.txt"], "x.md")
        await model.rename()
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: two.path).sorted(),
                       ["x.md", "y.txt"], "only what was listed")
        XCTAssertEqual(model.entries.map(\.id), ["one/x.md", "one/y.md", "two/x.md"])

        let undone = await FileHistory.shared.perform(.undo) { _ in true }
        XCTAssertTrue(undone.failures.isEmpty, "\(undone.failures)")
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: one.path).sorted(),
                       ["x.txt", "y.txt"])
    }

    func testAFlatViewClashIsSaidWithItsFolder() async throws {
        let one = folder.appendingPathComponent("one")
        try manager.createDirectory(at: one, withIntermediateDirectories: true)
        try Data().write(to: one.appendingPathComponent("x.txt"))
        try Data().write(to: one.appendingPathComponent("x.md"))
        let model = try await opened(RenameManyRequest(
            folder: folder, flatRows: [one.appendingPathComponent("x.txt")]))
        model.search = #"(.*)\.txt"#
        model.replacement = "$1.md"
        XCTAssertFalse(model.canRename, "x.md is there, though not listed")
        XCTAssertTrue(model.plan.problems.first?.hasPrefix("In one/") == true,
                      "\(model.plan.problems)")
    }

    func testAFolderCanBeRenamedToo() async throws {
        let inner = folder.appendingPathComponent("old folder")
        try manager.createDirectory(at: inner, withIntermediateDirectories: true)
        let model = RenameManyModel(folder: folder)
        model.load()
        for _ in 0 ..< 100 where model.isLoading { try await Task.sleep(for: .milliseconds(20)) }

        model.search = "old (.*)"
        model.replacement = "new $1"
        await model.rename()

        XCTAssertEqual(try names(), ["new folder"])
    }
}
