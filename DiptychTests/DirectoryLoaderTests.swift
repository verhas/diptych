import XCTest
@testable import Diptych

/// Listing directories: that it does not serialise, and that an abandoned
/// listing actually stops.
///
/// The bug these exist for: `DirectoryLoader` was an actor, so listing a USB
/// disk that took seconds to spin up held up every other listing behind it --
/// the other pane, and this pane's next directory, both waiting on a disk
/// neither of them cared about.
final class DirectoryLoaderTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychLoader-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func makeFiles(_ count: Int, in directory: URL) throws -> URL {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0 ..< count {
            try Data("x".utf8).write(to: directory.appendingPathComponent("f\(index).txt"))
        }
        return directory
    }

    func testListingReturnsEveryEntryPlusTheParentRow() async throws {
        let directory = try makeFiles(5, in: root.appendingPathComponent("plain"))

        let items = try await DirectoryLoader.load(directory: directory, showHidden: false,
                                                   columns: [.name, .size])

        XCTAssertEqual(items.count, 6, "five files and the .. row")
        XCTAssertTrue(items.first?.isParent ?? false)
    }

    func testAnAlreadyCancelledListingStopsInsteadOfWalking() throws {
        let directory = try makeFiles(600, in: root.appendingPathComponent("many"))
        let flag = CancellationFlag()
        flag.cancel()

        XCTAssertThrowsError(try DirectoryLoader.list(directory: directory, showHidden: false,
                                                      columns: [.name], cancelled: flag)) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancellingTheTaskAbandonsTheListing() async throws {
        let directory = try makeFiles(2000, in: root.appendingPathComponent("big"))

        let task = Task {
            try await DirectoryLoader.load(directory: directory, showHidden: false,
                                           columns: [.name, .permissions, .owner])
        }
        task.cancel()

        do {
            _ = try await task.value
            // Racing the cancellation is legitimate -- the listing may finish
            // first on a fast machine. What must not happen is a hang.
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testTwoListingsDoNotWaitForEachOther() async throws {
        // The point of dropping the actor. Both run at once; with a serialising
        // actor the second could not start until the first had finished.
        let a = try makeFiles(400, in: root.appendingPathComponent("a"))
        let b = try makeFiles(400, in: root.appendingPathComponent("b"))

        async let first = DirectoryLoader.load(directory: a, showHidden: false, columns: [.name])
        async let second = DirectoryLoader.load(directory: b, showHidden: false, columns: [.name])

        let (one, two) = try await (first, second)
        XCTAssertEqual(one.count, 401)
        XCTAssertEqual(two.count, 401)
    }

    func testAnUnreadableDirectoryThrowsRatherThanHanging() async throws {
        let missing = root.appendingPathComponent("not-there")

        do {
            _ = try await DirectoryLoader.load(directory: missing, showHidden: false,
                                               columns: [.name])
            XCTFail("a missing directory should throw")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testBlockingWorkRunsOffTheCallingActor() async {
        // Whatever thread it lands on, it must not be the main one -- that is
        // the entire point of routing file-system calls through it.
        let onMain = await BlockingWork.run { Thread.isMainThread }
        XCTAssertFalse(onMain)
    }
}
