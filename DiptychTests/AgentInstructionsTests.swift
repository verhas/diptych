import XCTest
@testable import Diptych

/// AGENTS.md and CLAUDE.md are Diptych's to rewrite only while they carry its
/// marker line; without it they are the person's and stay as they are.
final class AgentInstructionsTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentInstructionsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    func testBothFilesAreWrittenWhenMissing() throws {
        try AgentInstructions.write(into: folder, version: "9.9.9")
        let agents = try read("AGENTS.md")
        XCTAssertTrue(agents.hasPrefix(AgentInstructions.marker))
        XCTAssertTrue(agents.contains("propose_file_operations"))
        XCTAssertTrue(try read("CLAUDE.md").contains("@AGENTS.md"))
    }

    func testAFileWithTheMarkerIsBroughtUpToDate() throws {
        let url = folder.appendingPathComponent("AGENTS.md")
        try (AgentInstructions.header(version: "0.1") + "\n\nold text").write(
            to: url, atomically: true, encoding: .utf8)
        try AgentInstructions.write(into: folder, version: "9.9.9")
        XCTAssertFalse(try read("AGENTS.md").contains("old text"))
        XCTAssertTrue(try read("AGENTS.md").contains("Diptych 9.9.9"))
    }

    func testAFileWithoutTheMarkerIsLeftAlone() throws {
        let url = folder.appendingPathComponent("AGENTS.md")
        try "# My own rules\n".write(to: url, atomically: true, encoding: .utf8)
        try AgentInstructions.write(into: folder, version: "9.9.9")
        XCTAssertEqual(try read("AGENTS.md"), "# My own rules\n")
    }
}
