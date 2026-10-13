import Foundation
import Observation

/// The MCP server's bearer token, kept in its own file rather than in
/// `~/.diptych/config.json` -- config.json is meant to be readable and
/// hand-editable (see `ConfigStore`), which is exactly what a credential
/// should not be. `~/.diptych/.mcp.token` holds nothing else, and is set
/// owner-read-only immediately after every write.
@MainActor
@Observable
final class MCPTokenStore {

    static let shared = MCPTokenStore()

    static let url = StateStore.directory.appendingPathComponent(".mcp.token")

    private(set) var token: String

    private init() {
        token = Self.load() ?? Self.write(UUID().uuidString)
    }

    /// A fresh token, written to disk and pushed to the server immediately
    /// if it's currently running -- so a leaked token stops working the
    /// moment this is pressed, not the next time the server happens to
    /// restart.
    func regenerate() {
        token = Self.write(UUID().uuidString)
        Task { await MCPServer.shared.updateToken(token) }
    }

    /// A token typed or pasted in Settings -- one already in an agent's
    /// configuration, say. Only a UUID is taken, kept as written, since the
    /// server compares it exactly with what the agent sends.
    @discardableResult
    func set(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValid(trimmed) else { return false }
        guard trimmed != token else { return true }
        token = Self.write(trimmed)
        Task { await MCPServer.shared.updateToken(token) }
        return true
    }

    nonisolated static func isValid(_ text: String) -> Bool {
        UUID(uuidString: text) != nil
    }

    /// What the token looks like with its characters hidden: its shape,
    /// `••••••••-••••-…`, and nothing of it.
    nonisolated static func masked(_ text: String) -> String {
        String(text.map { $0 == "-" ? "-" : "\u{2022}" })
    }

    private static func load() -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Deletes and rewrites rather than truncating in place: a file already
    /// owner-read-only has no write bit to open for writing even for its own
    /// owner, but its owner can always replace it -- removing and creating a
    /// file is governed by the *directory's* permissions, not the file's.
    @discardableResult
    private static func write(_ token: String) -> String {
        try? FileManager.default.createDirectory(at: StateStore.directory,
                                                  withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        try? token.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        return token
    }
}
