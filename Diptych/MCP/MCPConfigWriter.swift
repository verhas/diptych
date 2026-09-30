import Foundation

/// Merges a Diptych entry into a directory's `.mcp.json`, for agent CLIs
/// (Claude Code, Codex, ...) that auto-discover MCP servers there. Reads and
/// rewrites only the `mcpServers.diptych` key -- any other server already
/// configured in the file survives untouched, and running this again against
/// the same directory updates that one key in place rather than duplicating
/// it.
enum MCPConfigWriter {

    enum WriteError: Error, LocalizedError {
        case malformedExistingFile

        var errorDescription: String? {
            switch self {
            case .malformedExistingFile:
                return ".mcp.json exists but isn't a JSON object Diptych can safely edit."
            }
        }
    }

    static func merge(port: Int, token: String, into directory: URL) throws {
        let url = directory.appendingPathComponent(".mcp.json")

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw WriteError.malformedExistingFile }
            root = existing
        }

        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["diptych"] = [
            "type": "http",
            "url": "http://127.0.0.1:\(port)/mcp",
            "headers": ["Authorization": "Bearer \(token)"],
        ]
        root["mcpServers"] = servers

        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
