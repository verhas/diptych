import AppKit

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

        add("New Folder", to: menu) { model.requestNewFolder() }
        add("New File", to: menu) { model.requestNewFile() }
        if model.clipboardCommandIsOffered {
            add("New from Clipboard", to: menu) { model.newFromClipboard() }
        }

        menu.addItem(.separator())
        add("Paste", to: menu) { model.pasteIntoActivePane() }
        add("Paste as Link", to: menu) { model.pasteAsLink() }

        menu.addItem(.separator())
        add("Rename Many\u{2026}", to: menu) { model.requestRenameMany() }
        add("Select All", to: menu) { model.selectAll() }
        add("Refresh", to: menu) { pane.reload() }

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

    private func add(_ title: String, to menu: NSMenu, run: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(chose(_:)), keyEquivalent: "")
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
