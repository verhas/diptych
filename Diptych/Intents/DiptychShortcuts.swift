import AppIntents

/// What can be said to Siri, and is offered in Spotlight and Shortcuts without
/// building a shortcut first. An app may offer ten; these are the questions
/// people ask out loud. Every other intent is still there in Shortcuts.
///
/// Each still goes through `IntentGate`: switched off in Settings, the answer
/// is that it is switched off.
struct DiptychShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetSelectionIntent(),
                    phrases: ["What's selected in \(.applicationName)",
                              "Get the selection in \(.applicationName)"],
                    shortTitle: "Selected Files", systemImageName: "checkmark.circle")
        AppShortcut(intent: GetPaneFolderIntent(),
                    phrases: ["Which folder is \(.applicationName) showing",
                              "Where am I in \(.applicationName)"],
                    shortTitle: "Folder Shown", systemImageName: "folder")
        AppShortcut(intent: GetPaneContentsIntent(),
                    phrases: ["What's in the \(.applicationName) pane",
                              "Get the files in \(.applicationName)"],
                    shortTitle: "Files in Pane", systemImageName: "doc.on.doc")
        AppShortcut(intent: ListRunsIntent(),
                    phrases: ["Did my last \(.applicationName) run finish",
                              "List my \(.applicationName) runs"],
                    shortTitle: "Runs", systemImageName: "terminal")
        AppShortcut(intent: GetRunOutputIntent(),
                    phrases: ["What did my last \(.applicationName) run print",
                              "Why did my \(.applicationName) run fail"],
                    shortTitle: "Run Output", systemImageName: "text.alignleft")
        AppShortcut(intent: ListWindowsIntent(),
                    phrases: ["What windows are open in \(.applicationName)"],
                    shortTitle: "Windows", systemImageName: "macwindow.on.rectangle")
        AppShortcut(intent: SetPaneViewIntent(),
                    phrases: ["Show \(.applicationName) as \(\.$view)",
                              "Switch \(.applicationName) to \(\.$view)"],
                    shortTitle: "Pane View", systemImageName: "square.grid.2x2")
        AppShortcut(intent: SetActivePaneIntent(),
                    phrases: ["Switch to the \(\.$side) in \(.applicationName)"],
                    shortTitle: "Active Pane", systemImageName: "rectangle.split.2x1")
        AppShortcut(intent: GetFolderComparisonIntent(),
                    phrases: ["What is \(.applicationName) comparing"],
                    shortTitle: "Folder Comparison", systemImageName: "plusminus.circle")
        AppShortcut(intent: GetDiptychInfoIntent(),
                    phrases: ["Which version of \(.applicationName) is running"],
                    shortTitle: "Diptych Info", systemImageName: "info.circle")
    }
}
