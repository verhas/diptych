import Foundation

/// The folder the agent terminal starts in: `~/.diptych/agentic` unless
/// Settings ▸ Agents says otherwise.
///
/// The agent is there to work through Diptych's MCP server, which reaches
/// files by path wherever they are -- so where the agent itself stands does
/// not matter, and a folder of Diptych's own is the one place where its
/// configuration can be kept without touching any project's files. It holds
/// the `.mcp.json` that points the agent at this Diptych, and the
/// `AGENTS.md` and `CLAUDE.md` that tell it how to work through Diptych.
@MainActor
enum AgentWorkspace {

    static var directory: URL {
        url(for: ConfigStore.shared.configuration.agentDirectory)
    }

    /// A path as typed in Settings: `~` is the home folder, and an empty
    /// field means the default.
    static func url(for path: String) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let chosen = trimmed.isEmpty ? Configuration.defaultAgentDirectory : trimmed
        return URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath,
                   isDirectory: true)
    }

    /// Make the folder, switch the MCP server on, and write the server's
    /// current port and token into `.mcp.json` -- every time, so a token
    /// regenerated or a port changed since the last time is not left stale --
    /// and the agent's instructions beside it.
    ///
    /// Switching the server on here is not a decision taken behind anyone's
    /// back: opening the agent terminal is asking for an agent that can reach
    /// Diptych, and without the server it could not.
    static func prepare() throws -> URL {
        let directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ConfigStore.shared.setMCPServerEnabled(true)
        try MCPConfigWriter.merge(port: ConfigStore.shared.configuration.mcpServerPort,
                                  token: MCPTokenStore.shared.token,
                                  into: directory)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        try AgentInstructions.write(into: directory, version: version)
        return directory
    }
}
