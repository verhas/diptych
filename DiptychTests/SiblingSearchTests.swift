import XCTest
@testable import Diptych

/// Finding a file's other names -- its hard links -- outwards from its folder.
final class SiblingSearchTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        // Real path: the walk reports what it reads, and /var is /private/var.
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Siblings-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        let resolved = realpath(temporary.path, nil)!
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved))
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func names(from url: URL) -> (found: [String], folders: Int) {
        let target = SiblingWalker.target(of: url)!
        var found: [String] = []
        var folders = 0
        SiblingWalker.search(from: url, for: target, cancelled: CancellationFlag()) { event in
            switch event {
            case .found(let path): found.append(path)
            case .progress(_, let count): folders = count
            case .unreadable: break
            }
        }
        return (found, folders)
    }

    /// Its own folder, then below it, then the folder above without the
    /// branch already read.
    func testNamesAreFoundNearestFirst() throws {
        let home = try folder("top/here")
        let file = home.appendingPathComponent("file")
        try Data("x".utf8).write(to: file)
        let below = try folder("top/here/deeper/still")
        let beside = try folder("top/beside")
        try fm.linkItem(at: file, to: beside.appendingPathComponent("far"))
        try fm.linkItem(at: file, to: below.appendingPathComponent("under"))
        try fm.linkItem(at: file, to: home.appendingPathComponent("next"))

        let found = names(from: file).found
        XCTAssertEqual(found.count, 4)
        XCTAssertEqual(Set(found.prefix(2)), [file.path, home.appendingPathComponent("next").path],
                       "its own folder first")
        XCTAssertEqual(found[2], below.appendingPathComponent("under").path, "then below it")
        XCTAssertEqual(found[3], beside.appendingPathComponent("far").path, "then outwards")
    }

    /// As many names as the inode has: the rest is not read.
    func testTheSearchStopsWhenEveryNameIsFound() throws {
        let home = try folder("here")
        let file = home.appendingPathComponent("file")
        try Data("x".utf8).write(to: file)
        try fm.linkItem(at: file, to: home.appendingPathComponent("twin"))
        for index in 0..<50 { _ = try folder("elsewhere/\(index)") }

        let (found, folders) = names(from: file)
        XCTAssertEqual(found.count, 2)
        XCTAssertLessThanOrEqual(folders, 1, "only its own folder was read")
    }

    /// A hard link to a symbolic link is a name of the link, not its target.
    func testAHardLinkToALinkIsFound() throws {
        let home = try folder("here")
        let link = home.appendingPathComponent("x5")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "x4")
        XCTAssertEqual(linkat(AT_FDCWD, link.path, AT_FDCWD,
                              home.appendingPathComponent("hardx5").path, 0), 0)

        XCTAssertEqual(Set(names(from: link).found),
                       [link.path, home.appendingPathComponent("hardx5").path])
    }

    /// A symbolic link to a folder is not gone into: the same name would be
    /// found twice, under two paths.
    func testLinkedFoldersAreNotFollowed() throws {
        let home = try folder("top/here")
        let file = home.appendingPathComponent("file")
        try Data("x".utf8).write(to: file)
        let other = try folder("top/other")
        try fm.linkItem(at: file, to: other.appendingPathComponent("second"))
        try fm.createSymbolicLink(atPath: home.appendingPathComponent("shortcut").path,
                                  withDestinationPath: other.path)

        XCTAssertEqual(names(from: file).found,
                       [file.path, other.appendingPathComponent("second").path])
    }

    func testAFileWithOneNameIsOneName() throws {
        let file = root.appendingPathComponent("alone")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(SiblingWalker.target(of: file)?.links, 1)
        XCTAssertEqual(names(from: file).found, [file.path])
    }
}
