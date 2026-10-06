import XCTest
@testable import Diptych

/// Symbolic link targets, and whether folders sort ahead of files.
@MainActor
final class LinkAndSortTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychLinks-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        LiveSettings.protect()
    }

    override func tearDown() async throws {
        LiveSettings.putBack()
        try? fm.removeItem(at: root)
    }

    // MARK: - Link targets

    func testTheLoaderReadsALinksTarget() async throws {
        try Data("x".utf8).write(to: root.appendingPathComponent("real.txt"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("link.txt").path,
                                  withDestinationPath: "real.txt")

        let items = try await DirectoryLoader.load(directory: root, showHidden: false,
                                                   columns: [.name])
        let link = try XCTUnwrap(items.first { $0.name == "link.txt" })

        XCTAssertTrue(link.isSymlink)
        XCTAssertEqual(link.linkTarget, "real.txt", "kept exactly as stored, still relative")
    }

    /// A link's own permissions are rwxr-xr-x whatever it points at; whether it
    /// is executable is its target's to say. A link to a PDF was badged.
    func testALinkIsExecutableOnlyWhenItsTargetIs() async throws {
        let document = root.appendingPathComponent("scan.pdf")
        try Data("%PDF".utf8).write(to: document)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: document.path)
        let tool = root.appendingPathComponent("tool.sh")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("to-scan.pdf").path,
                                  withDestinationPath: "scan.pdf")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("to-tool.sh").path,
                                  withDestinationPath: "tool.sh")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path,
                                  withDestinationPath: "nowhere")

        let items = try await DirectoryLoader.load(directory: root, showHidden: false,
                                                   columns: [.name])
        func named(_ name: String) throws -> FileItem {
            try XCTUnwrap(items.first { $0.name == name })
        }
        XCTAssertFalse(try named("to-scan.pdf").isExecutable, "a link to a document")
        XCTAssertTrue(try named("to-tool.sh").isExecutable, "a link to a program")
        XCTAssertFalse(try named("dangling").isExecutable, "a link to nothing")
    }

    /// A broken link still takes its name. Paste as Link took the name of a
    /// link whose target was gone for free, and was refused creating there.
    func testABrokenLinksNameIsNotFree() async throws {
        let picture = root.appendingPathComponent("untitled.png")
        try Data("png".utf8).write(to: picture)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("untitled-1.png").path,
                                  withDestinationPath: "gone.png")

        XCTAssertTrue(FileOperations.exists(root.appendingPathComponent("untitled-1.png")))
        let outcome = await FileOperations.shared.createLinks(to: [picture], in: root)
        XCTAssertTrue(outcome.failures.isEmpty, "\(outcome.failures)")
        XCTAssertEqual(outcome.succeeded.map(\.lastPathComponent), ["untitled-2.png"])
    }

    func testABrokenLinkIsMarked() async throws {
        try Data("x".utf8).write(to: root.appendingPathComponent("real.txt"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("good").path,
                                  withDestinationPath: "real.txt")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("broken").path,
                                  withDestinationPath: "nowhere")
        let items = try await DirectoryLoader.load(directory: root, showHidden: false,
                                                   columns: [.name])
        XCTAssertFalse(try XCTUnwrap(items.first { $0.name == "good" }).isBrokenLink)
        XCTAssertTrue(try XCTUnwrap(items.first { $0.name == "broken" }).isBrokenLink)
    }

    /// Go to Link Target goes one step, reading a relative target from the
    /// link's own folder.
    func testALinksTargetIsReadFromItsOwnFolder() throws {
        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sub.appendingPathComponent("real.txt"))
        let link = root.appendingPathComponent("link.txt")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "sub/real.txt")
        XCTAssertEqual(AppModel.linkTarget(of: link)?.path,
                       sub.appendingPathComponent("real.txt").standardizedFileURL.path)

        let absolute = root.appendingPathComponent("abs")
        try fm.createSymbolicLink(atPath: absolute.path, withDestinationPath: sub.path)
        XCTAssertEqual(AppModel.linkTarget(of: absolute)?.path, sub.standardizedFileURL.path)
        XCTAssertNil(AppModel.linkTarget(of: sub), "not a link")
    }

    func testANonLinkHasNoTarget() async throws {
        try Data("x".utf8).write(to: root.appendingPathComponent("plain.txt"))

        let items = try await DirectoryLoader.load(directory: root, showHidden: false,
                                                   columns: [.name])
        let plain = try XCTUnwrap(items.first { $0.name == "plain.txt" })

        XCTAssertEqual(plain.linkTarget, "")
    }

    func testABrokenLinkStillReportsWhereItPointed() async throws {
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path,
                                  withDestinationPath: "/nowhere/at/all")

        let items = try await DirectoryLoader.load(directory: root, showHidden: false,
                                                   columns: [.name])
        let link = try XCTUnwrap(items.first { $0.name == "dangling" })

        XCTAssertEqual(link.linkTarget, "/nowhere/at/all",
                       "a broken link is legal, and where it points is still worth showing")
    }

    func testRepointingALinkKeepsARelativeTargetRelative() throws {
        try Data("a".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: root.appendingPathComponent("b.txt"))
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "a.txt")

        let model = FileInfoModel(url: link)
        XCTAssertEqual(model.linkTarget, "a.txt")
        XCTAssertTrue(model.linkTargetExists)

        model.linkTarget = "b.txt"
        XCTAssertTrue(model.linkTargetHasChanges)
        model.applyLinkTarget()

        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), "b.txt")
        XCTAssertFalse(model.linkTargetHasChanges, "and the editor is back in step")
    }

    func testAFailedRepointPutsTheOriginalLinkBack() throws {
        // The target is removed and recreated, because there is no syscall to
        // change one in place -- so a failure must not leave a hole where a
        // link used to be.
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "somewhere")
        let model = FileInfoModel(url: link)

        // An empty destination is refused by the system call.
        model.linkTarget = String(repeating: "x", count: 2048)
        model.applyLinkTarget()

        XCTAssertTrue(fm.fileExists(atPath: link.path)
                      || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil,
                      "the link still exists either way")
    }

    func testABrokenTargetIsReportedRatherThanRefused() throws {
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/nowhere")

        let model = FileInfoModel(url: link)

        XCTAssertEqual(model.linkTarget, "/nowhere")
        XCTAssertFalse(model.linkTargetExists)
    }

    func testTheStatusFollowsWhatIsTypedRatherThanWhatIsOnDisk() throws {
        // It was computed once at load, from the link's own target, so it never
        // moved while editing -- and a freshly pasted, perfectly good path was
        // still reported as missing.
        try Data("x".utf8).write(to: root.appendingPathComponent("real.txt"))
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/nowhere")

        let model = FileInfoModel(url: link)
        XCTAssertFalse(model.linkTargetExists)

        model.linkTarget = "real.txt"
        XCTAssertTrue(model.linkTargetExists, "without saving anything")

        model.linkTarget = "/still/nowhere"
        XCTAssertFalse(model.linkTargetExists, "and back again")
    }

    func testAPastedAbsolutePathIsRecognised() throws {
        // Exactly the reported case: copy a full path from the pane, paste it.
        try Data("x".utf8).write(to: root.appendingPathComponent("real.txt"))
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "nothing")

        let model = FileInfoModel(url: link)
        model.linkTarget = root.appendingPathComponent("real.txt").path

        XCTAssertTrue(model.linkTargetExists)
        XCTAssertTrue(model.linkTargetNote.ok)
        XCTAssertEqual(model.linkTargetNote.text, "Points to a file.")
    }

    func testRelativeTargetsResolveAgainstTheLinksOwnFolder() throws {
        // Not against the process's working directory, which is what a naive
        // fileExists on the raw text would have checked.
        try fm.createDirectory(at: root.appendingPathComponent("sub"),
                               withIntermediateDirectories: true)
        let link = root.appendingPathComponent("sub/link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "x")
        try Data("x".utf8).write(to: root.appendingPathComponent("sub/sibling.txt"))

        let model = FileInfoModel(url: link)
        model.linkTarget = "sibling.txt"
        XCTAssertTrue(model.linkTargetExists)

        model.linkTarget = "../sibling.txt"
        XCTAssertFalse(model.linkTargetExists, "that one is a level up, and is not there")
    }

    func testTheNoteSaysWhetherTheTargetIsAFolder() throws {
        try fm.createDirectory(at: root.appendingPathComponent("folder"),
                               withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "folder")

        let model = FileInfoModel(url: link)
        XCTAssertEqual(model.linkTargetNote.text, "Points to a folder.")
    }

    func testAnEmptyTargetSaysWhatIsWrong() throws {
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "somewhere")

        let model = FileInfoModel(url: link)
        model.linkTarget = "   "

        XCTAssertFalse(model.linkTargetNote.ok)
        XCTAssertEqual(model.linkTargetNote.text, "A link needs a target.")
        XCTAssertFalse(model.linkTargetHasChanges, "whitespace alone is not an edit")
    }

    func testTildeInATargetIsExpanded() throws {
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "x")

        let model = FileInfoModel(url: link)
        model.linkTarget = "~"

        XCTAssertTrue(model.linkTargetExists)
    }

    // MARK: - Folders first

    private func pane() async throws -> PaneModel {
        try fm.createDirectory(at: root.appendingPathComponent("zebra"),
                               withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("apple.txt"))

        let pane = PaneModel(directory: root)
        pane.reload()
        while pane.isLoading { await Task.yield() }
        return pane
    }

    func testFoldersFirstPutsDirectoriesAboveFiles() async throws {
        ConfigStore.shared.configuration.foldersFirst = true
        let pane = try await pane()

        let names = pane.rows.filter { !$0.isParent }.map(\.name)
        XCTAssertEqual(names.first, "zebra", "a folder sorts above a file whatever its name")
    }

    func testMixedSortingOrdersEverythingTogether() async throws {
        ConfigStore.shared.configuration.foldersFirst = false
        let pane = try await pane()

        let names = pane.rows.filter { !$0.isParent }.map(\.name)
        XCTAssertEqual(names.first, "apple.txt", "by name, a file can come first")
    }

    func testParentStaysOnTopEitherWay() async throws {
        for foldersFirst in [true, false] {
            ConfigStore.shared.configuration.foldersFirst = foldersFirst
            let pane = try await pane()
            XCTAssertTrue(pane.rows.first?.isParent ?? false,
                          "\"..\" is navigation, not content (foldersFirst=\(foldersFirst))")
        }
    }
}
