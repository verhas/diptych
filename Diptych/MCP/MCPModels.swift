import Foundation
import MCP

/// JSON payloads for the MCP tool handlers.
///
/// `FileItem`, `PaneModel` and `AppModel` are deliberately not `Codable` --
/// they are live, in-memory UI state, not a wire format. These are the
/// bespoke, `Sendable` wrapper types built from that state at request time,
/// one per tool call, never stored.
enum MCPModels {

    struct FileEntry: Codable, Sendable {
        var name: String
        var path: String
        var isDirectory: Bool
        var isSymlink: Bool
        var isExecutable: Bool
        var byteSize: Int64
        var modified: Date
        var permissions: String
        var owner: String
        var group: String

        init(_ item: FileItem) {
            name = item.name
            path = item.url.path
            isDirectory = item.isDirectory
            isSymlink = item.isSymlink
            isExecutable = item.isExecutable
            byteSize = item.byteSize
            modified = item.modified
            permissions = item.permissions
            owner = item.owner
            group = item.group
        }
    }

    struct PaneSnapshot: Codable, Sendable {
        var windowId: String
        var side: String
        var directory: String
        var entries: [FileEntry]
    }

    struct SelectionSnapshot: Codable, Sendable {
        var windowId: String
        var side: String
        var entries: [FileEntry]
    }

    struct WindowSummary: Codable, Sendable {
        var windowId: String
        var windowNumber: Int
        var activeSide: String
        var leftDirectory: String
        var rightDirectory: String
    }

    /// A window with no `AppModel` behind it -- Get Info, Compare, Bin Edit,
    /// Text Edit, Rename Many, Settings -- described by kind and what it's
    /// showing, rather than by pane state it doesn't have.
    struct ToolWindowSummary: Codable, Sendable {
        var windowNumber: Int
        var kind: String
        var title: String
        var subject: String
    }

    /// The MCP spec requires `structuredContent` to be a JSON object, not a
    /// bare array -- `list_windows` needed something to wrap its arrays in.
    struct WindowList: Codable, Sendable {
        var windows: [WindowSummary]
        var toolWindows: [ToolWindowSummary]
    }

    /// Wraps any of the DTOs above as a tool result: the same value both as
    /// `structuredContent`, for a client that reads it, and as pretty JSON
    /// text, for one that only renders `content`.
    static func result<T: Codable>(for value: T) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(data: try encoder.encode(value), encoding: .utf8) ?? "{}"
        return try CallTool.Result(content: [.text(text: json, annotations: nil, _meta: nil)],
                                    structuredContent: value)
    }
}
