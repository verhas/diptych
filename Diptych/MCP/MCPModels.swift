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
        /// Set while the pane is a flat view of `directory`: the entries are
        /// then everything under it that the expression lists.
        var flatExpression: String? = nil
        /// A flat view whose rows were changed since it was walked, so that
        /// some no longer pass the expression.
        var flatStale: Bool? = nil
        /// Set while a flat view's walk is still collecting: the entries
        /// are what it has found so far.
        var flatProgress: FlatProgress? = nil
        /// The walk was stopped before the end: the entries are not all.
        var flatStopped: Bool? = nil
        /// Folders the walk could not read.
        var flatUnreadableFolders: [String]? = nil
        var entries: [FileEntry]
    }

    struct FlatProgress: Codable, Sendable {
        var found: Int
        var foldersRead: Int
        /// The folder being read now.
        var current: String
    }

    /// What `show_flat_view` did.
    struct FlatViewResult: Codable, Sendable {
        var windowId: String
        var side: String
        var directory: String
        var expression: String
        /// Parts that parse but cannot be what was meant -- worth fixing.
        var warnings: [String]
        /// The walk is still going -- almost always, as the call does not
        /// wait for it. `get_pane` says when it is done.
        var collecting: Bool
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

    /// `propose_file_operations`' immediate reply -- the call returns as
    /// soon as the review window is open, not once the person has answered
    /// it, since nothing says how long that takes.
    struct ProposedBatch: Codable, Sendable {
        var batchId: String
    }

    /// One program the person ran with Run ▸, as `list_runs` reports it.
    struct RunSummary: Codable, Sendable {
        /// 1 is the most recent run, 2 the one before, and so on.
        var index: Int
        var runId: String
        var commandLine: String
        var program: String
        var arguments: String
        var directory: String
        /// running, finished, failed or stopped.
        var state: String
        var exitCode: Int32?
        var startedAt: String
        var realSeconds: Double
        /// The program's and its children's CPU time, as `time` reports it;
        /// absent while it runs.
        var userSeconds: Double?
        var systemSeconds: Double?
        /// "real 1m12.403s  user 0m45.201s  sys 0m8.102s".
        var timing: String
        /// Its tab is open in the Runs window.
        var tabOpen: Bool
        /// Its tab was the one in front most recently: "this run", "the open one".
        var focused: Bool
        /// The Diptych process that started it, and whether that is the one
        /// running now -- as opposed to one before a restart.
        var diptychPid: Int32?
        var thisSession: Bool
    }

    /// The running Diptych, from `get_diptych_info`.
    struct DiptychInfo: Codable, Sendable {
        var pid: Int32
        var startedAt: String
        var version: String
        var build: String
        var appPath: String
        var debugBuild: Bool
        var macOS: String
        var mcpPort: Int
        /// Runs started by this process.
        var runsThisSession: Int
        /// All runs kept, from this and earlier sessions.
        var runsKept: Int
    }

    struct RunList: Codable, Sendable {
        var runs: [RunSummary]
        /// How many runs are kept in all.
        var total: Int
    }

    struct RunOutput: Codable, Sendable {
        var run: RunSummary
        /// What it printed, as plain text: the terminal's colours are not in it.
        var output: String
        var totalLines: Int
        var returnedLines: Int
        /// Only the last `returnedLines` of `totalLines` are in `output`.
        var truncated: Bool
    }

    struct BatchRowStatus: Codable, Sendable {
        var kind: String
        var description: String
        var included: Bool
        var problems: [String]
        /// What happened to this row, once `status` is past "reviewing" --
        /// nil while still being looked at.
        var result: String?
        /// Whether that was a failure (or a skip because a row it depended
        /// on failed) -- nil until the row has run. `result` is the system's
        /// own wording and not something to parse for this.
        var failed: Bool?
    }

    /// `get_batch_status`'s answer: where a proposed batch stands, and once
    /// it has run, what happened to each row.
    struct BatchStatus: Codable, Sendable {
        var batchId: String
        var status: String
        var rows: [BatchRowStatus]
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
