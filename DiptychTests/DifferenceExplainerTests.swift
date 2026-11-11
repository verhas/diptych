import XCTest
@testable import Diptych

/// What a comparison is turned into before Apple Intelligence reads it.
final class DifferenceExplainerTests: XCTestCase {

    // MARK: - Two files

    func testIdenticalFilesAreNotExplained() {
        let diff = TextDiff(left: ["a", "b"], right: ["a", "b"])
        XCTAssertNil(DifferenceExplainer.files(leftName: "l", rightName: "r", diff: diff))
    }

    func testFileDiffShowsChangesWithContext() {
        let left = ["one", "two", "three", "four", "five", "six", "seven"]
        var right = left
        right[3] = "FOUR"
        right.append("eight")
        let diff = TextDiff(left: left, right: right)
        let prompt = DifferenceExplainer.filePrompt(leftName: "old.txt", rightName: "new.txt",
                                                    diff: diff, budget: 10_000)
        XCTAssertTrue(prompt.contains("Left file: old.txt"))
        XCTAssertTrue(prompt.contains("Right file: new.txt"))
        XCTAssertTrue(prompt.contains("-four\n+FOUR\n"), prompt)
        XCTAssertTrue(prompt.contains("+eight\n"), prompt)
        XCTAssertTrue(prompt.contains(" three\n"), "context before the change: \(prompt)")
        XCTAssertFalse(prompt.contains(" one\n"), "too far from any change: \(prompt)")
    }

    func testFileDiffKeepsToTheBudget() {
        let left = (0..<2_000).map { "line \($0)" }
        let right = left.map { $0 + " changed" }
        let diff = TextDiff(left: left, right: right)
        let prompt = DifferenceExplainer.filePrompt(leftName: "l", rightName: "r",
                                                    diff: diff, budget: 1_000)
        XCTAssertLessThanOrEqual(prompt.count, 1_000 + 100)
        // One change from top to bottom: still shown, as far as it fits.
        XCTAssertTrue(prompt.contains("-line 0\n+line 0 changed\n"), prompt)
        let request = DifferenceExplainer.files(leftName: "l", rightName: "r", diff: diff)
        XCTAssertEqual(request?.prompts.count, 2)
        XCTAssertLessThan(request!.prompts[1].count, request!.prompts[0].count)
    }

    /// The real model, where there is one: an answer, not an error.
    func testTheModelExplainsAFileDiff() async throws {
        try XCTSkipUnless(NameSuggester.status == .ready, "Apple Intelligence is not ready here")
        let left = ["timeout = 30", "retries = 3", "host = example.org"]
        let right = ["timeout = 60", "retries = 3", "host = example.com"]
        let request = try XCTUnwrap(DifferenceExplainer.files(
            leftName: "settings.conf", rightName: "settings.conf",
            diff: TextDiff(left: left, right: right)))
        let outcome = await DifferenceExplainer.explain(request)
        guard case .explained(let text) = outcome else {
            return XCTFail("no explanation: \(outcome)")
        }
        print("MODEL SAID: \(text)")
        XCTAssertFalse(text.isEmpty)
    }

    // MARK: - Two folders

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DifferenceExplainerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testFolderPromptListsWhatDiffersAndCollapsesOneSidedFolders() throws {
        try write("same", "L/same.txt")
        try write("same", "R/same.txt")
        try write("left version", "L/changed.txt")
        try write("the right version", "R/changed.txt")
        try write("x", "L/gone/a.txt")
        try write("y", "L/gone/b.txt")
        try write("new", "R/added.txt")
        let left = root.appendingPathComponent("L")
        let right = root.appendingPathComponent("R")
        let options = DirectoryComparison.Options()
        let pairs = try DirectoryComparison.compare(left: left, right: right, options: options)

        let prompt = DifferenceExplainer.folderPrompt(left: left, right: right, pairs: pairs,
                                                      options: options, budget: 10_000)
        XCTAssertTrue(prompt.contains("differs: changed.txt"), prompt)
        XCTAssertTrue(prompt.contains("only on the left: gone/ (folder)"), prompt)
        XCTAssertFalse(prompt.contains("gone/a.txt"), "inside a one-sided folder: \(prompt)")
        XCTAssertTrue(prompt.contains("only on the right: added.txt"), prompt)
        XCTAssertFalse(prompt.contains("same.txt"), prompt)
    }

    func testSameFoldersAreNotExplained() throws {
        try write("same", "L/same.txt")
        try write("same", "R/same.txt")
        let left = root.appendingPathComponent("L")
        let right = root.appendingPathComponent("R")
        let options = DirectoryComparison.Options(comparePermissions: false, compareAttributes: false,
                                                  compareACL: false)
        let pairs = try DirectoryComparison.compare(left: left, right: right, options: options)
        XCTAssertNil(DifferenceExplainer.folders(left: left, right: right, pairs: pairs,
                                                 options: options))
    }
}
