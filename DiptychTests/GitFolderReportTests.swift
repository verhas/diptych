import XCTest
@testable import Diptych

/// The Git part of a folder's preview, against real repositories made here.
final class GitFolderReportTests: XCTestCase {

    private var root: URL!
    private var mine: URL!
    private var git: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let found = try XCTUnwrap(GitTool.locate(override: nil), "no git on this machine")
        git = found.url
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DiptychGitReport-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let shared = root.appendingPathComponent("shared.git")
        mine = root.appendingPathComponent("mine")
        try run(["init", "--bare", "-b", "main", shared.path], in: root)
        try run(["clone", shared.path, mine.path], in: root)
        try run(["config", "user.name", "Ada Tester"], in: mine)
        try run(["config", "user.email", "ada@example.com"], in: mine)
        try write("readme.md", "first\n")
        try write("docs/guide.md", "guide\n")
        try run(["add", "-A"], in: mine)
        try run(["commit", "-m", "Start the project"], in: mine)
        try run(["push", "-u", "origin", "main"], in: mine)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func run(_ arguments: [String], in directory: URL) throws -> String {
        let outcome = GitTool.run(arguments, executable: git, in: directory, timeout: 60)
        guard case .ok(let text) = outcome else {
            throw NSError(domain: "git", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(arguments): \(outcome)"])
        }
        return text
    }

    private func write(_ path: String, _ text: String) throws {
        let url = mine.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testTheRootSaysBranchSharedCopyChangesAndCommits() throws {
        try write("readme.md", "changed\n")
        try write("new.txt", "new\n")
        try run(["commit", "--allow-empty", "-m", "Not sent yet"], in: mine)

        let facts = try XCTUnwrap(GitFolderReport.read(mine, git: git))
        XCTAssertTrue(facts.isRoot)
        XCTAssertEqual(facts.status.branch, "main")
        XCTAssertEqual(facts.status.upstream, "origin/main")
        XCTAssertEqual(facts.status.ahead, 1)
        XCTAssertEqual(Set(facts.changes.map(\.path)), ["readme.md", "new.txt"])
        XCTAssertEqual(facts.commits.map(\.subject), ["Not sent yet", "Start the project"])
        XCTAssertEqual(facts.commits.first?.author, "Ada Tester")

        let html = GitFolderReport.section(facts)
        for expected in ["<b>main</b>", "origin/main", "1 commit of yours not sent", "1 changed", "1 not tracked",
                         "Start the project"] {
            XCTAssertTrue(html.contains(expected), expected)
        }
    }

    func testASubfolderShowsItsOwnChangesAndCommits() throws {
        try write("readme.md", "changed\n")
        try write("docs/guide.md", "edited\n")
        let docs = mine.appendingPathComponent("docs")

        let facts = try XCTUnwrap(GitFolderReport.read(docs, git: git))
        XCTAssertFalse(facts.isRoot)
        XCTAssertEqual(facts.changes.map(\.path), ["guide.md"], "relative to the folder, the rest left out")
        XCTAssertEqual(facts.commits.count, 1)
        XCTAssertTrue(GitFolderReport.section(facts).contains("Changes here"))
    }

    func testABranchNotLinkedAndAnEmptyRepository() throws {
        try run(["switch", "-c", "local-only"], in: mine)
        let facts = try XCTUnwrap(GitFolderReport.read(mine, git: git))
        XCTAssertNil(facts.status.upstream)
        XCTAssertTrue(GitFolderReport.section(facts).contains("not linked"))

        let fresh = root.appendingPathComponent("fresh")
        try run(["init", "-b", "main", fresh.path], in: root)
        let empty = try XCTUnwrap(GitFolderReport.read(fresh, git: git))
        XCTAssertTrue(empty.commits.isEmpty)
        XCTAssertTrue(GitFolderReport.section(empty).contains("No commits yet"))
    }

    func testAFolderOutsideARepositoryHasNoSection() throws {
        let outside = root.appendingPathComponent("plain")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        XCTAssertNil(GitFolderReport.read(outside, git: git))
    }

    func testTheFolderPageCarriesTheSection() throws {
        let facts = try XCTUnwrap(GitFolderReport.read(mine, git: git))
        let html = ListingReport.html(for: Listing.folder(at: mine), name: "mine", path: mine.path,
                                      kind: .folder, extra: GitFolderReport.section(facts))
        XCTAssertTrue(html.contains("<h2>Git</h2>"))
        XCTAssertTrue(html.contains("readme.md"))
    }
}
