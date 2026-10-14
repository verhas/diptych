import XCTest
@testable import Diptych

/// Syncing both ways: what changed since the last sync goes the way it was
/// made, what changed on both sides waits for a decision, and the record of
/// the sync is what tells a deletion from something new.
final class TwoWaySyncTests: XCTestCase {

    private var folder: URL!
    private var left: URL!
    private var right: URL!
    private var store: SyncBaselineStore!
    private let manager = FileManager.default

    private let options = DirectoryComparison.Options(
        compareModificationDate: true, compareCreationDate: false)

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychTwoWay-\(UUID().uuidString)")
        left = folder.appendingPathComponent("left")
        right = folder.appendingPathComponent("right")
        try manager.createDirectory(at: left, withIntermediateDirectories: true)
        try manager.createDirectory(at: right, withIntermediateDirectories: true)
        // Never the real ~/.diptych/sync.
        store = SyncBaselineStore(directory: folder.appendingPathComponent("records"))
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: folder)
    }

    private func write(_ text: String, _ path: String, in root: URL, at time: Double = 1_600_000_000) throws {
        let url = root.appendingPathComponent(path)
        try manager.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)],
                                  ofItemAtPath: url.path)
    }

    private func read(_ path: String, in root: URL) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func compare() throws -> [DirectoryComparison.Pair] {
        try DirectoryComparison.compare(left: left, right: right, options: options)
    }

    private func plan() throws -> DirectorySync.TwoWayPlan {
        DirectorySync.twoWay(try compare(), baseline: store.baseline(left: left, right: right),
                             left: left, right: right, options: options)
    }

    /// What the window does on Sync: run the choices, compare again, record.
    @discardableResult
    private func sync(_ choices: [String: DirectorySync.Choice] = [:]) async throws
        -> DirectorySync.Outcome {
        let outcome = await DirectorySync.run(try plan().resolve(choices), deleteOutright: true,
                                              monitor: TransferMonitor()) { _, _ in }
        try record()
        return outcome
    }

    private func record() throws {
        try store.save(SyncBaseline.after(try compare(), left: left, right: right,
                                          previous: store.baseline(left: left, right: right)))
    }

    private func suggestions(_ plan: DirectorySync.TwoWayPlan) -> [String] {
        plan.items.map { "\($0.relativePath): \($0.suggested.map { "\($0)" } ?? "?")" }
    }

    private func assertInSync(file: StaticString = #filePath, line: UInt = #line) throws {
        let different = try compare().filter { $0.status != .same }.map(\.id)
        XCTAssertEqual(different, [], file: file, line: line)
    }

    // MARK: - The first sync

    func testTheFirstSyncCopiesWhatIsOnOneSideAndAsksAboutTheRest() async throws {
        try write("a", "only-left.txt", in: left)
        try write("b", "folder/only-right.txt", in: right)
        try write("mine", "both.txt", in: left, at: 1_600_000_100)
        try write("yours", "both.txt", in: right)

        let first = try plan()
        XCTAssertTrue(first.isFirst)
        XCTAssertEqual(suggestions(first),
                       ["both.txt: ?", "folder: toLeft", "only-left.txt: toRight"])
        XCTAssertEqual(first.items.first?.newer, .toRight, "the left one is newer")

        let outcome = try await sync(["both.txt": .keepBoth])
        XCTAssertEqual(outcome.failures, [])
        try assertInSync()
        XCTAssertEqual(read("both.txt", in: right), "mine", "the newer keeps the name")
        XCTAssertEqual(read("both (right copy).txt", in: left), "yours")
        XCTAssertEqual(read("folder/only-right.txt", in: left), "b")
        XCTAssertTrue(try plan().isEmpty)
        XCTAssertFalse(try plan().isFirst)
    }

    // MARK: - After a sync

    func testEachChangeGoesTheWayItWasMade() async throws {
        try write("1", "edited-left.txt", in: left)
        try write("2", "edited-right.txt", in: left)
        try write("3", "deleted-left.txt", in: left)
        try write("4", "both.txt", in: left)
        try await sync()
        try assertInSync()

        try write("1 more", "edited-left.txt", in: left, at: 1_700_000_000)
        try write("2 more", "edited-right.txt", in: right, at: 1_700_000_000)
        try manager.removeItem(at: left.appendingPathComponent("deleted-left.txt"))
        try write("new", "new-right.txt", in: right)
        try write("left's", "both.txt", in: left, at: 1_700_000_000)
        try write("right's", "both.txt", in: right, at: 1_700_000_100)

        let next = try plan()
        XCTAssertFalse(next.isFirst)
        XCTAssertEqual(suggestions(next), [
            "both.txt: ?", "deleted-left.txt: toRight", "edited-left.txt: toRight",
            "edited-right.txt: toLeft", "new-right.txt: toLeft",
        ])
        XCTAssertEqual(next.items.first?.reason, "changed on both sides")
        XCTAssertEqual(next.items.first?.newer, .toLeft)

        try await sync(["both.txt": .toLeft])
        try assertInSync()
        XCTAssertNil(read("deleted-left.txt", in: right), "a deletion carried across")
        XCTAssertEqual(read("both.txt", in: left), "right's")
        XCTAssertEqual(read("edited-left.txt", in: right), "1 more")
        XCTAssertEqual(read("new-right.txt", in: left), "new")
    }

    func testAFolderDeletedOnOneSideAndChangedInsideOnTheOtherIsAsked() async throws {
        try write("x", "album/deep/x.jpg", in: left)
        try write("y", "plain/y.jpg", in: left)
        try await sync()

        try manager.removeItem(at: left.appendingPathComponent("album"))
        try manager.removeItem(at: left.appendingPathComponent("plain"))
        try write("x edited", "album/deep/x.jpg", in: right, at: 1_700_000_000)

        let next = try plan()
        XCTAssertEqual(suggestions(next), ["album: ?", "plain: toRight"])
        XCTAssertEqual(next.items.first?.reason, "deleted on the left, changed on the right")
        XCTAssertEqual(next.items.first?.newer, .toLeft, "the change is kept")
    }

    func testAFileRenamedOnOneSideIsRenamedOnTheOther() async throws {
        try write("the photo", "before.jpg", in: left)
        try await sync()
        try manager.moveItem(at: left.appendingPathComponent("before.jpg"),
                             to: left.appendingPathComponent("after.jpg"))

        let steps = try plan().resolve([:]).steps.map { "\($0.kind) \($0.relativePath)" }
        XCTAssertEqual(steps, ["move after.jpg"])
        try await sync()
        try assertInSync()
        XCTAssertEqual(read("after.jpg", in: right), "the photo")
    }

    func testWhatIsSkippedComesUpTheSameWayNextTime() async throws {
        try write("old", "both.txt", in: left)
        try await sync()
        try write("left's", "both.txt", in: left, at: 1_700_000_000)
        try write("right's", "both.txt", in: right, at: 1_700_000_100)
        try write("new", "new.txt", in: left)
        try await sync(["both.txt": .skip, "new.txt": .skip])

        XCTAssertEqual(suggestions(try plan()), ["both.txt: ?", "new.txt: toRight"])
    }

    func testFolderDatesAloneAreNeverAConflict() async throws {
        try manager.createDirectory(at: left.appendingPathComponent("f"), withIntermediateDirectories: true)
        try manager.createDirectory(at: right.appendingPathComponent("f"), withIntermediateDirectories: true)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                  ofItemAtPath: left.appendingPathComponent("f").path)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                  ofItemAtPath: right.appendingPathComponent("f").path)
        XCTAssertEqual(suggestions(try plan()), ["f: toLeft"])
    }

    // MARK: - The record

    func testTheRecordIsFoundWithThePanesSwappedAndKeepsDatesExactly() throws {
        try write("a", "a.txt", in: left, at: 1_600_000_000.123456789)
        try write("a", "a.txt", in: right, at: 1_600_000_000.123456789)
        try record()
        let kept = try XCTUnwrap(store.baseline(left: left, right: right))
        let entry = try XCTUnwrap(try compare().first { $0.id == "a.txt" }?.left)
        XCTAssertTrue(kept.entries["a.txt"]!.left.isUnchanged(SyncBaseline.State(entry)))

        let swapped = try XCTUnwrap(store.baseline(left: right, right: left))
        XCTAssertEqual(swapped.entries["a.txt"]?.left, kept.entries["a.txt"]?.right)
        store.forget(left: right, right: left)
        XCTAssertNil(store.baseline(left: left, right: right))
    }
}
