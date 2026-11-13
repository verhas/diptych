import Foundation
import AppKit

/// What can be asked of Diptych from outside it -- by an agent over MCP, by
/// Siri or a shortcut through App Intents -- in one place, so every way in
/// does the same thing by the same rules. Each adapter only translates: its
/// own arguments in, `DiptychData` out.
///
/// Reads build a value from whatever `AppModel` holds now, nothing kept.
/// What changes anything changes only what is on screen -- which folder a
/// pane shows, what is selected, which windows are open. Files themselves
/// are never changed from here: `proposeFileOperations` opens a window for
/// the person to review and run, or not.
@MainActor
enum DiptychCommands {

    static func listWindows() -> [DiptychData.WindowSummary] {
        KeyRouter.shared.allModels.map { model in
            DiptychData.WindowSummary(
                windowId: model.id.uuidString,
                windowNumber: model.window?.windowNumber ?? 0,
                activeSide: model.activeSide == .left ? "left" : "right",
                leftDirectory: RemoteBrowsing.reportedPath(model.left.directory),
                rightDirectory: RemoteBrowsing.reportedPath(model.right.directory),
                singlePane: model.isSinglePane)
        }
    }

    /// Every open window that isn't a two-pane browser window -- Get Info,
    /// Compare, Bin Edit, Text Edit, Rename Many -- which `listWindows()`
    /// above has no way to see, since none of them has an `AppModel` behind
    /// them. Backed by `AppWindows` (every window Diptych owns) filtered
    /// against `KeyRouter` (the browser ones among them), with `WindowSubjects`
    /// supplying what each remaining one is actually showing.
    static func listToolWindows() -> [DiptychData.ToolWindowSummary] {
        let browserWindows = Set(KeyRouter.shared.allModels.compactMap { $0.window })
        return AppWindows.shared.live
            .filter { !browserWindows.contains($0) }
            .compactMap { window in
                guard let subject = WindowSubjects.shared.subject(for: window) else { return nil }
                return DiptychData.ToolWindowSummary(
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

    /// The EXIF editor on explicit paths, which may be in different folders.
    static func openExifEditor(windowId: String?, paths: [String]) -> OpenResult {
        guard let model = resolveModel(windowId: windowId) else { return .windowNotFound }
        if let error = model.openExifEditor(on: paths) { return .failed(error) }
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

    static func pane(windowId: String?, side: String?) -> DiptychData.PaneSnapshot? {
        guard let model = resolveModel(windowId: windowId) else { return nil }
        let (pane, resolvedSide) = resolvePane(model: model, side: side)
        return DiptychData.PaneSnapshot(
            windowId: model.id.uuidString,
            side: resolvedSide,
            directory: RemoteBrowsing.reportedPath(pane.directory),
            flatExpression: pane.flat?.expression,
            flatStale: pane.isFlat ? pane.flatStale : nil,
            flatProgress: pane.flatProgress.map {
                DiptychData.FlatProgress(found: $0.found, foldersRead: $0.walk.folders,
                                       current: $0.walk.current.path)
            },
            flatStopped: pane.isFlat ? pane.flatStopped : nil,
            flatUnreadableFolders: pane.isFlat && !pane.flatUnreadable.isEmpty
                ? pane.flatUnreadable.map(\.path) : nil,
            entries: pane.rows.filter { !$0.isParent }.map(DiptychData.FileEntry.init))
    }

    enum FlatViewStart {
        case noWindow
        case notAFolder(String)
        case problem(FlatQuery.Problem)
        case left(side: String)
        case started(PaneModel, windowId: String, side: String, warnings: [String])
    }

    /// Puts a pane into a flat view of `directory` -- its own folder when
    /// nil -- filtered by `expression`, and starts the walk; or, with `off`,
    /// back to the folder.
    static func showFlatView(windowId: String?, side: String?, directory: String?,
                             expression: String, off: Bool) -> FlatViewStart {
        guard let model = resolveModel(windowId: windowId) else { return .noWindow }
        let (pane, resolvedSide) = resolvePane(model: model, side: side)
        if off {
            if pane.isFlat { pane.toggleFlat() }
            model.persist()
            return .left(side: resolvedSide)
        }
        // A flat view walks the folders on this Mac; a server's folders are not
        // walked here, so one named by its address is refused as not a folder.
        if let directory, directory.lowercased().hasPrefix("sftp://") {
            return .notAFolder(directory)
        }
        let root = directory.map { URL(fileURLWithPath: $0) }
            ?? pane.flat?.root ?? pane.directory
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder),
              isFolder.boolValue else { return .notAFolder(root.path) }
        let query: FlatQuery
        switch FlatQuery.parse(expression) {
        case .failure(let problem): return .problem(problem)
        case .success(let parsed): query = parsed
        }
        pane.showFlat(of: root.standardizedFileURL, expression: expression)
        model.persist()
        return .started(pane, windowId: model.id.uuidString, side: resolvedSide,
                        warnings: query.warnings.map(\.message))
    }

    static func selection(windowId: String?, side: String?) -> DiptychData.SelectionSnapshot? {
        guard let model = resolveModel(windowId: windowId) else { return nil }
        let (pane, resolvedSide) = resolvePane(model: model, side: side)
        return DiptychData.SelectionSnapshot(
            windowId: model.id.uuidString,
            side: resolvedSide,
            entries: pane.selectedItems.map(DiptychData.FileEntry.init))
    }

    /// `windowNumber` unset resolves to the frontmost open Compare (text
    /// diff) window, same resolution order as everything else here.
    static func textDiff(windowNumber: Int?) -> DiptychData.TextDiffSnapshot? {
        guard let (window, subject) = resolveToolWindow(windowNumber: windowNumber, kind: "textDiff"),
              let document = subject.model as? DiffDocument
        else { return nil }
        return DiptychData.TextDiffSnapshot(
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
    static func directoryDiff(windowNumber: Int?) -> DiptychData.DirectoryDiffSnapshot? {
        guard let (window, subject) = resolveToolWindow(windowNumber: windowNumber, kind: "directoryDiff"),
              let model = subject.model as? DirectoryDiffModel
        else { return nil }
        let applied = model.appliedOptions
        let renames = model.pairs.filter(\.isRename).compactMap { pair in
            (pair.left?.relativePath).flatMap { from in
                (pair.right?.relativePath).map { to in
                    DiptychData.DirectoryDiffRename(from: from, to: to)
                }
            }
        }
        return DiptychData.DirectoryDiffSnapshot(
            windowNumber: window.windowNumber,
            leftPath: model.left.path,
            rightPath: model.right.path,
            options: DiptychData.DirectoryDiffOptions(
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

    // MARK: - What a pane shows

    enum ShowFolderResult { case noWindow, notAFolder(String), shown(side: String) }

    /// Points a pane at a folder, as typing its path in the path bar would.
    /// A flat view is left first: it is a view of one folder, not a place.
    static func showFolder(windowId: String?, side: String?, path: String) -> ShowFolderResult {
        guard let model = resolveModel(windowId: windowId) else { return .noWindow }
        let (pane, resolvedSide) = resolvePane(model: model, side: side)
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder),
              isFolder.boolValue else { return .notAFolder(url.path) }
        if pane.isFlat { pane.toggleFlat() }
        pane.navigate(to: url)
        model.persist()
        return .shown(side: resolvedSide)
    }

    /// The three ways a pane shows its folder, by the names the outside uses.
    enum PaneView: String, CaseIterable, Sendable { case icons, placedIcons, list }

    /// Shows a pane as icons in name order, icons where they were placed, or
    /// a list -- that pane only.
    static func setPaneView(windowId: String?, side: String?, view: PaneView) -> String? {
        guard let model = resolveModel(windowId: windowId) else { return nil }
        let (pane, resolvedSide) = resolvePane(model: model, side: side)
        switch view {
        case .icons:
            pane.iconArrangement = .byName
            pane.viewStyle = .icons
        case .placedIcons:
            pane.iconArrangement = .finder
            pane.viewStyle = .icons
        case .list:
            pane.viewStyle = .list
        }
        return resolvedSide
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

    /// Operations written as JSON -- an array of objects with the same fields
    /// `propose_file_operations` takes -- for a way in that has no structured
    /// arguments of its own, such as a shortcut. Nil, with why, when it is
    /// not that.
    static func operations(fromJSON text: String) -> Result<[RawOperation], OperationsProblem> {
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return .failure(OperationsProblem(message: "Not a JSON array of operation objects.")) }
        guard !array.isEmpty else { return .failure(OperationsProblem(message: "No operations.")) }
        return .success(array.map { object in
            RawOperation(op: object["op"] as? String ?? "",
                         source: object["source"] as? String,
                         target: object["target"] as? String,
                         linkTarget: object["linkTarget"] as? String,
                         reason: object["reason"] as? String,
                         name: object["name"] as? String,
                         value: object["value"] as? String,
                         encoding: object["encoding"] as? String,
                         tags: object["tags"] as? [String])
        })
    }

    struct OperationsProblem: Error { let message: String }

    /// Builds a `BatchOperationsModel` from the call's raw operations,
    /// registers it, and opens the review window -- the round-trip
    /// counterpart to nothing in the GUI, since a batch only ever exists
    /// because an agent proposed it.
    static func proposeFileOperations(
        windowId: String?, operations: [RawOperation], from origin: Journal.Origin = .agent
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
        batch.origin = origin
        BatchOperationsStore.shared.register(batch)
        model.openBatchOperationsWindow?(batch.batchId)
        return .proposed(batch.batchId)
    }

    // MARK: - Journal

    /// A day, `2026-11-01`, or a moment, `2026-11-01T14:30` with or without
    /// seconds and a zone; nil for anything else. A day alone starts at
    /// local midnight.
    static func journalDate(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
                       "yyyy-MM", "yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Entries in the journal, newest first. Read-only: nothing here can
    /// write to the journal or delete from it.
    static func searchJournal(text: String?, from: Date?, to: Date?, kind: String?,
                              category: String? = nil, origin: String?, folder: String?, limit: Int?,
                              withFiles: Bool) -> DiptychData.JournalSearch {
        let limit = min(max(limit ?? 50, 1), 500)
        var query = Journal.Query()
        query.text = text ?? ""
        query.from = from
        query.to = to
        query.kinds = kind.map { [$0] } ?? []
        query.categories = category.flatMap { Journal.Category(rawValue: $0.lowercased()) }.map { [$0] } ?? []
        query.origins = origin.flatMap { Journal.Origin(rawValue: $0.lowercased()) }.map { [$0] } ?? []
        query.folder = folder.map { ($0 as NSString).expandingTildeInPath }
        query.limit = limit + 1
        let found = Journal.shared.search(query)
        return DiptychData.JournalSearch(
            entries: found.prefix(limit).map { entry in
                DiptychData.JournalEntry(
                    id: entry.id, time: entry.time.formatted(.iso8601), kind: entry.kind,
                    category: entry.category.rawValue,
                    origin: entry.origin.rawValue, told: entry.told, folder: entry.folder,
                    count: entry.count, outcome: entry.outcome,
                    files: withFiles
                        ? Journal.shared.files(of: entry.id).prefix(100).map {
                            DiptychData.JournalFile(before: $0.before, after: $0.after)
                        }
                        : nil)
            },
            truncated: found.count > limit,
            journalEnabled: ConfigStore.shared.configuration.journalEnabled)
    }

    static func journalStats(from: Date?, to: Date?) -> DiptychData.JournalStats {
        let stats = Journal.shared.stats(from: from, to: to)
        func counts(_ list: [Journal.Stats.Count]) -> [DiptychData.JournalCount] {
            list.map { DiptychData.JournalCount(name: $0.name, entries: $0.entries, files: $0.files) }
        }
        return DiptychData.JournalStats(
            entries: stats.entries, files: stats.files,
            first: stats.first?.formatted(.iso8601), last: stats.last?.formatted(.iso8601),
            byKind: counts(stats.byKind), byCategory: counts(stats.byCategory), byOrigin: counts(stats.byOrigin),
            byDay: counts(stats.byDay), busiestFolders: counts(stats.folders),
            journalEnabled: ConfigStore.shared.configuration.journalEnabled,
            keptDays: ConfigStore.shared.configuration.journalKeepDays)
    }

    // MARK: - Runs

    /// A run as MCP reports it, from its record -- with what only the live run
    /// knows, while it is still open or running, laid over it.
    static func runSummary(_ record: RunLog.Record, index: Int) -> DiptychData.RunSummary {
        let live = CommandRuns.shared.run(record.id)
        let started = record.startedAt
        let real = live?.realTime
            ?? (record.endedAt ?? Date()).timeIntervalSince(started)
        return DiptychData.RunSummary(
            index: index, runId: record.id.uuidString, commandLine: record.commandLine,
            program: record.program, arguments: record.arguments, directory: record.directory,
            state: live?.state ?? record.state, exitCode: live?.exitCode ?? record.exitCode,
            startedAt: started.formatted(.iso8601),
            realSeconds: (real * 1000).rounded() / 1000,
            userSeconds: live?.cpu?.user ?? record.userSeconds,
            systemSeconds: live?.cpu?.system ?? record.systemSeconds,
            timing: live?.timingLine ?? record.timing ?? "real " + CommandRun.formatted(real),
            tabOpen: live?.windowIsOpen ?? false,
            focused: CommandRuns.shared.focused == record.id,
            diptychPid: record.diptychPID, thisSession: record.isThisSession)
    }

    static func diptychInfo() -> DiptychData.DiptychInfo {
        let records = RunLog.shared.records
        return DiptychData.DiptychInfo(
            pid: DiptychProcess.pid,
            startedAt: DiptychProcess.startedAt.formatted(.iso8601),
            version: DiptychProcess.version, build: DiptychProcess.build,
            appPath: Bundle.main.bundlePath, debugBuild: DiptychProcess.isDebugBuild,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            mcpPort: ConfigStore.shared.configuration.mcpServerPort,
            runsThisSession: records.filter(\.isThisSession).count,
            runsKept: records.count)
    }

    /// Runs `from` ... `to`, counting back from the most recent, which is 1.
    static func runList(from: Int?, to: Int?) -> DiptychData.RunList {
        let all = RunLog.shared.newestFirst
        let first = max(1, from ?? 1)
        let last = min(max(first, to ?? first + 9), first + 99)
        let chosen = all.enumerated().filter { $0.offset + 1 >= first && $0.offset + 1 <= last }
        return DiptychData.RunList(
            runs: chosen.map { runSummary($0.element, index: $0.offset + 1) },
            total: all.count)
    }

    /// The last `tailLines` lines -- an error is nearly always at the end, and
    /// a long build's whole output would swamp the answer. From the live
    /// terminal while the run is open, from its saved output once it is not.
    static func runOutput(runId: UUID, tailLines: Int?) -> DiptychData.RunOutput? {
        let all = RunLog.shared.newestFirst
        guard let position = all.firstIndex(where: { $0.id == runId }) else { return nil }
        let text = CommandRuns.shared.run(runId)?.outputText
            ?? RunLog.shared.savedOutput(runId) ?? ""
        let lines = text.components(separatedBy: "\n")
        let wanted = min(max(1, tailLines ?? 400), 5000)
        let tail = Array(lines.suffix(wanted))
        return DiptychData.RunOutput(
            run: runSummary(all[position], index: position + 1),
            output: tail.joined(separator: "\n"),
            totalLines: lines.count, returnedLines: tail.count,
            truncated: tail.count < lines.count)
    }

    static func batchStatus(batchId: UUID) -> DiptychData.BatchStatus? {
        guard let model = BatchOperationsStore.shared.model(for: batchId) else { return nil }
        let statusName: String
        switch model.status {
        case .reviewing: statusName = "reviewing"
        case .executing: statusName = "executing"
        case .finished: statusName = "finished"
        case .cancelled: statusName = "cancelled"
        }
        let rows = model.rows.map { row in
            DiptychData.BatchRowStatus(kind: row.kind.rawValue, description: row.shortDescription,
                                     included: row.included, problems: row.problems,
                                     result: model.rowResults[row.id],
                                     failed: model.rowResults[row.id] == nil
                                         ? nil : model.failedRows.contains(row.id))
        }
        return DiptychData.BatchStatus(batchId: batchId.uuidString, status: statusName, rows: rows)
    }
}
