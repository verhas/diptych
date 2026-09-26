import XCTest
@testable import Diptych

/// Which version's release notes have already been shown, kept in its own
/// file under `~/.diptych` rather than in `config.json`. Follows the same
/// snapshot-and-restore convention `LiveSettings` uses for config.json,
/// since this test works against the same real file the running app reads.
@MainActor
final class ReleaseNotesSeenTests: XCTestCase {

    private var originalFile: Data??

    override func setUp() {
        originalFile = .some(try? Data(contentsOf: ReleaseNotesSeen.url))
    }

    override func tearDown() {
        guard let originalFile else { return }
        if let data = originalFile {
            try? data.write(to: ReleaseNotesSeen.url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: ReleaseNotesSeen.url)
        }
    }

    func testANeverRecordedVersionShouldShow() throws {
        try? FileManager.default.removeItem(at: ReleaseNotesSeen.url)
        XCTAssertTrue(ReleaseNotesSeen.shouldShow)
    }

    func testMarkingShownRecordsTheRunningVersion() throws {
        ReleaseNotesSeen.markShown()
        let recorded = try String(contentsOf: ReleaseNotesSeen.url, encoding: .utf8)
        XCTAssertEqual(recorded, ReleaseNotesSeen.currentVersion)
    }

    func testMarkingShownStopsShowingForThatSameVersion() {
        ReleaseNotesSeen.markShown()
        XCTAssertFalse(ReleaseNotesSeen.shouldShow)
    }

    func testARecordFromADifferentVersionStillShouldShow() throws {
        try "not.a.real.version".write(to: ReleaseNotesSeen.url, atomically: true, encoding: .utf8)
        XCTAssertTrue(ReleaseNotesSeen.shouldShow)
    }
}
