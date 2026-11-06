import AppKit
import SwiftUI

/// Space on a folder: what is in it, as a tree, in a floating panel of
/// Diptych's own rather than Quick Look's. It looks like the page Quick Look
/// showed -- the name, what is in it, the path, the files with their sizes and
/// dates -- and its folders open in place, each read when it is opened.
/// Right-click ▸ Jump Here takes the pane that opened it there.
///
/// Like Quick Look it follows the pane's cursor, and Space closes it: the
/// panel never takes the keyboard from the pane, only the mouse.
@MainActor
final class FolderPreview: NSObject, NSWindowDelegate {

    static let shared = FolderPreview()

    private var panel: NSPanel?
    private(set) var root: URL?
    private weak var owner: AppModel?
    /// The pane that opened it: where Jump Here goes.
    private weak var pane: PaneModel?

    var isVisible: Bool { panel?.isVisible == true }

    /// A folder this shows: not a package, which Space means as the app or
    /// document it is, and not a link, whose own page says where it leads.
    nonisolated static func shows(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey,
                                                       .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isPackage != true
            && values?.isSymbolicLink != true
    }

    func show(_ url: URL, owner: AppModel?, pane: PaneModel?) {
        self.owner = owner
        self.pane = pane
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if root != url || !panel.isVisible {
            root = url
            let tree = FolderTree(root: url)
            panel.title = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            panel.contentView = NSHostingView(rootView: FolderPreviewView(
                tree: tree,
                jump: { [weak self] node in self?.jump(to: node) }))
        }
        if !panel.isVisible {
            if panel.frameAutosaveName.isEmpty || !panel.setFrameUsingName(Self.frameName) {
                place(panel)
            }
            panel.setFrameAutosaveName(Self.frameName)
            panel.orderFront(nil)
        }
    }

    func close() {
        panel?.orderOut(nil)
        root = nil
    }

    // MARK: - Jump Here

    /// A folder opened in the pane; a file's folder, with the file selected.
    private func jump(to node: FolderNode) {
        guard let pane else { return }
        close()
        if let owner {
            owner.activeSide = pane === owner.left ? .left : .right
        }
        if node.isDirectory {
            pane.navigate(to: node.url)
        } else {
            pane.pendingSelection = [node.url.standardizedFileURL]
            pane.navigate(to: node.url.deletingLastPathComponent())
        }
        owner?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - The panel

    private static let frameName = "Diptych Folder Preview"

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        // The pane keeps the keyboard: its arrows move the cursor, the panel
        // follows, Space closes it. A click in the tree needs no key window.
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 380, height: 260)
        panel.delegate = self
        return panel
    }

    /// Beside the window it was opened from, the first time.
    private func place(_ panel: NSPanel) {
        guard let window = owner?.window, let screen = window.screen ?? NSScreen.main else {
            panel.center()
            return
        }
        let area = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = min(window.frame.midX - frame.width / 2, area.maxX - frame.width)
        frame.origin.y = max(window.frame.midY - frame.height / 2, area.minY)
        panel.setFrame(frame, display: false)
    }

    func windowWillClose(_ notification: Notification) {
        root = nil
    }
}

// MARK: - The tree

/// One row: a file, a folder whose children are read when it is opened, or a
/// line of its own -- "Reading…", "It is empty.", what was left unlisted.
@MainActor
final class FolderNode: NSObject {

    enum Note { case reading, empty, omitted(Int), trouble(String) }

    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
    let note: Note?
    /// Nil until read.
    var children: [FolderNode]?
    var isLoading = false

    init(url: URL, name: String, isDirectory: Bool, size: Int64? = nil, modified: Date? = nil,
         note: Note? = nil) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.note = note
    }

    static func note(_ note: Note, in folder: URL) -> FolderNode {
        FolderNode(url: folder, name: "", isDirectory: false, note: note)
    }

    lazy var readingNote = FolderNode.note(.reading, in: url)

    /// What the tree shows under it: its children, or that they are coming.
    var shown: [FolderNode] { children ?? [readingNote] }
}

@MainActor
@Observable
final class FolderTree {

    let root: URL
    let top: FolderNode
    private(set) var summary = "Looking inside the folder"

    /// Told when a folder's children have been read, to draw them.
    @ObservationIgnored var loaded: ((FolderNode) -> Void)?

    init(root: URL) {
        self.root = root
        top = FolderNode(url: root, name: root.lastPathComponent, isDirectory: true)
    }

    /// Read off the main thread, as the Quick Look page was, and as bounded:
    /// the first thousand of a folder, the rest counted.
    func load(_ node: FolderNode) {
        guard node.isDirectory, node.children == nil, !node.isLoading else { return }
        node.isLoading = true
        let url = node.url
        Task { [weak self] in
            let result = await BlockingWork.run { Listing.folder(at: url) }
            var children = result.entries.map {
                FolderNode(url: url.appendingPathComponent($0.name, isDirectory: $0.isDirectory),
                           name: $0.name, isDirectory: $0.isDirectory, size: $0.size,
                           modified: $0.modified)
            }
            if let trouble = result.trouble {
                children.insert(.note(.trouble(trouble), in: url), at: 0)
            } else if children.isEmpty {
                children.append(.note(.empty, in: url))
            }
            if result.omitted > 0 { children.append(.note(.omitted(result.omitted), in: url)) }
            node.children = children
            node.isLoading = false
            guard let self else { return }
            if node === top {
                summary = ListingReport.summary(result, kind: .folder, stillReading: false)
            }
            loaded?(node)
        }
    }
}

// MARK: - The view

struct FolderPreviewView: View {

    let tree: FolderTree
    let jump: (FolderNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tree.root.lastPathComponent.isEmpty ? tree.root.path : tree.root.lastPathComponent)
                .font(.system(size: 17, weight: .bold))
                .textSelection(.enabled)
            Text(tree.summary)
                .foregroundStyle(.secondary)
            Text(tree.root.path)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
            FolderOutline(tree: tree, jump: jump)
                .padding(.top, 8)
        }
        .font(.system(size: 13))
        .padding(EdgeInsets(top: 14, leading: 22, bottom: 14, trailing: 22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// An `NSOutlineView`: folders opened one level at a time, each read only
/// when it is opened, which a SwiftUI table cannot be told about.
private struct FolderOutline: NSViewRepresentable {

    let tree: FolderTree
    let jump: (FolderNode) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(tree: tree, jump: jump) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        outline.headerView = nil
        outline.style = .plain
        outline.rowSizeStyle = .custom
        outline.rowHeight = 22
        outline.gridStyleMask = .solidHorizontalGridLineMask
        outline.backgroundColor = .clear
        outline.usesAlternatingRowBackgroundColors = false
        outline.allowsMultipleSelection = false
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        for (id, width) in [(Column.name, 300.0), (.size, 80), (.modified, 150)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id.rawValue))
            column.width = width
            column.minWidth = id == .name ? 140 : width
            if id != .name { column.maxWidth = width }
            column.resizingMask = id == .name ? .autoresizingMask : []
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator

        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu

        context.coordinator.outline = outline
        tree.loaded = { [weak coordinator = context.coordinator] node in
            coordinator?.loaded(node)
        }
        tree.load(tree.top)

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}

    enum Column: String { case name, size, modified }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate,
                             NSMenuDelegate {

        let tree: FolderTree
        let jump: (FolderNode) -> Void
        weak var outline: NSOutlineView?

        init(tree: FolderTree, jump: @escaping (FolderNode) -> Void) {
            self.tree = tree
            self.jump = jump
        }

        private func node(_ item: Any?) -> FolderNode { item as? FolderNode ?? tree.top }

        func loaded(_ node: FolderNode) {
            guard let outline else { return }
            if node === tree.top {
                outline.reloadData()
            } else {
                outline.reloadItem(node, reloadChildren: true)
            }
        }

        // MARK: Data

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            node(item).isDirectory ? node(item).shown.count : 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int,
                         ofItem item: Any?) -> Any {
            node(item).shown[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            let node = node(item)
            return node.isDirectory && node.note == nil
        }

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let item = notification.userInfo?["NSObject"] as? FolderNode else { return }
            tree.load(item)
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            node(item).note == nil
        }

        // MARK: Cells

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                         item: Any) -> NSView? {
            let node = node(item)
            let column = Column(rawValue: tableColumn?.identifier.rawValue ?? "") ?? .name
            if let note = node.note {
                return column == .name ? noteCell(note) : nil
            }
            switch column {
            case .name:
                return nameCell(node, in: outlineView)
            case .size:
                return textCell(node.size.map(ListingReport.bytes) ?? "",
                                font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                                alignment: .right)
            case .modified:
                return textCell(node.modified.map(ListingReport.when) ?? "",
                                font: .systemFont(ofSize: 11), alignment: .left)
            }
        }

        private func nameCell(_ node: FolderNode, in outline: NSOutlineView) -> NSView {
            let id = NSUserInterfaceItemIdentifier("name")
            let cell = outline.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
                ?? makeNameCell(id)
            let icon = NSWorkspace.shared.icon(forFile: node.url.path)
            icon.size = NSSize(width: 16, height: 16)
            cell.imageView?.image = icon
            cell.textField?.stringValue = node.name
            cell.toolTip = node.url.path
            return cell
        }

        private func makeNameCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.font = .systemFont(ofSize: 13)
            for view in [image, text] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(view)
            }
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.imageView = image
            cell.textField = text
            return cell
        }

        private func textCell(_ value: String, font: NSFont,
                              alignment: NSTextAlignment) -> NSView {
            let text = NSTextField(labelWithString: value)
            text.font = font
            text.textColor = .secondaryLabelColor
            text.alignment = alignment
            text.lineBreakMode = .byClipping
            let cell = NSTableCellView()
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func noteCell(_ note: FolderNode.Note) -> NSView {
            let (words, colour): (String, NSColor) = switch note {
            case .reading: ("Reading\u{2026}", .secondaryLabelColor)
            case .empty: ("It is empty.", .secondaryLabelColor)
            case .omitted(let count):
                ("\(count) more item\(count == 1 ? "" : "s") not listed. "
                 + "A preview shows the first \(Listing.mostEntries).", .secondaryLabelColor)
            case .trouble(let trouble): (trouble, .systemOrange)
            }
            let text = NSTextField(labelWithString: words)
            text.font = NSFontManager.shared.convert(.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
            text.textColor = colour
            text.lineBreakMode = .byTruncatingTail
            let cell = NSTableCellView()
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        // MARK: Jump Here

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, outline.clickedRow >= 0,
                  let node = outline.item(atRow: outline.clickedRow) as? FolderNode,
                  node.note == nil else { return }
            let item = NSMenuItem(title: "Jump Here", action: #selector(jumpHere(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = node
            menu.addItem(item)
        }

        @objc private func jumpHere(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FolderNode else { return }
            jump(node)
        }
    }
}
