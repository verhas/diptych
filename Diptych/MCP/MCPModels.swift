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

    /// What's open in a Compare (text/binary diff) window -- never the diff
    /// content itself, which `diff`/`cmp` already give an agent once it knows
    /// the two paths; only what's live-only: whether a side has been
    /// unlocked for editing, and whether it now has unsaved changes.
    struct TextDiffSnapshot: Codable, Sendable {
        var windowNumber: Int
        var leftPath: String
        var rightPath: String
        var isComparingBytes: Bool
        var editableSide: String?
        var hasUnsavedEdits: Bool
        var hasSaved: Bool
        var ignoreWhitespace: Bool
        var wraps: Bool
    }

    /// The comparison options a Compare Folders window is actually showing
    /// results for (`DirectoryComparison.Options`) -- live UI state, not
    /// derivable from the two paths alone.
    struct DirectoryDiffOptions: Codable, Sendable {
        var compareContent: Bool
        var comparePermissions: Bool
        var compareAttributes: Bool
        var compareACL: Bool
        var compareModificationDate: Bool
        var compareCreationDate: Bool
        var compareOwnership: Bool
        var recurseHiddenDirectories: Bool
    }

    /// One pair diptych's rename detection matched by content across
    /// different relative paths -- a plain `diff -rq`/`rsync` comparison
    /// doesn't do this matching at all, which is the reason this exists
    /// as its own field rather than being left to bash.
    struct DirectoryDiffRename: Codable, Sendable {
        var from: String
        var to: String
    }

    /// What's open in a Compare Folders window: the two roots, the options
    /// results on screen were actually produced with (not necessarily what
    /// the checkboxes currently say -- `needsRefresh` covers that gap), and
    /// the rename pairs. Never the full added/removed/changed list, which is
    /// bash-reproducible once the paths and options are known.
    struct DirectoryDiffSnapshot: Codable, Sendable {
        var windowNumber: Int
        var leftPath: String
        var rightPath: String
        var options: DirectoryDiffOptions
        var needsRefresh: Bool
        var renames: [DirectoryDiffRename]
    }

    struct SettingSummary: Codable, Sendable {
        var key: String
        var kind: String
        var description: String
        var allowedValues: [String]?
        var value: Value
    }

    struct SettingsList: Codable, Sendable {
        var settings: [SettingSummary]
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
