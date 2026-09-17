import XCTest
@testable import Diptych

/// Which programs hold a file open, through libproc.
///
/// The test process is the program under observation: it opens the files
/// itself, so every expectation is about a descriptor this test can see.
final class OpenFilesTests: XCTestCase {

    private var folder: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychOpen-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: folder)
    }

    private func file(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("text".utf8).write(to: url)
        return url
    }

    private var us: pid_t { ProcessInfo.processInfo.processIdentifier }

    func testAFileThisProcessHasOpenForWritingIsFound() throws {
        let url = try file("written.txt")
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let report = OpenFiles.holders(of: url)

        let ours = report.holders.filter { $0.pid == us }
        XCTAssertEqual(ours.count, 1, "\(report.holders)")
        XCTAssertTrue(ours.first?.isWriting ?? false, "open for writing")
        XCTAssertFalse(ours.first?.program.isEmpty ?? true, "the program is named")
    }

    func testAFileOpenForReadingIsNotReportedAsWriting() throws {
        let url = try file("read.txt")
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let report = OpenFiles.holders(of: url)

        let ours = try XCTUnwrap(report.holders.first { $0.pid == us })
        XCTAssertFalse(ours.isWriting)
        XCTAssertEqual(ours.kind.describes, "open for reading")
    }

    func testAFileNobodyHasOpenIsEmpty() throws {
        let url = try file("quiet.txt")

        let report = OpenFiles.holders(of: url)

        XCTAssertTrue(report.isEmpty, "\(report.holders)")
        XCTAssertNil(report.failure)
    }

    func testAClosedFileIsNoLongerReported() throws {
        let url = try file("closed.txt")
        let handle = try FileHandle(forWritingTo: url)
        try handle.close()

        XCTAssertTrue(OpenFiles.holders(of: url).isEmpty)
    }

    func testAPathThroughASymlinkIsTheSameFile() throws {
        // The kernel answers with the real path where Foundation may have been
        // given a symlinked one -- /tmp against /private/tmp is the everyday
        // case, and it is how the first attempt at this found nothing at all.
        let real = folder.appendingPathComponent("real")
        try manager.createDirectory(at: real, withIntermediateDirectories: true)
        let url = real.appendingPathComponent("spelt.txt")
        try Data("text".utf8).write(to: url)
        let link = folder.appendingPathComponent("link")
        try manager.createSymbolicLink(at: link, withDestinationURL: real)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let throughLink = link.appendingPathComponent("spelt.txt")

        XCTAssertFalse(OpenFiles.holders(of: throughLink).isEmpty,
                       "asked by its other spelling, \(throughLink.path)")
    }

    func testTheCountsSayHowMuchCouldBeSeen() throws {
        let report = OpenFiles.holders(of: try file("counted.txt"))

        XCTAssertGreaterThan(report.processes, 1, "there is more than one process on a Mac")
        XCTAssertGreaterThan(report.looked, 0, "our own could be looked inside")
        XCTAssertLessThanOrEqual(report.looked + report.refused, report.processes)
        XCTAssertLessThan(abs(report.at.timeIntervalSinceNow), 10, "the answer is dated")
    }

    func testARunOutOfTimeIsSaidRatherThanHidden() throws {
        let url = try file("slow.txt")

        let report = OpenFiles.holders(of: url, deadline: 0)

        XCTAssertTrue(report.incomplete)
        XCTAssertNil(report.failure, "not a failure: an answer that is not the whole answer")
    }

    func testAFolderReportsWhatIsInItAndWhoIsStandingInIt() throws {
        // A process's current folder is not an open file, and for a folder it
        // is the more useful half of the answer.
        let was = manager.currentDirectoryPath
        defer { manager.changeCurrentDirectoryPath(was) }
        XCTAssertTrue(manager.changeCurrentDirectoryPath(folder.path))

        let report = OpenFiles.holders(of: folder)

        let ours = report.holders.filter { $0.pid == us }
        XCTAssertTrue(ours.contains { $0.kind == .currentFolder }, "\(report.holders)")
    }

    func testAFolderReportsWhatIsOpenInsideIt() throws {
        // The useful question about a folder is what is open *in* it -- that
        // is what stops it being moved or trashed.
        let inside = folder.appendingPathComponent("deep/notes.txt")
        try manager.createDirectory(at: inside.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        try Data("text".utf8).write(to: inside)
        let handle = try FileHandle(forWritingTo: inside)
        defer { try? handle.close() }

        let report = OpenFiles.holders(of: folder)

        let ours = try XCTUnwrap(report.holders.first { $0.pid == us && $0.path != nil })
        XCTAssertEqual(ours.path, inside.resolvingSymlinksInPath().path,
                       "it says which file, not just that something is open")
        XCTAssertTrue(ours.isWriting)
    }

    func testAFileIsNotReportedAsSomethingInsideItself() throws {
        let url = try file("plain.txt")
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let ours = try XCTUnwrap(OpenFiles.holders(of: url).holders.first { $0.pid == us })

        XCTAssertNil(ours.path, "the file asked about needs no second mention")
    }

    /// The Info window's own path: the model asks, off the main thread, and
    /// keeps the answer for the tab to show.
    @MainActor
    func testTheInfoWindowModelFillsTheTab() async throws {
        let url = try file("shown.txt")
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let model = FileInfoModel(url: url)

        model.lookForOpenBy()
        for _ in 0 ..< 100 where model.openBy == nil {
            try await Task.sleep(for: .milliseconds(50))
        }

        let report = try XCTUnwrap(model.openBy)
        XCTAssertFalse(model.isLookingForOpenBy)
        XCTAssertTrue(report.holders.contains { $0.pid == us }, "\(report.holders)")
    }

    func testTheWriterIsListedFirst() throws {
        let url = try file("both.txt")
        let reader = try FileHandle(forReadingFrom: url)
        let writer = try FileHandle(forWritingTo: url)
        defer { try? reader.close(); try? writer.close() }

        let report = OpenFiles.holders(of: url)

        XCTAssertEqual(report.holders.count, 2, "\(report.holders)")
        XCTAssertTrue(report.holders.first?.isWriting ?? false, "the one changing it comes first")
    }
}
