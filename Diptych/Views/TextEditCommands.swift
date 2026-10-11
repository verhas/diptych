import SwiftUI

/// The Format menu: for the Text Edit window in front, and greyed out
/// everywhere else. A greyed-out item leaves its keys to whatever has focus,
/// so Shift-Command-Up still selects to the start of a text field, and moves
/// files in a pane.
struct TextEditCommands: Commands {

    @FocusedValue(\.textEditor) private var editor: TextEditorTarget?

    private var inText: Bool { editor != nil && !(editor?.link.showsTree ?? false) }
    private var inTree: Bool { editor?.link.showsTree == true && editor?.isReadOnly == false }

    @Bindable private var store = ConfigStore.shared

    private var emphasis: Int { editor?.link.emphasis ?? 0 }
    private var limit: Int { store.configuration.textStyle.emphasisLimit }

    private func emphasisTitle(up: Bool) -> String {
        let next = emphasis + (up ? 1 : -1)
        guard inText, (0 ... limit).contains(next) else {
            return up ? "Increase Structure Emphasis" : "Decrease Structure Emphasis"
        }
        if next == 0 { return "Decrease Structure Emphasis to None" }
        return (up ? "Increase" : "Decrease") + " Structure Emphasis to \(next)"
    }

    var body: some Commands {
        CommandMenu("Format") {
            Button("Format Document") { editor?.controller?.formatDocument() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!(editor?.canFormat ?? false))
            Button("Compact JSON") { editor?.controller?.formatDocument(compact: true) }
                .disabled(editor?.format != .json || editor?.isReadOnly != false)

            Divider()

            Button("Comment Lines") { editor?.controller?.toggleComment() }
                .keyboardShortcut("/")
                .disabled(!inText || ![.xml, .yaml, .toml].contains(editor?.format?.markup))
            // In the tree the selected node moves, with all it holds.
            Button(inTree ? "Move Up" : "Move Lines Up") { editor?.controller?.moveUp(true) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                .disabled(!inText && !inTree)
            Button(inTree ? "Move Down" : "Move Lines Down") { editor?.controller?.moveUp(false) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
                .disabled(!inText && !inTree)
            // Command-Delete is Move to Trash's; in Text Edit it reaches the
            // text view, which deletes the line.
            Button("Delete Lines") { editor?.controller?.deleteLines() }
                .disabled(!inText || editor?.isReadOnly != false)

            // The structure around the caret, shaded: the window's own level,
            // named with where it goes.
            Button(emphasisTitle(up: true)) { editor?.link.emphasis += 1 }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!inText || emphasis >= limit)
            Button(emphasisTitle(up: false)) { editor?.link.emphasis -= 1 }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!inText || emphasis <= 0)

            Divider()

            // Taken by the editor before Edit ▸ Find Next sees it; shown
            // here so the key is found.
            Button("Go to Line\u{2026}") { editor?.controller?.askForLine() }
                .keyboardShortcut("g")
                .disabled(editor == nil)
            Button(editor?.link.showsTree == true ? "Show as Text" : "Show as Tree") {
                editor?.link.showsTree.toggle()
            }
            .keyboardShortcut("t", modifiers: [.command, .control])
            .disabled(!(editor?.hasTree ?? false))
            // What is added is what is next to it, or what the parent
            // mostly holds; the tree's right-click menu offers every kind.
            Button("Add Child") { editor?.controller?.tree?.addChild() }
                .keyboardShortcut("n", modifiers: [.command, .control])
                .disabled(!inTree)
            Button("Add After") { editor?.controller?.tree?.addAfter() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!inTree)
            Toggle("Show Type Column", isOn: $store.configuration.textStyle.treeShowsTypes)
                .disabled(!(editor?.hasTree ?? false))
        }
    }
}
