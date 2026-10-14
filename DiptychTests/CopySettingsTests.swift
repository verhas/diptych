import XCTest
import Darwin
@testable import Diptych

/// What a copy keeps besides its bytes, as Settings ▸ Behaviour ▸ Copying
/// says.
final class CopySettingsTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    private let created = FileHistory.FileTime(seconds: 1_600_000_000, nanoseconds: 987_654_321)
    private let modified = FileHistory.FileTime(seconds: 1_700_000_000, nanoseconds: 123_456_789)
    private let acl = "!#acl 1\nuser:FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000063:nobody:99:deny:write\n"
    private let quarantine = "0081;00000000;DiptychTests;"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychCopySettings-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    /// A folder with a file in it, both carrying everything a copy may or
    /// may not take along.
    private func makeTree() throws -> URL {
        let folder = root.appendingPathComponent("tree")
        let file = folder.appendingPathComponent("file.txt")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: file)
        for url in [file, folder] {
            XCTAssertNil(ExtendedAttributes.set(Data("v".utf8), name: "dev.diptych.test",
                                                on: url.path))
            XCTAssertNil(ExtendedAttributes.set(Data(quarantine.utf8),
                                                name: "com.apple.quarantine", on: url.path))
            XCTAssertNil(AccessControl.setText(acl, on: url.path))
            XCTAssertEqual(chmod(url.path, url == file ? 0o604 : 0o705), 0)
            try FileHistory.setDate(.modified, modified, of: url)
            try FileHistory.setDate(.created, created, of: url)
        }
        return folder
    }

    private func copy(_ source: URL, _ settings: CopySettings, progress: Bool,
                      kind: FileOperations.Transfer = .copy) async throws -> URL {
        let target = root.appendingPathComponent("copy")
        let failure = await FileOperations.shared.transferOne(
            source, to: target, kind: kind, overwrite: false,
            monitor: progress ? TransferMonitor() : nil, copying: settings)
        XCTAssertNil(failure)
        return target
    }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        stat(url.path, &info)
        return info.st_mode & 0o7777
    }

    private func items(_ copy: URL) -> [URL] {
        [copy, copy.appendingPathComponent("file.txt")]
    }

    // MARK: - Everything kept

    func testByDefaultACopyKeepsEverything() async throws {
        for progress in [true, false] {
            let copy = try await copy(try makeTree(), CopySettings(), progress: progress)
            for url in items(copy) {
                let what = "\(url.lastPathComponent), progress \(progress)"
                XCTAssertEqual(FileHistory.exactDate(.created, of: url), created, what)
                XCTAssertEqual(FileHistory.exactDate(.modified, of: url), modified, what)
                XCTAssertEqual(ExtendedAttributes.data(of: url.path, name: "dev.diptych.test"),
                               Data("v".utf8), what)
                XCTAssertNotNil(AccessControl.text(of: url.path), what)
                XCTAssertEqual(mode(url), url == copy ? 0o705 : 0o604, what)
            }
            try fm.removeItem(at: root.appendingPathComponent("tree"))
            try fm.removeItem(at: copy)
        }
    }

    // MARK: - Nothing kept

    func testACopyCanStartFresh() async throws {
        var settings = CopySettings()
        settings.extendedAttributes = false
        settings.accessControlList = false
        settings.createdDate = .now
        settings.modifiedDate = .now
        settings.permissions = .umask
        let mask = CopySettings.processUmask

        for progress in [true, false] {
            let before = Date().timeIntervalSince1970 - 1
            let copy = try await copy(try makeTree(), settings, progress: progress)
            for url in items(copy) {
                let what = "\(url.lastPathComponent), progress \(progress)"
                for which in [FileHistory.DateChange.Which.created, .modified] {
                    let date = try XCTUnwrap(FileHistory.exactDate(which, of: url))
                    XCTAssertGreaterThan(Double(date.seconds), before, "\(which) \(what)")
                }
                XCTAssertNil(ExtendedAttributes.data(of: url.path, name: "dev.diptych.test"), what)
                // Present, not equal: macOS rewrites the mark on a copy.
                XCTAssertNotNil(ExtendedAttributes.data(of: url.path, name: "com.apple.quarantine"),
                                "a downloaded file stays quarantined: \(what)")
                XCTAssertNil(AccessControl.text(of: url.path), what)
                XCTAssertEqual(mode(url), (url == copy ? 0o777 : 0o666) & ~mask, what)
            }
            try fm.removeItem(at: root.appendingPathComponent("tree"))
            try fm.removeItem(at: copy)
        }
    }

    func testEachDateCanBeChosenOnItsOwn() async throws {
        var settings = CopySettings()
        settings.modifiedDate = .now
        let before = Date().timeIntervalSince1970 - 1
        let copy = try await copy(try makeTree(), settings, progress: true)
        let file = copy.appendingPathComponent("file.txt")

        XCTAssertEqual(FileHistory.exactDate(.created, of: file), created)
        let date = try XCTUnwrap(FileHistory.exactDate(.modified, of: file))
        XCTAssertGreaterThan(Double(date.seconds), before)
    }

    func testFilesAndFoldersGetTheirOwnPermissionsSpecialBitsIncluded() async throws {
        var settings = CopySettings()
        settings.permissions = .fixed
        settings.filePermissions = "rwSr-x--T"
        settings.folderPermissions = "rwxr-s--t"
        let copy = try await copy(try makeTree(), settings, progress: true)

        XCTAssertEqual(mode(copy.appendingPathComponent("file.txt")), 0o5650,
                       "setuid and sticky on a file, as asked, used or not")
        XCTAssertEqual(mode(copy), 0o3751)
    }

    // MARK: - Group

    /// A group of the user's other than `gid`, or nil when there is none.
    private func otherGroup(than gid: gid_t) -> gid_t? {
        var groups = [gid_t](repeating: 0, count: 64)
        let count = getgroups(Int32(groups.count), &groups)
        return groups.prefix(Int(max(count, 0))).first { $0 != gid }
    }

    private func group(_ url: URL) -> gid_t {
        var info = stat()
        lstat(url.path, &info)
        return info.st_gid
    }

    /// A folder to copy into, of another group of the user's, with setgid or not.
    private func destination(setgid: Bool, original: URL) throws -> (URL, gid_t) {
        let folder = root.appendingPathComponent("into")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let other = try XCTUnwrap(otherGroup(than: group(original)),
                                  "the user belongs to one group only")
        XCTAssertEqual(lchown(folder.path, uid_t.max, other), 0)
        XCTAssertEqual(chmod(folder.path, setgid ? 0o2755 : 0o755), 0)
        return (folder, other)
    }

    private func copy(_ source: URL, into folder: URL, _ settings: CopySettings) async -> URL {
        let target = folder.appendingPathComponent(source.lastPathComponent)
        let failure = await FileOperations.shared.transferOne(
            source, to: target, kind: .copy, overwrite: false,
            monitor: TransferMonitor(), copying: settings)
        XCTAssertNil(failure)
        return target
    }

    func testACopyInASetgidFolderTakesTheFoldersGroup() async throws {
        let tree = try makeTree()
        let file = tree.appendingPathComponent("file.txt")
        XCTAssertEqual(chmod(file.path, 0o4755), 0)
        let original = group(file)
        let (folder, other) = try destination(setgid: true, original: tree)
        var settings = CopySettings()
        settings.group = .setgid

        let copy = await copy(tree, into: folder, settings)

        XCTAssertEqual(group(copy), other)
        XCTAssertEqual(group(copy.appendingPathComponent("file.txt")), original,
                       "the copied folder has no setgid of its own, so its file keeps its group")
    }

    func testASetuidFileKeepsItsBitsWhenItTakesTheFoldersGroup() async throws {
        let tree = try makeTree()
        let file = tree.appendingPathComponent("file.txt")
        XCTAssertEqual(chmod(file.path, 0o4755), 0)
        let (folder, other) = try destination(setgid: true, original: file)
        var settings = CopySettings()
        settings.group = .setgid

        let copy = await copy(file, into: folder, settings)

        XCTAssertEqual(group(copy), other)
        XCTAssertEqual(mode(copy), 0o4755,
                       "changing the group clears setuid; the original's permissions come back")
    }

    func testASetgidCopiedFolderPassesItsGroupOn() async throws {
        let tree = try makeTree()
        XCTAssertEqual(chmod(tree.path, 0o2755), 0)
        let (folder, other) = try destination(setgid: true, original: tree)
        var settings = CopySettings()
        settings.group = .setgid

        let copy = await copy(tree, into: folder, settings)

        XCTAssertEqual(group(copy), other)
        XCTAssertEqual(group(copy.appendingPathComponent("file.txt")), other)
    }

    func testWithoutSetgidOrWithTheOriginalChosenTheGroupIsTheOriginals() async throws {
        let tree = try makeTree()
        let original = group(tree)
        var settings = CopySettings()
        settings.group = .setgid
        let (folder, _) = try destination(setgid: false, original: tree)
        let first = await copy(tree, into: folder, settings)
        XCTAssertEqual(group(first), original)

        try fm.removeItem(at: folder.appendingPathComponent("tree"))
        XCTAssertEqual(chmod(folder.path, 0o2755), 0)
        let second = await copy(tree, into: folder, CopySettings())
        XCTAssertEqual(group(second), original)
    }

    func testAMoveKeepsEverythingWhateverIsSet() async throws {
        var settings = CopySettings()
        settings.extendedAttributes = false
        settings.modifiedDate = .now
        settings.permissions = .umask
        let moved = try await copy(try makeTree(), settings, progress: true, kind: .move)
        let file = moved.appendingPathComponent("file.txt")

        XCTAssertEqual(FileHistory.exactDate(.modified, of: file), modified)
        XCTAssertEqual(ExtendedAttributes.data(of: file.path, name: "dev.diptych.test"),
                       Data("v".utf8))
        XCTAssertEqual(mode(file), 0o604)
    }

    // MARK: - The setting

    func testPermissionsAreReadInLsForm() {
        XCTAssertEqual(CopySettings.mode(from: "rw-r--r--"), 0o644)
        XCTAssertEqual(CopySettings.mode(from: "rwxr-x---"), 0o750)
        XCTAssertEqual(CopySettings.mode(from: "rwsr-sr-t"), 0o7755)
        XCTAssertEqual(CopySettings.mode(from: "rwSr--r-T"), 0o5644)
        for text in ["", "rw-r--r-", "rw-r--r--x", "rw-r--r-s", "xw-r--r--", "644"] {
            XCTAssertNil(CopySettings.mode(from: text), text)
        }
        for mode: mode_t in [0o644, 0o7755, 0o5644, 0o000, 0o777] {
            XCTAssertEqual(CopySettings.mode(from: FileOperations.rwxString(mode)), mode)
        }
    }

    func testAnInvalidFixedPermissionKeepsTheOriginals() {
        var settings = CopySettings()
        settings.permissions = .fixed
        settings.filePermissions = "nonsense"
        XCTAssertNil(settings.mode(folder: false))
        XCTAssertEqual(settings.mode(folder: true), 0o755)
    }

    func testAnOlderConfigurationKeepsEverything() throws {
        let decoded = try JSONDecoder().decode(Configuration.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.copying.keepsEverything)

        var configuration = Configuration()
        configuration.copying.createdDate = .now
        configuration.copying.permissions = .fixed
        configuration.copying.folderPermissions = "rwx--S--T"
        configuration.copying.group = .setgid
        let again = try JSONDecoder().decode(Configuration.self,
                                             from: JSONEncoder().encode(configuration))
        XCTAssertEqual(again.copying, configuration.copying)
    }
}
