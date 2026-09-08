import XCTest
@testable import Diptych

/// The destructive paths.
///
/// Every case here corresponds to a way an earlier version of Diptych could
/// lose data: copying an item onto itself, replacing without a fallback,
/// recursing a folder into itself, or letting a typed name escape its folder.
final class FileOperationsTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: - Helpers

    @discardableResult
    private func makeFile(_ path: String, _ contents: String = "x") throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    private func makeDirectory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func contents(of url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func stagingLeftovers(in directory: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(".diptych-staging") }
    }

    // MARK: - Onto itself

    func testCopyOntoItselfLeavesTheFileAlone() async throws {
        let file = try makeFile("self/f.txt", "original")

        let message = await FileOperations.shared.transferOne(file, to: file,
                                                              kind: .copy, overwrite: true)

        XCTAssertNil(message)
        XCTAssertEqual(contents(of: file), "original",
                       "overwrite removes the target, which here is also the source")
    }

    func testMoveOntoItselfLeavesTheFileAlone() async throws {
        let file = try makeFile("self-move/f.txt", "original")

        _ = await FileOperations.shared.transferOne(file, to: file,
                                                    kind: .move, overwrite: true)

        XCTAssertEqual(contents(of: file), "original")
    }

    // MARK: - Replacing

    func testFailedReplaceKeepsTheExistingDestination() async throws {
        let target = try makeFile("replace/keep.txt", "existing")
        let missing = root.appendingPathComponent("replace/absent.txt")

        let message = await FileOperations.shared.transferOne(missing, to: target,
                                                              kind: .copy, overwrite: true)

        XCTAssertNotNil(message, "copying something that is not there must fail")
        XCTAssertEqual(contents(of: target), "existing",
                       "a failed replace must not consume the destination")
    }

    func testSuccessfulReplaceSwapsContentAndCleansUp() async throws {
        let target = try makeFile("swap/t.txt", "old")
        let source = try makeFile("swap/s.txt", "new")

        let message = await FileOperations.shared.transferOne(source, to: target,
                                                              kind: .copy, overwrite: true)

        XCTAssertNil(message)
        XCTAssertEqual(contents(of: target), "new")
        XCTAssertEqual(stagingLeftovers(in: target.deletingLastPathComponent()), [],
                       "the staging copy must not survive the swap")
    }

    func testFailedCopyLeavesNoPartialTarget() async throws {
        let source = try makeDirectory("partial/tree")
        try makeFile("partial/tree/a.txt")
        // A file where the copy wants to create a directory.
        let target = try makeFile("partial/blocked", "occupied")

        let message = await FileOperations.shared.transferOne(source, to: target,
                                                              kind: .copy, overwrite: false)

        XCTAssertNotNil(message)
        XCTAssertEqual(contents(of: target), "occupied",
                       "cleanup must not delete a destination this call did not create")
    }

    // MARK: - Into itself

    func testCopyIntoOwnDescendantIsRefused() async throws {
        let source = try makeDirectory("descend/tree")
        try makeFile("descend/tree/child/f.txt")
        let inside = source.appendingPathComponent("child/tree")

        let message = await FileOperations.shared.transferOne(source, to: inside,
                                                              kind: .copy, overwrite: false)

        XCTAssertEqual(message, "A folder cannot be copied into itself.")
        XCTAssertFalse(fm.fileExists(atPath: inside.path))
    }

    func testMoveIntoOwnDescendantIsRefused() async throws {
        let source = try makeDirectory("descend-move/tree")
        try makeDirectory("descend-move/tree/child")
        let inside = source.appendingPathComponent("child/tree")

        let message = await FileOperations.shared.transferOne(source, to: inside,
                                                              kind: .move, overwrite: false)

        XCTAssertEqual(message, "A folder cannot be moved into itself.")
    }

    /// The trap that made the first descendant guard useless:
    /// `resolvingSymlinksInPath()` rewrites `/private/tmp/x` to `/tmp/x` only
    /// when the path exists, so an existing parent and a not-yet-created child
    /// canonicalised differently and the comparison silently answered false.
    func testCanonicalPathAgreesForExistingAndMissingPaths() throws {
        let existing = try makeDirectory("canon/here")
        let missing = existing.appendingPathComponent("not/created/yet")

        XCTAssertTrue(FileOperations.canonicalPath(missing)
                        .hasPrefix(FileOperations.canonicalPath(existing) + "/"))
        XCTAssertTrue(FileOperations.isDescendant(missing, of: existing))
    }

    // MARK: - Names

    func testSafeChildRejectsAnythingThatIsNotAName() throws {
        let parent = try makeDirectory("names")

        XCTAssertNil(FileOperations.safeChild(named: "../escaped", in: parent))
        XCTAssertNil(FileOperations.safeChild(named: "a/b", in: parent))
        XCTAssertNil(FileOperations.safeChild(named: "..", in: parent))
        XCTAssertNil(FileOperations.safeChild(named: ".", in: parent))
        XCTAssertNil(FileOperations.safeChild(named: "   ", in: parent))
        XCTAssertNotNil(FileOperations.safeChild(named: "ordinary.txt", in: parent))
        XCTAssertNotNil(FileOperations.safeChild(named: ".hidden", in: parent))
    }

    func testRenameCannotEscapeItsFolder() async throws {
        let file = try makeFile("escape/inner/f.txt")
        let escaped = root.appendingPathComponent("escape/escaped.txt")

        do {
            _ = try await FileOperations.shared.rename(file, to: "../escaped.txt")
            XCTFail("rename should reject a name containing a separator")
        } catch {}

        XCTAssertFalse(fm.fileExists(atPath: escaped.path))
        XCTAssertTrue(fm.fileExists(atPath: file.path), "the original must be untouched")
    }

    func testCreateDirectoryCannotEscapeItsParent() async throws {
        let parent = try makeDirectory("mkdir/inner")
        let escaped = root.appendingPathComponent("mkdir/escaped")

        do {
            _ = try await FileOperations.shared.createDirectory(named: "../escaped", in: parent)
            XCTFail("createDirectory should reject a name containing a separator")
        } catch {}

        XCTAssertFalse(fm.fileExists(atPath: escaped.path))
    }

    func testUniqueNamesCountFromOneAndUseADash() throws {
        let file = try makeFile("unique/report.pdf")

        let first = FileOperations.uniqueURL(for: file)
        XCTAssertEqual(first.lastPathComponent, "report-1.pdf")

        try "x".write(to: first, atomically: true, encoding: .utf8)
        XCTAssertEqual(FileOperations.uniqueURL(for: file).lastPathComponent, "report-2.pdf")
    }

    // MARK: - Permission bits

    func testMergingKeepsEverythingAboveTheNineBits() {
        // 4755 = setuid + rwxr-xr-x
        XCTAssertEqual(FileOperations.merging(0o644, into: 0o4755), 0o4644)
        XCTAssertEqual(FileOperations.merging(0o777, into: 0o1755), 0o1777)
        XCTAssertEqual(FileOperations.merging(0o600, into: 0o2644), 0o2600)
        XCTAssertEqual(FileOperations.merging(0o644, into: 0o755), 0o644)
    }

    func testRwxStringShowsTheSpecialBitsWhereLsDoes() {
        // setuid, execute on: "s" in the user triple -- /usr/bin/sudo is 4511.
        XCTAssertEqual(FileOperations.rwxString(0o4511), "r-s--x--x")
        // sticky, execute on: "t" in the other triple -- /tmp is 1777.
        XCTAssertEqual(FileOperations.rwxString(0o1777), "rwxrwxrwt")
        // Special bit set while execute is off: capital.
        XCTAssertEqual(FileOperations.rwxString(0o4644), "rwSr--r--")
        XCTAssertEqual(FileOperations.rwxString(0o2644), "rw-r-Sr--")
        XCTAssertEqual(FileOperations.rwxString(0o1666), "rw-rw-rwT")
        // Nothing special: unchanged.
        XCTAssertEqual(FileOperations.rwxString(0o755), "rwxr-xr-x")
    }

    func testTheEditorOwnsAllTwelveBits() async throws {
        let file = try makeFile("twelve/tool", "x")
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o4755)],
                             ofItemAtPath: file.path)

        // Editing with the full mask clears setuid, because the editor can now
        // show and change it.
        _ = await FileOperations.shared.setPermissions(0o0644, mask: 0o7777, for: [file])
        XCTAssertEqual(try FileOperations.currentMode(of: file) & 0o7777, 0o644)

        // And can set it again.
        _ = await FileOperations.shared.setPermissions(0o4755, mask: 0o7777, for: [file])
        XCTAssertEqual(try FileOperations.currentMode(of: file) & 0o7777, 0o4755)
    }

    func testEditingPermissionsKeepsSetuidAndSticky() async throws {
        let file = try makeFile("special/tool", "x")
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o4755)],
                             ofItemAtPath: file.path)

        let outcome = await FileOperations.shared.setPermissions(0o644, for: [file])

        XCTAssertTrue(outcome.isCompleteSuccess)
        let mode = try FileOperations.currentMode(of: file)
        XCTAssertEqual(mode & 0o777, 0o644, "the nine bits are the editor's business")
        XCTAssertEqual(mode & 0o4000, 0o4000, "setuid is not, and must survive")
    }

    func testCaseOnlyRenameSucceeds() async throws {
        let file = try makeFile("case/notes.txt", "body")

        let renamed = try await FileOperations.shared.rename(file, to: "Notes.txt")

        XCTAssertEqual(renamed.lastPathComponent, "Notes.txt")
        XCTAssertEqual(contents(of: renamed), "body")
        let names = try fm.contentsOfDirectory(atPath: renamed.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["Notes.txt"], "no hidden temporary name may survive")
    }
}
