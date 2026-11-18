import AppIntents
import Foundation

// Intents that change something -- only ever what is on screen: which folder
// a pane shows, what is selected, which windows are open, a setting from the
// list an agent may change too. Files themselves are not changed from here:
// the file operations are proposed in a window, to be looked over and run,
// or not, by the person -- as an agent's are. Each brings Diptych forward, so
// what it did is in sight.

struct ShowFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Folder in Diptych"
    static let description = IntentDescription("""
        Shows a folder in a Diptych pane, as typing its path in the path bar would -- \
        leaving a flat view first if the pane is one.
        """)
    static let openAppWhenRun = true

    @Parameter(title: "Folder", supportedContentTypes: [.folder])
    var folder: IntentFile

    @Parameter(title: "Pane", default: .active)
    var pane: PaneOption

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$folder) in the \(\.$pane) of Diptych")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let path = folder.localPath else {
            throw DiptychIntentError.failed("That is not a folder on this Mac.")
        }
        try IntentGate.admit("Show Folder", path)
        switch DiptychCommands.showFolder(windowId: nil, side: pane.rawValue, path: path) {
        case .noWindow: throw DiptychIntentError.noWindow
        case .notAFolder(let path): throw DiptychIntentError.failed("Not a folder: \(path)")
        case .shown(let side):
            let said = "The \(side) pane shows \(IntentText.tilde(path))."
            return .result(dialog: "\(said)")
        }
    }
}

struct SetActivePaneIntent: AppIntent {
    static let title: LocalizedStringResource = "Make Diptych Pane Active"
    static let description = IntentDescription("""
        Gives the left or right pane of the front Diptych window the keyboard: what the \
        other commands mean by the active pane.
        """)
    static let openAppWhenRun = true

    @Parameter(title: "Pane")
    var side: SideOption

    static var parameterSummary: some ParameterSummary {
        Summary("Make the \(\.$side) of Diptych active")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try IntentGate.admit("Set Active Pane", side.rawValue)
        guard DiptychCommands.setActivePane(windowId: nil, side: side.rawValue)
        else { throw DiptychIntentError.noWindow }
        let said = "The \(side.rawValue) pane is active."
        return .result(dialog: "\(said)")
    }
}

struct SetPaneViewIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Diptych Pane View"
    static let description = IntentDescription("""
        How a pane shows its folder: as icons in name order, as icons where they were \
        placed, or as a list. That pane only.
        """)
    static let openAppWhenRun = true

    @Parameter(title: "View")
    var view: PaneViewOption

    @Parameter(title: "Pane", default: .active)
    var pane: PaneOption

    static var parameterSummary: some ParameterSummary {
        Summary("Show the \(\.$pane) of Diptych as \(\.$view)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try IntentGate.admit("Set Pane View", "\(pane.rawValue): \(view.rawValue)")
        guard let chosen = DiptychCommands.PaneView(rawValue: view.rawValue),
              let side = DiptychCommands.setPaneView(windowId: nil, side: pane.rawValue, view: chosen)
        else { throw DiptychIntentError.noWindow }
        let words = ["icons": "icons", "placedIcons": "placed icons", "list": "a list"][view.rawValue] ?? ""
        let said = "The \(side) pane shows \(words)."
        return .result(dialog: "\(said)")
    }
}

struct SelectFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Select Files in Diptych"
    static let description = IntentDescription("""
        Selects exactly these files in a Diptych pane; any the pane does not list are left \
        out. Nothing is done to them -- they are only selected.
        """)
    static let openAppWhenRun = true

    @Parameter(title: "Files", supportedContentTypes: [.item])
    var files: [IntentFile]

    @Parameter(title: "Pane", default: .active)
    var pane: PaneOption

    static var parameterSummary: some ParameterSummary {
        Summary("Select \(\.$files) in the \(\.$pane) of Diptych")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let paths = files.compactMap(\.localPath)
        try IntentGate.admit("Select Files", IntentText.count(paths.count, "path"))
        guard DiptychCommands.selectItems(windowId: nil, side: pane.rawValue, paths: paths)
        else { throw DiptychIntentError.noWindow }
        let selected = DiptychCommands.selection(windowId: nil, side: pane.rawValue)?.entries.count ?? 0
        let said = IntentText.count(selected, "item") + " selected."
        return .result(dialog: "\(said)")
    }
}

struct ShowFlatViewIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Diptych Flat View"
    static let description = IntentDescription("""
        Turns a pane into a flat view: one list of a folder and everything under it, \
        filtered by an expression such as  name = "*.jpg" and size > 10MB  -- the same \
        expressions as View > Flat View. Empty lists everything. Returns at once; a big \
        folder takes a while to walk.
        """)
    static let openAppWhenRun = true

    @Parameter(title: "Expression", default: "")
    var expression: String

    @Parameter(title: "Folder", description: "The pane's own folder when not given.",
               supportedContentTypes: [.folder])
    var folder: IntentFile?

    @Parameter(title: "Pane", default: .active)
    var pane: PaneOption

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$expression) under \(\.$folder) in the \(\.$pane) of Diptych")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try IntentGate.admit("Show Flat View", expression)
        switch DiptychCommands.showFlatView(windowId: nil, side: pane.rawValue,
                                            directory: folder?.localPath,
                                            expression: expression, off: false) {
        case .noWindow: throw DiptychIntentError.noWindow
        case .notAFolder(let path): throw DiptychIntentError.failed("Not a folder: \(path)")
        case .problem(let problem):
            throw DiptychIntentError.failed("The expression does not parse at character "
                                            + "\(problem.range.location): \(problem.message)")
        case .left: throw DiptychIntentError.noWindow
        case .started(let started, _, let side, let warnings):
            var said = "The \(side) pane is collecting everything under "
                + IntentText.tilde(started.directory.path)
                + (expression.isEmpty ? "" : " that matches \u{201C}\(expression)\u{201D}") + "."
            if let first = warnings.first { said += " Note: \(first)" }
            return .result(dialog: "\(said)")
        }
    }
}

struct LeaveFlatViewIntent: AppIntent {
    static let title: LocalizedStringResource = "Leave Diptych Flat View"
    static let description = IntentDescription("Shows a pane's folder again instead of its flat view.")
    static let openAppWhenRun = true

    @Parameter(title: "Pane", default: .active)
    var pane: PaneOption

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try IntentGate.admit("Leave Flat View", pane.rawValue)
        guard case .left(let side) = DiptychCommands.showFlatView(
            windowId: nil, side: pane.rawValue, directory: nil, expression: "", off: true)
        else { throw DiptychIntentError.noWindow }
        let said = "The \(side) pane shows its folder again."
        return .result(dialog: "\(said)")
    }
}

struct OpenComparisonIntent: AppIntent {
    static let title: LocalizedStringResource = "Compare in Diptych"
    static let description = IntentDescription("""
        Opens a Compare window on two files, or a Compare Folders window on two folders -- \
        both must be the same kind. You look at the differences in the window.
        """)
    static let openAppWhenRun = true

    @Parameter(title: "Left", supportedContentTypes: [.item, .folder])
    var left: IntentFile

    @Parameter(title: "Right", supportedContentTypes: [.item, .folder])
    var right: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Compare \(\.$left) with \(\.$right) in Diptych")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let leftPath = left.localPath, let rightPath = right.localPath else {
            throw DiptychIntentError.failed("Both have to be files or folders on this Mac.")
        }
        try IntentGate.admit("Compare", "\(leftPath) | \(rightPath)")
        switch DiptychCommands.openDiff(windowId: nil, left: leftPath, right: rightPath,
                                        directoryOptions: nil, textOptions: nil) {
        case .windowNotFound: throw DiptychIntentError.noWindow
        case .failed(let message): throw DiptychIntentError.failed(message)
        case .opened: return .result(dialog: "Opened the comparison.")
        }
    }
}

struct OpenInfoIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Info in Diptych"
    static let description = IntentDescription("""
        Opens Diptych's Info window on a file or folder: general facts, owner and \
        permissions, tags, extended attributes, and what has it open.
        """)
    static let openAppWhenRun = true

    @Parameter(title: "File", supportedContentTypes: [.item, .folder])
    var file: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Show Diptych's Info window for \(\.$file)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let path = file.localPath else {
            throw DiptychIntentError.failed("That is not a file on this Mac.")
        }
        try IntentGate.admit("Show Info", path)
        switch DiptychCommands.openInfoWindow(windowId: nil, path: path) {
        case .windowNotFound: throw DiptychIntentError.noWindow
        case .failed(let message): throw DiptychIntentError.failed(message)
        case .opened: return .result(dialog: "Opened the Info window.")
        }
    }
}

struct OpenExifEditorIntent: AppIntent {
    static let title: LocalizedStringResource = "Edit EXIF in Diptych"
    static let description = IntentDescription("""
        Opens the EXIF editor on JPEG and HEIC images. Nothing is written until you save \
        in the window, and a save can be undone.
        """)
    static let openAppWhenRun = true

    @Parameter(title: "Images", supportedContentTypes: [.jpeg, .heic])
    var images: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Edit the EXIF of \(\.$images) in Diptych")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let paths = images.compactMap(\.localPath)
        guard !paths.isEmpty else { throw DiptychIntentError.failed("No images on this Mac were given.") }
        try IntentGate.admit("Edit EXIF", IntentText.count(paths.count, "image"))
        switch DiptychCommands.openExifEditor(windowId: nil, paths: paths) {
        case .windowNotFound: throw DiptychIntentError.noWindow
        case .failed(let message): throw DiptychIntentError.failed(message)
        case .opened: return .result(dialog: "Opened the EXIF editor.")
        }
    }
}

struct CloseWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Close Diptych Window"
    static let description = IntentDescription("""
        Closes a Diptych window, by the number List Diptych Windows gives it. Asks first; \
        and a window with unsaved changes asks again, as Command-W would.
        """)

    @Parameter(title: "Window Number")
    var windowNumber: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try IntentGate.admit("Close Window", "\(windowNumber)")
        try await requestConfirmation(dialog: "Close Diptych window \(windowNumber)?")
        guard DiptychCommands.closeWindow(windowNumber: windowNumber)
        else { throw DiptychIntentError.failed("No Diptych window has number \(windowNumber).") }
        return .result(dialog: "Asked the window to close.")
    }
}

/// The keys of the settings that may be changed, to choose from.
struct SettingKeyOptions: DynamicOptionsProvider {
    func results() async throws -> [String] {
        await MainActor.run { DiptychSettings.items.map(\.key) }
    }
}

struct ChangeSettingIntent: AppIntent {
    static let title: LocalizedStringResource = "Change Diptych Setting"
    static let description = IntentDescription("""
        Changes one of the settings List Diptych Settings gives -- the same list an agent may \
        change. On or off: true or false; a choice: one of its values. Asks first.
        """)

    @Parameter(title: "Setting", optionsProvider: SettingKeyOptions())
    var key: String

    @Parameter(title: "Value")
    var value: String

    static var parameterSummary: some ParameterSummary {
        Summary("Set Diptych's \(\.$key) to \(\.$value)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try IntentGate.admit("Change Setting", "\(key)=\(value)")
        guard let item = DiptychSettings.item(for: key) else {
            throw DiptychIntentError.failed("Diptych has no setting \(key).")
        }
        let question = "Set Diptych's \(key) to \(value)?"
        try await requestConfirmation(dialog: "\(question)")
        if let problem = item.set(.string(value)) { throw DiptychIntentError.failed(problem) }
        let said = "\(key) is now \(value)."
        return .result(dialog: "\(said)")
    }
}

// MARK: - File operations, proposed

struct ProposeFileOperationsIntent: AppIntent {
    static let title: LocalizedStringResource = "Propose Diptych File Operations"
    static let description = IntentDescription("""
        Proposes file operations for you to look over and run in a window -- nothing is done \
        until you do. Written as JSON: an array of objects with the fields an agent uses over \
        MCP, such as  [{"op": "move", "source": "/path/a", "target": "/path/b"}]. Gives the \
        batch's id, for Get Diptych Batch Status.
        """)
    static let openAppWhenRun = true

    @Parameter(title: "Operations (JSON)", inputOptions: String.IntentInputOptions(multiline: true))
    var operations: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try IntentGate.admit("Propose File Operations")
        switch DiptychCommands.operations(fromJSON: operations) {
        case .failure(let problem): throw DiptychIntentError.failed(problem.message)
        case .success(let raw): return try ProposeFileOperationIntent.propose(raw)
        }
    }
}

enum FileOperationOption: String, AppEnum {
    case copy, move, trash, deletePermanently, rename, createFolder

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Operation"
    static let caseDisplayRepresentations: [FileOperationOption: DisplayRepresentation] = [
        .copy: "Copy",
        .move: "Move",
        .trash: "Move to Trash",
        .deletePermanently: "Delete Permanently",
        .rename: "Rename",
        .createFolder: "New Folder",
    ]
}

struct ProposeFileOperationIntent: AppIntent {
    static let title: LocalizedStringResource = "Propose Diptych File Operation"
    static let description = IntentDescription("""
        Proposes copying, moving, trashing, deleting or renaming files, or making a folder, \
        for you to look over and run in a window -- nothing is done until you do, and \
        anything written over or deleted for good asks again. Gives the batch's id.
        """)
    static let openAppWhenRun = true

    @Parameter(title: "Operation")
    var operation: FileOperationOption

    @Parameter(title: "Files", supportedContentTypes: [.item, .folder])
    var files: [IntentFile]?

    @Parameter(title: "Destination", description: "Where to copy or move to, or make the folder in.",
               supportedContentTypes: [.folder])
    var destination: IntentFile?

    @Parameter(title: "Name", description: "The new name, to rename or for a new folder.")
    var name: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Propose \(\.$operation) of \(\.$files)") {
            \.$destination
            \.$name
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let sources = (files ?? []).compactMap(\.localPath)
        let target = destination?.localPath
        let reason = "Asked for with Siri or Shortcuts"
        var raw: [DiptychCommands.RawOperation] = []
        switch operation {
        case .copy, .move:
            guard let target, !sources.isEmpty else {
                throw DiptychIntentError.failed("Copying and moving need files and a destination folder.")
            }
            raw = sources.map {
                DiptychCommands.RawOperation(
                    op: operation == .copy ? "copy" : "move", source: $0,
                    target: (target as NSString).appendingPathComponent(($0 as NSString).lastPathComponent),
                    linkTarget: nil, reason: reason)
            }
        case .trash, .deletePermanently:
            guard !sources.isEmpty else { throw DiptychIntentError.failed("No files on this Mac were given.") }
            raw = sources.map {
                DiptychCommands.RawOperation(op: operation == .trash ? "trash" : "delete_permanent",
                                             source: $0, target: nil, linkTarget: nil, reason: reason)
            }
        case .rename:
            guard sources.count == 1, let name, !name.isEmpty else {
                throw DiptychIntentError.failed("Renaming needs exactly one file and its new name.")
            }
            raw = [DiptychCommands.RawOperation(op: "rename", source: sources[0], target: name,
                                                linkTarget: nil, reason: reason)]
        case .createFolder:
            guard let target, let name, !name.isEmpty else {
                throw DiptychIntentError.failed("A new folder needs the folder to make it in, and a name.")
            }
            raw = [DiptychCommands.RawOperation(
                op: "create_directory", source: nil,
                target: (target as NSString).appendingPathComponent(name), linkTarget: nil, reason: reason)]
        }
        try IntentGate.admit("Propose File Operation", "\(operation.rawValue): "
                             + IntentText.count(raw.count, "operation"))
        return try Self.propose(raw)
    }

    /// Opens the review window, as `propose_file_operations` does for an agent.
    @MainActor
    static func propose(_ raw: [DiptychCommands.RawOperation]) throws
        -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        switch DiptychCommands.proposeFileOperations(windowId: nil, operations: raw,
                                                       from: .shortcuts) {
        case .unknownOp(let op): throw DiptychIntentError.failed("Diptych has no operation \(op).")
        case .noWindow: throw DiptychIntentError.noWindow
        case .proposed(let id):
            let said = IntentText.count(raw.count, "operation") + " to look over in Diptych."
            return .result(value: id.uuidString, dialog: "\(said)")
        }
    }
}
