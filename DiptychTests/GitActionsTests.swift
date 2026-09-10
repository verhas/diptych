import XCTest
@testable import Diptych

/// Sending work and getting the latest, against real repositories.
///
/// Nothing is mocked. Git is a subprocess, so a test can make a repository, a
/// bare "shared copy" to push to, and a second clone standing in for the
/// colleague -- which is the only way the interesting paths (a push refused
/// because someone else went first, a fast-forward that cannot happen) are
/// exercised at all.
@MainActor
final class GitActionsTests: XCTestCase {

    private var root: URL!
    private var mine: URL!
    private var shared: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try XCTSkipIf(GitTool.locate(override: nil) == nil, "no git on this machine")
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychGit-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        shared = root.appendingPathComponent("shared.git")
        mine = root.appendingPathComponent("mine")
        try run(["init", "--bare", "-b", "main", shared.path], in: root)
        try run(["clone", shared.path, mine.path], in: root)
        try configure(mine)

        try write("readme.md", "first\n")
        try run(["add", "-A"], in: mine)
        try run(["commit", "-m", "start"], in: mine)
        try run(["push", "-u", "origin", "main"], in: mine)

        GitService.shared.locate()
        GitService.shared.forgetEverything()
    }

    override func tearDownWithError() throws {
        GitService.shared.forgetEverything()
        try? fm.removeItem(at: root)
    }

    // MARK: - Helpers

    @discardableResult
    private func run(_ arguments: [String], in directory: URL) throws -> String {
        let git = try XCTUnwrap(GitTool.locate(override: nil))
        let outcome = GitTool.run(arguments, executable: git.url, in: directory, timeout: 60)
        guard case .ok(let text) = outcome else {
            throw NSError(domain: "git", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(arguments): \(outcome)"])
        }
        return text
    }

    private func configure(_ repo: URL) throws {
        try run(["config", "user.name", "Test"], in: repo)
        try run(["config", "user.email", "test@example.com"], in: repo)
    }

    private func write(_ name: String, _ contents: String, in repo: URL? = nil) throws {
        let url = (repo ?? mine).appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func read(_ name: String, in repo: URL? = nil) -> String? {
        try? String(contentsOf: (repo ?? mine).appendingPathComponent(name), encoding: .utf8)
    }

    /// A second clone, standing in for the colleague.
    private func colleague() throws -> URL {
        let theirs = root.appendingPathComponent("theirs")
        try run(["clone", shared.path, theirs.path], in: root)
        try configure(theirs)
        return theirs
    }

    // MARK: - Availability

    func testLocateIfNeededDoesNothingWhileTheSettingIsOff() {
        // The panes ask at startup; with the feature off that must stay free.
        let original = ConfigStore.shared.configuration.gitEnabled
        defer { ConfigStore.shared.configuration.gitEnabled = original }

        ConfigStore.shared.configuration.gitEnabled = false
        GitService.shared.forgetEverything()
        GitService.shared.locateIfNeeded()

        XCTAssertFalse(GitService.shared.isEnabled)
    }

    func testResolvingGitAnnouncesItself() async throws {
        // A pane drawn before Git was resolved has no colours, and nothing else
        // would ever tell it to look again -- which is why locate() posts.
        let original = ConfigStore.shared.configuration.gitEnabled
        defer { ConfigStore.shared.configuration.gitEnabled = original }
        ConfigStore.shared.configuration.gitEnabled = true

        let heard = expectation(forNotification: GitService.availabilityChanged,
                                object: nil, notificationCenter: .default)
        GitService.shared.locate()
        await fulfillment(of: [heard], timeout: 5)
        XCTAssertTrue(GitService.shared.isEnabled)
    }

    // MARK: - What the dialog lists

    func testChangesAreSplitIntoSendingAndNew() async throws {
        try write("readme.md", "changed\n")
        try write("scratch.txt", "new\n")
        GitService.shared.invalidate(mine)

        let changes = await GitService.shared.changes(inRepository: mine)

        XCTAssertEqual(changes.sending.map(\.path), ["readme.md"])
        XCTAssertEqual(changes.new.map(\.path), ["scratch.txt"],
                       "a file git does not know about is offered separately, unticked")
    }

    func testADeletionIsAChangeToBeSent() async throws {
        try fm.removeItem(at: mine.appendingPathComponent("readme.md"))
        GitService.shared.invalidate(mine)

        let changes = await GitService.shared.changes(inRepository: mine)

        XCTAssertEqual(changes.sending.map(\.path), ["readme.md"],
                       "removing a file is something to send, not an error")
    }

    // MARK: - Sending

    func testSendingCommitsAndPushes() async throws {
        try write("readme.md", "changed\n")

        let result = await GitService.shared.send(paths: ["readme.md"], newPaths: [],
                                                  message: "an edit", inRepository: mine)

        guard case .sent(let count) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(count, 1)
        // Really on the shared copy, not just committed here.
        let theirs = try colleague()
        XCTAssertEqual(read("readme.md", in: theirs), "changed\n")
    }

    func testOnlyTheChosenFilesAreSent() async throws {
        try write("readme.md", "changed\n")
        try write("other.md", "also changed\n")
        try run(["add", "-A"], in: mine)
        try run(["commit", "-m", "add other"], in: mine)
        try run(["push"], in: mine)
        try write("readme.md", "changed again\n")
        try write("other.md", "not this one\n")

        _ = await GitService.shared.send(paths: ["readme.md"], newPaths: [],
                                         message: "just the one", inRepository: mine)

        let theirs = try colleague()
        XCTAssertEqual(read("readme.md", in: theirs), "changed again\n")
        XCTAssertEqual(read("other.md", in: theirs), "also changed\n",
                       "the unticked file stays behind")
    }

    func testAnUntickedNewFileIsNotSent() async throws {
        try write("draft.md", "private\n")

        _ = await GitService.shared.send(paths: [], newPaths: [], message: "nothing",
                                         inRepository: mine)

        let theirs = try colleague()
        XCTAssertNil(read("draft.md", in: theirs),
                     "a new file is only sent when it is ticked")
    }

    func testATickedNewFileIsTrackedAndSent() async throws {
        try write("chapter4.md", "new work\n")

        let result = await GitService.shared.send(paths: [], newPaths: ["chapter4.md"],
                                                  message: "chapter four", inRepository: mine)

        guard case .sent = result else { return XCTFail("\(result)") }
        let theirs = try colleague()
        XCTAssertEqual(read("chapter4.md", in: theirs), "new work\n")
    }

    // MARK: - When the push fails

    func testAFailedPushUndoesTheCommit() async throws {
        // Someone else pushes first, so ours is refused. The whole action must
        // fail: no commit left behind, no hidden "saved but not shared" state.
        let theirs = try colleague()
        try write("readme.md", "from my colleague\n", in: theirs)
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        let before = try run(["rev-parse", "HEAD"], in: mine)
        try write("readme.md", "mine\n")

        let result = await GitService.shared.send(paths: ["readme.md"], newPaths: [],
                                                  message: "mine", inRepository: mine)

        guard case .notSent = result else { return XCTFail("\(result)") }
        XCTAssertEqual(try run(["rev-parse", "HEAD"], in: mine), before,
                       "the commit is gone")
        XCTAssertEqual(read("readme.md"), "mine\n",
                       "and the file is exactly as it was left")
    }

    func testAFailedPushLeavesTheFileStillChanged() async throws {
        let theirs = try colleague()
        try write("readme.md", "from my colleague\n", in: theirs)
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)
        try write("readme.md", "mine\n")

        _ = await GitService.shared.send(paths: ["readme.md"], newPaths: [],
                                         message: "mine", inRepository: mine)
        GitService.shared.invalidate(mine)

        let changes = await GitService.shared.changes(inRepository: mine)
        XCTAssertEqual(changes.sending.map(\.path), ["readme.md"],
                       "still there to send, so the button still means something")
    }

    // MARK: - Getting the latest

    func testGettingTheLatestFastForwards() async throws {
        let theirs = try colleague()
        try write("readme.md", "from my colleague\n", in: theirs)
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        let result = await GitService.shared.getLatest(inRepository: mine)

        guard case .updated = result else { return XCTFail("\(result)") }
        XCTAssertEqual(read("readme.md"), "from my colleague\n")
    }

    func testUpToDateSaysSo() async throws {
        let result = await GitService.shared.getLatest(inRepository: mine)
        guard case .upToDate = result else { return XCTFail("\(result)") }
    }

    func testTheConflictingSetIsOnlyWhatBothSidesTouched() async throws {
        // The colleague changes two files; I changed one of them. Only the
        // overlap is my problem -- "everything that differs" would list both.
        let theirs = try colleague()
        try write("readme.md", "theirs\n", in: theirs)
        try write("untouched.md", "theirs only\n", in: theirs)
        try run(["add", "-A"], in: theirs)
        try run(["commit", "-m", "two files"], in: theirs)
        try run(["push"], in: theirs)
        try write("readme.md", "mine\n")

        let result = await GitService.shared.getLatest(inRepository: mine)

        guard case .conflicting(let paths, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(paths, ["readme.md"])
    }

    func testKeepingCopiesPreservesMyVersionAndTakesTheShared() async throws {
        let theirs = try colleague()
        try write("readme.md", "theirs\n", in: theirs)
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)
        try write("readme.md", "mine\n")

        guard case .conflicting(let paths, _) =
                await GitService.shared.getLatest(inRepository: mine) else {
            return XCTFail("expected a conflict")
        }
        let result = await GitService.shared.keepCopiesAndTakeShared(paths: paths,
                                                                    inRepository: mine)

        guard case .updated = result else { return XCTFail("\(result)") }
        XCTAssertEqual(read("readme.md"), "theirs\n", "the folder matches the shared copy")
        XCTAssertEqual(read("readme (my version).md"), "mine\n", "and nothing of mine is lost")
    }

    func testTheKeptCopyIsNotOfferedForSending() async throws {
        // It goes in .git/info/exclude -- local only, never pushed, and no
        // tracked file touched -- so it cannot be sent by accident.
        let theirs = try colleague()
        try write("readme.md", "theirs\n", in: theirs)
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)
        try write("readme.md", "mine\n")

        guard case .conflicting(let paths, _) =
                await GitService.shared.getLatest(inRepository: mine) else {
            return XCTFail("expected a conflict")
        }
        _ = await GitService.shared.keepCopiesAndTakeShared(paths: paths, inRepository: mine)
        GitService.shared.invalidate(mine)

        let changes = await GitService.shared.changes(inRepository: mine)
        XCTAssertFalse(changes.new.contains { $0.path.contains("my version") },
                       "the copy is invisible to git")
        let excludes = read(".git/info/exclude") ?? ""
        XCTAssertTrue(excludes.contains("(my version)"))
        XCTAssertFalse((read(".gitignore") ?? "").contains("my version"),
                       "and no tracked file was modified")
    }

    func testDivergedHistoryKeepsTheDroppedVersionsOnABookmark() async throws {
        // My changes were already saved as versions, so taking the shared copy
        // means dropping commits. They must stay reachable.
        let theirs = try colleague()
        try write("readme.md", "theirs\n", in: theirs)
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        try write("readme.md", "mine\n")
        try run(["commit", "-am", "my saved version"], in: mine)
        let dropped = try run(["rev-parse", "HEAD"], in: mine)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard case .conflicting(let paths, let hasOwn) =
                await GitService.shared.getLatest(inRepository: mine) else {
            return XCTFail("expected a conflict")
        }
        XCTAssertTrue(hasOwn, "the dialog needs to say the extra sentence")
        _ = await GitService.shared.keepCopiesAndTakeShared(paths: paths, inRepository: mine)

        XCTAssertEqual(read("readme.md"), "theirs\n")
        XCTAssertEqual(read("readme (my version).md"), "mine\n")
        let bookmarks = try run(["branch", "--contains", dropped], in: mine)
        XCTAssertTrue(bookmarks.contains("diptych-kept-"),
                      "the dropped commit is still reachable: \(bookmarks)")
    }

    // MARK: - Tracking

    func testNeverTrackWritesGitignoreAndHidesTheFile() async throws {
        try write("notes.tmp", "scratch\n")

        _ = await GitService.shared.neverTrack(["notes.tmp"], inRepository: mine)
        GitService.shared.invalidate(mine)

        let changes = await GitService.shared.changes(inRepository: mine)
        XCTAssertFalse(changes.new.contains { $0.path == "notes.tmp" })
        XCTAssertTrue((read(".gitignore") ?? "").contains("notes.tmp"))
    }

    func testTrackingMakesAFileNewAndTracked() async throws {
        try write("chapter4.md", "new\n")

        _ = await GitService.shared.track(["chapter4.md"], inRepository: mine)
        GitService.shared.invalidate(mine)

        let changes = await GitService.shared.changes(inRepository: mine)
        XCTAssertTrue(changes.sending.contains { $0.path == "chapter4.md" && $0.state == .added })
        XCTAssertFalse(changes.new.contains { $0.path == "chapter4.md" })
    }
}
