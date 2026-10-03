import Foundation
import AppKit

/// `@MainActor` glue between the MCP tool handlers (dispatched on the SDK's
/// own `Server` actor) and Diptych's live UI state. Every function here is a
/// single, self-contained read: build a DTO from whatever `AppModel`
/// currently holds, nothing kept, nothing mutated.
@MainActor
enum MCPToolSupport {

    static func listWindows() -> [MCPModels.WindowSummary] {
        KeyRouter.shared.allModels.map { model in
            MCPModels.WindowSummary(
                windowId: model.id.uuidString,
                windowNumber: model.window?.windowNumber ?? 0,
                activeSide: model.activeSide == .left ? "left" : "right",
                leftDirectory: model.left.directory.path,
                rightDirectory: model.right.directory.path)
        }
    }

    /// Every open window that isn't a two-pane browser window -- Get Info,
    /// Compare, Bin Edit, Text Edit, Rename Many -- which `listWindows()`
    /// above has no way to see, since none of them has an `AppModel` behind
    /// them. Backed by `AppWindows` (every window Diptych owns) filtered
    /// against `KeyRouter` (the browser ones among them), with `WindowSubjects`
    /// supplying what each remaining one is actually showing.
    static func listToolWindows() -> [MCPModels.ToolWindowSummary] {
        let browserWindows = Set(KeyRouter.shared.allModels.compactMap { $0.window })
        return AppWindows.shared.live
            .filter { !browserWindows.contains($0) }
            .compactMap { window in
                guard let subject = WindowSubjects.shared.subject(for: window) else { return nil }
                return MCPModels.ToolWindowSummary(
                    windowNumber: window.windowNumber, kind: subject.kind,
                    title: window.title, subject: subject.description)
            }
    }

    /// Replaces a pane's selection with exactly these paths (any not
    /// actually present in the pane are dropped, matching what clicking
    /// a Finder-dragged file that no longer exists does). Returns whether
    /// a matching window was found at all.
    static func selectItems(windowId: String?, side: String?, paths: [String]) -> Bool {
        guard let model = resolveModel(windowId: windowId) else { return false }
        let (pane, _) = resolvePane(model: model, side: side)
        let wanted = Set(paths.map { URL(fileURLWithPath: $0) })
        pane.selection = Set(pane.rows.map(\.id)).intersection(wanted)
        return true
    }

    /// Makes the given side the active pane -- keyboard focus, and what
    /// `side: "active"` resolves to on every other tool -- rather than just
    /// telling the agent which one already is.
    static func setActivePane(windowId: String?, side: String) -> Bool {
        guard let model = resolveModel(windowId: windowId) else { return false }
        model.activeSide = side == "left" ? .left : .right
        return true
    }

    /// Shared by every "open something in a window" tool: `open_diff`,
    /// `open_info_window`.
    enum OpenResult { case windowNotFound, failed(String), opened }

    /// Opens a comparison between two explicit paths in the given (or
    /// frontmost) window -- the round-trip counterpart to `get_text_diff`/
    /// `get_directory_diff`, for "compare these two folders" rather than
    /// just answering questions about one already open. `directoryOptions`/
    /// `textOptions` are `nil` when the call gave none of the matching
    /// option arguments at all -- meaning "no opinion," not "everything
    /// off" -- so a fresh window still gets the application's own defaults
    /// and an already-open one is left alone, exactly like calling with no
    /// options ever meant anything.
    static func openDiff(windowId: String?, left: String, right: String,
                         directoryOptions: DirectoryComparison.Options?,
                         textOptions: TextDiffPresetOptions.Preset?) -> OpenResult {
        guard let model = resolveModel(windowId: windowId) else { return .windowNotFound }
        if let error = model.openComparison(left: URL(fileURLWithPath: left),
                                            right: URL(fileURLWithPath: right),
                                            directoryOptions: directoryOptions,
                                            textOptions: textOptions) {
            return .failed(error)
        }
        return .opened
    }

    /// Opens the Info window for an explicit path -- the round-trip
    /// counterpart to `showInfo()` (Cmd-I), which acts on the selection.
    static func openInfoWindow(windowId: String?, path: String) -> OpenResult {
        guard let model = resolveModel(windowId: windowId) else { return .windowNotFound }
        if let error = model.openInfo(for: URL(fileURLWithPath: path)) {
            return .failed(error)
        }
        return .opened
    }

    /// `performClose`, not `close`: it runs the same "you have unsaved
    /// changes" prompt (Text Edit, Bin Edit) that Cmd-W does, rather than
    /// discarding edits an agent was never told about. Returns whether a
    /// window with this number was found at all -- not whether it actually
    /// closed, since a save prompt can still turn the close down.
    static func closeWindow(windowNumber: Int) -> Bool {
        guard let window = AppWindows.shared.live.first(where: { $0.windowNumber == windowNumber })
        else { return false }
        window.performClose(nil)
        return true
    }

    static func pane(windowId: String?, side: String?) -> MCPModels.PaneSnapshot? {
        guard let model = resolveModel(windowId: windowId) else { return nil }
        let (pane, resolvedSide) = resolvePane(model: model, side: side)
        return MCPModels.PaneSnapshot(
            windowId: model.id.uuidString,
            side: resolvedSide,
            directory: pane.directory.path,
            entries: pane.rows.filter { !$0.isParent }.map(MCPModels.FileEntry.init))
    }

    static func selection(windowId: String?, side: String?) -> MCPModels.SelectionSnapshot? {
        guard let model = resolveModel(windowId: windowId) else { return nil }
        let (pane, resolvedSide) = resolvePane(model: model, side: side)
        return MCPModels.SelectionSnapshot(
            windowId: model.id.uuidString,
            side: resolvedSide,
            entries: pane.selectedItems.map(MCPModels.FileEntry.init))
    }

    /// `windowNumber` unset resolves to the frontmost open Compare (text
    /// diff) window, same resolution order as everything else here.
    static func textDiff(windowNumber: Int?) -> MCPModels.TextDiffSnapshot? {
        guard let (window, subject) = resolveToolWindow(windowNumber: windowNumber, kind: "textDiff"),
              let document = subject.model as? DiffDocument
        else { return nil }
        return MCPModels.TextDiffSnapshot(
            windowNumber: window.windowNumber,
            leftPath: document.pair.left.path,
            rightPath: document.pair.right.path,
            isComparingBytes: document.isComparingBytes,
            editableSide: document.editable.map { $0 == .left ? "left" : "right" },
            hasUnsavedEdits: document.isDirty,
            hasSaved: document.hasSaved,
            ignoreWhitespace: document.ignoreWhitespace,
            wraps: document.wraps)
    }

    /// `windowNumber` unset resolves to the frontmost open Compare Folders
    /// window.
    static func directoryDiff(windowNumber: Int?) -> MCPModels.DirectoryDiffSnapshot? {
        guard let (window, subject) = resolveToolWindow(windowNumber: windowNumber, kind: "directoryDiff"),
              let model = subject.model as? DirectoryDiffModel
        else { return nil }
        let applied = model.appliedOptions
        let renames = model.pairs.filter(\.isRename).compactMap { pair in
            (pair.left?.relativePath).flatMap { from in
                (pair.right?.relativePath).map { to in
                    MCPModels.DirectoryDiffRename(from: from, to: to)
                }
            }
        }
        return MCPModels.DirectoryDiffSnapshot(
            windowNumber: window.windowNumber,
            leftPath: model.left.path,
            rightPath: model.right.path,
            options: MCPModels.DirectoryDiffOptions(
                compareContent: applied.compareContent,
                comparePermissions: applied.comparePermissions,
                compareAttributes: applied.compareAttributes,
                compareACL: applied.compareACL,
                compareModificationDate: applied.compareModificationDate,
                compareCreationDate: applied.compareCreationDate,
                compareOwnership: applied.compareOwnership,
                recurseHiddenDirectories: applied.recurseHiddenDirectories),
            needsRefresh: model.needsRefresh,
            renames: renames)
    }

    /// Resolution order matches `resolveModel`: an explicit window number,
    /// then the frontmost window of the right kind, then simply the first
    /// one open.
    private static func resolveToolWindow(
        windowNumber: Int?, kind: String
    ) -> (NSWindow, WindowSubjects.Subject)? {
        let candidates = AppWindows.shared.live.compactMap { window -> (NSWindow, WindowSubjects.Subject)? in
            guard let subject = WindowSubjects.shared.subject(for: window), subject.kind == kind
            else { return nil }
            return (window, subject)
        }
        if let windowNumber {
            return candidates.first { $0.0.windowNumber == windowNumber }
        }
        if let key = NSApp.keyWindow, let match = candidates.first(where: { $0.0 === key }) {
            return match
        }
        return candidates.first
    }

    /// Resolution order: an explicit id, then whichever Diptych window is
    /// currently frontmost, then simply the first open one -- so a tool call
    /// with no arguments still does something useful rather than failing
    /// whenever the terminal, not a Diptych window, happens to have focus.
    private static func resolveModel(windowId: String?) -> AppModel? {
        let models = KeyRouter.shared.allModels
        if let windowId, let uuid = UUID(uuidString: windowId) {
            return models.first { $0.id == uuid }
        }
        if let key = NSApp.keyWindow, let match = models.first(where: { $0.window === key }) {
            return match
        }
        return models.first
    }

    private static func resolvePane(model: AppModel, side: String?) -> (PaneModel, String) {
        switch side {
        case "left": return (model.left, "left")
        case "right": return (model.right, "right")
        default: return (model.active, model.activeSide == .left ? "left" : "right")
        }
    }

    // MARK: - Batch file operations

    /// One element of `propose_file_operations`' `operations` array, already
    /// pulled out of the SDK's `Value` type by the caller in `MCPServer` --
    /// this file otherwise never touches `Value` directly.
    struct RawOperation {
        let op: String
        let source: String?
        let target: String?
        let linkTarget: String?
        let reason: String?
        var name: String? = nil
        var value: String? = nil
        var encoding: String? = nil
        var tags: [String]? = nil
    }

    enum ProposeResult { case unknownOp(String), noWindow, proposed(UUID) }

    /// Builds a `BatchOperationsModel` from the call's raw operations,
    /// registers it, and opens the review window -- the round-trip
    /// counterpart to nothing in the GUI, since a batch only ever exists
    /// because an agent proposed it.
    static func proposeFileOperations(
        windowId: String?, operations: [RawOperation]
    ) -> ProposeResult {
        var rows: [BatchOperationRow] = []
        for entry in operations {
            switch BatchOperationRow.build(op: entry.op, source: entry.source, target: entry.target,
                                           linkTarget: entry.linkTarget, reason: entry.reason,
                                           name: entry.name, value: entry.value,
                                           encoding: entry.encoding, tags: entry.tags) {
            case .unknownOp(let name): return .unknownOp(name)
            case .row(let row): rows.append(row)
            }
        }
        guard let model = resolveModel(windowId: windowId) else { return .noWindow }
        let batch = BatchOperationsModel(rows: rows)
        BatchOperationsStore.shared.register(batch)
        model.openBatchOperationsWindow?(batch.batchId)
        return .proposed(batch.batchId)
    }

    static func batchStatus(batchId: UUID) -> MCPModels.BatchStatus? {
        guard let model = BatchOperationsStore.shared.model(for: batchId) else { return nil }
        let statusName: String
        switch model.status {
        case .reviewing: statusName = "reviewing"
        case .executing: statusName = "executing"
        case .finished: statusName = "finished"
        case .cancelled: statusName = "cancelled"
        }
        let rows = model.rows.map { row in
            MCPModels.BatchRowStatus(kind: row.kind.rawValue, description: row.shortDescription,
                                     included: row.included, problems: row.problems,
                                     result: model.rowResults[row.id],
                                     failed: model.rowResults[row.id] == nil
                                         ? nil : model.failedRows.contains(row.id))
        }
        return MCPModels.BatchStatus(batchId: batchId.uuidString, status: statusName, rows: rows)
    }
}
