import SwiftUI

/// `@main` marks the process entry point -- Swift's `public static void main`.
/// An `App` is a value type describing the scenes the app owns; SwiftUI creates
/// the NSApplication, the windows and the menu bar from it.
@main
struct DiptychApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            // No model here on purpose. `@State` on an App is created once for
            // the process, so a model declared at this level is shared by every
            // window and tab. ContentView owns one model per window instead.
            ContentView()
        }
        .defaultSize(width: 1100, height: 680)
        .commands { FileCommands() }

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

    var body: some Commands {
        // `after:` rather than `replacing:` -- SwiftUI puts its own "New Window"
        // (Cmd-N) in the .newItem group for a WindowGroup scene, and each window
        // it opens gets a fresh AppModel. Replacing the group would delete it.
        CommandGroup(after: .newItem) {
            Button("New Folder") { model?.requestNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model == nil)
        }

        CommandMenu("Files") {
            Button("Open") { model?.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Enclosing Folder") { model?.active.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Go to Folder...") { model?.requestPathEdit() }
                .keyboardShortcut("g", modifiers: [.command, .shift])

            Divider()

            Button("Copy to Other Pane") { model?.copySelection() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Move to Other Pane") { model?.moveSelection() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Rename...") { model?.requestRename() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Move to Trash") { model?.trashNow() }
                .keyboardShortcut(.delete, modifiers: .command)

            Divider()

            Button("Reveal in Finder") { model?.revealSelection() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Open Terminal Here") { model?.openTerminal() }
                .keyboardShortcut("t", modifiers: [.command, .option])
        }

        CommandMenu("View") {
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
