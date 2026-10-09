import XCTest
@testable import Diptych

/// Text Edit's change bars: the last commit and the last save as bases.
@MainActor
final class TextEditGutterTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychTextGit-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        LiveSettings.protect()
        ConfigStore.shared.configuration.gitEnabled = true
        await GitService.shared.locate()
        try XCTSkipIf(GitService.shared.tool == nil, "git could not be resolved")
    }

    override func tearDown() async throws {
        LiveSettings.putBack()
        GitService.shared.forgetEverything()
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func git(_ arguments: [String]) throws -> String {
        let tool = try XCTUnwrap(GitTool.locate(override: nil))
        guard case .ok(let text) = GitTool.run(arguments, executable: tool.url, in: root,
                                               timeout: 60) else {
            XCTFail("git \(arguments) failed")
            return ""
        }
        return text
    }

    func testTheBaseIsTheLastCommit() async throws {
        try git(["init", "-q"])
        try git(["config", "user.email", "t@example.com"])
        try git(["config", "user.name", "T"])
        let url = root.appendingPathComponent("a.yaml")
        try Data("a: 1\nb: 2\n".utf8).write(to: url)
        try git(["add", "a.yaml"])
        try git(["commit", "-q", "-m", "first"])

        let base = await TextEditController.baseline(for: url)
        XCTAssertEqual(base, .committed("a: 1\nb: 2\n"))

        let fresh = root.appendingPathComponent("new.yaml")
        try Data("x: 1\n".utf8).write(to: fresh)
        let uncommitted = await TextEditController.baseline(for: fresh)
        XCTAssertEqual(uncommitted, .uncommitted)

        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychNoGit-\(UUID().uuidString).yaml")
        try Data("x: 1\n".utf8).write(to: outside)
        defer { try? fm.removeItem(at: outside) }
        let none = await TextEditController.baseline(for: outside)
        XCTAssertEqual(none, .unavailable)
    }

    func testTheBarsFromTheirBases() {
        let changes = LineChanges.compute(base: "a\nb\nc\n", current: "a\nB\nc\nd\n")
        XCTAssertEqual(changes.lines, [1: .modified, 3: .added])
        let deleted = LineChanges.compute(base: "a\nb\nc\n", current: "a\nc\n")
        XCTAssertEqual(deleted.deletions, [1])
        XCTAssertTrue(LineChanges.compute(base: "a\r\nb", current: "a\nb").isEmpty,
                      "CRLF and LF are the same lines")
        XCTAssertEqual(LineChanges.allAdded("x\ny").lines.count, 2)
    }
}
