import SwiftUI

/// `@main` marks the process entry point -- Swift's `public static void main`.
/// An `App` is a value type describing the scenes the app owns; SwiftUI creates
/// the NSApplication, the windows and the menu bar from it.
@main
struct DiptychApp: App {

    static let windowGroupID = "diptych.window"
    static let infoWindowID = "diptych.info"
    static let binaryWindowID = "diptych.binary"
    static let textWindowID = "diptych.text"
    static let renameWindowID = "diptych.rename"
    static let diffWindowID = "diptych.diff"
    static let directoryDiffWindowID = "diptych.directoryDiff"
    static let releaseNotesWindowID = "diptych.releaseNotes"
    static let mcpConsoleWindowID = "diptych.mcpConsole"
    static let batchOperationsWindowID = "diptych.batchOperations"
    static let runWindowID = "diptych.run"
    static let siblingsWindowID = "diptych.siblings"
    static let duplicatesWindowID = "diptych.duplicates"
    static let exifWindowID = "diptych.exif"
    static let videoWindowID = "diptych.video"
    static let archiveWindowID = "diptych.archive"
    static let optimizeWindowID = "diptych.optimize"
    static let recoverWindowID = "diptych.recover"
    static let versionsWindowID = "diptych.versions"
    static let diskUsageWindowID = "diptych.diskUsage"
    static let splitWindowID = "diptych.split"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup(id: DiptychApp.windowGroupID) {
            // No model here on purpose. `@State` on an App is created once for
            // the process, so a model declared at this level is shared by every
            // window and tab. ContentView owns one model per window instead.
            ContentView()
        }
        .defaultSize(width: 1100, height: 680)
        .commands {
            FileCommands()
            TextEditCommands()
        }

        // One info window per file, keyed by URL, so Cmd-I on a second file
        // opens a second window rather than replacing the first.
        WindowGroup(id: DiptychApp.infoWindowID, for: URL.self) { $url in
            if let url { InfoView(url: url) }
        }
        .defaultSize(width: 1180, height: 620)
        // Not restored at launch. macOS brings a window group back without the
        // value it was opened with, so what reappeared was an empty window
        // about nothing -- which the user then has to close.
        .restorationBehavior(.disabled)

        // One Bin Edit per file, for the same reason as the info window.
        WindowGroup(id: DiptychApp.binaryWindowID, for: URL.self) { $url in
            if let url { BinaryView(url: url) }
        }
        .defaultSize(width: 840, height: 560)
        .restorationBehavior(.disabled)

        // One Text Edit per file: asking again for the same file brings its
        // window forward rather than opening a second editor on it.
        WindowGroup(id: DiptychApp.textWindowID, for: URL.self) { $url in
            if let url { TextEditView(url: url) }
        }
        .defaultSize(width: 780, height: 620)
        .restorationBehavior(.disabled)

        // One search for a file's other names per file.
        WindowGroup(id: DiptychApp.siblingsWindowID, for: URL.self) { $url in
            if let url { SiblingsView(url: url) }
        }
        .defaultSize(width: 680, height: 380)
        .restorationBehavior(.disabled)

        // One search for duplicates per file or folder.
        WindowGroup(id: DiptychApp.duplicatesWindowID, for: URL.self) { $url in
            if let url { DuplicatesView(url: url) }
        }
        .defaultSize(width: 820, height: 560)
        .restorationBehavior(.disabled)

        // One EXIF editor per set of images: asking again for the same ones
        // brings it forward.
        WindowGroup(id: DiptychApp.exifWindowID, for: [URL].self) { $urls in
            if let urls { ExifEditorView(urls: urls) }
        }
        .defaultSize(width: 760, height: 680)
        .restorationBehavior(.disabled)

        // The same for videos.
        WindowGroup(id: DiptychApp.videoWindowID, for: [URL].self) { $urls in
            if let urls { ExifEditorView(urls: urls, kind: .videos) }
        }
        .defaultSize(width: 760, height: 680)
        .restorationBehavior(.disabled)

        // One Create Archive per selection.
        WindowGroup(id: DiptychApp.archiveWindowID, for: ArchiveRequest.self) { $request in
            if let request { CreateArchiveView(request: request) }
        }
        .defaultSize(width: 620, height: 640)
        .restorationBehavior(.disabled)

        // One Optimize File Size per selection.
        WindowGroup(id: DiptychApp.optimizeWindowID, for: OptimizeRequest.self) { $request in
            if let request { OptimizeView(request: request) }
        }
        .defaultSize(width: 1180, height: 760)
        .restorationBehavior(.disabled)

        // One Recover Password per zip.
        WindowGroup(id: DiptychApp.recoverWindowID, for: PasswordRecoveryRequest.self) { $request in
            if let request { PasswordRecoveryView(request: request) }
        }
        .defaultSize(width: 560, height: 580)
        .restorationBehavior(.disabled)

        // One Previous Versions per file.
        WindowGroup(id: DiptychApp.versionsWindowID, for: FileVersions.Request.self) { $request in
            if let request { FileVersionsView(request: request) }
        }
        .defaultSize(width: 560, height: 480)
        .restorationBehavior(.disabled)

        // One Disk Usage per folder.
        WindowGroup(id: DiptychApp.diskUsageWindowID, for: URL.self) { $url in
            if let url { DiskUsageView(url: url) }
        }
        .defaultSize(width: 900, height: 640)
        .restorationBehavior(.disabled)

        // The Split File window -- movable, so it can be slid off the file
        // list. Keyed by a job id, like the batch-operations window.
        WindowGroup(id: DiptychApp.splitWindowID, for: UUID.self) { $jobId in
            if let jobId { SplitView(jobId: jobId) }
        }
        .defaultSize(width: 460, height: 360)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        // One Rename Many per folder -- and selection, or flat view.
        WindowGroup(id: DiptychApp.renameWindowID, for: RenameManyRequest.self) { $request in
            if let request { RenameManyView(request: request) }
        }
        .defaultSize(width: 720, height: 620)
        .restorationBehavior(.disabled)

        // One comparison per pair of files, so a second Cmd-D on two other
        // files opens its own window rather than replacing the first.
        WindowGroup(id: DiptychApp.diffWindowID, for: DiffPair.self) { $pair in
            if let pair { DiffView(pair: pair) }
        }
        .defaultSize(width: 1000, height: 640)
        .restorationBehavior(.disabled)

        // One comparison per pair of folders, for the same reason.
        WindowGroup(id: DiptychApp.directoryDiffWindowID, for: DirectoryDiffPair.self) { $pair in
            if let pair { DirectoryDiffView(pair: pair) }
        }
        .defaultSize(width: 900, height: 600)
        .restorationBehavior(.disabled)

        // One window, shown once after an update -- not `WindowGroup(for:)`,
        // since there is only ever one and it carries no value of its own.
        Window("Release Notes", id: DiptychApp.releaseNotesWindowID) {
            ReleaseNotesView()
        }
        .defaultSize(width: 700, height: 600)
        .restorationBehavior(.disabled)

        // One console, showing MCP activity for the whole process -- not
        // per-window, since the server itself is one process-wide listener.
        Window("MCP Activity", id: DiptychApp.mcpConsoleWindowID) {
            MCPConsoleView()
        }
        .defaultSize(width: 560, height: 420)
        .restorationBehavior(.disabled)

        // Opened only by MCP's propose_file_operations -- keyed by a batch
        // id rather than by a file, since a batch isn't about any one path.
        WindowGroup(id: DiptychApp.batchOperationsWindowID, for: UUID.self) { $batchId in
            if let batchId { BatchOperationsView(batchId: batchId) }
        }
        .defaultSize(width: 760, height: 560)
        .restorationBehavior(.disabled)

        // One Runs window, a tab per run -- its own tab strip, not macOS's
        // window tabs; see RunsView.
        Window("Runs", id: DiptychApp.runWindowID) {
            RunsView()
        }
        .defaultSize(width: 820, height: 520)
        .restorationBehavior(.disabled)

        // Adds "Settings..." (Cmd-,) to the app menu in the standard place.
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Ask before quitting, when the setting says to.
    ///
    /// An NSAlert rather than anything in SwiftUI: the answer has to be given
    /// back to AppKit as a return value, before the application starts tearing
    /// itself down.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard MainActor.assumeIsolated({ ConfigStore.shared.configuration.confirmQuit })
        else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Quit Diptych?"
        alert.informativeText = "Anything you have not saved will be asked about separately."
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Do not ask anymore"
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runSelectable()
        // Applied whichever button was pressed: ticking the box is its own
        // decision, not conditional on quitting actually going through.
        if alert.suppressionButton?.state == .on {
            MainActor.assumeIsolated { ConfigStore.shared.configuration.confirmQuit = false }
        }
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }


    /// Before launching finishes: a "show this file" request may be what
    /// launched Diptych, and it arrives straight after.
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { FileViewer.shared.installHandlers() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // MCP tool calls implicitly address "the" Diptych window (no session
        // binding exists yet to say which one), so there can only be one
        // running instance for that to mean anything. A second launch
        // activates the first and quits itself, rather than the two
        // silently coexisting as they would by default.
        //
        // Except when this process is itself an XCTest host: `xcodebuild
        // test` launches the app under test the same way a real second
        // launch would, and this must never fight with a manually-running
        // instance for that -- it isn't a second instance of the app in any
        // sense a person means, and the whole test run silently produces no
        // test output at all if this quits it.
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

        // Copies kept for undoing a change to a file's contents, by a
        // Diptych that has since quit: its history went with it.
        DispatchQueue.global(qos: .utility).async { UndoSnapshots.removeAbandoned() }
        if !isRunningTests, let bundleID = Bundle.main.bundleIdentifier {
            let myPID = ProcessInfo.processInfo.processIdentifier
            let other = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .first { $0.processIdentifier != myPID }
            if let other {
                other.activate()
                NSApp.terminate(nil)
                return
            }
        }

        // The Dock caches an app's icon against its bundle path, and a debug
        // build living in DerivedData keeps whatever it cached the first time --
        // a generic placeholder, if the app was ever built before it had an
        // icon. Re-registering with LaunchServices does not always dislodge it.
        // Setting the tile image explicitly at launch sidesteps the cache.
        if let icon = NSImage(named: "AppIcon") {
            NSApplication.shared.applicationIconImage = icon
        }

        // AppKit's tooltip delay has no public API, only this long-standing
        // undocumented default -- roughly 1.5 seconds otherwise, which reads
        // as broken rather than deliberate on something meant to be skimmed
        // one after another, like the letter badges on a folder comparison.
        // `register`, not `set`: a fallback for this process, not a change
        // written to the user's real preferences.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 150])

        // macOS appends Start Dictation and Emoji & Symbols to the bottom of
        // any Edit menu it recognises as one -- which the Files menu's own
        // Cut/Copy/Paste group (`CommandGroup(replacing: .pasteboard)`) is
        // enough to trigger. Neither means anything here: nothing in Diptych
        // is a text view they could act on, so both items sat there able to
        // be clicked and unable to do anything. These two keys are the
        // documented way to ask AppKit not to add them.
        UserDefaults.standard.register(defaults: [
            "NSDisabledDictationMenuItem": true,
            "NSDisabledCharacterPaletteMenuItem": true,
        ])

        MainActor.assumeIsolated {
            ClipboardNamePrefetcher.shared.start()
            FileViewer.reconcileAtLaunch()
        }

        if !isRunningTests {
            // What a crash left of archives opened as folders.
            Task.detached(priority: .utility) { ArchiveBrowsing.removeAll() }
            MainActor.assumeIsolated {
                StartupWarnings.start()
                ServerAutoConnect.start()
                ServerAutoConnect.watchWaking()
            }
        }

        MainActor.assumeIsolated {
            let store = ConfigStore.shared
            guard store.configuration.mcpServerEnabled else { return }
            let port = store.configuration.mcpServerPort
            let token = MCPTokenStore.shared.token
            Task { await MCPServer.shared.applyConfiguration(enabled: true, port: port, token: token) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Archives opened as folders were unpacked for this run only.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            ArchiveBrowsing.removeAll()
        }
        // The agent terminals' shells, and the agents in them, end with the
        // app rather than being left to notice their terminal has gone.
        MainActor.assumeIsolated {
            for model in KeyRouter.shared.allModels { model.terminal?.terminate() }
        }
        Task { await MCPServer.shared.shutdown() }
    }
}

/// The Files menu.
///
/// macOS convention: everything reachable by keyboard is also in the menu bar
/// with a Command-key equivalent -- doubly so here, because macOS maps F1-F12 to
/// brightness and volume unless the user opts out in System Settings.
struct FileCommands: Commands {

    /// The model of whichever window currently has focus, published by
    /// ContentView's `.focusedSceneValue`. Nil when no window is focused, which
    /// is what disables the menu items.
    @FocusedValue(\.appModel) private var model: AppModel?
    @FocusedValue(\.editingUndo) private var editingUndo: EditingUndo?
    /// Text Edit in front: View's text sizes are its, and the panes' menu
    /// items are greyed out.
    @FocusedValue(\.textEditor) private var editor: TextEditorTarget?

    /// Run the pane command when a pane is focused, otherwise let AppKit send
    /// the standard action to whatever text view has focus.
    private func dispatch(_ command: (() -> Void)?, _ fallback: Selector) {
        if let command {
            command()
        } else {
            NSApp.sendAction(fallback, to: nil, from: nil)
        }
    }

    var body: some Commands {
        // The standard About panel, with the slogan under the version.
        CommandGroup(replacing: .appInfo) {
            Button("About Diptych") { AboutPanel.show() }
        }
        // Under About, above Settings, where macOS apps keep it.
        CommandGroup(after: .appInfo) {
            Button("Check for Updates\u{2026}") { UpdateChecker.shared.checkNow(on: model) }
        }

        // `after:` rather than `replacing:` -- SwiftUI puts its own "New Window"
        // (Cmd-N) in the .newItem group for a WindowGroup scene, and each window
        // it opens gets a fresh AppModel. Replacing the group would delete it.
        // "File" and "Files" side by side was a coin toss every time. Split
        // the way Finder splits: what you do *to* an item belongs in File, and
        // where you go belongs in Go.
        CommandGroup(after: .newItem) {
            Button("New Tab") { model?.newTab() }
                .keyboardShortcut(.newTab)
                .disabled(model == nil)
            // Greyed on a read-only server -- FTP, or a share mounted so --
            // as is everything below that would change what is there.
            Button("New Folder") { model?.requestNewFolder() }
                .keyboardShortcut(.newFolder)
                .disabled(model == nil || model?.active.isFlat == true || model?.active.volume.isReadOnly == true)
            Button("New File") { model?.requestNewFile() }
                .keyboardShortcut(.newFile)
                .disabled(model == nil || model?.active.isFlat == true || model?.active.volume.isReadOnly == true)
            // Absent, not greyed, when the setting says so: a command switched
            // off is not a command that is temporarily unavailable.
            if model?.clipboardCommandIsOffered ?? false {
                Button("New from Clipboard") { model?.newFromClipboard() }
                    .keyboardShortcut(.newFromClipboard)
                    // Greyed out when there is nothing to make a file from,
                    // rather than enabled and then complaining.
                    .disabled(model == nil || ClipboardWatcher.shared.kind == .empty)
            }

            Divider()

            // Finder keeps Open in File, next to the things done to an item,
            // even though Enclosing Folder sits in Go. Following that rather
            // than inventing a third arrangement.
            // Greyed out with no pane in front: Command-Down goes on to the
            // text there, as Move to Trash's Command-Delete does.
            Button("Open") { model?.openFromMenu() }
                .keyboardShortcut(.open)
                .disabled(model == nil)
            Button("Run with Arguments\u{2026}") { model?.runSelectionWithArguments() }
                .keyboardShortcut(.runWithArguments)
                .disabled(model == nil)
            Button("Get Info") { model?.showInfo() }
                .keyboardShortcut(.getInfo)
                .disabled(model == nil)
            Button("Compare") { model?.showDiff() }
                .keyboardShortcut(.compare)
                .disabled(model == nil)
            Button("Previous Versions\u{2026}") { model?.showPreviousVersions() }
                .disabled(model?.canShowPreviousVersions != true)
            Button("Find Duplicates\u{2026}") { model?.findDuplicates() }
                .disabled(model?.canFindDuplicates != true)
            Button("Disk Usage\u{2026}") { model?.showDiskUsage() }
                .disabled(model?.canShowDiskUsage != true)
            Button("Optimize File Size\u{2026}") { model?.requestOptimize() }
                .disabled(model?.canOptimize != true)
            Button("Split File\u{2026}") { model?.requestSplitFile() }
                .disabled(model?.canSplitFile != true)
            Button("Join Parts") { model?.joinParts() }
                .disabled(model?.canJoinParts != true)
            Button("Rename...") { model?.requestRename() }
                .disabled(model == nil || model?.active.volume.isReadOnly == true)
            Button("Rename Many\u{2026}") { model?.requestRenameMany() }
                .keyboardShortcut(.renameMany)
                .disabled(model == nil || model?.active.volume.isReadOnly == true)
            // Absent unless it can work: switched on, and Apple Intelligence
            // ready on this Mac. Settings says which of the two is missing.
            if model?.namesCanBeSuggested ?? false {
                // Command-F2 only: Control-Command-R now belongs to Rename
                // Many, and one shortcut cannot mean two things. F2 is the
                // rename key people already use, and the model takes the
                // Command form of it.
                Button("Rename with Suggested Name...") { model?.renameWithSuggestion() }
                    .keyboardShortcut(.renameSuggested)
                    .disabled(model?.isSuggestingName ?? true)
            }

            Divider()

            Button("Copy to Other Pane") { model?.copySelection() }
                .keyboardShortcut(.copyToOtherPane)
                .disabled(model == nil || model?.inactive.volume.isReadOnly == true)
            Button("Move to Other Pane") { model?.moveSelection() }
                .keyboardShortcut(.moveToOtherPane)
                .disabled(model == nil || model?.active.volume.isReadOnly == true
                          || model?.inactive.volume.isReadOnly == true)

            Divider()

            Button("Change Permissions...") { model?.requestPermissionEdit() }
                .keyboardShortcut(.changePermissions)
                .disabled(model == nil || model?.active.volume.isReadOnly == true)
            Button("Change Owner...") { model?.requestOwnerEdit() }
                .disabled(model == nil || model?.active.volume.isReadOnly == true)
            Button("Change Group...") { model?.requestGroupEdit() }
                .disabled(model == nil || model?.active.volume.isReadOnly == true)

            // Named for what they are. Absent entirely when scripts are
            // switched off, or when none of them suits what is selected --
            // a menu of permanently greyed commands teaches nobody anything.
            if let scripts = model?.applicableScripts, !scripts.isEmpty {
                Menu("Scripts") {
                    ForEach(scripts) { script in
                        Button(script.name) { model?.runScript(script) }
                            .help(script.summary)
                    }
                }
            }
            if ConfigStore.shared.configuration.scriptsEnabled {
                Button("Get Scripts\u{2026}") { model?.requestGetScripts() }
                    .disabled(model == nil)
            }
            if ConfigStore.shared.configuration.scriptsDeveloperMode,
               ConfigStore.shared.configuration.scriptsEnabled {
                Button("Read the Scripts Folder Again") { model?.rereadScripts() }
            }

            Divider()

            // Version tracking. Hidden entirely when the folder is not tracked
            // or the feature is off, rather than permanently greyed out.
            if model?.gitRepositoryRoot != nil {
                Button("Send My Work\u{2026}") { model?.requestSendWork() }
                    .keyboardShortcut(.sendWork)
                Button("Get the Latest") { model?.getLatest() }
                    .keyboardShortcut(.getLatest)
                Button("Check for Changes") { model?.checkForChanges() }
                    .keyboardShortcut(.checkForChanges)

                Divider()
            }

            Button("Move to Trash") { model?.trashFromMenu() }
                .keyboardShortcut(.trashNow)
                .disabled(model == nil || model?.active.volume.isReadOnly == true)

            Divider()

            Button("Reveal in Finder") { model?.revealSelection() }
                .keyboardShortcut(.revealInFinder)
                .disabled(model == nil)
            Button("Open Terminal Here") { model?.openTerminal() }
                .keyboardShortcut(.openTerminal)
                .disabled(model == nil)
            Button("Add Diptych to Agent Config (.mcp.json)\u{2026}") {
                model?.requestAddMCPConfig()
            }
            .disabled(model == nil)
        }

        // Every one of these falls back to the standard responder action when
        // no pane has focus. Menu key equivalents are matched before the
        // responder chain, so without the fallback Cmd-V in the Info window
        // would hit a nil model and simply be swallowed.
        // Undo and Redo for what was done to files, in a pane window. Anywhere
        // else -- a text field, Text Edit, the Info window -- they are the
        // ordinary text undo, and in a comparison that window's own.
        CommandGroup(replacing: .undoRedo) {
            Button(model.flatMap { _ in FileHistory.shared.undoName }
                    .map { "Undo \($0)" } ?? "Undo") {
                if let model {
                    model.undoFromMenu()
                } else if let editingUndo {
                    editingUndo.undo()
                } else {
                    NSApp.sendAction(#selector(UndoActions.undo(_:)), to: nil, from: nil)
                }
            }
            .keyboardShortcut("z")
            Button(model.flatMap { _ in FileHistory.shared.redoName }
                    .map { "Redo \($0)" } ?? "Redo") {
                if let model {
                    model.redoFromMenu()
                } else if let editingUndo {
                    editingUndo.redo()
                } else {
                    NSApp.sendAction(#selector(UndoActions.redo(_:)), to: nil, from: nil)
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])

            // Several at once, chosen from a list: the way back out of a
            // sequence of operations without pressing Command-Z five times and
            // answering five questions.
            Button("Undo or Redo Many\u{2026}") { model?.requestHistoryMany() }
                .keyboardShortcut("z", modifiers: [.command, .control])
                .disabled(model == nil)
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { dispatch(model?.cutSelectionToClipboard, #selector(NSText.cut(_:))) }
                .keyboardShortcut(.cut)
            Button("Copy") { dispatch(model?.copySelectionToClipboard, #selector(NSText.copy(_:))) }
                .keyboardShortcut(.copy)
            Button("Paste") { dispatch(model?.pasteIntoActivePane, #selector(NSText.paste(_:))) }
                .keyboardShortcut(.paste)
            // Control-Command-V. Finder spells "paste something other than a
            // copy" with a modifier on V (Option-Command-V moves), so V with a
            // modifier is where anyone would look for it.
            Button("Paste as Link") { model?.pasteAsLink() }
                .keyboardShortcut(.pasteAsLink)
                .disabled(model == nil || model?.active.volume.isReadOnly == true)
            // The copied file's permissions, dates, EXIF... onto the selection.
            PasteSpecialMenu(model: model)

            Button("Select All") { dispatch(model?.selectAll, #selector(NSText.selectAll(_:))) }
                .keyboardShortcut(.selectAll)

            Divider()

            Button("Copy File Names") { model?.copySelectionNames(fullPath: false) }
                .keyboardShortcut(.copyNames)
                .disabled(model == nil)
            Button("Copy Full Paths") { model?.copySelectionNames(fullPath: true) }
                .keyboardShortcut(.copyPaths)
                .disabled(model == nil)
            // Absent, like the right-click entry, when there is nothing in the
            // selection the clipboard could hold.
            if model?.canCopySelectionContents ?? false {
                Button("Copy Contents") { model?.copySelectionContents() }
                    .keyboardShortcut(.copyContent)
            }
        }

        CommandGroup(after: .toolbar) {
            // With Text Edit in front, its size; otherwise the panes'.
            Button("Bigger Text") { editor == nil ? PaneFont.zoom(by: 1) : EditorFont.zoom(by: 1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(editor == nil
                          ? ConfigStore.shared.configuration.fontSize >= Configuration.fontSizes.upperBound
                          : EditorFont.size >= TextStyle.fontSizes.upperBound)
            // The menu shows Command-+, which AppKit matches by character and
            // so only with Shift held. Command-= -- the same physical key
            // unshifted, and what half of everyone actually presses -- is
            // caught in KeyRouter, because a menu cannot carry two equivalents
            // for one command and a second visible item would be nonsense.

            Button("Smaller Text") { editor == nil ? PaneFont.zoom(by: -1) : EditorFont.zoom(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(editor == nil
                          ? ConfigStore.shared.configuration.fontSize <= Configuration.fontSizes.lowerBound
                          : EditorFont.size <= TextStyle.fontSizes.lowerBound)

            Button("Actual Size") { editor == nil ? PaneFont.reset() : EditorFont.reset() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(editor == nil
                          ? ConfigStore.shared.configuration.fontSize == Configuration.defaultFontSize
                          : EditorFont.size == TextStyle.defaultFontSize)

            Divider()
        }

        CommandMenu("Go") {
            Button("Back") { model?.goBack() }
                .keyboardShortcut("[")
                .disabled(model?.active.canGoBack != true)
            Button("Forward") { model?.goForward() }
                .keyboardShortcut("]")
                .disabled(model?.active.canGoForward != true)
            // Greyed out with no pane in front, so Command-Up goes on to the
            // text there, as in any other window.
            Button("Enclosing Folder") { model?.goUpFromMenu() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model == nil)

            Divider()

            // Two ways in, differing only in what is selected. Command-G is
            // disabled rather than absent when no pane has focus, so its key
            // equivalent falls through to a binary view's Find Next instead of
            // being swallowed by a menu item that cannot act.
            Button("Go") { model?.requestPathEdit(selectingAll: true) }
                .keyboardShortcut("g")
                .disabled(model == nil)
            Button("Go to Folder...") { model?.requestPathEdit() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model == nil)

            Divider()

            Button("Connect to Server\u{2026}") { model?.requestConnectToServer() }
                .keyboardShortcut("k")
                .disabled(model == nil)
        }

        // Making archives and opening them, a menu of its own beside Go.
        CommandMenu("Archive") {
            Button("Create Archive\u{2026}") { model?.requestCreateArchive() }
                .disabled(model?.canCreateArchive != true)
            Divider()
            Button(model?.openableAsFolder.map(DiskImaging.isDiskImage) == true
                   ? "Mount in Pane" : "Open as Folder") { model?.openSelectionAsFolder() }
                .disabled(model?.openableAsFolder == nil)
            Button("Extract Here") { model?.extractHere() }
                .disabled(model?.canExtract != true)
            Button("Extract to Other Pane") { model?.extractToOtherPane() }
                .disabled(model?.canExtractToOtherPane != true)
            Divider()
            Button("Recover ZIP Password\u{2026}") { model?.recoverPassword() }
                .disabled(model?.canRecoverPassword != true)
        }

        // Making a file's checksum and checking one, a menu of its own.
        CommandMenu("Checksum") {
            Menu("Create") {
                Button("MD5") { model?.createChecksums(.md5) }
                Button("SHA-1") { model?.createChecksums(.sha1) }
                Button("SHA-256") { model?.createChecksums(.sha256) }
                Button("SHA-512") { model?.createChecksums(.sha512) }
            }
            .disabled(model?.canChecksum != true)
            Button("Check") { model?.checkChecksums() }
                .disabled(model?.canChecksum != true)
        }

        // Placed *into* the system View menu rather than declared as a second
        // menu of the same name. A CommandMenu("View") does not merge with the
        // built-in one -- it sits next to it, and macOS then has nowhere to put
        // Show Tab Bar and the other window-tab commands.
        CommandGroup(after: .sidebar) {
            Button(model?.sidebarVisible == true ? "Hide Sidebar" : "Show Sidebar") {
                model?.sidebarVisible.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(model == nil)
            Button(model?.isSinglePane == true ? "Show Both Panes" : "Show One Pane") {
                model?.isSinglePane.toggle()
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(model == nil)

            Toggle("Flat View", isOn: Binding(
                get: { model?.active.isFlat ?? false },
                set: { _ in model?.toggleFlatView() }))
                .keyboardShortcut(.flatView)
                .disabled(model == nil)

            Toggle("Show Hidden Files", isOn: Binding(
                get: { model?.showHidden ?? false },
                set: { model?.showHidden = $0 }))
                // Shift-Cmd-. as in Finder. Plain Cmd-. is the system's
                // "cancel", which this was shadowing while a sheet was open.
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(model == nil)

            Divider()

            Button("Swap Panes") { model?.swapPanes() }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(model == nil)
            Button("Switch Pane") { model?.toggleActiveSide() }
                .disabled(model == nil)
            Button("Same Folder in Other Pane") { model?.syncPanes() }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(model == nil)
            Button("Refresh") { model?.active.reload() }
                .keyboardShortcut(.refresh)
                .disabled(model == nil)
            // Greyed while the Size column, where the totals go, is hidden.
            Button("Calculate Directory Sizes") { model?.calculateDirectorySizes() }
                .disabled(model?.canCalculateDirectorySizes != true)
            Button("Clear Directory Sizes") { model?.clearDirectorySizes() }
                .disabled(model == nil || DirectorySizes.shared.isEmpty)

            Divider()

            Button(model?.terminalVisible == true ? "Hide Agent Terminal" : "Show Agent Terminal") {
                model?.toggleTerminal()
            }
            .keyboardShortcut(.toggleTerminal)
            .disabled(model == nil)
        }
    }
}
