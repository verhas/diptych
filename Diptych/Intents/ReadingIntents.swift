import AppIntents
import Foundation

// Intents that only read -- what MCP's get_* and list_* tools answer, for
// Siri to say and a shortcut to use. Each answers in words for Siri, and with
// a value for a shortcut: files where there are files, otherwise the same
// JSON an agent gets.

struct GetDiptychInfoIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Diptych Info"
    static let description = IntentDescription("""
        The running Diptych: its version and build, when it started, and how many runs \
        it keeps. As JSON, with the same fields an agent gets over MCP.
        """)

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try IntentGate.admit("Get Diptych Info")
        let info = DiptychCommands.diptychInfo()
        let said = "Diptych \(info.version) (\(info.build)), running since "
            + "\(info.startedAt.prefix(16).replacingOccurrences(of: "T", with: " "))."
        return .result(value: IntentText.json(info), dialog: "\(said)")
    }
}

struct ListWindowsIntent: AppIntent {
    static let title: LocalizedStringResource = "List Diptych Windows"
    static let description = IntentDescription("""
        Every open Diptych window: the two-pane windows, each with the folders its \
        panes show and which is active, and any other window -- Info, Compare, Text \
        Edit and the rest. As JSON.
        """)

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try IntentGate.admit("List Windows")
        let list = DiptychData.WindowList(windows: DiptychCommands.listWindows(),
                                          toolWindows: DiptychCommands.listToolWindows())
        let folders = list.windows.map {
            $0.singlePane
                ? IntentText.tilde($0.activeSide == "left" ? $0.leftDirectory : $0.rightDirectory)
                : IntentText.tilde($0.leftDirectory) + " and " + IntentText.tilde($0.rightDirectory)
        }
        var said = IntentText.count(list.windows.count, "window")
        if !folders.isEmpty { said += ": " + folders.joined(separator: "; ") }
        if !list.toolWindows.isEmpty {
            said += ", and " + IntentText.count(list.toolWindows.count, "other window")
        }
        return .result(value: IntentText.json(list), dialog: "\(said).")
    }
}

struct GetPaneContentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Files in Diptych Pane"
    static let description = IntentDescription("""
        The files a Diptych pane lists -- in a flat view, everything it found -- as \
        files a shortcut can pass on. Files on a server are left out: there they are \
        only addresses.
        """)

    @Parameter(title: "Pane", default: .active)
    var pane: PaneOption

    static var parameterSummary: some ParameterSummary {
        Summary("Get the files in the \(\.$pane) of Diptych")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> & ProvidesDialog {
        try IntentGate.admit("Get Files in Pane", pane.rawValue)
        guard let snapshot = DiptychCommands.pane(windowId: nil, side: pane.rawValue)
        else { throw DiptychIntentError.noWindow }
        var said = "The \(snapshot.side) pane shows \(IntentText.tilde(snapshot.directory)): "
            + IntentText.count(snapshot.entries.count, "item")
        if let expression = snapshot.flatExpression {
            said += " in a flat view" + (expression.isEmpty ? "" : " of \u{201C}\(expression)\u{201D}")
            if snapshot.flatProgress != nil { said += ", still looking" }
        }
        return .result(value: IntentText.files(snapshot.entries), dialog: "\(said).")
    }
}

struct GetPaneFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Folder Shown in Diptych"
    static let description = IntentDescription("""
        The folder a Diptych pane shows.
        """)

    @Parameter(title: "Pane", default: .active)
    var pane: PaneOption

    static var parameterSummary: some ParameterSummary {
        Summary("Get the folder the \(\.$pane) of Diptych shows")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile?> & ProvidesDialog {
        try IntentGate.admit("Get Folder Shown", pane.rawValue)
        guard let snapshot = DiptychCommands.pane(windowId: nil, side: pane.rawValue)
        else { throw DiptychIntentError.noWindow }
        let folder = snapshot.directory.hasPrefix("/")
            ? IntentFile(fileURL: URL(fileURLWithPath: snapshot.directory, isDirectory: true))
            : nil
        let said = "The \(snapshot.side) pane shows \(IntentText.tilde(snapshot.directory))."
        return .result(value: folder, dialog: "\(said)")
    }
}

struct GetSelectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Files Selected in Diptych"
    static let description = IntentDescription("""
        The files selected in a Diptych pane, as files a shortcut can pass on.
        """)

    @Parameter(title: "Pane", default: .active)
    var pane: PaneOption

    static var parameterSummary: some ParameterSummary {
        Summary("Get the files selected in the \(\.$pane) of Diptych")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> & ProvidesDialog {
        try IntentGate.admit("Get Selection", pane.rawValue)
        guard let snapshot = DiptychCommands.selection(windowId: nil, side: pane.rawValue)
        else { throw DiptychIntentError.noWindow }
        let names = snapshot.entries.map(\.name)
        let said: String
        switch names.count {
        case 0: said = "Nothing is selected in the \(snapshot.side) pane."
        case 1...3: said = "Selected: " + names.joined(separator: ", ") + "."
        default: said = IntentText.count(names.count, "item") + " are selected, beginning with "
            + names.prefix(3).joined(separator: ", ") + "."
        }
        return .result(value: IntentText.files(snapshot.entries), dialog: "\(said)")
    }
}

struct GetFileComparisonIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Diptych File Comparison"
    static let description = IntentDescription("""
        What the frontmost Compare window compares: the two files, whether it compares \
        bytes, and whether a side has edits not yet saved. As JSON. Not the \
        differences themselves.
        """)

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try IntentGate.admit("Get File Comparison")
        guard let snapshot = DiptychCommands.textDiff(windowNumber: nil)
        else { throw DiptychIntentError.noComparison("Compare") }
        var said = "Comparing \(IntentText.tilde(snapshot.leftPath)) with "
            + "\(IntentText.tilde(snapshot.rightPath))"
        if snapshot.hasUnsavedEdits { said += "; there are edits not yet saved" }
        return .result(value: IntentText.json(snapshot), dialog: "\(said).")
    }
}

struct GetFolderComparisonIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Diptych Folder Comparison"
    static let description = IntentDescription("""
        What the frontmost Compare Folders window compares: the two folders, the \
        options its results were made with, and the renames Diptych found by content. \
        As JSON.
        """)

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try IntentGate.admit("Get Folder Comparison")
        guard let snapshot = DiptychCommands.directoryDiff(windowNumber: nil)
        else { throw DiptychIntentError.noComparison("Compare Folders") }
        var said = "Comparing \(IntentText.tilde(snapshot.leftPath)) with "
            + "\(IntentText.tilde(snapshot.rightPath))"
        if !snapshot.renames.isEmpty { said += ", with " + IntentText.count(snapshot.renames.count, "rename") }
        if snapshot.needsRefresh { said += "; its options have changed since it was compared" }
        return .result(value: IntentText.json(snapshot), dialog: "\(said).")
    }
}

struct ListRunsIntent: AppIntent {
    static let title: LocalizedStringResource = "List Diptych Runs"
    static let description = IntentDescription("""
        Programs run from Diptych and still kept, counted back from the most recent: 1 \
        is the last. Each with its command, state, exit code and timing. As JSON. \
        Nothing is run.
        """)

    @Parameter(title: "From", default: 1, inclusiveRange: (1, 1000))
    var from: Int

    @Parameter(title: "To", default: 10, inclusiveRange: (1, 1000))
    var to: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try IntentGate.admit("List Runs", "\(from)-\(to)")
        let list = DiptychCommands.runList(from: from, to: to)
        guard let last = list.runs.first else {
            return .result(value: IntentText.json(list), dialog: "Diptych keeps no runs.")
        }
        let said = "\(IntentText.count(list.total, "run")) kept. The most recent, "
            + "\u{201C}\(last.commandLine)\u{201D}, \(Self.state(last))."
        return .result(value: IntentText.json(list), dialog: "\(said)")
    }

    static func state(_ run: DiptychData.RunSummary) -> String {
        switch run.state {
        case "running": "is still running"
        case "finished": "finished"
        case "failed": "failed" + (run.exitCode.map { " with exit code \($0)" } ?? "")
        default: run.state
        }
    }
}

struct GetRunOutputIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Diptych Run Output"
    static let description = IntentDescription("""
        What a run printed, as plain text -- by default the most recent run's last 400 \
        lines, where an error usually is.
        """)

    @Parameter(title: "Run", description: "Counting back: 1 is the most recent.",
               default: 1, inclusiveRange: (1, 1000))
    var run: Int

    @Parameter(title: "Lines from the End", default: 400, inclusiveRange: (1, 5000))
    var lines: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try IntentGate.admit("Get Run Output", "run \(run)")
        guard let record = DiptychCommands.runList(from: run, to: run).runs.first,
              let id = UUID(uuidString: record.runId),
              let output = DiptychCommands.runOutput(runId: id, tailLines: lines)
        else { throw DiptychIntentError.failed("Diptych keeps no run \(run).") }
        let lastLine = output.output.split(separator: "\n").last.map(String.init) ?? ""
        let said = "\u{201C}\(record.commandLine)\u{201D} \(ListRunsIntent.state(record))."
            + (lastLine.isEmpty ? "" : " Its last line: \(lastLine)")
        return .result(value: output.output, dialog: "\(said)")
    }
}

struct GetBatchStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Diptych Batch Status"
    static let description = IntentDescription("""
        Where a batch of proposed file operations stands -- reviewing, executing, \
        finished or cancelled -- and, once run, what happened to each. As JSON.
        """)

    @Parameter(title: "Batch", description: "The id Propose File Operations gave.")
    var batch: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try IntentGate.admit("Get Batch Status", batch)
        guard let id = UUID(uuidString: batch.trimmingCharacters(in: .whitespacesAndNewlines)),
              let status = DiptychCommands.batchStatus(batchId: id)
        else { throw DiptychIntentError.failed("Diptych has no such batch.") }
        let failed = status.rows.filter { $0.failed == true }.count
        var said = "The batch is \(status.status)"
        if failed > 0 { said += "; " + IntentText.count(failed, "operation") + " failed" }
        return .result(value: IntentText.json(status), dialog: "\(said).")
    }
}

struct ListSettingsIntent: AppIntent {
    static let title: LocalizedStringResource = "List Diptych Settings"
    static let description = IntentDescription("""
        Every setting Siri and Shortcuts may read or change -- the same list an agent \
        has over MCP -- each with its key, what it does, the values it takes and its \
        value now. As JSON.
        """)

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try IntentGate.admit("List Settings")
        let list = DiptychSettings.items.map {
            SettingText(key: $0.key, kind: $0.kind, description: $0.description,
                        allowedValues: $0.allowedValues, value: SettingText.text($0.get()))
        }
        let said = IntentText.count(list.count, "setting") + " can be changed."
        return .result(value: IntentText.json(list), dialog: "\(said)")
    }

    struct SettingText: Encodable {
        let key: String
        let kind: String
        let description: String
        let allowedValues: [String]?
        let value: String

        static func text(_ value: DiptychSettings.Value) -> String {
            switch value {
            case .bool(let on): on ? "true" : "false"
            case .string(let text): text
            }
        }
    }
}
