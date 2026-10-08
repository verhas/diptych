import XCTest
@testable import Diptych

/// Trashing where a cloud provider is in the way, and what the copy messages
/// say.
final class TrashAndCopyMessageTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testAShortTextIsShownWhole() {
        XCTAssertEqual(AppModel.shortened("notes.txt"), "notes.txt")
    }

    /// The start says where, the end says what: both are kept.
    func testALongTextKeepsItsStartAndItsEnd() {
        let path = "/Users/someone/Library/CloudStorage/Dropbox/projects/2026/october/"
            + "a-rather-long-file-name-for-the-report.pdf"
        let short = AppModel.shortened(path, to: 40)
        XCTAssertEqual(short.count, 40)
        XCTAssertTrue(short.hasPrefix("/Users/someone/Libr"), short)
        XCTAssertTrue(short.hasSuffix("e-for-the-report.pdf"), short)
        XCTAssertTrue(short.contains("\u{2026}"), short)
    }

    /// A file that is gone is not waited for.
    func testAGoneFileIsNotWaitedFor() {
        let start = ContinuousClock.now
        XCTAssertFalse(FileOperations.stillThere(folder.appendingPathComponent("nothing")))
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(500))
    }

    /// One that stays is waited for, then reported as still there.
    func testAFileThatStaysIsReportedAfterTheWait() throws {
        let file = folder.appendingPathComponent("stays")
        try Data("x".utf8).write(to: file)
        XCTAssertTrue(FileOperations.stillThere(file, waiting: .milliseconds(300)))
    }

    /// A file that goes during the wait counts as gone.
    func testAFileThatGoesLateCountsAsGone() throws {
        let file = folder.appendingPathComponent("goes")
        try Data("x".utf8).write(to: file)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            try? FileManager.default.removeItem(at: file)
        }
        XCTAssertFalse(FileOperations.stillThere(file, waiting: .seconds(2)))
    }

    /// The fallback is for cloud folders only; a local file is not one.
    func testALocalFileIsNotACloudItem() throws {
        let file = folder.appendingPathComponent("local")
        try Data("x".utf8).write(to: file)
        XCTAssertFalse(FileOperations.isCloudItem(file))
    }
}
