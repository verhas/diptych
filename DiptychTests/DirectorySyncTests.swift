import XCTest
@testable import Diptych

/// One folder of a comparison made the same as the other: what is planned,
/// and that afterwards the two compare the same in everything, dates
/// included.
final class DirectorySyncTests: XCTestCase {

    private var folder: URL!
    private var left: URL!
    private var right: URL!
    private let manager = FileManager.default

    /// Everything, dates and hidden folders too: what "the same" means after
    /// a sync.
    private let everything = DirectoryComparison.Options(
        compareModificationDate: true, compareCreationDate: true,
        recurseHiddenDirectories: true)

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychSync-\(UUID().uuidString)")
        left = folder.appendingPathComponent("left")
        right = folder.appendingPathComponent("right")
        try manager.createDirectory(at: left, withIntermediateDirectories: true)
        try manager.createDirectory(at: right, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: folder)
    }

    private func write(_ text: String, _ path: String, in root: URL,
                       modified: Date = Date(timeIntervalSince1970: 1_600_000_000)) throws {
        let url = root.appendingPathComponent(path)
        try manager.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try manager.setAttributes([.modificationDate: modified,
                                   .creationDate: Date(timeIntervalSince1970: 1_500_000_000)],
                                  ofItemAtPath: url.path)
    }

    private func plan(_ direction: DirectorySync.Direction) throws -> DirectorySync.Plan {
        let pairs = try DirectoryComparison.compare(left: left, right: right, options: everything)
        return DirectorySync.mirror(pairs, direction: direction, left: left, right: right)
    }

    private func run(_ plan: DirectorySync.Plan) async -> DirectorySync.Outcome {
        await DirectorySync.run(plan, deleteOutright: true, monitor: TransferMonitor()) { _, _ in }
    }

    private func steps(_ plan: DirectorySync.Plan) -> [String] {
        plan.steps.map { "\($0.kind) \($0.relativePath)" }
    }

    func testAFolderCopiedOrDeletedWholeTakesWhatIsInItAlong() throws {
        try write("a", "new/one.txt", in: left)
        try write("b", "new/deeper/two.txt", in: left)
        try write("c", "gone/three.txt", in: right)
        XCTAssertEqual(steps(try plan(.leftToRight)), ["delete gone", "copy new"])
        XCTAssertEqual(steps(try plan(.rightToLeft)), ["delete new", "copy gone"])
    }

    func testOnlyWhatDiffersIsTouchedAndAsLittleAsWill() throws {
        try write("same", "same.txt", in: left)
        try write("same", "same.txt", in: right)
        try write("new", "changed.txt", in: left)
        try write("old", "changed.txt", in: right)
        try write("mode", "mode.txt", in: left)
        try write("mode", "mode.txt", in: right)
        try manager.setAttributes([.posixPermissions: 0o600],
                                  ofItemAtPath: right.appendingPathComponent("mode.txt").path)
        try write("renamed content", "photos/after.jpg", in: left)
        try write("renamed content", "before.jpg", in: right)
        try manager.createDirectory(at: right.appendingPathComponent("photos"),
                                    withIntermediateDirectories: true)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                  ofItemAtPath: left.appendingPathComponent("photos").path)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                  ofItemAtPath: right.appendingPathComponent("photos").path)

        XCTAssertEqual(steps(try plan(.leftToRight)),
                       ["move photos/after.jpg", "replace changed.txt", "metadata mode.txt"])
    }

    func testARenameIntoAFolderThatIsCopiedWholeIsADeleteInstead() throws {
        try write("x", "album/x.jpg", in: left)
        try write("x", "x-old.jpg", in: right)
        XCTAssertEqual(steps(try plan(.leftToRight)), ["delete x-old.jpg", "copy album"])
    }

    func testAFileWhereAFolderShouldBeIsReplacedByTheFolder() throws {
        try write("inside", "thing/inside.txt", in: left)
        try write("a file", "thing", in: right)
        XCTAssertEqual(steps(try plan(.leftToRight)), ["delete thing", "copy thing"])
    }

    func testAfterwardsTheTwoAreTheSameInEverything() async throws {
        try write("same", "same.txt", in: left)
        try write("same", "same.txt", in: right)
        try write("new content", "docs/changed.txt", in: left)
        try write("old", "docs/changed.txt", in: right)
        try write("mode", "mode.txt", in: left)
        try write("mode", "mode.txt", in: right)
        try manager.setAttributes([.posixPermissions: 0o600],
                                  ofItemAtPath: right.appendingPathComponent("mode.txt").path)
        try write("dates", "dates.txt", in: left, modified: Date(timeIntervalSince1970: 1_650_000_000))
        try write("dates", "dates.txt", in: right)
        try write("tagged", "tagged.txt", in: left)
        try write("tagged", "tagged.txt", in: right)
        XCTAssertNil(ExtendedAttributes.set(Data("1".utf8), name: "dev.diptych.test",
                                             on: left.appendingPathComponent("tagged.txt").path))
        XCTAssertNil(ExtendedAttributes.set(Data("2".utf8), name: "dev.diptych.extra",
                                             on: right.appendingPathComponent("tagged.txt").path))
        try write("renamed content", "photos/after.jpg", in: left)
        try write("renamed content", "before.jpg", in: right)
        try write("deep", "new/deeper/file.txt", in: left)
        try write("gone", "old/file.txt", in: right)
        try write("inside", "thing/inside.txt", in: left)
        try write("a file", "thing", in: right)

        let outcome = await run(try plan(.leftToRight))
        XCTAssertEqual(outcome.failures, [])
        XCTAssertFalse(outcome.cancelled)

        let after = try DirectoryComparison.compare(left: left, right: right, options: everything)
        let different = after.filter { $0.status != .same }
            .map { "\($0.id): \($0.differences.summary)" }
        XCTAssertEqual(different, [])
        XCTAssertTrue(try plan(.leftToRight).isEmpty)
    }

    func testAFolderAboveIsRecognised() {
        XCTAssertTrue(DirectorySync.hasAncestor("a/b/c", in: ["a"]))
        XCTAssertTrue(DirectorySync.hasAncestor("a/b/c", in: ["a/b"]))
        XCTAssertFalse(DirectorySync.hasAncestor("a/b/c", in: ["a/b/c"]), "not itself")
        XCTAssertFalse(DirectorySync.hasAncestor("ab/c", in: ["a"]))
    }

    func testThePlanSaysWhatItDoes() throws {
        try write("a", "one.txt", in: left)
        try write("b", "two.txt", in: right)
        XCTAssertEqual(try plan(.leftToRight).summary, "1 copied, 1 deleted")
        try manager.removeItem(at: left.appendingPathComponent("one.txt"))
        try manager.removeItem(at: right.appendingPathComponent("two.txt"))
        XCTAssertEqual(try plan(.leftToRight).summary, "Nothing to change")
    }
}
