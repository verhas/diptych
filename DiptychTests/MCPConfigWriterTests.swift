import XCTest
@testable import Diptych

/// Merging Diptych's entry into a directory's `.mcp.json`.
final class MCPConfigWriterTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychMCPConfig-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func readConfig() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(".mcp.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testWritesADiptychEntryWhenNoFileExists() throws {
        try MCPConfigWriter.merge(port: 8787, token: "tok-1", into: root)

        let config = try readConfig()
        let servers = try XCTUnwrap(config["mcpServers"] as? [String: Any])
        let diptych = try XCTUnwrap(servers["diptych"] as? [String: Any])
        XCTAssertEqual(diptych["type"] as? String, "http")
        XCTAssertEqual(diptych["url"] as? String, "http://127.0.0.1:8787/mcp")
        let headers = try XCTUnwrap(diptych["headers"] as? [String: String])
        XCTAssertEqual(headers["Authorization"], "Bearer tok-1")
    }

    func testLeavesAnUnrelatedServerEntryUntouched() throws {
        let existing: [String: Any] = [
            "mcpServers": ["other-tool": ["type": "stdio", "command": "other-tool"]]
        ]
        let data = try JSONSerialization.data(withJSONObject: existing)
        try data.write(to: root.appendingPathComponent(".mcp.json"))

        try MCPConfigWriter.merge(port: 8787, token: "tok-1", into: root)

        let config = try readConfig()
        let servers = try XCTUnwrap(config["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["diptych"])
        let other = try XCTUnwrap(servers["other-tool"] as? [String: Any])
        XCTAssertEqual(other["command"] as? String, "other-tool")
    }

    func testRunningItAgainUpdatesInPlaceRatherThanDuplicating() throws {
        try MCPConfigWriter.merge(port: 8787, token: "tok-1", into: root)
        try MCPConfigWriter.merge(port: 9999, token: "tok-2", into: root)

        let config = try readConfig()
        let servers = try XCTUnwrap(config["mcpServers"] as? [String: Any])
        XCTAssertEqual(servers.count, 1)
        let diptych = try XCTUnwrap(servers["diptych"] as? [String: Any])
        XCTAssertEqual(diptych["url"] as? String, "http://127.0.0.1:9999/mcp")
        let headers = try XCTUnwrap(diptych["headers"] as? [String: String])
        XCTAssertEqual(headers["Authorization"], "Bearer tok-2")
    }

    func testMalformedExistingFileIsReportedRatherThanOverwritten() throws {
        try "not json".write(to: root.appendingPathComponent(".mcp.json"),
                             atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MCPConfigWriter.merge(port: 8787, token: "tok-1", into: root))
    }
}
