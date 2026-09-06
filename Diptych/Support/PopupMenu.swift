import AppKit

/// A one-shot popup list, used for picking an owner or a group.
///
/// A menu rather than an in-cell editor: the value has to come from a fixed set
/// the system defines, and the set is long enough that typing it would be worse
/// than choosing it.
@MainActor
final class PopupMenu: NSObject {

    struct Section {
        let title: String?
        let items: [String]
    }

    private var onPick: ((String) -> Void)?
    private var menu: NSMenu?

    func show(sections: [Section], current: String?, onPick: @escaping (String) -> Void) {
        self.onPick = onPick

        let menu = NSMenu()
        for (index, section) in sections.enumerated() where !section.items.isEmpty {
            if index > 0 { menu.addItem(.separator()) }
            if let title = section.title {
                let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
            }
            for name in section.items {
                let item = NSMenuItem(title: name, action: #selector(pick(_:)), keyEquivalent: "")
                item.target = self
                item.state = (name == current) ? .on : .off
                menu.addItem(item)
            }
        }

        self.menu = menu
        // Screen coordinates, at the pointer -- which is where the click that
        // opened it just happened.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        onPick?(sender.title)
    }
}
