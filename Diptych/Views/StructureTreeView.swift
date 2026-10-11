import AppKit

/// One row of the tree: a node and where it is.
final class TreeItem: NSObject {
    let path: [Int]
    let node: StructureNode
    /// Its place among its parent's children, for a name when it has none.
    let identity: String
    var children: [TreeItem] = []

    init(path: [Int], node: StructureNode, identity: String) {
        self.path = path
        self.node = node
        self.identity = identity
    }
}

/// Text Edit's tree: a JSON, XML or YAML file as an outline whose keys and
/// values can be edited in place, with nodes added, deleted, duplicated,
/// given another type and dragged elsewhere. Every change is a change to
/// the text -- `StructureEditor` works out which -- so Undo, saving and the
/// text view all see one file.
@MainActor
final class StructureTreeController: NSObject {

    weak var controller: TextEditController?
    let scrollView = NSScrollView()
    let outline = TreeOutlineView()
    /// Shown instead of the outline when the text cannot be read as a tree.
    let message = NSTextField(wrappingLabelWithString: "")
    let container = NSView()
    /// ⌘F in the tree.
    let findBar = TreeFindBar()
    private var scrollUnderBar: NSLayoutConstraint!
    private var scrollAtTop: NSLayoutConstraint!
    /// The rows that hold what the find bar has, in the order they are shown.
    private(set) var matches: [[Int]] = []

    private var root: StructureNode?
    /// The text's lines, for the line each row's node starts on.
    private var lines = LineIndex("")
    private(set) lazy var gutter = TreeLineGutter(scrollView: scrollView)
    /// The text area open on a value, while it is.
    private(set) var textArea: TreeTextArea?
    private var items: [TreeItem] = []
    private var editor: StructureEditor?
    private var format: TextFormat?
    /// Set while the tree changes the text, so that change does not rebuild
    /// it a second time.
    private var applying = false

    static let dragType = NSPasteboard.PasteboardType("dev.verhas.diptych.tree-node")

    /// Text Edit's size, zoomed with View ▸ Bigger Text.
    private var fontSize: CGFloat { CGFloat(controller?.style.fontSize ?? TextStyle.defaultFontSize) }

    enum Column: String {
        case key, type, value
    }

    override init() {
        super.init()
        for (column, title, width) in [(Column.key, "Key", 220.0), (.type, "Type", 90.0), (.value, "Value", 320.0)] {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = title
            tableColumn.width = width
            tableColumn.minWidth = 50
            outline.addTableColumn(tableColumn)
            if column == .key { outline.outlineTableColumn = tableColumn }
        }
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.allowsColumnReordering = false
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = false
        outline.style = .fullWidth
        outline.dataSource = self
        outline.delegate = self
        outline.tree = self
        outline.registerForDraggedTypes([Self.dragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.doubleAction = #selector(doubleClicked)
        outline.target = self
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        // The header's own: the Type column, on or off.
        let header = NSMenu()
        header.delegate = self
        outline.headerView?.menu = header

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // The text's line numbers, beside the rows, when the text has them.
        gutter.tree = self
        scrollView.hasVerticalRuler = true
        scrollView.verticalRulerView = gutter
        scrollView.rulersVisible = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        outline.postsFrameChangedNotifications = true
        for (name, object) in [(NSView.boundsDidChangeNotification, scrollView.contentView as NSView),
                               (NSView.frameDidChangeNotification, outline as NSView)] {
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.gutter.needsDisplay = true }
            }
        }

        message.alignment = .center
        message.textColor = .secondaryLabelColor
        message.isHidden = true
        container.addSubview(findBar)
        container.addSubview(scrollView)
        container.addSubview(message)
        findBar.isHidden = true
        findBar.onChange = { [weak self] _ in self?.findChanged() }
        findBar.onStep = { [weak self] forward in self?.findNext(forward: forward) }
        findBar.onClose = { [weak self] in self?.closeFind() }
        findBar.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        message.translatesAutoresizingMaskIntoConstraints = false
        scrollUnderBar = scrollView.topAnchor.constraint(equalTo: findBar.bottomAnchor)
        scrollAtTop = scrollView.topAnchor.constraint(equalTo: container.topAnchor)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: container.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollAtTop,
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            message.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])
    }

    // MARK: - Reading the text

    /// The text read again, what was open kept open and the selection kept.
    func reload(select wanted: [Int]? = nil) {
        guard let controller else { return }
        let format = controller.format
        self.format = format
        let text = controller.nsText
        let expanded = expandedIdentities()
        let selected = wanted ?? selectedItem?.path
        guard let format, StructureTree.supports(format),
              let root = StructureTree.parse(text, as: format) else {
            self.root = nil
            editor = nil
            items = []
            outline.reloadData()
            scrollView.isHidden = true
            message.isHidden = false
            if let format, StructureTree.supports(format) {
                let problem = StructuredText.analyse(text as String, as: format).problem
                if let problem {
                    message.stringValue = "The tree shows valid \(format.title) only.\n\n"
                        + "Line \(problem.line), column \(problem.column): \(problem.message)"
                } else if format == .yaml, let line = StructureTree.yamlStop(text) {
                    message.stringValue = "The tree reads one YAML document of mappings, sequences "
                        + "and values, without ? keys.\n\nLine \(line) is beyond that."
                } else {
                    message.stringValue = "The tree shows valid \(format.title) only."
                }
            } else {
                message.stringValue = "This file has no tree: only JSON, XML and YAML do."
            }
            return
        }
        scrollView.isHidden = false
        message.isHidden = true
        outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(Column.type.rawValue))?.isHidden =
            !controller.style.treeShowsTypes
        outline.rowHeight = (fontSize * 1.35).rounded() + 6
        self.root = root
        editor = StructureEditor(text: text, format: format, root: root, style: controller.style)
        items = build(root, path: [], identity: "")
        lines = LineIndex(text)
        gutter.updateThickness(lines: lines.count)
        outline.reloadData()
        restore(expanded)
        if let selected { select(selected, edit: nil) }
        if !findBar.isHidden { updateMatches() }
    }

    private func build(_ node: StructureNode, path: [Int], identity: String) -> [TreeItem] {
        node.children.enumerated().map { index, child in
            let name = child.key.map { "\(child.kind == .attribute ? "@" : "")\($0)" } ?? "#\(index)"
            let item = TreeItem(path: path + [index], node: child, identity: identity + "/" + name)
            item.children = build(child, path: path + [index], identity: item.identity)
            return item
        }
    }

    private func expandedIdentities() -> Set<String> {
        var open: Set<String> = []
        func walk(_ items: [TreeItem]) {
            for item in items where outline.isItemExpanded(item) {
                open.insert(item.identity)
                walk(item.children)
            }
        }
        walk(items)
        return open
    }

    private func restore(_ open: Set<String>) {
        func walk(_ items: [TreeItem], depth: Int) {
            for item in items where open.contains(item.identity) || (open.isEmpty && depth < 2) {
                outline.expandItem(item)
                walk(item.children, depth: depth + 1)
            }
        }
        walk(items, depth: 0)
    }

    func item(at path: [Int]) -> TreeItem? {
        var level = items
        var found: TreeItem?
        for index in path {
            guard index < level.count else { return found }
            found = level[index]
            level = level[index].children
        }
        return found
    }

    var selectedItem: TreeItem? {
        outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? TreeItem : nil
    }

    /// The row of `path` selected, opened up to and shown -- and, for a new
    /// one, its name or value ready to type.
    func select(_ path: [Int], edit column: Column?) {
        guard let item = item(at: path) else { return }
        var parents: [TreeItem] = []
        var level = items
        for index in path.dropLast() where index < level.count {
            parents.append(level[index])
            level = level[index].children
        }
        for parent in parents { outline.expandItem(parent) }
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        if let column { beginEditing(item, column) }
    }

    func showLineNumbers(_ on: Bool) {
        scrollView.rulersVisible = on
        gutter.needsDisplay = true
    }

    /// The line, one-based, the node starts on: where its first character
    /// is, past the line break a text node may begin with.
    func line(of item: TreeItem) -> Int? {
        let range = item.node.range
        guard let controller, range.location < controller.nsText.length || range.length == 0 else { return nil }
        let text = controller.nsText
        var at = range.location
        let end = min(NSMaxRange(range), text.length)
        while at < end, let scalar = UnicodeScalar(text.character(at: at)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            at += 1
        }
        return lines.line(containing: min(at == end ? range.location : at, text.length)) + 1
    }

    /// A name or a value to type: in the row, or, for a value over several
    /// lines or the DOCTYPE, in a text area.
    func beginEditing(_ item: TreeItem, _ column: Column) {
        let row = outline.row(forItem: item)
        guard row >= 0,
              let index = outline.tableColumns.firstIndex(where: { $0.identifier.rawValue == column.rawValue })
        else { return }
        if column == .value, needsTextArea(item.node) {
            editInTextArea(item)
        } else {
            outline.editColumn(index, row: row, with: nil, select: true)
        }
    }

    func needsTextArea(_ node: StructureNode) -> Bool {
        [.declaration, .instruction].contains(node.kind) || (node.value ?? "").contains(where: \.isNewline)
    }

    /// The value in a text area under its row: Done, Command-Return or a
    /// click elsewhere keeps it, Escape leaves it.
    func editInTextArea(_ item: TreeItem) {
        guard editor?.canEditValue(item.path) == true else { NSSound.beep(); return }
        let row = outline.row(forItem: item)
        guard row >= 0, let column = outline.tableColumns.firstIndex(where: { $0.identifier.rawValue == Column.value.rawValue })
        else { return }
        // A row edit open on it shows the value's one line, ↩ for its
        // breaks: dropped, not kept, as the area takes the keyboard.
        if outline.editedRow == row { outline.abortEditing() }
        let path = item.path
        let area = TreeTextArea(text: item.node.value ?? "", font: EditorFont.text(fontSize)) { [weak self] text in
            guard let self, let item = self.item(at: path) else { return }
            self.setValue(item, to: text)
        }
        textArea = area
        area.show(relativeTo: outline.frameOfCell(atColumn: column, row: row), of: outline)
    }

    /// The deepest node the text's caret is in.
    func path(containing location: Int) -> [Int]? {
        guard let root else { return nil }
        var path: [Int] = []
        var node = root
        while let index = node.children.firstIndex(where: {
            location >= $0.range.location && location <= NSMaxRange($0.range)
        }) {
            path.append(index)
            node = node.children[index]
        }
        return path.isEmpty ? nil : path
    }

    /// ⌘G: the node the line is in selected and scrolled to -- the
    /// innermost one that starts on it or holds it.
    func reveal(line: Int) {
        guard let controller, !items.isEmpty else { return NSSound.beep() }
        let text = controller.nsText
        let index = min(max(line - 1, 0), lines.count - 1)
        var at = lines.starts[index]
        let end = NSMaxRange(lines.contentRange(ofLine: index))
        while at < end, let scalar = UnicodeScalar(text.character(at: at)),
              CharacterSet.whitespaces.contains(scalar) {
            at += 1
        }
        // The node that starts there rather than one that ends there.
        var path: [Int] = []
        var node = root
        while let children = node?.children, let index = children.firstIndex(where: {
            at >= $0.range.location && at < NSMaxRange($0.range)
        }) ?? children.firstIndex(where: { at >= $0.range.location && at <= NSMaxRange($0.range) }) {
            path.append(index)
            node = children[index]
        }
        select(path.isEmpty ? [0] : path, edit: nil)
    }

    // MARK: - Finding

    func showFind() {
        guard !scrollView.isHidden else { return NSSound.beep() }
        if findBar.isHidden {
            findBar.isHidden = false
            scrollAtTop.isActive = false
            scrollUnderBar.isActive = true
        }
        container.window?.makeFirstResponder(findBar.field)
        findBar.field.selectText(nil)
        if !findBar.field.stringValue.isEmpty { updateMatches() }
    }

    func closeFind() {
        findBar.isHidden = true
        scrollUnderBar.isActive = false
        scrollAtTop.isActive = true
        matches = []
        container.window?.makeFirstResponder(outline)
    }

    /// Typed in the find bar: the first match from the selected row on.
    func findChanged() {
        updateMatches()
        guard !matches.isEmpty else { return }
        let from = selectedItem.map { order(of: $0.path) } ?? 0
        select(matches.first { order(of: $0) >= from } ?? matches[0], edit: nil)
        updateCount()
    }

    /// Return and Shift-Return: the next match, or the one before, round
    /// from the end to the start.
    func findNext(forward: Bool) {
        guard !matches.isEmpty else { return NSSound.beep() }
        let here = selectedItem.map { order(of: $0.path) } ?? -1
        let next = forward
            ? matches.first { order(of: $0) > here } ?? matches[0]
            : matches.last { order(of: $0) < here } ?? matches[matches.count - 1]
        select(next, edit: nil)
        updateCount()
    }

    /// Every node, folded away or not, whose name or value holds the text.
    private func updateMatches() {
        let wanted = findBar.field.stringValue
        matches = []
        orders = [:]
        var counter = 0
        func walk(_ level: [TreeItem]) {
            for item in level {
                orders[item.path] = counter
                counter += 1
                if !wanted.isEmpty, [title(of: item), item.node.value ?? ""].contains(where: {
                    $0.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }) {
                    matches.append(item.path)
                }
                walk(item.children)
            }
        }
        walk(items)
        updateCount()
    }

    private var orders: [[Int]: Int] = [:]

    /// Where a node is when the whole tree is open, top to bottom.
    private func order(of path: [Int]) -> Int { orders[path] ?? 0 }

    private func updateCount() {
        if findBar.field.stringValue.isEmpty {
            findBar.count.stringValue = ""
        } else if matches.isEmpty {
            findBar.count.stringValue = "Not found"
        } else if let path = selectedItem?.path, let index = matches.firstIndex(of: path) {
            findBar.count.stringValue = "\(index + 1) of \(matches.count)"
        } else {
            findBar.count.stringValue = matches.count == 1 ? "1 match" : "\(matches.count) matches"
        }
    }

    // MARK: - Changing the text

    /// A tree edit applied to the text, then the tree read again.
    @discardableResult
    func apply(_ edit: TreeEdit?, named name: String, edit column: Column? = nil) -> Bool {
        guard let edit, let controller, let format else {
            NSSound.beep()
            return false
        }
        // What the tree cannot read again is not made: a DOCTYPE typed with
        // its bracket missing, a value that breaks the file.
        let after = NSMutableString(string: controller.nsText)
        for change in edit.changes.sorted(by: { $0.range.location > $1.range.location }) {
            after.replaceCharacters(in: change.range, with: change.text)
        }
        guard StructureTree.parse(after, as: format) != nil else {
            NSSound.beep()
            reload()
            return false
        }
        applying = true
        let changed = controller.change(edit.changes, select: nil, named: name)
        applying = false
        reload(select: edit.select)
        if let path = edit.select, column != nil { select(path, edit: column) }
        return changed
    }

    /// The text changed outside the tree -- typing, Undo.
    func textChanged() {
        guard !applying, !container.isHidden else { return }
        reload()
    }

    /// In XML a name is also what a node is: `@` before an element's name
    /// makes it an attribute, and an attribute's name without it an element.
    func rename(_ item: TreeItem, to name: String) {
        if format == .xml {
            let attribute = name.hasPrefix("@")
            let bare = attribute ? String(name.dropFirst()) : name
            if attribute != (item.node.kind == .attribute) {
                convert(item, named: bare)
                return
            }
            guard bare != item.node.key else { return }
            apply(editor?.rename(item.path, to: bare), named: "Rename")
            return
        }
        guard name != item.node.key else { return }
        apply(editor?.rename(item.path, to: name), named: "Rename")
    }

    /// An element made an attribute, or an attribute an element.
    func convert(_ item: TreeItem, named name: String? = nil) {
        guard let conversion = editor?.conversion(item.path, named: name),
              relocate(conversion.removal, conversion.fragment, into: conversion.parent, at: conversion.index,
                       named: item.node.kind == .attribute ? "Make Element" : "Make Attribute") else {
            NSSound.beep()
            reloadRow(of: item)
            return
        }
    }

    /// A name typed that came to nothing: the row as it was.
    private func reloadRow(of item: TreeItem) {
        let row = outline.row(forItem: item)
        if row >= 0 {
            outline.reloadData(forRowIndexes: IndexSet(integer: row),
                               columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns))
        }
    }

    func setValue(_ item: TreeItem, to value: String) {
        guard value != item.node.value else { return }
        apply(editor?.setValue(item.path, to: value), named: "Change Value")
    }

    func add(_ kind: StructureNode.Kind, into parent: [Int], at index: Int) {
        guard let editor else { return }
        let keyed = needsKey(in: parent, kind: kind)
        let edit = editor.insert(.new(kind, key: defaultKey(for: kind), value: defaultValue(for: kind)),
                                 into: parent, at: index)
        let column: Column? = keyed ? .key : ([.object, .array, .mapping, .sequence, .null].contains(kind) ? nil : .value)
        apply(edit, named: "Add \(kind.title)", edit: column)
    }

    /// What Add Child (⌃⌘N) and Add After (⌘↩) add without asking: what is
    /// next to it already, or what such a parent mostly holds.
    func defaultKind(in kinds: [StructureNode.Kind], like sibling: StructureNode?) -> StructureNode.Kind? {
        if let kind = sibling?.kind, kinds.contains(kind), ![.text, .comment].contains(kind) { return kind }
        for preferred in [StructureNode.Kind.element, .string, .scalar] where kinds.contains(preferred) {
            return preferred
        }
        return kinds.first
    }

    /// The kinds Add After offers next to `node`: an attribute among
    /// attributes, anything else among the content.
    func kindsAfter(_ node: StructureNode, in parent: [Int]) -> [StructureNode.Kind] {
        let kinds = editor?.addable(into: parent) ?? []
        if node.kind == .attribute { return kinds.filter { $0 == .attribute } }
        return format == .xml ? kinds.filter { $0 != .attribute } : kinds
    }

    /// ⌃⌘N: a child at the end of the selected node -- or of the root, when
    /// nothing is selected.
    func addChild() {
        guard let editor else { return NSSound.beep() }
        let item = selectedItem
        let parent = item?.path ?? []
        guard let node = editor.find(parent) else { return NSSound.beep() }
        let content = node.kind == .element ? Array(node.content) : node.children
        guard let kind = defaultKind(in: editor.addable(into: parent), like: content.last)
        else { return NSSound.beep() }
        add(kind, into: parent, at: node.children.count)
    }

    /// ⌘↩: one more like the selected node, after it.
    func addAfter() {
        guard let item = selectedItem, let index = item.path.last else { return addChild() }
        let parent = Array(item.path.dropLast())
        guard let kind = defaultKind(in: kindsAfter(item.node, in: parent), like: item.node)
        else { return NSSound.beep() }
        add(kind, into: parent, at: index + 1)
    }

    private func needsKey(in parent: [Int], kind: StructureNode.Kind) -> Bool {
        guard let node = editor?.find(parent) else { return false }
        return [.object, .mapping].contains(node.kind) || kind == .element || kind == .attribute
    }

    private func defaultKey(for kind: StructureNode.Kind) -> String? {
        switch kind {
        case .element: "element"
        case .attribute: "name"
        default: "key"
        }
    }

    private func defaultValue(for kind: StructureNode.Kind) -> String? {
        switch kind {
        case .text: "text"
        case .number: "0"
        case .boolean: "false"
        default: nil
        }
    }

    func delete(_ item: TreeItem) {
        apply(editor?.delete(item.path), named: "Delete")
    }

    func duplicate(_ item: TreeItem) {
        guard let editor, let copied = editor.copy(item.path), let index = item.path.last else { return }
        apply(editor.insert(.copy(copied), into: Array(item.path.dropLast()), at: index + 1), named: "Duplicate")
    }

    func changeType(_ item: TreeItem, to kind: StructureNode.Kind) {
        apply(editor?.changeType(item.path, to: kind), named: "Change Type")
    }

    /// Out of its place, the text read again, into the new one: one step of Undo.
    func move(_ path: [Int], into parent: [Int], at index: Int) -> Bool {
        guard let editor, let copied = editor.copy(path), let removal = editor.delete(path) else { return false }
        let (target, at) = TreeMoves.adjust(parent: parent, index: index, afterRemoving: path)
        return relocate(removal, .copy(copied), into: target, at: at, named: "Move")
    }

    /// Shift-Command-Up and -Down, or Command-Up and -Down: the selected node
    /// and all it holds to the next place in the structure -- past the node
    /// next to it, into it at that end when it is an open container, or out
    /// of its own container when it is at the end of it.
    func moveSelected(up: Bool) {
        guard controller?.textView.isEditable == true, let item = selectedItem,
              let target = structuralMove(of: item, up: up),
              move(item.path, into: target.parent, at: target.index)
        else { NSSound.beep(); return }
    }

    /// Where `moveSelected` takes `item`, counted in the text as it is.
    func structuralMove(of item: TreeItem, up: Bool) -> (parent: [Int], index: Int)? {
        guard let editor, let index = item.path.last else { return nil }
        let parentPath = Array(item.path.dropLast())
        guard let parent = editor.find(parentPath) else { return nil }
        var places: [(parent: [Int], index: Int)] = []
        let neighbour = up ? index - 1 : index + 1
        if parent.children.indices.contains(neighbour) {
            let path = parentPath + [neighbour]
            let next = parent.children[neighbour]
            // Into the open container next to it: at its end going up, at its
            // start -- after an element's attributes -- going down.
            if item.node.kind != .attribute, next.isContainer,
               let row = self.item(at: path), row.path == path, outline.isItemExpanded(row) {
                places.append((path, up ? next.children.count : next.attributeCount))
            }
            places.append((parentPath, up ? neighbour : neighbour + 1))
        }
        // Out of its container, before or after it: at its end, or where the
        // node next to it is one it cannot pass -- an element past an attribute.
        if let parentIndex = parentPath.last {
            places.append((Array(parentPath.dropLast()), up ? parentIndex : parentIndex + 1))
        }
        return places.first { editor.canMove(item.path, into: $0.parent, at: $0.index) }
    }

    /// A node taken out, the text read again, and `fragment` put in at
    /// `index` of `parent` -- counted in the text without the node.
    private func relocate(_ removal: TreeEdit, _ fragment: TreeFragment, into parent: [Int], at index: Int,
                          named name: String) -> Bool {
        guard let controller, let format else { return false }
        // Worked out on a copy first, so that nothing is changed if the
        // second half cannot be done.
        let after = NSMutableString(string: controller.nsText)
        for change in removal.changes.sorted(by: { $0.range.location > $1.range.location }) {
            after.replaceCharacters(in: change.range, with: change.text)
        }
        guard let reread = StructureTree.parse(after, as: format) else { return false }
        let next = StructureEditor(text: after, format: format, root: reread, style: controller.style)
        guard let insertion = next.insert(fragment, into: parent, at: index) else { return false }
        let undo = controller.textView.undoManager
        undo?.beginUndoGrouping()
        applying = true
        controller.change(removal.changes, select: nil, named: name)
        controller.change(insertion.changes, select: nil, named: name)
        applying = false
        undo?.setActionName(name)
        undo?.endUndoGrouping()
        reload(select: insertion.select)
        return true
    }

    // MARK: - Actions

    @objc private func doubleClicked() {
        let row = outline.clickedRow
        let column = outline.clickedColumn
        guard row >= 0, column >= 0, let item = outline.item(atRow: row) as? TreeItem else { return }
        let id = Column(rawValue: outline.tableColumns[column].identifier.rawValue)
        if let id, id == .key && editor?.canRename(item.path) == true
            || id == .value && editor?.canEditValue(item.path) == true {
            beginEditing(item, id)
        } else if item.node.isContainer {
            if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
        }
    }

    /// Return: the value to type, or the name where there is no value.
    func editSelected() {
        guard let item = selectedItem, let editor else { return }
        let row = outline.selectedRow
        _ = row
        if editor.canEditValue(item.path) {
            beginEditing(item, .value)
        } else if editor.canRename(item.path) {
            beginEditing(item, .key)
        } else {
            NSSound.beep()
        }
    }

    func deleteSelected() {
        guard let item = selectedItem, editor?.canDelete(item.path) == true else {
            NSSound.beep()
            return
        }
        delete(item)
    }

    @objc private func cellEdited(_ sender: NSTextField) {
        let row = outline.row(for: sender)
        let column = outline.column(for: sender)
        guard row >= 0, column >= 0, let item = outline.item(atRow: row) as? TreeItem else { return }
        let started = (sender as? KeyField)?.editingText ?? (column == 0 ? title(of: item) : item.node.value)
        let isValue = Column(rawValue: outline.tableColumns[column].identifier.rawValue) == .value
        // Left as it was: nothing to change, and the row drawn afresh. A
        // value over several lines is the text area's alone -- the row has
        // only its one line, ↩ for the breaks, and that is never written.
        guard sender.stringValue != started,
              !(isValue && needsTextArea(item.node)),
              !(isValue && sender.stringValue == Self.oneLine(item.node.value ?? ""))
        else {
            DispatchQueue.main.async { [weak self] in self?.reloadRow(of: item) }
            return
        }
        switch Column(rawValue: outline.tableColumns[column].identifier.rawValue) {
        case .key: rename(item, to: sender.stringValue)
        case .value: setValue(item, to: sender.stringValue)
        default: break
        }
    }

    @objc private func menuAdd(_ sender: NSMenuItem) {
        guard let (kind, parent, index) = sender.representedObject as? (StructureNode.Kind, [Int], Int) else { return }
        add(kind, into: parent, at: index)
    }

    @objc private func menuConvert(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? TreeItem { convert(item) }
    }

    @objc private func menuTextArea(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? TreeItem { editInTextArea(item) }
    }

    @objc private func menuCopyPath(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TreeItem else { return }
        copyPath(of: item)
    }

    /// The node's XPath, JSON path or YAML path on the clipboard.
    @discardableResult
    func copyPath(of item: TreeItem) -> String? {
        guard let editor, let format, let path = StructurePath.path(item.path, in: editor.root, format: format)
        else { return nil }
        let board = controller?.pasteboard ?? .general
        board.clearContents()
        board.setString(path, forType: .string)
        return path
    }

    @objc private func menuShowTypes(_ sender: NSMenuItem) {
        ConfigStore.shared.configuration.textStyle.treeShowsTypes.toggle()
    }

    @objc private func menuDuplicate(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? TreeItem { duplicate(item) }
    }

    @objc private func menuDelete(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? TreeItem { delete(item) }
    }

    @objc private func menuType(_ sender: NSMenuItem) {
        guard let (item, kind) = sender.representedObject as? (TreeItem, StructureNode.Kind) else { return }
        changeType(item, to: kind)
    }

    @objc private func menuShowInText(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TreeItem else { return }
        controller?.showInText(item.node.keyRange?.location ?? item.node.valueRange?.location
                               ?? item.node.range.location)
    }

    @objc private func menuExpandAll(_ sender: NSMenuItem) { outline.expandItem(nil, expandChildren: true) }
    @objc private func menuCollapseAll(_ sender: NSMenuItem) { outline.collapseItem(nil, collapseChildren: true) }

    // MARK: - Showing

    func title(of item: TreeItem) -> String {
        let node = item.node
        if let key = node.key { return key }
        switch node.kind {
        case .text: return "#text"
        case .comment: return "#comment"
        case .cdata: return "#cdata"
        case .instruction: return "<?…?>"
        case .declaration: return "<!…>"
        default:
            return item.path.count == 1 && format != .xml ? "Root" : "Item \(item.path.last ?? 0)"
        }
    }

    func type(of node: StructureNode) -> String {
        guard node.kind == .scalar else { return node.kind.title }
        guard node.quote == nil, let value = node.value else { return "String" }
        if ["true", "false", "yes", "no", "True", "False", "on", "off"].contains(value) { return "Boolean" }
        if ["", "~", "null", "Null", "NULL"].contains(value) { return "Null" }
        if Double(value) != nil { return "Number" }
        return "String"
    }

    func summary(of node: StructureNode) -> String? {
        switch node.kind {
        case .object, .mapping, .dictionary:
            return node.children.count == 1 ? "1 key" : "\(node.children.count) keys"
        case .array, .sequence:
            return node.children.count == 1 ? "1 item" : "\(node.children.count) items"
        case .element where !node.textOnly:
            let content = node.content.count
            return content == 0 ? nil : content == 1 ? "1 child" : "\(content) children"
        case .instruction, .declaration:
            return node.value
        default:
            return nil
        }
    }
}

// MARK: - Data source and delegate

extension StructureTreeController: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? TreeItem)?.children.count ?? items.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? TreeItem)?.children[index] ?? items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? TreeItem)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? TreeItem, let tableColumn,
              let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell." + column.rawValue)
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let field = KeyField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            // A comment or a value over several lines shows its first: a
            // row is one line high.
            field.usesSingleLineMode = true
            field.maximumNumberOfLines = 1
            field.cell?.truncatesLastVisibleLine = true
            field.translatesAutoresizingMaskIntoConstraints = false
            field.target = self
            field.action = #selector(cellEdited(_:))
            // Clicking elsewhere keeps what was typed, as Return does; it
            // was left in the row unsaved, drawn as if still being edited.
            field.cell?.sendsActionOnEndEditing = true
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        guard let field = cell.textField as? KeyField else { return cell }
        let node = item.node
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = .labelColor
        field.editingText = nil
        cell.toolTip = nil
        switch column {
        case .key:
            field.isEditable = editor?.canRename(item.path) == true
            if node.key == nil { field.textColor = .secondaryLabelColor }
            if node.kind == .element { field.textColor = .systemBlue }
            if node.kind == .attribute {
                field.attributedStringValue = Self.attributeTitle(title(of: item), font: field.font!)
                field.editingText = "@" + title(of: item)
            } else {
                field.stringValue = title(of: item)
            }
            cell.toolTip = type(of: node)
        case .type:
            field.stringValue = type(of: node)
            field.isEditable = false
            field.textColor = .secondaryLabelColor
        case .value:
            if let summary = summary(of: node) {
                field.stringValue = Self.oneLine(summary)
                field.textColor = .secondaryLabelColor
            } else {
                let value = node.value ?? ""
                field.stringValue = Self.oneLine(value)
                // Edited as it is, line breaks and all.
                if field.stringValue != value { field.editingText = value }
                switch type(of: node) {
                case "Number", "Integer", "Real": field.textColor = .systemBlue
                case "Boolean", "Null": field.textColor = .systemPink
                case "Date", "Data": field.textColor = .systemTeal
                default: break
                }
            }
            // Over several lines it is edited in the text area only: a row
            // holds one line, and a field in it could not show the rest.
            field.isEditable = editor?.canEditValue(item.path) == true && !needsTextArea(node)
            field.font = EditorFont.text(fontSize)
        }
        return cell
    }

    /// A row is one line: the breaks of a longer value shown as ↩.
    static func oneLine(_ text: String) -> String {
        guard text.contains(where: \.isNewline) else { return text }
        return text.replacingOccurrences(of: #"[ \t]*\R\s*"#, with: " \u{21A9} ", options: .regularExpression)
    }

    /// An attribute's name after an orange `@` badge, set apart from the
    /// name as an icon is -- so an attribute is told from an element at a
    /// glance with the Type column hidden.
    static func attributeTitle(_ name: String, font: NSFont) -> NSAttributedString {
        let title = NSMutableAttributedString()
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemOrange]))
        if let image = NSImage(systemSymbolName: "at.circle.fill", accessibilityDescription: "attribute")?
            .withSymbolConfiguration(configuration) {
            let badge = NSTextAttachment()
            badge.image = image
            badge.bounds = NSRect(x: 0, y: font.descender + 1, width: image.size.width, height: image.size.height)
            title.append(NSAttributedString(attachment: badge))
            title.append(NSAttributedString(string: "\u{2009}", attributes: [.font: font]))
        } else {
            title.append(NSAttributedString(string: "@", attributes: [.font: font,
                                                                     .foregroundColor: NSColor.secondaryLabelColor]))
        }
        title.append(NSAttributedString(string: name, attributes: [.font: font,
                                                                  .foregroundColor: NSColor.systemOrange]))
        return title
    }

    // MARK: Dragging

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let item = item as? TreeItem, editor?.canDelete(item.path) == true else { return nil }
        let board = NSPasteboardItem()
        board.setString(item.path.map(String.init).joined(separator: "."), forType: Self.dragType)
        return board
    }

    private func draggedPath(_ info: NSDraggingInfo) -> [Int]? {
        guard info.draggingSource as? NSOutlineView === outline,
              let text = info.draggingPasteboard.string(forType: Self.dragType) else { return nil }
        return text.split(separator: ".").compactMap { Int($0) }
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let editor, let path = draggedPath(info) else { return [] }
        var parent = (item as? TreeItem)?.path ?? []
        var at = index
        if index == NSOutlineViewDropOnItemIndex {
            // Onto a node: into it at its end, or after it when it holds nothing.
            guard let target = item as? TreeItem else { return [] }
            if target.node.isContainer, !editor.addable(into: target.path).isEmpty {
                at = dropIndex(of: path, onto: target)
            } else {
                parent = Array(target.path.dropLast())
                at = (target.path.last ?? 0) + 1
                outlineView.setDropItem(self.item(at: parent), dropChildIndex: at)
            }
        }
        guard editor.canMove(path, into: parent, at: at) else { return [] }
        if Array(path.dropLast()) == parent, at == path.last || at == (path.last ?? 0) + 1 { return [] }
        return .move
    }

    /// Dropped onto a node: at its end -- an attribute after its attributes.
    private func dropIndex(of path: [Int], onto target: TreeItem) -> Int {
        editor?.find(path)?.kind == .attribute ? target.node.attributeCount : target.node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?,
                     childIndex index: Int) -> Bool {
        guard let path = draggedPath(info) else { return false }
        var parent = (item as? TreeItem)?.path ?? []
        var at = index
        if index == NSOutlineViewDropOnItemIndex, let target = item as? TreeItem {
            at = dropIndex(of: path, onto: target)
            parent = target.path
        }
        return move(path, into: parent, at: at)
    }
}

// MARK: - The context menu

extension StructureTreeController: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === outline.headerView?.menu {
            let shown = controller?.style.treeShowsTypes == true
            let item = NSMenuItem(title: shown ? "Hide Type Column" : "Show Type Column",
                                  action: #selector(menuShowTypes(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return
        }
        guard let editor else { return }
        let row = outline.clickedRow
        let item = row >= 0 ? outline.item(atRow: row) as? TreeItem : nil
        if item != nil, row != outline.selectedRow {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let path = item?.path ?? []

        /// The kind the shortcut adds shows the shortcut.
        func submenu(_ title: String, kinds: [StructureNode.Kind], parent: [Int], index: Int,
                     shortcut: (key: String, modifiers: NSEvent.ModifierFlags, kind: StructureNode.Kind?)) {
            guard !kinds.isEmpty else { return }
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for kind in kinds {
                let choice = NSMenuItem(title: kind.title, action: #selector(menuAdd(_:)), keyEquivalent: "")
                choice.target = self
                choice.representedObject = (kind, parent, index)
                if kind == shortcut.kind {
                    choice.keyEquivalent = shortcut.key
                    choice.keyEquivalentModifierMask = shortcut.modifiers
                }
                sub.addItem(choice)
            }
            entry.submenu = sub
            menu.addItem(entry)
        }

        let node = editor.find(path)
        if let node, item == nil || item?.node.isContainer == true {
            let kinds = editor.addable(into: path)
            let content = node.kind == .element ? Array(node.content) : node.children
            submenu(item == nil ? "Add" : "Add Child", kinds: kinds, parent: path, index: node.children.count,
                    shortcut: ("n", [.command, .control], defaultKind(in: kinds, like: content.last)))
        }
        if let item, let index = path.last {
            let parent = Array(path.dropLast())
            let kinds = kindsAfter(item.node, in: parent)
            submenu("Add After", kinds: kinds, parent: parent, index: index + 1,
                    shortcut: ("\r", .command, defaultKind(in: kinds, like: item.node)))
        }
        guard let item else {
            menu.addItem(.separator())
            addShowTypes(to: menu)
            addFormatItems(to: menu)
            return
        }
        if editor.canMakeAttribute(path) || editor.canMakeElement(path) {
            let title = item.node.kind == .attribute ? "Make Element" : "Make Attribute"
            let convert = NSMenuItem(title: title, action: #selector(menuConvert(_:)), keyEquivalent: "")
            convert.target = self
            convert.representedObject = item
            menu.addItem(convert)
        }
        let types = editor.types(for: path)
        if !types.isEmpty {
            let entry = NSMenuItem(title: "Change Type", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for kind in types {
                let choice = NSMenuItem(title: kind.title, action: #selector(menuType(_:)), keyEquivalent: "")
                choice.target = self
                choice.representedObject = (item, kind)
                choice.state = kind == item.node.kind ? .on : .off
                sub.addItem(choice)
            }
            entry.submenu = sub
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        if editor.canDelete(path) {
            let duplicate = NSMenuItem(title: "Duplicate", action: #selector(menuDuplicate(_:)), keyEquivalent: "")
            duplicate.target = self
            duplicate.representedObject = item
            menu.addItem(duplicate)
            let delete = NSMenuItem(title: "Delete", action: #selector(menuDelete(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = item
            menu.addItem(delete)
            menu.addItem(.separator())
        }
        if editor.canEditValue(item.path) {
            let area = NSMenuItem(title: "Edit in Text Area…", action: #selector(menuTextArea(_:)), keyEquivalent: "")
            area.target = self
            area.representedObject = item
            menu.addItem(area)
        }
        if let format, StructurePath.path(item.path, in: editor.root, format: format) != nil {
            let copy = NSMenuItem(title: StructurePath.title(for: format), action: #selector(menuCopyPath(_:)),
                                  keyEquivalent: "")
            copy.target = self
            copy.representedObject = item
            menu.addItem(copy)
        }
        let show = NSMenuItem(title: "Show in Text", action: #selector(menuShowInText(_:)), keyEquivalent: "")
        show.target = self
        show.representedObject = item
        menu.addItem(show)
        let expand = NSMenuItem(title: "Expand All", action: #selector(menuExpandAll(_:)), keyEquivalent: "")
        expand.target = self
        menu.addItem(expand)
        let collapse = NSMenuItem(title: "Collapse All", action: #selector(menuCollapseAll(_:)), keyEquivalent: "")
        collapse.target = self
        menu.addItem(collapse)
        menu.addItem(.separator())
        addShowTypes(to: menu)
        addFormatItems(to: menu)
    }

    /// The Format menu's, as in the text.
    private func addFormatItems(to menu: NSMenu) {
        guard let format = controller?.formatMenuItems(), !format.isEmpty else { return }
        menu.addItem(.separator())
        format.forEach(menu.addItem)
    }

    private func addShowTypes(to menu: NSMenu) {
        let types = NSMenuItem(title: "Show Type Column", action: #selector(menuShowTypes(_:)), keyEquivalent: "")
        types.target = self
        types.state = controller?.style.treeShowsTypes == true ? .on : .off
        menu.addItem(types)
    }
}

/// A cell's text. An attribute shows its `@` as a badge, and is edited as
/// `@name`: what is typed there says whether it stays an attribute.
final class KeyField: NSTextField {
    /// What editing starts from, when it is not what is shown.
    var editingText: String?
    private var shown: NSAttributedString?

    override func becomeFirstResponder() -> Bool {
        if let editingText, isEditable {
            shown = attributedStringValue
            stringValue = editingText
        }
        return super.becomeFirstResponder()
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        restore()
    }

    override func abortEditing() -> Bool {
        let aborted = super.abortEditing()
        restore()
        return aborted
    }

    /// The badge back, when the edit left the row as it was.
    private func restore() {
        if let shown, let editingText, stringValue == editingText { attributedStringValue = shown }
        shown = nil
    }
}

/// The responder actions behind Edit ▸ Undo and Redo, which AppKit's text
/// views and windows answer -- named, so the menu can send them by selector.
@MainActor @objc protocol UndoActions {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}

/// The outline: Delete deletes, Return edits, and Undo is the text's.
final class TreeOutlineView: NSOutlineView, NSMenuItemValidation, UndoActions {
    weak var tree: StructureTreeController?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = modifiers.subtracting([.function, .numericPad]).isEmpty
        if plain, event.keyCode == 51 || event.keyCode == 117 {
            MainActor.assumeIsolated { tree?.deleteSelected() }
        } else if plain, event.keyCode == 36 || event.keyCode == 76 {
            MainActor.assumeIsolated { tree?.editSelected() }
        } else if [126, 125].contains(event.keyCode),
                  modifiers.subtracting([.function, .numericPad, .shift]) == .command {
            // Command-Up and -Down, with Shift or without: the node moves.
            MainActor.assumeIsolated { tree?.moveSelected(up: event.keyCode == 126) }
        } else {
            super.keyDown(with: event)
        }
    }

    private var textUndo: UndoManager? {
        MainActor.assumeIsolated { tree?.controller?.textView.undoManager }
    }

    @objc func undo(_ sender: Any?) { textUndo?.undo() }
    @objc func redo(_ sender: Any?) { textUndo?.redo() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(undo(_:)) { return textUndo?.canUndo ?? false }
        if item.action == #selector(redo(_:)) { return textUndo?.canRedo ?? false }
        return true
    }
}
