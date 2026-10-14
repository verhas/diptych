import XCTest
@testable import Diptych

/// Find Duplicates: the files holding the same bytes as one file, nearest
/// first, or every set of them in a folder -- and what the window lets go to
/// the Trash.
final class DuplicateFinderTests: XCTestCase {

    private var root: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        let made = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychDuplicates-\(UUID().uuidString)")
        try manager.createDirectory(at: made, withIntermediateDirectories: true)
        // The real path: the search reports /private/var, not /var --
        // which `resolvingSymlinksInPath` turns back into.
        let resolved = try XCTUnwrap(realpath(made.path, nil))
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved))
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: root)
    }

    @discardableResult
    private func write(_ text: String, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try manager.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func search(_ path: String, _ options: DuplicateFinder.Options = .init(),
                        others: [DuplicateFinder.Root] = [], ceiling: String? = nil,
                        cancelled: CancellationFlag = CancellationFlag())
        -> [(group: Int, found: DuplicateFinder.Found)] {
        var events: [(Int, DuplicateFinder.Found)] = []
        DuplicateFinder.search(for: root.appendingPathComponent(path), options: options,
                               cancelled: cancelled, others: others,
                               ceiling: ceiling) { event in
            if case .found(let group, let found) = event { events.append((group, found)) }
        }
        return events
    }

    /// Paths relative to the test folder, and their kind when not a copy.
    private func names(_ events: [(group: Int, found: DuplicateFinder.Found)]) -> [String] {
        events.map { event in
            let path = String(event.found.url.path.dropFirst(root.path.count + 1))
            switch event.found.kind {
            case .copy: return path
            case .original: return path + " (original)"
            case .hardLink: return path + " (hard link)"
            case .symbolicLink: return path + " (link)"
            }
        }
    }

    // MARK: - For a file

    func testCopiesAreFoundNearestFirstAndOnlyTheSameBytes() throws {
        try write("photo", "start/a.jpg")
        try write("photo", "start/z copy.jpg")
        try write("other", "start/same size.jpg")
        try write("photo", "start/deep/deeper/c.jpg")
        try write("photo", "start/deep/b.jpg")
        try write("photo", "elsewhere/not searched.jpg")

        XCTAssertEqual(names(search("start/a.jpg")), [
            "start/a.jpg (original)", "start/z copy.jpg", "start/deep/b.jpg",
            "start/deep/deeper/c.jpg",
        ])
        var shallow = DuplicateFinder.Options()
        shallow.subfolders = false
        XCTAssertEqual(names(search("start/a.jpg", shallow)),
                       ["start/a.jpg (original)", "start/z copy.jpg"])
    }

    func testTheWholeVolumeGoesUpAFolderAtATimeAndThenToOtherVolumes() throws {
        try write("x", "top/one/two/start.txt")
        try write("x", "top/one/two/below/copy.txt")
        try write("x", "top/one/beside/copy.txt")
        try write("x", "top/copy.txt")
        try write("x", "volume/copy.txt")

        var options = DuplicateFinder.Options()
        options.subfolders = false
        options.wholeVolume = true
        options.volumes = [root.appendingPathComponent("volume").path]
        var info = stat()
        lstat(root.path, &info)
        let other = DuplicateFinder.Root(path: root.appendingPathComponent("volume").path,
                                         device: info.st_dev)
        XCTAssertEqual(names(search("top/one/two/start.txt", options, others: [other],
                                    ceiling: root.appendingPathComponent("top").path)), [
            "top/one/two/start.txt (original)", "top/one/two/below/copy.txt",
            "top/one/beside/copy.txt", "top/copy.txt", "volume/copy.txt",
        ], "the whole volume takes in the folders below, whatever the checkbox says")

        var stages: [DuplicateFinder.Stage] = []
        DuplicateFinder.search(for: root.appendingPathComponent("top/one/two/start.txt"),
                               options: options, cancelled: CancellationFlag(), others: [other],
                               ceiling: root.appendingPathComponent("top").path) { event in
            if case .stage(let stage) = event { stages.append(stage) }
        }
        XCTAssertEqual(stages, [
            .folder, .subfolders, .up(root.appendingPathComponent("top/one").path),
            .up(root.appendingPathComponent("top").path),
            .volume(name: "volume", path: other.path),
        ])
    }

    func testOnlyTheVolumesTickedAreSearched() throws {
        try write("x", "a/start.txt")
        try write("x", "backup/copy.txt")
        try write("x", "server/copy.txt")
        var info = stat()
        lstat(root.path, &info)
        let backup = DuplicateFinder.Root(path: root.appendingPathComponent("backup").path,
                                          device: info.st_dev)
        let server = DuplicateFinder.Root(path: root.appendingPathComponent("server").path,
                                          device: info.st_dev)
        var options = DuplicateFinder.Options()
        XCTAssertEqual(names(search("a/start.txt", options, others: [backup, server])),
                       ["a/start.txt (original)"])
        options.volumes = [server.path]
        XCTAssertEqual(names(search("a/start.txt", options, others: [backup, server])),
                       ["a/start.txt (original)", "server/copy.txt"])
    }

    func testLinksAreListedOnlyWhenAskedFor() throws {
        let original = try write("bytes", "f/original.txt")
        try write("bytes", "f/copy.txt")
        try manager.linkItem(at: original, to: root.appendingPathComponent("f/hard.txt"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("f/soft.txt"),
                                       withDestinationURL: original)
        try manager.createSymbolicLink(at: root.appendingPathComponent("f/broken.txt"),
                                       withDestinationURL: root.appendingPathComponent("gone"))

        XCTAssertEqual(names(search("f/original.txt")),
                       ["f/original.txt (original)", "f/copy.txt"])
        var options = DuplicateFinder.Options()
        options.includeLinks = true
        XCTAssertEqual(names(search("f/original.txt", options)), [
            "f/original.txt (original)", "f/copy.txt", "f/hard.txt (hard link)",
            "f/soft.txt (link)",
        ])
    }

    func testALinkToACopyIsListedWithTheFileItLeadsToWhereverThatIs() throws {
        try write("bytes", "f/original.txt")
        let near = try write("bytes", "f/copy.txt")
        let far = try write("bytes", "away/far copy.txt")
        try write("other", "away/same size.txt")
        try manager.createDirectory(at: root.appendingPathComponent("f/sub"),
                                    withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: root.appendingPathComponent("f/to copy.txt"),
                                       withDestinationURL: near)
        try manager.createSymbolicLink(at: root.appendingPathComponent("f/sub/to far.txt"),
                                       withDestinationURL: far)
        try manager.createSymbolicLink(at: root.appendingPathComponent("f/to other.txt"),
                                       withDestinationURL: root.appendingPathComponent("away/same size.txt"))

        XCTAssertEqual(names(search("f/original.txt")),
                       ["f/original.txt (original)", "f/copy.txt"], "links not asked for")
        var options = DuplicateFinder.Options()
        options.includeLinks = true
        XCTAssertEqual(names(search("f/original.txt", options)), [
            "f/original.txt (original)", "f/copy.txt", "f/to copy.txt (link)",
            "f/sub/to far.txt (link)", "away/far copy.txt",
        ], "the copy the first link leads to is listed once; the far one with its link")
    }

    func testInAFolderALinkGroupsWithTheFileItLeadsTo() throws {
        let file = try write("linked", "l/file.txt")
        try write("own", "l/other.txt")
        try manager.createSymbolicLink(at: root.appendingPathComponent("l/link.txt"),
                                       withDestinationURL: file)
        let outside = try write("far", "outside/target.txt")
        try manager.createSymbolicLink(at: root.appendingPathComponent("l/far link.txt"),
                                       withDestinationURL: outside)
        XCTAssertEqual(names(search("l")), [])
        var options = DuplicateFinder.Options()
        options.includeLinks = true
        let events = search("l", options)
        XCTAssertEqual(names(events), ["l/far link.txt (link)", "outside/target.txt",
                                       "l/file.txt", "l/link.txt (link)"])
        XCTAssertEqual(events.map(\.group), [0, 0, 1, 1])
    }

    func testWhatSetsACopyApartIsSaid() throws {
        try write("same", "d/a.txt")
        let other = try write("same", "d/b.txt")
        chmod(other.path, 0o600)
        let found = try XCTUnwrap(search("d/a.txt").last?.found)
        XCTAssertTrue(found.differences.contains(.permissions))
        XCTAssertTrue(found.differences.contains(.name))
        XCTAssertEqual(found.item.name, "b.txt")
    }

    func testAnEmptyFileHasNoDuplicatesAndAStoppedSearchFindsNothingMore() throws {
        try write("", "e/empty.txt")
        try write("", "e/also empty.txt")
        XCTAssertEqual(names(search("e/empty.txt")), ["e/empty.txt (original)"])

        try write("a", "s/a.txt")
        try write("a", "s/b.txt")
        let cancelled = CancellationFlag()
        cancelled.cancel()
        XCTAssertEqual(names(search("s/a.txt", cancelled: cancelled)), ["s/a.txt (original)"])
    }

    // MARK: - For a folder

    func testAFolderGroupsWhatHasTheSameBytes() throws {
        try write("one", "g/1.txt")
        try write("two", "g/2.txt")
        try write("one", "g/sub/1 again.txt")
        try write("two", "g/sub/deeper/2 again.txt")
        try write("one", "g/sub/deeper/1 third.txt")
        try write("own", "g/unique.txt")
        try write("", "g/empty1")
        try write("", "g/empty2")

        let events = search("g")
        XCTAssertEqual(names(events), [
            "g/1.txt", "g/sub/1 again.txt", "g/sub/deeper/1 third.txt", "g/2.txt",
            "g/sub/deeper/2 again.txt",
        ])
        XCTAssertEqual(events.map(\.group), [0, 0, 0, 1, 1])

        var shallow = DuplicateFinder.Options()
        shallow.subfolders = false
        XCTAssertEqual(names(search("g", shallow)), [])
    }

    func testInAFolderASecondNameIsADuplicateOnlyWhenLinksAreAsked() throws {
        let file = try write("linked", "h/file.txt")
        try manager.linkItem(at: file, to: root.appendingPathComponent("h/other name.txt"))
        XCTAssertEqual(names(search("h")), [])
        var options = DuplicateFinder.Options()
        options.includeLinks = true
        XCTAssertEqual(names(search("h", options)),
                       ["h/file.txt", "h/other name.txt (hard link)"])
    }

    // MARK: - The window's rules

    @MainActor
    func testEveryFileOfAGroupSelectedIsNeverMovedToTheTrash() async throws {
        try write("one", "w/a.txt")
        try write("one", "w/b.txt")
        try write("two", "w/c.txt")
        try write("two", "w/d.txt")
        let search = DuplicateSearch(url: root.appendingPathComponent("w"))
        XCTAssertTrue(search.isFolder)
        search.start()
        for _ in 0..<200 where search.isSearching {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(search.groups.map { $0.files.count }, [2, 2])
        XCTAssertFalse(search.canTrash, "nothing selected")

        search.chosen = [root.appendingPathComponent("w/b.txt")]
        XCTAssertTrue(search.canTrash)
        search.toggleAll(in: search.groups[1])
        XCTAssertFalse(search.canTrash, "the second group would be gone")
        search.toggleAll(in: search.groups[1])
        XCTAssertEqual(search.chosen, [root.appendingPathComponent("w/b.txt")],
                       "selecting all twice deselects them")
        XCTAssertTrue(search.canTrash)
    }

    @MainActor
    func testALinkWhoseFileIsSelectedIsSaidToLeadNowhereButDoesNotStopTheTrash() async throws {
        try write("one", "o/a.txt")
        let copy = try write("one", "o/b.txt")
        try manager.createSymbolicLink(at: root.appendingPathComponent("o/c link.txt"),
                                       withDestinationURL: copy)
        let search = DuplicateSearch(url: root.appendingPathComponent("o"))
        search.options.includeLinks = true
        search.start()
        for _ in 0..<200 where search.isSearching {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(search.groups.map { $0.files.count }, [3])
        XCTAssertTrue(search.orphans.isEmpty)

        search.chosen = [copy]
        XCTAssertTrue(search.canTrash)
        XCTAssertEqual(search.orphans.map(\.link.lastPathComponent), ["c link.txt"])
        XCTAssertEqual(search.orphans.map(\.target), [copy])
        search.chosen.insert(root.appendingPathComponent("o/c link.txt"))
        XCTAssertTrue(search.orphans.isEmpty, "the link goes to the Trash with it")
    }

    @MainActor
    func testALinkLeftUnselectedDoesNotKeepTheContent() async throws {
        let file = try write("one", "k/a.txt")
        try write("one", "k/b.txt")
        try manager.createSymbolicLink(at: root.appendingPathComponent("k/c link.txt"),
                                       withDestinationURL: file)
        let search = DuplicateSearch(url: root.appendingPathComponent("k"))
        search.options.includeLinks = true
        search.start()
        for _ in 0..<200 where search.isSearching {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(search.groups.map { $0.files.count }, [3])

        search.chosen = [root.appendingPathComponent("k/a.txt"),
                         root.appendingPathComponent("k/b.txt")]
        XCTAssertFalse(search.canTrash, "only the link would be left")
        XCTAssertEqual(search.unkept.map(\.id), [search.groups[0].id])
        search.chosen.remove(root.appendingPathComponent("k/b.txt"))
        XCTAssertTrue(search.canTrash)
        XCTAssertTrue(search.unkept.isEmpty)
    }
}
