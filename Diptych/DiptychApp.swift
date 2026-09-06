import SwiftUI

/// `@main` marks the process entry point -- Swift's `public static void main`.
/// An `App` is a value type describing the scenes the app owns; SwiftUI creates
/// the NSApplication, the windows and the menu bar from it.
@main
struct DiptychApp: App {

    static let windowGroupID = "diptych.window"
    static let infoWindowID = "diptych.info"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup(id: DiptychApp.windowGroupID) {
            // No model here on purpose. `@State` on an App is created once for
            // the process, so a model declared at this level is shared by every
            // window and tab. ContentView owns one model per window instead.
            ContentView()
        }
        .defaultSize(width: 1100, height: 680)
        .commands { FileCommands() }

        // One info window per file, keyed by URL, so Cmd-I on a second file
        // opens a second window rather than replacing the first.
        WindowGroup(id: DiptychApp.infoWindowID, for: URL.self) { $url in
            if let url { InfoView(url: url) }
        }
        .defaultSize(width: 560, height: 540)

        // Adds "Settings..." (Cmd-,) to the app menu in the standard place.
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The Dock caches an app's icon against its bundle path, and a debug
        // build living in DerivedData keeps whatever it cached the first time --
        // a generic placeholder, if the app was ever built before it had an
        // icon. Re-registering with LaunchServices does not always dislodge it.
        // Setting the tile image explicitly at launch sidesteps the cache.
        if let icon = NSImage(named: "AppIcon") {
            NSApplication.shared.applicationIconImage = icon
        }
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
        // `after:` rather than `replacing:` -- SwiftUI puts its own "New Window"
        // (Cmd-N) in the .newItem group for a WindowGroup scene, and each window
        // it opens gets a fresh AppModel. Replacing the group would delete it.
        CommandGroup(after: .newItem) {
            Button("New Tab") { model?.newTab() }
                .keyboardShortcut("t")
            Button("New Folder") { model?.requestNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model == nil)
        }

        // Every one of these falls back to the standard responder action when
        // no pane has focus. Menu key equivalents are matched before the
        // responder chain, so without the fallback Cmd-V in the Info window
        // would hit a nil model and simply be swallowed.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { dispatch(model?.cutSelectionToClipboard, #selector(NSText.cut(_:))) }
                .keyboardShortcut("x")
            Button("Copy") { dispatch(model?.copySelectionToClipboard, #selector(NSText.copy(_:))) }
                .keyboardShortcut("c")
            Button("Paste") { dispatch(model?.pasteIntoActivePane, #selector(NSText.paste(_:))) }
                .keyboardShortcut("v")

            Button("Select All") { dispatch(model?.selectAll, #selector(NSText.selectAll(_:))) }
                .keyboardShortcut("a")

            Divider()

            Button("Copy File Names") { model?.copySelectionNames(fullPath: false) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Copy Full Paths") { model?.copySelectionNames(fullPath: true) }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
        }

        CommandMenu("Files") {
            Button("Open") { model?.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Back") { model?.goBack() }
                .keyboardShortcut("[")
                .disabled(model?.active.canGoBack != true)
            Button("Forward") { model?.goForward() }
                .keyboardShortcut("]")
                .disabled(model?.active.canGoForward != true)
            Button("Enclosing Folder") { model?.active.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Go to Folder...") { model?.requestPathEdit() }
                .keyboardShortcut("g", modifiers: [.command, .shift])

            Divider()

            Button("Copy to Other Pane") { model?.copySelection() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Move to Other Pane") { model?.moveSelection() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Get Info") { model?.showInfo() }
                .keyboardShortcut("i")
            Button("Rename...") { model?.requestRename() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Change Permissions...") { model?.requestPermissionEdit() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Change Owner...") { model?.requestOwnerEdit() }
            Button("Change Group...") { model?.requestGroupEdit() }
            Button("Move to Trash") { model?.trashNow() }
                .keyboardShortcut(.delete, modifiers: .command)

            Divider()

            Button("Reveal in Finder") { model?.revealSelection() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Open Terminal Here") { model?.openTerminal() }
                .keyboardShortcut("t", modifiers: [.command, .option])
        }

        // Placed *into* the system View menu rather than declared as a second
        // menu of the same name. A CommandMenu("View") does not merge with the
        // built-in one -- it sits next to it, and macOS then has nowhere to put
        // Show Tab Bar and the other window-tab commands.
        CommandGroup(after: .sidebar) {
            Button(model?.isSinglePane == true ? "Show Both Panes" : "Show One Pane") {
                model?.isSinglePane.toggle()
            }
            .keyboardShortcut("2", modifiers: .command)

            Toggle("Show Hidden Files", isOn: Binding(
                get: { model?.showHidden ?? false },
                set: { model?.showHidden = $0 }))
                .keyboardShortcut(".", modifiers: .command)

            Divider()

            Button("Swap Panes") { model?.swapPanes() }
                .keyboardShortcut("u", modifiers: .command)
            Button("Switch Pane") { model?.toggleActiveSide() }
            Button("Same Folder in Other Pane") { model?.syncPanes() }
                .keyboardShortcut("=", modifiers: .command)
            Button("Refresh") { model?.active.reload() }
                .keyboardShortcut("r", modifiers: .command)
        }
    }
}
