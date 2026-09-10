import XCTest
@testable import Diptych

/// Copying with progress, and stopping part-way.
final class TransferProgressTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychTransfer-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func makeFile(_ path: String, kilobytes: Int = 1) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: kilobytes * 1024).write(to: url)
        return url
    }

    // MARK: - Measuring

    func testTotalBytesCountsAWholeTree() throws {
        try makeFile("tree/a.bin", kilobytes: 10)
        try makeFile("tree/deep/b.bin", kilobytes: 20)

        let total = FileOperations.totalBytes(of: [root.appendingPathComponent("tree")])

        XCTAssertEqual(total, 30 * 1024, "a bar without a total is only a spinner")
    }

    func testTotalBytesOfASingleFile() throws {
        let file = try makeFile("one.bin", kilobytes: 7)
        XCTAssertEqual(FileOperations.totalBytes(of: [file]), 7 * 1024)
    }

    // MARK: - Copying

    func testCopyingReportsProgressAndFinishes() throws {
        let source = try makeFile("src.bin", kilobytes: 512)
        let target = root.appendingPathComponent("dst.bin")
        let monitor = TransferMonitor()

        let seen = Locked<[Int64]>([])
        monitor.onProgress = { bytes, _ in seen.append(bytes) }

        let result = FileOperations.copyWithProgress(source, to: target, monitor: monitor)

        guard case .done(let bytes) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(bytes, 512 * 1024)
        XCTAssertEqual(try Data(contentsOf: target).count, 512 * 1024)
        XCTAssertFalse(seen.value.isEmpty, "the copy has to say how far it has got")
    }

    func testCopyingCarriesExtendedAttributes() throws {
        // The reason this uses copyfile rather than a read/write loop: metadata
        // comes with it.
        let source = try makeFile("meta.bin")
        XCTAssertNil(ExtendedAttributes.set(Data("v".utf8), name: "dev.diptych.test",
                                            on: source.path))
        let target = root.appendingPathComponent("meta-copy.bin")

        _ = FileOperations.copyWithProgress(source, to: target, monitor: TransferMonitor())

        XCTAssertEqual(ExtendedAttributes.data(of: target.path, name: "dev.diptych.test"),
                       Data("v".utf8))
    }

    func testAnAlreadyCancelledCopyWritesNothing() throws {
        let source = try makeFile("src.bin", kilobytes: 64)
        let target = root.appendingPathComponent("dst.bin")
        let monitor = TransferMonitor()
        monitor.cancel()

        let result = FileOperations.copyWithProgress(source, to: target, monitor: monitor)

        guard case .cancelled = result else { return XCTFail("\(result)") }
    }

    func testCancellingPartWayLeavesNoWholeFile() throws {
        // Cancelled during the data copy, so whatever landed is a fragment --
        // which is exactly why the caller removes it and then asks the user
        // about the items that had already finished.
        let source = try makeFile("big.bin", kilobytes: 40 * 1024)
        let target = root.appendingPathComponent("big-copy.bin")
        let monitor = TransferMonitor()
        monitor.onProgress = { _, _ in monitor.cancel() }

        let result = FileOperations.copyWithProgress(source, to: target, monitor: monitor)

        guard case .cancelled = result else { return XCTFail("expected a cancellation") }
        let landed = (try? Data(contentsOf: target).count) ?? 0
        XCTAssertLessThan(landed, 40 * 1024 * 1024, "it stopped rather than finishing")
    }

    func testCopyingRefusesToOverwrite() throws {
        // Deciding what to do about a clash belongs to the caller, which has a
        // dialog for it; the copy itself must never quietly replace anything.
        let source = try makeFile("a.bin")
        let target = try makeFile("b.bin", kilobytes: 3)

        let result = FileOperations.copyWithProgress(source, to: target,
                                                     monitor: TransferMonitor())

        guard case .failed = result else { return XCTFail("\(result)") }
        XCTAssertEqual(try Data(contentsOf: target).count, 3 * 1024, "the original stands")
    }

    func testTheMonitorAccumulatesAcrossItems() throws {
        let monitor = TransferMonitor()
        let one = try makeFile("one.bin", kilobytes: 4)
        let two = try makeFile("two.bin", kilobytes: 6)

        _ = FileOperations.copyWithProgress(one, to: root.appendingPathComponent("c1"),
                                            monitor: monitor)
        XCTAssertEqual(monitor.completedBytes, 4 * 1024)
        _ = FileOperations.copyWithProgress(two, to: root.appendingPathComponent("c2"),
                                            monitor: monitor)
        XCTAssertEqual(monitor.completedBytes, 10 * 1024,
                       "each item continues where the last stopped, not from zero")
    }

    // MARK: - What the sheet says

    @MainActor
    func testTheBarIsIndeterminateWithoutATotal() {
        let progress = TransferProgress(verb: "Copying", itemCount: 1, bytesTotal: 0)
        XCTAssertNil(progress.fraction, "no total means no honest fraction")
    }

    @MainActor
    func testTheFractionNeverExceedsOne() {
        let progress = TransferProgress(verb: "Copying", itemCount: 1, bytesTotal: 100)
        progress.update(bytes: 500, item: "x")
        XCTAssertEqual(progress.fraction, 1)
    }

    @MainActor
    func testProgressNeverGoesBackwards() {
        // Each item restarts copyfile's own counter, so a naive assignment
        // would make the bar jump back at every file boundary.
        let progress = TransferProgress(verb: "Copying", itemCount: 2, bytesTotal: 100)
        progress.update(bytes: 60, item: "a")
        progress.update(bytes: 10, item: "b")
        XCTAssertEqual(progress.bytesDone, 60)
    }

    @MainActor
    func testAPaneReloadCanBeWaitedFor() async throws {
        // What the transfer chain needs: the rows are actually there when this
        // returns, rather than a reload merely having been started.
        try makeFile("tree/a.txt")
        let pane = PaneModel(directory: root.appendingPathComponent("tree"))

        await pane.reloadAndWait()

        XCTAssertFalse(pane.isLoading)
        XCTAssertTrue(pane.items.contains { $0.name == "a.txt" })
    }

    @MainActor
    func testAReloadAfterAChangeSeesIt() async throws {
        try makeFile("tree/a.txt")
        let directory = root.appendingPathComponent("tree")
        let pane = PaneModel(directory: directory)
        await pane.reloadAndWait()
        XCTAssertEqual(pane.items.filter { !$0.isParent }.count, 1)

        try fm.removeItem(at: directory.appendingPathComponent("a.txt"))
        await pane.reloadAndWait()

        XCTAssertEqual(pane.items.filter { !$0.isParent }.count, 0,
                       "a moved item must be gone by the time this returns")
    }

    @MainActor
    func testNoEstimateBeforeThereIsSomethingToExtrapolateFrom() {
        let progress = TransferProgress(verb: "Copying", itemCount: 1, bytesTotal: 1_000_000)
        progress.update(bytes: 1, item: "x")
        XCTAssertNil(progress.remaining, "a guess made in the first moment is noise")
    }
}

/// A tiny box, because the copy callback runs on another thread.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ element: Int64) where Value == [Int64] {
        lock.lock(); stored.append(element); lock.unlock()
    }
}
