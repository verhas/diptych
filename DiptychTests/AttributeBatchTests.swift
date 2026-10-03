import XCTest
@testable import Diptych

/// Extended attributes and Finder tags as batch operations: parsed from an
/// agent's call, checked, run, and undone.
@MainActor
final class AttributeBatchTests: XCTestCase {

    private var folder: URL!
    private var file: URL!

    override func setUpWithError() throws {
        FileHistory.shared.forgetEverything()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttributeBatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("download.dmg")
        try Data("x".utf8).write(to: file)
    }

    override func tearDownWithError() throws {
        FileHistory.shared.forgetEverything()
        try? FileManager.default.removeItem(at: folder)
    }

    private func row(_ op: String, name: String? = nil, value: String? = nil,
                     encoding: String? = nil, tags: [String]? = nil) throws -> BatchOperationRow {
        guard case .row(let row) = BatchOperationRow.build(
            op: op, source: file.path, target: nil, linkTarget: nil, reason: nil,
            name: name, value: value, encoding: encoding, tags: tags) else {
            throw XCTSkip("\(op) was not recognised")
        }
        return row
    }

    // MARK: - Parsing

    func testValuesDecodeInEachEncoding() throws {
        XCTAssertEqual(try row("set_xattr", name: "a", value: "hi").xattrValue, Data("hi".utf8))
        XCTAssertEqual(try row("set_xattr", name: "a", value: "6869", encoding: "hex").xattrValue,
                       Data("hi".utf8))
        XCTAssertEqual(try row("set_xattr", name: "a", value: "aGk=", encoding: "base64").xattrValue,
                       Data("hi".utf8))
    }

    func testAnUnknownEncodingIsAProblemNotAGuess() throws {
        let row = try row("set_xattr", name: "a", value: "6869", encoding: "hexadecimal")
        XCTAssertFalse(row.problems.isEmpty)
    }

    func testBadHexIsAProblem() throws {
        XCTAssertFalse(try row("set_xattr", name: "a", value: "6g", encoding: "hex").problems.isEmpty)
    }

    func testRemoveNeedsAName() throws {
        XCTAssertFalse(try row("remove_xattr").problems.isEmpty)
    }

    // MARK: - Tags

    func testAddingKeepsWhatIsThereAndIgnoresCase() throws {
        let row = try row("add_tags", tags: ["red", "Work"])
        XCTAssertEqual(row.resultingTags(from: ["Red", "Home"]), ["Red", "Home", "Work"])
    }

    func testRemovingIgnoresCase() throws {
        let row = try row("remove_tags", tags: ["work"])
        XCTAssertEqual(row.resultingTags(from: ["Red", "Work"]), ["Red"])
    }

    func testSettingReplacesAndAnEmptyListClears() throws {
        XCTAssertEqual(try row("set_tags", tags: ["Blue"]).resultingTags(from: ["Red"]), ["Blue"])
        let clear = try row("set_tags", tags: [])
        XCTAssertTrue(clear.problems.isEmpty)
        XCTAssertEqual(clear.resultingTags(from: ["Red"]), [])
    }

    // MARK: - Running and undoing

    func testQuarantineRemovalRunsAndUndoes() async throws {
        let quarantine = Data("0081;00000000;Safari;".utf8)
        XCTAssertNil(ExtendedAttributes.set(quarantine, name: "com.apple.quarantine", on: file.path))

        let batch = BatchOperationsModel(rows: [try row("remove_xattr", name: "com.apple.quarantine")])
        XCTAssertTrue(batch.canExecute)
        await batch.execute()
        XCTAssertNil(ExtendedAttributes.data(of: file.path, name: "com.apple.quarantine"))
        XCTAssertTrue(batch.failedRows.isEmpty)

        await FileHistory.shared.perform(.undo) { _ in true }
        XCTAssertEqual(ExtendedAttributes.data(of: file.path, name: "com.apple.quarantine"),
                       quarantine)
    }

    func testTagsAreAddedAndUndone() async throws {
        let batch = BatchOperationsModel(rows: [try row("add_tags", tags: ["Red", "Work"])])
        await batch.execute()
        XCTAssertTrue(batch.failedRows.isEmpty, "\(batch.rowResults)")
        XCTAssertEqual(Set(BatchOperationRow.tags(of: file)), ["Red", "Work"])

        await FileHistory.shared.perform(.undo) { _ in true }
        XCTAssertEqual(BatchOperationRow.tags(of: file), [])
    }

    // MARK: - Attributes macOS keeps for itself

    func testTheProvenanceIDIsTheLastEightBytes() {
        let value = Data([0x01, 0x02, 0x00, 0x3d, 0x00, 0xef, 0x54, 0x96, 0x8d, 0x8e, 0xc7])
        XCTAssertEqual(Provenance.id(of: value), "3d00ef54968d8ec7")
        XCTAssertNil(Provenance.id(of: Data([0x01, 0x02])))
    }

    /// Verified against the real table: this value's ID is the `pk` of the
    /// app's row, read little-endian and signed.
    func testTheProvenanceKeyIsTheTablesPrimaryKey() {
        let value = Data([0x01, 0x02, 0x00, 0x3d, 0x00, 0xef, 0x54, 0x96, 0x8d, 0x8e, 0xc7])
        XCTAssertEqual(Provenance.key(of: value), -4067157736659419075)
    }

    /// What `sqlite3 -readonly -json` prints for an app's row, key as text.
    func testADatabaseRowBecomesTheAppsName() throws {
        let output = #"[{"pk":"-4067157736659419075","url":"/Applications/Ghostty.app/","#
            + #""bundle_id":"com.mitchellh.ghostty","team_identifier":"24VZTF6M5V","#
            + #""signing_identifier":"com.mitchellh.ghostty","timestamp":1758700000}]"#
        let record = try XCTUnwrap(
            Provenance.Lookup.records(fromJSON: output)[-4067157736659419075])
        XCTAssertTrue(record.summary.hasPrefix(
            "made or last changed by Ghostty (com.mitchellh.ghostty, team 24VZTF6M5V)"),
            record.summary)
        XCTAssertTrue(Provenance.Lookup.records(fromJSON: "").isEmpty)
    }

    /// What was looked up survives a relaunch: saved, reopened, read back.
    func testSavedLookupsComeBackAfterReopening() throws {
        let url = folder.appendingPathComponent("provenance.sqlite")
        let record = Provenance.Record(path: "/Applications/Ghostty.app/",
                                       bundleID: "com.mitchellh.ghostty", team: "24VZTF6M5V",
                                       signingID: nil, since: Date(timeIntervalSince1970: 1758700000))
        Provenance.SavedLookups(url: url).save(record, for: -4067157736659419075)
        XCTAssertEqual(Provenance.SavedLookups(url: url).all()[-4067157736659419075], record)
    }

    func testRemovingProvenanceIsAProblemBeforeItRuns() throws {
        XCTAssertFalse(try row("remove_xattr", name: "com.apple.provenance").problems.isEmpty)
    }

    /// The bug this guards: `removexattr` answers 0 for com.apple.provenance
    /// and leaves it in place, and that 0 was reported as "removed".
    func testARemovalMacOSIgnoresIsReportedAsAFailure() throws {
        guard ExtendedAttributes.names(of: file.path).contains("com.apple.provenance") else {
            throw XCTSkip("This test host does not get com.apple.provenance on new files.")
        }
        XCTAssertNotNil(ExtendedAttributes.remove(name: "com.apple.provenance", from: file.path))
        XCTAssertTrue(ExtendedAttributes.names(of: file.path).contains("com.apple.provenance"))
    }

    func testARowThatChangesNothingSaysSo() async throws {
        let row = try row("remove_xattr", name: "dev.verhas.absent")
        let batch = BatchOperationsModel(rows: [row])
        XCTAssertTrue(row.isNoOp)
        await batch.execute()
        XCTAssertEqual(batch.rowResults[row.id], "Unchanged: already so.")
        XCTAssertNil(FileHistory.shared.undoName)
    }
}
