import XCTest
@testable import Diptych

/// Metadata writes that the file's permissions refuse.
///
/// The bug these exist for: adding an extended attribute to a read-only file
/// failed with EACCES and Diptych reported nothing, so the attribute simply did
/// not appear and no one was told why.
final class MetadataWriteTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychMetadata-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Read-only fixtures would otherwise stay behind.
        if let items = try? fm.contentsOfDirectory(atPath: root.path) {
            for item in items {
                try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o644)],
                                      ofItemAtPath: root.appendingPathComponent(item).path)
            }
        }
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func makeFile(_ name: String, mode: mode_t = 0o644) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
        return url
    }

    /// Runs a privileged-path command *without* privileges, which is enough to
    /// check that it is well-formed and correctly quoted.
    @discardableResult
    private func run(_ command: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - The refusal is visible

    func testWritingToUnwritableFileReportsPermissionDenied() throws {
        let file = try makeFile("locked.txt", mode: 0o444)

        let failure = ExtendedAttributes.set(Data("v".utf8), name: "dev.diptych.test",
                                             on: file.path)

        let reported = try XCTUnwrap(failure, "a refused write must not look like a success")
        XCTAssertTrue(reported.isPermissionDenied)
        XCTAssertEqual(reported.code, EACCES)
    }

    func testEncodingFailureIsNotMistakenForPermissionDenied() {
        // Only a refusal opens the unlock ladder; our own errors must not.
        XCTAssertFalse(ExtendedAttributes.Failure(message: "unencodable").isPermissionDenied)
    }

    func testWritableFileNeedsNoRecovery() async throws {
        let file = try makeFile("open.txt")

        let outcome = await MainActor.run {
            MetadataWrite.xattrs([XattrWrite(name: "dev.diptych.test", data: Data([0x01, 0x02]))],
                                 on: file, action: "add the attribute").perform()
        }

        guard case .succeeded(let warning) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNil(warning)
        XCTAssertEqual(ExtendedAttributes.data(of: file.path, name: "dev.diptych.test"),
                       Data([0x01, 0x02]))
    }

    // MARK: - Unlock, change, restore

    func testUnlockingWritesAndPutsThePermissionsBack() async throws {
        let file = try makeFile("locked.txt", mode: 0o444)
        let write = XattrWrite(name: "dev.diptych.test", data: Data("v".utf8))

        let outcome = await MainActor.run {
            MetadataWrite.xattrs([write], on: file, action: "add the attribute")
                .unlockedWrite(restoring: 0o444)
        }

        guard case .succeeded(let warning) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNil(warning)
        XCTAssertEqual(ExtendedAttributes.data(of: file.path, name: "dev.diptych.test"),
                       Data("v".utf8))
        XCTAssertEqual(try FileOperations.currentMode(of: file), 0o444,
                       "the file must not be left writable")
    }

    func testPermissionsGoBackEvenWhenTheWriteStillFails() async throws {
        let file = try makeFile("locked.txt", mode: 0o444)
        // An empty name is rejected by setxattr whatever the permissions are,
        // so the restore has to happen on the failing path too.
        let write = XattrWrite(name: "", data: Data("v".utf8))

        let outcome = await MainActor.run {
            MetadataWrite.xattrs([write], on: file, action: "add the attribute")
                .unlockedWrite(restoring: 0o444)
        }

        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try FileOperations.currentMode(of: file), 0o444,
                       "a failed change must not leave the file writable")
    }

    func testUnlockingPreservesTheSpecialBits() async throws {
        let file = try makeFile("setgid.txt", mode: 0o2444)
        let write = XattrWrite(name: "dev.diptych.test", data: Data("v".utf8))

        let outcome = await MainActor.run {
            MetadataWrite.xattrs([write], on: file, action: "add the attribute")
                .unlockedWrite(restoring: 0o2444)
        }

        guard case .succeeded = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try FileOperations.currentMode(of: file), 0o2444)
    }

    // MARK: - The privileged equivalent

    func testPrivilegedCommandWritesTheSameBytes() throws {
        // Awkward on purpose: the name that started this carries an apostrophe,
        // and a tag payload is a binary plist full of bytes a shell would eat.
        let file = try makeFile("quote'apostrophe.txt")
        let payload = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x00, 0xFF, 0x0A])
        let write = XattrWrite(name: "dev.diptych.test", data: payload)

        let command = try XCTUnwrap(write.command(for: file.path))
        XCTAssertEqual(try run(command), 0, command)

        XCTAssertEqual(ExtendedAttributes.data(of: file.path, name: "dev.diptych.test"), payload)
    }

    func testPrivilegedRemovalIsSkippedWhenTheAttributeIsAbsent() throws {
        // `xattr -d` fails on a missing attribute, which would fail the whole
        // escalated command for a step that had nothing to do.
        let file = try makeFile("plain.txt")
        let write = XattrWrite(name: "dev.diptych.absent", data: nil)

        XCTAssertNil(write.command(for: file.path))
        XCTAssertNil(write.apply(to: file.path), "nor is it a failure in-process")
    }

    func testPrivilegedRemovalCommandRemovesTheAttribute() throws {
        let file = try makeFile("tagged.txt")
        XCTAssertNil(ExtendedAttributes.set(Data("v".utf8), name: "dev.diptych.test",
                                            on: file.path))

        let command = try XCTUnwrap(XattrWrite(name: "dev.diptych.test", data: nil)
                                        .command(for: file.path))
        XCTAssertEqual(try run(command), 0)
        XCTAssertNil(ExtendedAttributes.data(of: file.path, name: "dev.diptych.test"))
    }

    func testTagChangeWritesBothAttributesTogether() throws {
        let file = try makeFile("coloured.txt")

        let writes = try FinderTag.writes(for: ["Red"], on: file.path)
        for write in writes { XCTAssertNil(write.apply(to: file.path)) }

        XCTAssertNotNil(ExtendedAttributes.data(of: file.path, name: FinderTag.xattrName))
        let info = try XCTUnwrap(ExtendedAttributes.data(of: file.path,
                                                         name: FinderInfo.xattrName))
        // Red is colour 6, held in bits 1-3 of the flags at offset 8.
        XCTAssertEqual((Int(info[9]) >> 1) & 0x7, FinderTag.colourIndex(of: "Red"))
    }

    func testClearingTagsRemovesBothAttributes() throws {
        let file = try makeFile("uncoloured.txt")
        for write in try FinderTag.writes(for: ["Red"], on: file.path) {
            XCTAssertNil(write.apply(to: file.path))
        }

        for write in try FinderTag.writes(for: [], on: file.path) {
            XCTAssertNil(write.apply(to: file.path))
        }

        XCTAssertNil(ExtendedAttributes.data(of: file.path, name: FinderTag.xattrName))
        XCTAssertNil(ExtendedAttributes.data(of: file.path, name: FinderInfo.xattrName),
                     "all-zero Finder info is the same as none")
    }

    // MARK: - Folder icons

    func testTintingAFolderSetsBothPiecesAndUnsettingClearsThem() throws {
        let folder = root.appendingPathComponent("tinted")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        for write in FolderIcon.writes(customised: true, symbol: "star.fill", on: folder.path) {
            XCTAssertNil(write.apply(to: folder.path))
        }
        XCTAssertTrue(FolderIcon.isCustomised(folder.path))
        XCTAssertEqual(FolderIcon.symbol(of: folder.path), "star.fill")

        for write in FolderIcon.writes(customised: false, symbol: "", on: folder.path) {
            XCTAssertNil(write.apply(to: folder.path))
        }
        XCTAssertFalse(FolderIcon.isCustomised(folder.path))
        XCTAssertNil(FolderIcon.symbol(of: folder.path),
                     "switching the icon off must not leave the symbol behind")
    }

    func testFolderIconAndTagShareTheFlagWordWithoutClobberingEachOther() throws {
        // Both write com.apple.FinderInfo: the label lives in bits 1-3 and the
        // custom-icon flag in bit 10 of the same 16-bit word.
        let folder = root.appendingPathComponent("both")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        for write in FolderIcon.writes(customised: true, symbol: "eyebrow", on: folder.path) {
            XCTAssertNil(write.apply(to: folder.path))
        }
        for write in try FinderTag.writes(for: ["Red"], on: folder.path) {
            XCTAssertNil(write.apply(to: folder.path))
        }

        XCTAssertTrue(FolderIcon.isCustomised(folder.path), "the tag must not clear the flag")
        let flags = FinderInfo.flags(of: folder.path)
        XCTAssertEqual(Int(flags >> 1) & 0x7, FinderTag.colourIndex(of: "Red"))

        // ...and back the other way.
        for write in FolderIcon.writes(customised: true, symbol: "star", on: folder.path) {
            XCTAssertNil(write.apply(to: folder.path))
        }
        XCTAssertEqual(Int(FinderInfo.flags(of: folder.path) >> 1) & 0x7,
                       FinderTag.colourIndex(of: "Red"),
                       "the folder icon must not clear the label")
    }

    func testEveryCataloguedSymbolExistsOnThisSystem() {
        // A symbol added in a later SF Symbols release renders as nothing at
        // all rather than failing, so a stale name would be an invisible cell.
        for group in SymbolCatalog.groups {
            for symbol in group.symbols {
                XCTAssertTrue(SymbolCatalog.exists(symbol), "\(group.name): \(symbol)")
            }
        }
        XCTAssertGreaterThan(SymbolCatalog.all.count, 100, "the catalogue was filtered away")
    }

    func testSearchingFallsThroughToSymbolsOutsideTheCatalogue() {
        // The picker is a convenience, not a limit: a real symbol name typed in
        // full is offered even when it is not one of ours.
        XCTAssertEqual(SymbolCatalog.matches("swift"), ["swift"])
        XCTAssertTrue(SymbolCatalog.matches("definitely.not.a.symbol").isEmpty)
        XCTAssertTrue(SymbolCatalog.matches("star").contains("star"))
        XCTAssertEqual(SymbolCatalog.matches("  "), SymbolCatalog.all)
    }

    func testACLCommandRestoresTheSameEntry() throws {
        let file = try makeFile("acl.txt")
        // `acl_from_text` only reads its own canonical output, so the entry is
        // laid down with chmod and read back in the form the editor shows.
        XCTAssertEqual(try run("/bin/chmod +a '\(NSUserName()) allow read' \(file.path)"), 0)
        let wanted = try XCTUnwrap(AccessControl.text(of: file.path))

        // Round trip: the command has to reproduce what we could set ourselves,
        // translated out of the UUID form that chmod refuses.
        let command = try XCTUnwrap(AccessControl.command(setting: wanted, on: file.path))
        XCTAssertNil(AccessControl.setText("", on: file.path))
        XCTAssertEqual(try run(command), 0, command)

        XCTAssertEqual(AccessControl.text(of: file.path), wanted)
    }

    func testACLRemovalCommandRemovesIt() throws {
        let file = try makeFile("acl-gone.txt")
        XCTAssertEqual(try run("/bin/chmod +a '\(NSUserName()) allow read' \(file.path)"), 0)

        let command = try XCTUnwrap(AccessControl.command(setting: "", on: file.path))
        XCTAssertEqual(try run(command), 0, command)

        XCTAssertNil(AccessControl.text(of: file.path))
    }

    func testUntranslatableACLOffersNoEscalation() {
        // Better no escalated path than one that applies the entry to whoever
        // `chmod` happens to parse out of a name with a space in it.
        let text = "!#acl 1\nuser:ABC:Domain Admins:502:allow:read\n"
        XCTAssertNil(AccessControl.command(setting: text, on: "/tmp/x"))
    }
}
