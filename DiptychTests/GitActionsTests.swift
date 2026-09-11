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
    private var settings: Configuration!

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

        GitService.shared.forgetEverything()

        // These run against the real ConfigStore, so anything a test depends on
        // is set here rather than inherited from the machine it runs on. One
        // test assumed a default this way and started failing the day the
        // setting began persisting properly.
        settings = ConfigStore.shared.configuration
        ConfigStore.shared.configuration.gitUpdateWhenSending = true
        ConfigStore.shared.configuration.gitCheckOnOpen = false
    }

    /// Resolving Git is asynchronous now, so every test that uses it waits
    /// rather than racing a Task that has not run yet.
    private func readyGit() async throws {
        await GitService.shared.locate()
        try XCTSkipIf(GitService.shared.tool == nil, "git could not be resolved")
    }

    override func tearDownWithError() throws {
        if let settings { ConfigStore.shared.configuration = settings }
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

    /// A third clone, for checking what actually reached the shared copy after
    /// the colleague has already been used.
    private func colleague2() throws -> URL {
        let other = root.appendingPathComponent("checking-\(UUID().uuidString.prefix(6))")
        try run(["clone", shared.path, other.path], in: root)
        return other
    }

    /// A second clone, standing in for the colleague.
    private func colleague() throws -> URL {
        let theirs = root.appendingPathComponent("theirs")
        try run(["clone", shared.path, theirs.path], in: root)
        try configure(theirs)
        return theirs
    }

    // MARK: - Availability

    func testLocateIfNeededDoesNothingWhileTheSettingIsOff() async {
        // The panes ask at startup; with the feature off that must stay free.
        let original = ConfigStore.shared.configuration.gitEnabled
        defer { ConfigStore.shared.configuration.gitEnabled = original }

        ConfigStore.shared.configuration.gitEnabled = false
        GitService.shared.forgetEverything()
        await GitService.shared.locateIfNeeded()

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
        Task { await GitService.shared.locate() }
        await fulfillment(of: [heard], timeout: 5)
        XCTAssertTrue(GitService.shared.isEnabled)
    }

    // MARK: - What the dialog lists

    func testChangesAreSplitIntoSendingAndNew() async throws {
        try await readyGit()
        try write("readme.md", "changed\n")
        try write("scratch.txt", "new\n")
        GitService.shared.invalidate(mine)

        let changes = await GitService.shared.changes(inRepository: mine)

        XCTAssertEqual(changes.sending.map(\.path), ["readme.md"])
        XCTAssertEqual(changes.new.map(\.path), ["scratch.txt"],
                       "a file git does not know about is offered separately, unticked")
    }

    func testADeletionIsListedAsRemovedRatherThanChanged() async throws {
        try await readyGit()
        try fm.removeItem(at: mine.appendingPathComponent("readme.md"))
        GitService.shared.invalidate(mine)

        let changes = await GitService.shared.changes(inRepository: mine)

        XCTAssertEqual(changes.sending.map(\.path), ["readme.md"],
                       "removing a file is something to send, not an error")
        XCTAssertEqual(changes.sending.first?.describes, "removed",
                       "\"changed\" reads as a mistake next to a file you deleted on purpose")
    }

    func testARemovalIsActuallySent() async throws {
        try await readyGit()
        try fm.removeItem(at: mine.appendingPathComponent("readme.md"))

        let result = await GitService.shared.send(paths: ["readme.md"], newPaths: [],
                                                  message: "removed it", inRepository: mine)

        guard case .sent = result else { return XCTFail("\(result)") }
        let theirs = try colleague()
        XCTAssertNil(read("readme.md", in: theirs), "the removal reached the shared copy")
    }

    // MARK: - Sending

    func testSendingCommitsAndPushes() async throws {
        try await readyGit()
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
        try await readyGit()
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
        try await readyGit()
        try write("draft.md", "private\n")

        _ = await GitService.shared.send(paths: [], newPaths: [], message: "nothing",
                                         inRepository: mine)

        let theirs = try colleague()
        XCTAssertNil(read("draft.md", in: theirs),
                     "a new file is only sent when it is ticked")
    }

    func testATickedNewFileIsTrackedAndSent() async throws {
        try await readyGit()
        try write("chapter4.md", "new work\n")

        let result = await GitService.shared.send(paths: [], newPaths: ["chapter4.md"],
                                                  message: "chapter four", inRepository: mine)

        guard case .sent = result else { return XCTFail("\(result)") }
        let theirs = try colleague()
        XCTAssertEqual(read("chapter4.md", in: theirs), "new work\n")
    }

    // MARK: - When the push fails

    func testAFailedPushUndoesTheCommit() async throws {
        try await readyGit()
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

    func testAFailedPushKeepsAFileThatWasAlreadyTracked() async throws {
        // Tracking a file is a decision made *before* pressing Send. Undoing
        // the send must not undo it -- `reset --mixed` unstages everything, so
        // a file marked green by hand went brown again when the push failed.
        try await readyGit()
        try write("chapter4.md", "mine\n")
        _ = await GitService.shared.track(["chapter4.md"], inRepository: mine)
        GitService.shared.invalidate(mine)
        var changes = await GitService.shared.changes(inRepository: mine)
        XCTAssertEqual(changes.sending.first { $0.path == "chapter4.md" }?.state, .added)

        // Someone else adds the same file first, so ours cannot go.
        let theirs = try colleague()
        try write("chapter4.md", "theirs\n", in: theirs)
        try run(["add", "-A"], in: theirs)
        try run(["commit", "-m", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        let result = await GitService.shared.send(paths: ["chapter4.md"], newPaths: [],
                                                  message: "mine", inRepository: mine)

        guard case .notSent = result else { return XCTFail("\(result)") }
        GitService.shared.invalidate(mine)
        changes = await GitService.shared.changes(inRepository: mine)
        XCTAssertEqual(changes.sending.first { $0.path == "chapter4.md" }?.state, .added,
                       "still tracked, still green")
        XCTAssertFalse(changes.new.contains { $0.path == "chapter4.md" },
                       "and not offered as though it had never been tracked")
    }

    func testAFailedPushKeepsAFileTickedInTheDialog() async throws {
        // Ticking means "include it, now and from now on", so the tracking
        // survives even though the send did not.
        try await readyGit()
        try write("ticked.md", "mine\n")

        let theirs = try colleague()
        try write("ticked.md", "theirs\n", in: theirs)
        try run(["add", "-A"], in: theirs)
        try run(["commit", "-m", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        _ = await GitService.shared.send(paths: [], newPaths: ["ticked.md"],
                                         message: "mine", inRepository: mine)
        GitService.shared.invalidate(mine)

        let changes = await GitService.shared.changes(inRepository: mine)
        XCTAssertEqual(changes.sending.first { $0.path == "ticked.md" }?.state, .added)
    }

    func testAnUnrelatedChangeBySomeoneElseDoesNotStopASend() async throws {
        // The commonest case, and the one that needs no decision at all: the
        // shared copy moved on, but nobody touched the same files. Git refuses
        // the push for being behind; that is Diptych's problem to solve, not
        // something to hand to the user as a question.
        try await readyGit()
        let theirs = try colleague()
        try write("theirs-only.md", "theirs\n", in: theirs)
        try run(["add", "-A"], in: theirs)
        try run(["commit", "-m", "unrelated"], in: theirs)
        try run(["push"], in: theirs)

        try write("mine-only.md", "mine\n")

        let result = await GitService.shared.send(paths: [], newPaths: ["mine-only.md"],
                                                  message: "mine", inRepository: mine)

        guard case .sent = result else { return XCTFail("\(result)") }
        let checking = try colleague2()
        XCTAssertEqual(read("mine-only.md", in: checking), "mine\n")
        XCTAssertEqual(read("theirs-only.md"), "theirs\n", "and theirs arrived here")
    }

    func testARefusalWithAClashNamesTheFiles() async throws {
        // The message has to say *which*, or "someone changed some of the same
        // files" is a riddle.
        try await readyGit()
        let theirs = try colleague()
        try write("readme.md", "theirs\n", in: theirs)
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        try write("readme.md", "mine\n")

        let result = await GitService.shared.send(paths: ["readme.md"], newPaths: [],
                                                  message: "mine", inRepository: mine)

        guard case .notSent(let reason, _, let conflicts) = result else {
            return XCTFail("\(result)")
        }
        XCTAssertEqual(conflicts, ["readme.md"])
        XCTAssertTrue(reason.contains("not sent"), "says what happened: \(reason)")
        XCTAssertFalse(reason.contains("saved on this Mac"),
                       "and not what the user already knows")
    }

    func testAnUncontestedFileIsSentWhileTheContestedOneWaits() async throws {
        // The reported case, and the one Diptych got wrong for a long time:
        // two files changed here, one of them also changed by someone else.
        // Leaving the contested one unticked must send the other -- any other
        // Git client manages it, and so it is a legitimate commit and push.
        try await readyGit()
        try write("second.md", "first version\n")
        try run(["add", "-A"], in: mine)
        try run(["commit", "-m", "add second"], in: mine)
        try run(["push"], in: mine)

        let theirs = try colleague()
        try write("readme.md", "theirs\n", in: theirs)
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        // Both changed here; only readme.md is contested.
        try write("readme.md", "mine\n")
        try write("second.md", "mine too\n")

        // "Keep mine" already chosen: what is under test here is the partial
        // send, not the question, which has tests of its own.
        let sent = await GitService.shared.send(paths: ["second.md"], newPaths: [],
                                                message: "just the second", inRepository: mine,
                                                decided: ["readme.md"])

        guard case .sent(let count) = sent else { return XCTFail("\(sent)") }
        XCTAssertEqual(count, 1)
        let checking = try colleague2()
        XCTAssertEqual(read("second.md", in: checking), "mine too\n", "the unticked one went")
        XCTAssertEqual(read("readme.md", in: checking), "theirs\n",
                       "and the contested one was left entirely alone")
    }

    func testWorkNotTickedIsLeftExactlyAsItWas() async throws {
        // Reported, and right: a file the user deliberately left out is a file
        // they are still working on. Catching up must not rename it, must not
        // put the arrived version in its place, and must certainly not leave
        // <<<<<<< in it. It stays theirs, uncommitted, and simply shows as
        // changed -- which is what it was before they pressed Send.
        try await readyGit()
        try write("second.md", "first version\n")
        try run(["add", "-A"], in: mine)
        try run(["commit", "-m", "add second"], in: mine)
        try run(["push"], in: mine)

        let theirs = try colleague()
        try write("readme.md", "theirs\n", in: theirs)
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        try write("readme.md", "mine\n")
        try write("second.md", "mine too\n")

        let sent = await GitService.shared.send(paths: ["second.md"], newPaths: [],
                                                message: "just the second", inRepository: mine,
                                                decided: ["readme.md"])
        guard case .sent = sent else { return XCTFail("\(sent)") }

        XCTAssertEqual(read("readme.md"), "mine\n", "my content, under my name")
        XCTAssertNil(read("readme (my version).md"), "nothing copied aside")
        XCTAssertEqual(try run(["stash", "list"], in: mine), "", "nothing left half-done")

        let status = try run(["status", "--porcelain"], in: mine)
        XCTAssertFalse(status.contains("UU"), "no unresolved state: \(status)")
        XCTAssertTrue(status.contains("readme.md"), "still a change waiting to be sent")

        GitService.shared.invalidate(mine)
        let changes = await GitService.shared.changes(inRepository: mine)
        XCTAssertEqual(changes.sending.map(\.path), ["readme.md"],
                       "and offered again next time, as it should be")
    }

    func testCatchingUpLeavesNothingBehindInTheFolder() async throws {
        // The parking place is inside .git, so the folder the user works in
        // never sees it.
        try await readyGit()
        try write("second.md", "first version\n")
        try run(["add", "-A"], in: mine)
        try run(["commit", "-m", "add second"], in: mine)
        try run(["push"], in: mine)

        let theirs = try colleague()
        try write("readme.md", "theirs\n", in: theirs)
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        try write("readme.md", "mine\n")
        try write("second.md", "mine too\n")
        _ = await GitService.shared.send(paths: ["second.md"], newPaths: [],
                                         message: "just the second", inRepository: mine)

        let left = try fm.contentsOfDirectory(atPath: mine.path).filter { $0 != ".git" }
        XCTAssertEqual(left.sorted(), ["readme.md", "second.md"])
        XCTAssertFalse(fm.fileExists(atPath: mine.appendingPathComponent(".git/diptych-parked").path),
                       "and the parking place is cleared up")
    }

    func testAnUntrackedFileThatAlsoArrivesKeepsItsNameAndContents() async throws {
        // Git refuses to start when an arriving file would overwrite something
        // untracked here. Diptych moves it out of the way for the length of the
        // rebase and puts it straight back: the user never asked for the
        // arrived version, so their file wins and reads as changed.
        try await readyGit()
        try write("second.md", "first version\n")
        try run(["add", "-A"], in: mine)
        try run(["commit", "-m", "add second"], in: mine)
        try run(["push"], in: mine)

        let theirs = try colleague()
        try write("notes.md", "theirs\n", in: theirs)
        try run(["add", "-A"], in: theirs)
        try run(["commit", "-m", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        try write("notes.md", "mine, never tracked\n")   // untracked, same name
        try write("second.md", "mine too\n")

        let sent = await GitService.shared.send(paths: ["second.md"], newPaths: [],
                                                message: "just the second", inRepository: mine)

        guard case .sent = sent else { return XCTFail("\(sent)") }
        XCTAssertEqual(read("notes.md"), "mine, never tracked\n", "mine, under its own name")
        XCTAssertNil(read("notes (my version).md"), "and nothing renamed")
    }

    func testAbandoningTheCatchUpPutsParkedFilesBack() async throws {
        // If the send cannot go through after all, a file moved out of the way
        // to make room must come back: nothing arrived, so nothing should look
        // different.
        try await readyGit()
        let theirs = try colleague()
        try write("readme.md", "theirs\n", in: theirs)
        try write("notes.md", "theirs\n", in: theirs)
        try run(["add", "-A"], in: theirs)
        try run(["commit", "-m", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        try write("readme.md", "mine\n")                 // contested *and* ticked
        try write("notes.md", "mine, never tracked\n")   // untracked, also arriving

        let result = await GitService.shared.send(paths: ["readme.md"], newPaths: [],
                                                  message: "mine", inRepository: mine)

        guard case .notSent = result else { return XCTFail("\(result)") }
        XCTAssertEqual(read("notes.md"), "mine, never tracked\n", "back under its own name")
        XCTAssertNil(read("notes (my version).md"), "and no leftover copy")
    }

    func testTheRefusalNamesOnlyWhatWasTicked() async throws {
        // Reported: listing a file the user deliberately left out reads as
        // though it were in the way, when it is none of this send's business.
        // It still turns red -- that part was right.
        try await readyGit()
        try write("second.md", "one\ntwo\nthree\n")
        try run(["add", "-A"], in: mine)
        try run(["commit", "-m", "add second"], in: mine)
        try run(["push"], in: mine)

        let theirs = try colleague()
        try write("readme.md", "theirs\n", in: theirs)
        try write("second.md", "one\ntwo\nTHEIRS\n", in: theirs)   // last line
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        try write("readme.md", "mine\n")                 // ticked, and clashes
        try write("second.md", "MINE\ntwo\nthree\n")     // unticked, merges cleanly

        let result = await GitService.shared.send(paths: ["readme.md"], newPaths: [],
                                                  message: "only the readme", inRepository: mine)

        guard case .notSent(_, _, let conflicts) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(conflicts, ["readme.md"], "only the one that was ticked")
        XCTAssertEqual(GitService.shared.check(for: mine)?.contested, ["readme.md", "second.md"],
                       "but both are remembered, so both are coloured")
    }

    // MARK: - Clashes in files nobody ticked

    /// Both sides changed README.md; only second.md is being sent.
    private func clashSetUp() async throws {
        try write("second.md", "first version\n")
        try run(["add", "-A"], in: mine)
        try run(["commit", "-m", "add second"], in: mine)
        try run(["push"], in: mine)

        let theirs = try colleague()
        try write("readme.md", "one\nTHEIRS\nthree\n", in: theirs)
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        try write("readme.md", "one\nMINE\nthree\n")
        try write("second.md", "mine too\n")
    }

    func testASendStopsToAskAboutAFileNobodyTicked() async throws {
        // The hole: catching up put their version into the history while my
        // copy stayed as it was, and from then on Git saw an ordinary change.
        // Sending it later wiped their work with no refusal and no warning.
        try await readyGit()
        try await clashSetUp()
        let before = try run(["rev-parse", "HEAD"], in: mine)

        let result = await GitService.shared.send(paths: ["second.md"], newPaths: [],
                                                  message: "just the second",
                                                  inRepository: mine)

        guard case .needsDecision(let paths) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(paths, ["readme.md"])
        // A question, not a state: nothing has moved.
        XCTAssertEqual(try run(["rev-parse", "HEAD"], in: mine), before, "commit undone")
        XCTAssertEqual(read("readme.md"), "one\nMINE\nthree\n", "my copy untouched")
        XCTAssertEqual(read("second.md"), "mine too\n")
        let checking = try colleague2()
        XCTAssertEqual(read("second.md", in: checking), "first version\n", "nothing sent")
    }

    func testEditsInDifferentPlacesAreNotWorthAsking() async throws {
        // Git merges those, and the copy here ends up holding both changes.
        // Asking would be friction with nothing behind it.
        try await readyGit()
        try write("readme.md", "one\ntwo\nthree\n")
        try write("second.md", "first version\n")
        try run(["add", "-A"], in: mine)
        try run(["commit", "-m", "setup"], in: mine)
        try run(["push"], in: mine)

        let theirs = try colleague()
        try write("readme.md", "one\ntwo\nTHEIRS\n", in: theirs)   // last line
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        try write("readme.md", "MINE\ntwo\nthree\n")               // first line
        try write("second.md", "mine too\n")

        let result = await GitService.shared.send(paths: ["second.md"], newPaths: [],
                                                  message: "just the second",
                                                  inRepository: mine)

        guard case .sent = result else { return XCTFail("\(result)") }
        XCTAssertEqual(read("readme.md"), "MINE\ntwo\nTHEIRS\n", "both changes survived")
    }

    func testKeepingMineLetsTheSendThroughAndDoesNotAskTwice() async throws {
        try await readyGit()
        try await clashSetUp()

        let result = await GitService.shared.send(paths: ["second.md"], newPaths: [],
                                                  message: "just the second",
                                                  inRepository: mine,
                                                  decided: ["readme.md"])

        guard case .sent = result else { return XCTFail("\(result)") }
        XCTAssertEqual(read("readme.md"), "one\nMINE\nthree\n", "mine, exactly as it was")
        XCTAssertNil(read("readme (my version).md"), "and no copy made")
        let checking = try colleague2()
        XCTAssertEqual(read("second.md", in: checking), "mine too\n", "the ticked one went")
    }

    func testTakingTheirsKeepsACopyAndThenTheSendGoesThrough() async throws {
        try await readyGit()
        try await clashSetUp()

        let kept = await GitService.shared.setAsideMyVersion(["readme.md"], inRepository: mine)
        XCTAssertEqual(kept, ["readme (my version).md"])
        XCTAssertEqual(read("readme (my version).md"), "one\nMINE\nthree\n")

        let result = await GitService.shared.send(paths: ["second.md"], newPaths: [],
                                                  message: "just the second",
                                                  inRepository: mine)

        guard case .sent = result else { return XCTFail("\(result)") }
        XCTAssertEqual(read("readme.md"), "one\nTHEIRS\nthree\n", "theirs took the name")
    }

    func testAKeptCopyIsDrawnAsOneRatherThanAsAnOrdinaryFile() async throws {
        // Reported: these looked exactly like tracked, up-to-date files,
        // because an ignored file is drawn plainly -- and unlike a brown file
        // this one cannot be tracked at all.
        try await readyGit()
        try await clashSetUp()
        _ = await GitService.shared.setAsideMyVersion(["readme.md"], inRepository: mine)

        GitService.shared.invalidate(mine)
        let seen = await GitService.shared.status(for: mine)
        let status = try XCTUnwrap(seen).status

        XCTAssertEqual(status.state(for: mine.appendingPathComponent("readme (my version).md"),
                                    root: mine),
                       .keptCopy)
        let changes = await GitService.shared.changes(inRepository: mine)
        XCTAssertFalse(changes.new.contains { $0.path.contains("my version") },
                       "and never offered for sending")
    }

    // MARK: - Whether a send may update the folder

    private func withUpdating(_ on: Bool, _ body: () async throws -> Void) async rethrows {
        let was = ConfigStore.shared.configuration.gitUpdateWhenSending
        ConfigStore.shared.configuration.gitUpdateWhenSending = on
        defer { ConfigStore.shared.configuration.gitUpdateWhenSending = was }
        try await body()
    }

    private func withUpdatingOff(_ body: () async throws -> Void) async rethrows {
        try await withUpdating(false, body)
    }

    private func withUpdatingOn(_ body: () async throws -> Void) async rethrows {
        try await withUpdating(true, body)
    }

    func testUpdatingWhileSendingIsOnByDefault() {
        XCTAssertTrue(Configuration().gitUpdateWhenSending)
    }

    func testWithUpdatingOffASendBehindIsRefusedRatherThanCaughtUp() async throws {
        // "I only wanted to send a file" -- so nothing arrives, the folder is
        // left exactly as it was, and the update is offered instead of taken.
        try await readyGit()
        try write("second.md", "first version\n")
        try run(["add", "-A"], in: mine)
        try run(["commit", "-m", "add second"], in: mine)
        try run(["push"], in: mine)

        let theirs = try colleague()
        try write("theirs-only.md", "theirs\n", in: theirs)
        try run(["add", "-A"], in: theirs)
        try run(["commit", "-m", "unrelated"], in: theirs)
        try run(["push"], in: theirs)

        try write("second.md", "mine too\n")
        let before = try run(["rev-parse", "HEAD"], in: mine)

        try await withUpdatingOff {
            let result = await GitService.shared.send(paths: ["second.md"], newPaths: [],
                                                      message: "just the second",
                                                      inRepository: mine)

            guard case .notSent(let reason, _, let conflicts) = result else {
                return XCTFail("\(result)")
            }
            XCTAssertTrue(conflicts.isEmpty, "nothing clashes; it is only behind")
            XCTAssertTrue(reason.contains("since you last updated"),
                          "and says so rather than blaming a clash: \(reason)")
            XCTAssertNil(read("theirs-only.md"), "nothing arrived unasked")
            XCTAssertEqual(try run(["rev-parse", "HEAD"], in: mine), before, "commit undone")
            XCTAssertEqual(read("second.md"), "mine too\n", "and my work is where I left it")
        }
    }

    func testWithUpdatingOnTheSameSendGoesThrough() async throws {
        // The other half of the switch, so the default keeps working.
        try await readyGit()
        try write("second.md", "first version\n")
        try run(["add", "-A"], in: mine)
        try run(["commit", "-m", "add second"], in: mine)
        try run(["push"], in: mine)

        let theirs = try colleague()
        try write("theirs-only.md", "theirs\n", in: theirs)
        try run(["add", "-A"], in: theirs)
        try run(["commit", "-m", "unrelated"], in: theirs)
        try run(["push"], in: theirs)

        try write("second.md", "mine too\n")

        try await withUpdatingOn {
            let result = await GitService.shared.send(paths: ["second.md"], newPaths: [],
                                                      message: "just the second",
                                                      inRepository: mine)

            guard case .sent = result else { return XCTFail("\(result)") }
            XCTAssertEqual(read("theirs-only.md"), "theirs\n", "and theirs came down with it")
        }
    }

    // MARK: - Checking what other people have sent

    func testCheckingFindsWhatIsWaiting() async throws {
        try await readyGit()
        let theirs = try colleague()
        try write("theirs-only.md", "theirs\n", in: theirs)
        try run(["add", "-A"], in: theirs)
        try run(["commit", "-m", "unrelated"], in: theirs)
        try run(["push"], in: theirs)

        // Nothing knows about it until we ask -- the whole point.
        XCTAssertNil(GitService.shared.check(for: mine), "no answer before asking")

        let result = await GitService.shared.checkForChanges(inRepository: mine)

        guard case .checked(let behind, let contested) = result else {
            return XCTFail("\(result)")
        }
        XCTAssertEqual(behind, 1)
        XCTAssertTrue(contested.isEmpty, "nobody touched the same file")
        XCTAssertNotNil(GitService.shared.check(for: mine)?.at, "and the answer is dated")
    }

    func testCheckingNamesWhatBothSidesChanged() async throws {
        try await readyGit()
        let theirs = try colleague()
        try write("readme.md", "theirs\n", in: theirs)
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        try write("readme.md", "mine\n")

        let result = await GitService.shared.checkForChanges(inRepository: mine)

        guard case .checked(_, let contested) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(contested, ["readme.md"])
        XCTAssertEqual(GitService.shared.check(for: mine)?.contested, ["readme.md"])
    }

    func testAContestedFileIsRedInThePane() async throws {
        // The colour is the point of the whole feature: red appears only after
        // the check, because only the check can know.
        try await readyGit()
        let theirs = try colleague()
        try write("readme.md", "theirs\n", in: theirs)
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        try write("readme.md", "mine\n")
        GitService.shared.invalidate(mine)

        let first = await GitService.shared.status(for: mine)
        var status = try XCTUnwrap(first).status
        XCTAssertEqual(status.state(for: mine.appendingPathComponent("readme.md"), root: mine),
                       .changed, "blue until we ask")

        _ = await GitService.shared.checkForChanges(inRepository: mine)

        let second = await GitService.shared.status(for: mine)
        status = try XCTUnwrap(second).status
        for path in try XCTUnwrap(GitService.shared.check(for: mine)).contested {
            status.states[path] = .contested
        }
        XCTAssertEqual(status.state(for: mine.appendingPathComponent("readme.md"), root: mine),
                       .contested, "red once we have asked")
    }

    func testAnAnswerTooOldToVouchForIsDropped() async throws {
        // Red that outlives what it was based on is exactly the complaint this
        // feature had to answer, so the answer expires on its own.
        try await readyGit()
        GitService.shared.noteCheck(mine, contested: ["readme.md"], stale: [], behind: 1)
        XCTAssertNotNil(GitService.shared.check(for: mine), "fresh")

        GitService.shared.checks[mine.path]?.at =
            Date().addingTimeInterval(-GitService.checkGoesStaleAfter - 1)

        XCTAssertNil(GitService.shared.check(for: mine), "and gone once it is too old")
        XCTAssertNil(GitService.shared.checks[mine.path], "not merely hidden, actually dropped")
    }

    func testOnlySoManyAnswersAreKept() async throws {
        // Browsing through a great many repositories must not grow without end.
        try await readyGit()
        for index in 0 ... GitService.checksRemembered {
            let fake = root.appendingPathComponent("repo\(index)")
            GitService.shared.noteCheck(fake, contested: [], stale: [], behind: 0)
        }
        XCTAssertLessThanOrEqual(GitService.shared.checks.count, GitService.checksRemembered)
    }

    func testARefusedSendRecordsWhatItLearned() async throws {
        // The send has just fetched and worked out the clash. Making the user
        // press Check to see it in red would be asking for what we already have.
        try await readyGit()
        let theirs = try colleague()
        try write("readme.md", "theirs\n", in: theirs)
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        try write("readme.md", "mine\n")
        let result = await GitService.shared.send(paths: ["readme.md"], newPaths: [],
                                                  message: "mine", inRepository: mine)

        guard case .notSent = result else { return XCTFail("\(result)") }
        XCTAssertEqual(GitService.shared.check(for: mine)?.contested, ["readme.md"])
    }

    func testASuccessfulSendLeavesNothingContested() async throws {
        try await readyGit()
        GitService.shared.noteCheck(mine, contested: ["readme.md"], stale: [], behind: 1)
        try write("readme.md", "changed\n")

        _ = await GitService.shared.send(paths: ["readme.md"], newPaths: [],
                                         message: "an edit", inRepository: mine)

        XCTAssertEqual(GitService.shared.check(for: mine)?.contested, [],
                       "it went, so nothing is contested -- and the stamp stays fresh")
    }

    func testAHalfFinishedMergeIsNeverOfferedForSending() async throws {
        // `git add` on an unmerged file marks it resolved and stages it *with
        // the conflict markers in it*. It must not be tickable.
        try await readyGit()
        try run(["checkout", "-b", "side"], in: mine)
        try write("readme.md", "side\n")
        try run(["commit", "-am", "side"], in: mine)
        try run(["checkout", "main"], in: mine)
        try write("readme.md", "main\n")
        try run(["commit", "-am", "main"], in: mine)
        _ = try? run(["merge", "side"], in: mine)   // conflicts on purpose

        GitService.shared.invalidate(mine)
        let changes = await GitService.shared.changes(inRepository: mine)

        XCTAssertFalse(changes.sending.contains { $0.path == "readme.md" },
                       "not offered with a tick beside it")
        XCTAssertFalse(changes.new.contains { $0.path == "readme.md" })
        XCTAssertEqual(changes.unresolved.map(\.path), ["readme.md"],
                       "listed, so it does not simply vanish")
    }

    func testAHalfFinishedMergeOutranksEverythingElse() async throws {
        try await readyGit()
        XCTAssertEqual(GitStatus.stronger(.contested, .conflicted), .conflicted)
        XCTAssertEqual(GitStatus.stronger(.changed, .contested), .contested)
    }

    // MARK: - Checking automatically

    /// The setting is off by default, so every test here turns it on and puts
    /// it back.
    private func withAutomaticChecking(_ body: () throws -> Void) rethrows {
        let was = ConfigStore.shared.configuration.gitCheckOnOpen
        ConfigStore.shared.configuration.gitCheckOnOpen = true
        defer { ConfigStore.shared.configuration.gitCheckOnOpen = was }
        try body()
    }

    func testNothingIsCheckedAutomaticallyWhileTheSettingIsOff() async throws {
        // Set explicitly rather than relied upon: these tests run against the
        // real ConfigStore, so once the setting started persisting properly a
        // test that assumed the default failed on any machine where the user
        // had turned it on.
        try await readyGit()
        try write("readme.md", "changed\n")
        GitService.shared.invalidate(mine)
        let answer = await GitService.shared.status(for: mine)
        let status = try XCTUnwrap(answer).status

        let was = ConfigStore.shared.configuration.gitCheckOnOpen
        ConfigStore.shared.configuration.gitCheckOnOpen = false
        defer { ConfigStore.shared.configuration.gitCheckOnOpen = was }

        XCTAssertFalse(GitService.shared.claimAutomaticCheck(for: mine, status: status),
                       "nothing reaches the network unless this is asked for")
    }

    func testCheckingOnOpenIsOffInAFreshConfiguration() {
        XCTAssertFalse(Configuration().gitCheckOnOpen,
                       "the default is off: it is the one thing that reaches the network")
    }

    func testAFolderWithChangesIsCheckedOncePerLaunch() async throws {
        try await readyGit()
        try write("readme.md", "changed\n")
        GitService.shared.invalidate(mine)
        let answer = await GitService.shared.status(for: mine)
        let status = try XCTUnwrap(answer).status

        withAutomaticChecking {
            XCTAssertTrue(GitService.shared.claimAutomaticCheck(for: mine, status: status))
            XCTAssertFalse(GitService.shared.claimAutomaticCheck(for: mine, status: status),
                           "and not again -- decoration runs on every navigation")
        }
    }

    func testAFolderWithNoChangesIsLeftAlone() async throws {
        // Contested means "changed on both sides", so with nothing changed here
        // there is nothing a check could colour. No network call.
        try await readyGit()
        GitService.shared.invalidate(mine)
        let answer = await GitService.shared.status(for: mine)
        let status = try XCTUnwrap(answer).status

        withAutomaticChecking {
            XCTAssertFalse(GitService.shared.claimAutomaticCheck(for: mine, status: status))
        }
    }

    func testTheOncePerLaunchPromiseOutlivesTheAnswer() async throws {
        // `checks` expires after half an hour. The right to make a network call
        // must not come back with it, or an afternoon in one folder would mean
        // a fetch every thirty minutes.
        try await readyGit()
        try write("readme.md", "changed\n")
        GitService.shared.invalidate(mine)
        let answer = await GitService.shared.status(for: mine)
        let status = try XCTUnwrap(answer).status

        withAutomaticChecking {
            XCTAssertTrue(GitService.shared.claimAutomaticCheck(for: mine, status: status))
            GitService.shared.checks.removeAll()
            XCTAssertFalse(GitService.shared.claimAutomaticCheck(for: mine, status: status))
        }
    }

    func testOneCheckColoursTheWholeTree() async throws {
        // "Recurse the whole directory structure": a check is repository-wide,
        // so walking into a subfolder afterwards costs nothing more.
        try await readyGit()
        try write("chapters/deep/three.md", "first\n")
        try run(["add", "-A"], in: mine)
        try run(["commit", "-m", "add a deep one"], in: mine)
        try run(["push"], in: mine)

        let theirs = try colleague()
        try write("chapters/deep/three.md", "theirs\n", in: theirs)
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        try write("chapters/deep/three.md", "mine\n")
        _ = await GitService.shared.checkForChanges(inRepository: mine)

        let check = try XCTUnwrap(GitService.shared.check(for: mine))
        XCTAssertEqual(check.contested, ["chapters/deep/three.md"], "found without visiting it")

        // And the folders above it carry the colour up, which is what the pane
        // draws when only the top of the tree is on screen.
        let second = await GitService.shared.status(for: mine)
        var status = try XCTUnwrap(second).status
        for path in check.contested { status.states[path] = .contested }
        XCTAssertEqual(status.state(for: mine.appendingPathComponent("chapters"), root: mine),
                       .contested)
    }

    func testUpdatingClearsTheRed() async throws {
        // Reported: after keeping copies and taking the shared version, the
        // files that had just arrived stayed red until Check for Changes was
        // pressed by hand.
        try await readyGit()
        let theirs = try colleague()
        try write("readme.md", "theirs\n", in: theirs)
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        try write("readme.md", "mine\n")
        let conflicting = await GitService.shared.getLatest(inRepository: mine)
        guard case .conflicting(let paths, _) = conflicting else {
            return XCTFail("\(conflicting)")
        }
        XCTAssertEqual(GitService.shared.check(for: mine)?.contested, ["readme.md"], "red")

        _ = await GitService.shared.keepCopiesAndTakeShared(paths: paths, inRepository: mine)

        XCTAssertEqual(GitService.shared.check(for: mine)?.contested, [],
                       "and black again, without being asked")
    }

    func testAFileChangedOnlyByThemIsOutOfDateNotAClash() async throws {
        try await readyGit()
        try write("second.md", "first version\n")
        try run(["add", "-A"], in: mine)
        try run(["commit", "-m", "add second"], in: mine)
        try run(["push"], in: mine)

        let theirs = try colleague()
        try write("readme.md", "theirs\n", in: theirs)      // only they touched this
        try write("second.md", "theirs too\n", in: theirs)  // both touched this
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        try write("second.md", "mine\n")

        _ = await GitService.shared.checkForChanges(inRepository: mine)

        let check = try XCTUnwrap(GitService.shared.check(for: mine))
        XCTAssertEqual(check.stale, ["readme.md"], "theirs alone: purple")
        XCTAssertEqual(check.contested, ["second.md"], "both: red")
    }

    func testNothingIsOutOfDateOnceTheLatestIsIn() async throws {
        try await readyGit()
        let theirs = try colleague()
        try write("readme.md", "theirs\n", in: theirs)
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        _ = await GitService.shared.checkForChanges(inRepository: mine)
        XCTAssertEqual(GitService.shared.check(for: mine)?.stale, ["readme.md"])

        _ = await GitService.shared.getLatest(inRepository: mine)

        XCTAssertEqual(GitService.shared.check(for: mine)?.stale, [],
                       "the purple clears itself the moment the reason for it is gone")
    }

    func testAnOutOfDateFileIsNotOfferedForSending() async throws {
        // There is nothing of the user's in it to send.
        try await readyGit()
        let theirs = try colleague()
        try write("readme.md", "theirs\n", in: theirs)
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)
        _ = await GitService.shared.checkForChanges(inRepository: mine)

        let changes = await GitService.shared.changes(inRepository: mine)

        XCTAssertTrue(changes.sending.isEmpty)
        XCTAssertTrue(changes.new.isEmpty)
    }

    // MARK: - Getting the latest

    func testGettingTheLatestFastForwards() async throws {
        try await readyGit()
        let theirs = try colleague()
        try write("readme.md", "from my colleague\n", in: theirs)
        try run(["commit", "-am", "theirs"], in: theirs)
        try run(["push"], in: theirs)

        let result = await GitService.shared.getLatest(inRepository: mine)

        guard case .updated = result else { return XCTFail("\(result)") }
        XCTAssertEqual(read("readme.md"), "from my colleague\n")
    }

    func testUpToDateSaysSo() async throws {
        try await readyGit()
        let result = await GitService.shared.getLatest(inRepository: mine)
        guard case .upToDate = result else { return XCTFail("\(result)") }
    }

    func testTheConflictingSetIsOnlyWhatBothSidesTouched() async throws {
        try await readyGit()
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

    func testAnUntrackedFileThatAlsoArrivedIsListedAsConflicting() async throws {
        // The reported case: the same new file created in two clones. `git
        // diff` never sees an untracked file, so it was missing from the list
        // entirely -- the dialog offered to keep copies of nothing, and the
        // update then failed on the very file it had not mentioned.
        try await readyGit()
        let theirs = try colleague()
        try write("shared-new.md", "theirs\n", in: theirs)
        try run(["add", "-A"], in: theirs)
        try run(["commit", "-m", "new file"], in: theirs)
        try run(["push"], in: theirs)

        try write("shared-new.md", "mine\n")

        let result = await GitService.shared.getLatest(inRepository: mine)

        guard case .conflicting(let paths, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(paths, ["shared-new.md"])
    }

    func testKeepingCopiesWorksWhenTheFileWasUntracked() async throws {
        // Git refuses to overwrite an untracked file, and there is nothing to
        // restore it from -- so it has to be removed once the copy is safe.
        try await readyGit()
        let theirs = try colleague()
        try write("shared-new.md", "theirs\n", in: theirs)
        try run(["add", "-A"], in: theirs)
        try run(["commit", "-m", "new file"], in: theirs)
        try run(["push"], in: theirs)

        try write("shared-new.md", "mine\n")
        guard case .conflicting(let paths, _) =
                await GitService.shared.getLatest(inRepository: mine) else {
            return XCTFail("expected a conflict")
        }

        let result = await GitService.shared.keepCopiesAndTakeShared(paths: paths,
                                                                    inRepository: mine)

        guard case .keptCopies = result else { return XCTFail("\(result)") }
        XCTAssertEqual(read("shared-new.md"), "theirs\n", "the shared version is in place")
        XCTAssertEqual(read("shared-new (my version).md"), "mine\n", "and mine is beside it")
    }

    func testKeepingCopiesWorksForAFileStagedButNeverCommitted() async throws {
        // The case that broke: a file tracked by hand before a send that
        // failed is *tracked* and still absent from HEAD, so restoring it with
        // `checkout --` brought it back from the index and left it in place.
        // "Is it in HEAD" is the question, not "does Git know about it".
        try await readyGit()
        let theirs = try colleague()
        try write("both.md", "theirs\n", in: theirs)
        try run(["add", "-A"], in: theirs)
        try run(["commit", "-m", "new file"], in: theirs)
        try run(["push"], in: theirs)

        try write("both.md", "mine\n")
        _ = await GitService.shared.track(["both.md"], inRepository: mine)
        GitService.shared.invalidate(mine)
        // Staged as added, and not in HEAD -- exactly the state that failed.
        let changes = await GitService.shared.changes(inRepository: mine)
        XCTAssertEqual(changes.sending.first { $0.path == "both.md" }?.state, .added)

        guard case .conflicting(let paths, _) =
                await GitService.shared.getLatest(inRepository: mine) else {
            return XCTFail("expected a conflict")
        }
        let result = await GitService.shared.keepCopiesAndTakeShared(paths: paths,
                                                                    inRepository: mine)

        guard case .keptCopies(let names) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(read("both.md"), "theirs\n", "the shared version actually landed")
        XCTAssertEqual(read("both (my version).md"), "mine\n")
        XCTAssertEqual(names, ["both (my version).md"], "and it says what it set aside")
    }

    func testAKeptCopyIsInvisibleToGitForEver() async throws {
        // What happens to a "(my version)" file left lying about: nothing. It
        // is excluded locally, so it is never offered for sending and never
        // clashes with anything.
        try await readyGit()
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

        let after = await GitService.shared.changes(inRepository: mine)
        XCTAssertTrue(after.isEmpty, "a kept copy is not a pending change")

        // And a later update is not blocked by it either.
        try write("readme.md", "theirs again\n", in: theirs)
        try run(["commit", "-am", "more"], in: theirs)
        try run(["push"], in: theirs)
        let again = await GitService.shared.getLatest(inRepository: mine)
        guard case .updated = again else { return XCTFail("\(again)") }
    }

    func testKeepingCopiesPreservesMyVersionAndTakesTheShared() async throws {
        try await readyGit()
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

        guard case .keptCopies = result else { return XCTFail("\(result)") }
        XCTAssertEqual(read("readme.md"), "theirs\n", "the folder matches the shared copy")
        XCTAssertEqual(read("readme (my version).md"), "mine\n", "and nothing of mine is lost")
    }

    func testTheKeptCopyIsNotOfferedForSending() async throws {
        try await readyGit()
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
        try await readyGit()
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
        try await readyGit()
        try write("notes.tmp", "scratch\n")

        _ = await GitService.shared.neverTrack(["notes.tmp"], inRepository: mine)
        GitService.shared.invalidate(mine)

        let changes = await GitService.shared.changes(inRepository: mine)
        XCTAssertFalse(changes.new.contains { $0.path == "notes.tmp" })
        XCTAssertTrue((read(".gitignore") ?? "").contains("notes.tmp"))
    }

    func testTrackingMakesAFileNewAndTracked() async throws {
        try await readyGit()
        try write("chapter4.md", "new\n")

        _ = await GitService.shared.track(["chapter4.md"], inRepository: mine)
        GitService.shared.invalidate(mine)

        let changes = await GitService.shared.changes(inRepository: mine)
        XCTAssertTrue(changes.sending.contains { $0.path == "chapter4.md" && $0.state == .added })
        XCTAssertFalse(changes.new.contains { $0.path == "chapter4.md" })
    }
}
