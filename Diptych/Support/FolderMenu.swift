import AppKit
import SwiftUI

/// The menu for the empty space below a pane's rows: what you can do *here*,
/// rather than to a file.
///
/// AppKit, because SwiftUI never asks about that space. A `Table` answers a
/// right-click with `contextMenu(forSelectionType:)`, which is only ever
/// consulted for rows, and a plain `contextMenu` on the table is not consulted
/// at all -- so right-clicking below the listing produced no menu whatsoever,
/// where every file manager offers New Folder and Paste.
///
/// The right-click is caught in `ClickRouter`, which already watches the mouse
/// for the whole application, and this puts a real `NSMenu` under the pointer.
@MainActor
final class FolderMenu: NSObject {


    static let shared = FolderMenu()

    /// What each item does, by the item's tag: an `NSMenuItem` carries a
    /// selector and a target, not a closure.
    private var actions: [() -> Void] = []
    private var menu: NSMenu?

    func show(for model: AppModel, pane: PaneModel) {
        model.activate(pane)

        actions = []
        let menu = NSMenu()

        // A Trash listing is not a place to make or paste files: the empty
        // space offers only to select and to refresh.
        if pane.isTrashListing {
            add("Select All", .selectAll, to: menu) { model.selectAll() }
            add("Refresh", .refresh, to: menu) { pane.reload() }
            self.menu = menu
            let at = NSEvent.mouseLocation
            DispatchQueue.main.async { menu.popUp(positioning: nil, at: at, in: nil) }
            return
        }

        // New as a submenu, as the row menu has it: Folder, File, from Clipboard.
        let newItem = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        let newSub = NSMenu()
        add("Folder", .newFolder, to: newSub) { model.requestNewFolder() }
        add("File", .newFile, to: newSub) { model.requestNewFile() }
        if model.clipboardCommandIsOffered {
            add("from Clipboard", .newFromClipboard, to: newSub) { model.newFromClipboard() }
        }
        newItem.submenu = newSub
        menu.addItem(newItem)

        // The scripts that take no items: they are about the folder on
        // screen, and this is the menu for the folder on screen. The file
        // menu's own empty-selection case never shows -- SwiftUI asks it only
        // about rows -- so without this they were reachable from File alone.
        let scripts = ScriptCatalogue.shared.applicable(to: [], in: pane.directory)
        if !scripts.isEmpty {
            let entry = NSMenuItem(title: "Scripts", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for script in scripts {
                add(script.name, nil, to: sub) {
                    model.runScript(script, on: [], in: pane.directory)
                }
                sub.items.last?.toolTip = script.summary.isEmpty ? nil : script.summary
            }
            entry.submenu = sub
            menu.addItem(entry)
        }

        // Paste as a submenu too: Paste itself, then as Link. AppKit will not
        // let one item both run on click and open a submenu, so the paste sits
        // inside rather than on the parent -- ⌘V pastes directly regardless.
        menu.addItem(.separator())
        let pasteItem = NSMenuItem(title: "Paste", action: nil, keyEquivalent: "")
        let pasteSub = NSMenu()
        add("Paste", .paste, to: pasteSub) { model.pasteIntoActivePane() }
        add("as Link", .pasteAsLink, to: pasteSub) { model.pasteAsLink() }
        pasteItem.submenu = pasteSub
        menu.addItem(pasteItem)

        menu.addItem(.separator())
        add("Rename Many\u{2026}", .renameMany, to: menu) { model.requestRenameMany() }
        add("Select All", .selectAll, to: menu) { model.selectAll() }
        add("Refresh", .refresh, to: menu) { pane.reload() }

        self.menu = menu
        // Next turn of the run loop, at the pointer.
        //
        // A menu runs its own tracking loop, and starting one from inside the
        // event monitor -- while the click that asked for it is still being
        // dispatched -- does nothing at all: the call returns and no menu
        // appears. Letting the click finish first is what puts it on screen.
        let at = NSEvent.mouseLocation
        DispatchQueue.main.async { menu.popUp(positioning: nil, at: at, in: nil) }
    }

    private func add(_ title: String, _ shortcut: KeyboardShortcut?, to menu: NSMenu,
                     run: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(chose(_:)), keyEquivalent: "")
        if let shortcut { item.show(shortcut) }
        item.target = self
        item.tag = actions.count
        actions.append(run)
        menu.addItem(item)
    }

    @objc private func chose(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}
