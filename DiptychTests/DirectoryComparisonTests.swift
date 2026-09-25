import XCTest
@testable import Diptych

/// Two folders, entry by entry.
final class DirectoryComparisonTests: XCTestCase {

    private var root: URL!
    private var left: URL!
    private var right: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychDirDiff-\(UUID().uuidString)")
        left = root.appendingPathComponent("left")
        right = root.appendingPathComponent("right")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ text: String, at relative: String, in base: URL) throws -> URL {
        let url = base.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func pair(_ pairs: [DirectoryComparison.Pair], _ id: String) -> DirectoryComparison.Pair? {
        pairs.first { $0.id == id }
    }

    // MARK: - The three basic shapes

    func testMatchingFilesWithTheSameEverythingAreTheSame() throws {
        try write("hello", at: "a.txt", in: left)
        try write("hello", at: "a.txt", in: right)

        let pairs = try DirectoryComparison.compare(left: left, right: right)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].status, .same)
        XCTAssertTrue(pairs[0].differences.isEmpty)
        XCTAssertTrue(pairs[0].canOpenComparison)
    }

    func testAFileOnlyOnTheLeftIsReportedAsSuch() throws {
        try write("hello", at: "only-left.txt", in: left)

        let pairs = try DirectoryComparison.compare(left: left, right: right)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].status, .onlyLeft)
        XCTAssertNotNil(pairs[0].left)
        XCTAssertNil(pairs[0].right)
        XCTAssertFalse(pairs[0].canOpenComparison)
    }

    func testAFileOnlyOnTheRightIsReportedAsSuch() throws {
        try write("hello", at: "only-right.txt", in: right)

        let pairs = try DirectoryComparison.compare(left: left, right: right)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].status, .onlyRight)
        XCTAssertNil(pairs[0].left)
        XCTAssertNotNil(pairs[0].right)
    }

    // MARK: - Differing pairs

    func testFilesOfDifferentSizeDifferInSizeAndContent() throws {
        try write("hello", at: "a.txt", in: left)
        try write("hello, world", at: "a.txt", in: right)

        let pairs = try DirectoryComparison.compare(left: left, right: right)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].status, .differs)
        XCTAssertTrue(pairs[0].differences.contains(.size))
        XCTAssertTrue(pairs[0].differences.contains(.content))
    }

    func testFilesOfTheSameSizeButDifferentBytesDifferInContentOnly() throws {
        try write("aaaaa", at: "a.txt", in: left)
        try write("bbbbb", at: "a.txt", in: right)

        let pairs = try DirectoryComparison.compare(left: left, right: right)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertTrue(pairs[0].differences.contains(.content))
        XCTAssertFalse(pairs[0].differences.contains(.size))
    }

    func testFilesThatDifferOnlyInPermissionsAreReportedAsSuch() throws {
        let leftURL = try write("same", at: "a.txt", in: left)
        let rightURL = try write("same", at: "a.txt", in: right)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: leftURL.path)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rightURL.path)

        let pairs = try DirectoryComparison.compare(left: left, right: right)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].status, .differs)
        XCTAssertEqual(pairs[0].differences, .permissions)
    }

    func testFilesThatDifferOnlyInExtendedAttributesAreReportedAsSuch() throws {
        let leftURL = try write("same", at: "a.txt", in: left)
        _ = try write("same", at: "a.txt", in: right)
        XCTAssertNil(ExtendedAttributes.set(Data("tag".utf8), name: "com.diptych.test",
                                           on: leftURL.path))

        let pairs = try DirectoryComparison.compare(left: left, right: right)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].differences, .attributes)
    }

    func testAFileAndAFolderAtTheSamePathDifferInKindAlone() throws {
        try write("hello", at: "thing", in: left)
        try fm.createDirectory(at: right.appendingPathComponent("thing"),
                               withIntermediateDirectories: true)

        let pairs = try DirectoryComparison.compare(left: left, right: right)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].differences, .kind)
    }

    // MARK: - Folders

    func testFoldersAreComparedByPermissionsAndAttributesButNotSizeOrContent() throws {
        try fm.createDirectory(at: left.appendingPathComponent("sub"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: right.appendingPathComponent("sub"),
                               withIntermediateDirectories: true)

        let pairs = try DirectoryComparison.compare(left: left, right: right)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].status, .same)
        XCTAssertTrue(pairs[0].isDirectory)
        // Two matching folders can still be opened -- narrowed to a
        // comparison of their own, not the file comparison window.
        XCTAssertTrue(pairs[0].canOpenComparison)
    }

    // MARK: - Renames

    func testAFileWithTheSameContentUnderADifferentNameIsMatchedAsARename() throws {
        try write("identical bytes", at: "old-name.txt", in: left)
        try write("identical bytes", at: "new-name.txt", in: right)

        let pairs = try DirectoryComparison.compare(left: left, right: right)

        XCTAssertEqual(pairs.count, 1, "one matched pair, not two unmatched halves")
        XCTAssertTrue(pairs[0].isRename)
        // The name itself is the one thing that does differ about a rename,
        // and it is reported as such, even though the bytes agree.
        XCTAssertEqual(pairs[0].status, .differs)
        XCTAssertEqual(pairs[0].differences, .name)
        XCTAssertEqual(pairs[0].left?.relativePath, "old-name.txt")
        XCTAssertEqual(pairs[0].right?.relativePath, "new-name.txt")
    }

    func testFilesOfTheSameSizeButDifferentContentAreNotMatchedAsARename() throws {
        try write("aaaaa", at: "old-name.txt", in: left)
        try write("bbbbb", at: "new-name.txt", in: right)

        let pairs = try DirectoryComparison.compare(left: left, right: right)

        XCTAssertEqual(pairs.count, 2, "same size is not the same content")
        XCTAssertEqual(Set(pairs.map(\.status)), [.onlyLeft, .onlyRight])
    }

    // MARK: - Symlinks

    func testSymlinksAreComparedByTheirTargetRatherThanBeingFollowed() throws {
        try write("target", at: "target.txt", in: left)
        try write("target", at: "target.txt", in: right)
        try fm.createSymbolicLink(atPath: left.appendingPathComponent("link").path,
                                  withDestinationPath: "target.txt")
        try fm.createSymbolicLink(atPath: right.appendingPathComponent("link").path,
                                  withDestinationPath: "elsewhere.txt")

        let pairs = try DirectoryComparison.compare(left: left, right: right)

        let link = pair(pairs, "link")
        XCTAssertNotNil(link)
        XCTAssertEqual(link?.differences, .content)
        XCTAssertFalse(link?.canOpenComparison ?? true, "a symlink is not opened as a file")
    }

    // MARK: - Sorting

    func testPairsComeBackInHierarchicalOrder() throws {
        try write("x", at: "b.txt", in: left)
        try write("x", at: "b.txt", in: right)
        try write("x", at: "sub/a.txt", in: left)
        try write("x", at: "sub/a.txt", in: right)
        try fm.createDirectory(at: left.appendingPathComponent("sub"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: right.appendingPathComponent("sub"),
                               withIntermediateDirectories: true)

        let pairs = try DirectoryComparison.compare(left: left, right: right)
        let order = pairs.map { $0.left?.relativePath ?? "" }

        XCTAssertEqual(order, ["b.txt", "sub", "sub/a.txt"])
    }

    // MARK: - Options

    func testPermissionsAreNotComparedWhenTheOptionIsOff() throws {
        let leftURL = try write("same", at: "a.txt", in: left)
        let rightURL = try write("same", at: "a.txt", in: right)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: leftURL.path)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rightURL.path)

        var options = DirectoryComparison.Options()
        options.comparePermissions = false
        let pairs = try DirectoryComparison.compare(left: left, right: right, options: options)

        XCTAssertEqual(pairs[0].status, .same)
        XCTAssertTrue(pairs[0].differences.isEmpty)
    }

    func testExtendedAttributesAreNotComparedWhenTheOptionIsOff() throws {
        let leftURL = try write("same", at: "a.txt", in: left)
        _ = try write("same", at: "a.txt", in: right)
        XCTAssertNil(ExtendedAttributes.set(Data("tag".utf8), name: "com.diptych.test",
                                           on: leftURL.path))

        var options = DirectoryComparison.Options()
        options.compareAttributes = false
        let pairs = try DirectoryComparison.compare(left: left, right: right, options: options)

        XCTAssertEqual(pairs[0].status, .same)
    }

    /// Size is treated as part of content, not as a fact of its own: a size
    /// difference is exactly what a byte comparison nobody asked for would
    /// have found, so switching content off has to switch it off too. This
    /// used to be wrong -- size was checked unconditionally -- which meant
    /// two files that differed only in bytes an unchecked "Content" was
    /// supposed to excuse still showed up as differing.
    func testSizeIsNotComparedEitherWhenContentIsOff() throws {
        try write("aaaaa", at: "a.txt", in: left)
        try write("bbbbb", at: "a.txt", in: right)
        try write("short", at: "b.txt", in: left)
        try write("much, much longer", at: "b.txt", in: right)

        var options = DirectoryComparison.Options()
        options.compareContent = false
        let pairs = try DirectoryComparison.compare(left: left, right: right, options: options)

        XCTAssertEqual(pair(pairs, "a.txt")?.status, .same)
        XCTAssertEqual(pair(pairs, "b.txt")?.status, .same,
                       "different sizes, but nothing left switched on says so")
    }

    /// The exact shape of the reported bug: permissions the only thing
    /// switched on, content/attributes/ACL switched off, and the two files
    /// differ only in the things that were switched off.
    func testSwitchingEverythingOffExceptPermissionsIgnoresContentAndAttributeDifferences() throws {
        let leftURL = try write("short", at: "README.md", in: left)
        _ = try write("a good deal longer than that", at: "README.md", in: right)
        XCTAssertNil(ExtendedAttributes.set(Data("tag".utf8), name: "com.diptych.test",
                                           on: leftURL.path))

        var options = DirectoryComparison.Options()
        options.compareContent = false
        options.compareAttributes = false
        options.compareACL = false
        // comparePermissions is left at its default, true, and both files
        // were created the same way, so it has nothing to report either.
        let pairs = try DirectoryComparison.compare(left: left, right: right, options: options)

        XCTAssertEqual(pair(pairs, "README.md")?.status, .same)
    }

    func testRenamesAreNotMatchedWhenContentIsNotCompared() throws {
        try write("identical bytes", at: "old-name.txt", in: left)
        try write("identical bytes", at: "new-name.txt", in: right)

        var options = DirectoryComparison.Options()
        options.compareContent = false
        let pairs = try DirectoryComparison.compare(left: left, right: right, options: options)

        XCTAssertEqual(pairs.count, 2, "with no content check there is no way to tell a rename "
                       + "from two unrelated files of the same size")
        XCTAssertEqual(Set(pairs.map(\.status)), [.onlyLeft, .onlyRight])
    }

    // MARK: - Hidden folders

    func testAHiddenFolderIsListedButNotRecursedIntoByDefault() throws {
        try write("exclude", at: ".git/info/exclude", in: left)
        try write("exclude", at: ".git/info/exclude", in: right)

        let pairs = try DirectoryComparison.compare(left: left, right: right)

        XCTAssertNotNil(pair(pairs, ".git"), "the hidden folder itself is still listed")
        XCTAssertNil(pair(pairs, ".git/info"), "nothing under it is, by default")
        XCTAssertNil(pair(pairs, ".git/info/exclude"))
    }

    func testAHiddenFolderIsRecursedIntoWhenTheOptionIsOn() throws {
        try write("exclude", at: ".git/info/exclude", in: left)
        try write("exclude", at: ".git/info/exclude", in: right)

        var options = DirectoryComparison.Options()
        options.recurseHiddenDirectories = true
        let pairs = try DirectoryComparison.compare(left: left, right: right, options: options)

        let file = pair(pairs, ".git/info/exclude")
        XCTAssertNotNil(file)
        XCTAssertEqual(file?.status, .same)
    }

    // MARK: - Dates and ownership

    func testModificationDateIsIgnoredByDefault() throws {
        let leftURL = try write("same", at: "a.txt", in: left)
        let rightURL = try write("same", at: "a.txt", in: right)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)],
                             ofItemAtPath: leftURL.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)],
                             ofItemAtPath: rightURL.path)

        let pairs = try DirectoryComparison.compare(left: left, right: right)

        XCTAssertEqual(pairs[0].status, .same)
    }

    func testModificationDateDifferenceIsReportedWhenTheOptionIsOn() throws {
        let leftURL = try write("same", at: "a.txt", in: left)
        let rightURL = try write("same", at: "a.txt", in: right)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)],
                             ofItemAtPath: leftURL.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)],
                             ofItemAtPath: rightURL.path)

        var options = DirectoryComparison.Options()
        options.compareModificationDate = true
        let pairs = try DirectoryComparison.compare(left: left, right: right, options: options)

        XCTAssertEqual(pairs[0].differences, .modified)
    }

    func testCreationDateDifferenceIsReportedWhenTheOptionIsOn() throws {
        let leftURL = try write("same", at: "a.txt", in: left)
        let rightURL = try write("same", at: "a.txt", in: right)
        try fm.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_000)],
                             ofItemAtPath: leftURL.path)
        try fm.setAttributes([.creationDate: Date(timeIntervalSince1970: 2_000)],
                             ofItemAtPath: rightURL.path)

        var options = DirectoryComparison.Options()
        options.compareCreationDate = true
        let pairs = try DirectoryComparison.compare(left: left, right: right, options: options)

        XCTAssertEqual(pairs[0].differences, .created)
    }

    /// Owner and group are one switch, not two: nothing here has ever asked
    /// about a mismatched owner without also caring about the group.
    func testOwnershipIsIgnoredByDefaultEvenWhenTheOptionWouldHaveNothingToCompareAnyway() throws {
        try write("same", at: "a.txt", in: left)
        try write("same", at: "a.txt", in: right)

        var options = DirectoryComparison.Options()
        options.compareOwnership = true
        let pairs = try DirectoryComparison.compare(left: left, right: right, options: options)

        // Both files were made by the same process, so there is nothing to
        // tell apart -- this only confirms the option does not crash or flag
        // a false difference against itself.
        XCTAssertEqual(pairs[0].status, .same)
    }
}
