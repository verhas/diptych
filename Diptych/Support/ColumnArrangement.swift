import AppKit

/// A pane's columns arranged in its own header, as in Settings: dragged left
/// and right -- Name stays first -- and shown or hidden from the header's
/// right-click menu, every column listed in its order. Either is a change to
/// the settings, kept, and every pane follows.
///
/// SwiftUI's table lets no column be dragged: its header's own gestures for
/// that never start. So the drag is Diptych's -- ClickRouter hands over a
/// press on a header that turns into a drag -- and what it ends in is a
/// change to the settings, from which SwiftUI builds the columns again.
@MainActor
enum ColumnArrangement {

    private static let menuHandler = HeaderMenu()

    /// How far the mouse goes before a press on a header is a drag, not a
    /// click that sorts.
    private static let threshold: CGFloat = 4

    /// The column menu, for a right-click on a pane's header.
    /// The columns greyed are those with nothing in them in any of `rows`.
    static func showMenu(for event: NSEvent, in header: NSTableHeaderView, rows: [FileItem]) {
        menuHandler.empty = empty(in: rows)
        NSMenu.popUpContextMenu(menuHandler.menu, with: event, for: header)
    }

    /// How long the menu may spend reading files to find out what is empty.
    /// A column not settled by then is not greyed: grey says "nothing here",
    /// which is only said when it is known.
    static let patience: TimeInterval = 0.4

    /// The columns no row has a value in. What a hidden column would show is
    /// read here, from the file; a picture's or video's facts are cached, so
    /// a second menu asks the disk nothing.
    static func empty(in rows: [FileItem], until deadline: Date = Date() + patience)
        -> Set<FileColumn> {
        let items = rows.filter { !$0.isParent }
        let shown = Set(ConfigStore.shared.configuration.columns)
        // Every file has these.
        let always: Set<FileColumn> = [.name, .size, .kind, .modified, .created, .permissions,
                                       .owner, .group]
        var undecided = Set(FileColumn.allCases).subtracting(always)
        guard !items.isEmpty else { return undecided.union(always).subtracting([.name]) }
        func settle(_ column: FileColumn, _ has: (FileItem) -> Bool) {
            guard undecided.contains(column) else { return }
            for item in items where has(item) {
                undecided.remove(column)
                return
            }
        }
        settle(.fileExtension) { !$0.isDirectory && !($0.name as NSString).pathExtension.isEmpty }
        if shown.contains(.tags) { settle(.tags) { !$0.tags.isEmpty } }
        if shown.contains(.added) { settle(.added) { $0.added != .distantPast } }
        if shown.contains(.git) { settle(.git) { !$0.text(for: .git).isEmpty } }
        var empty = Set<FileColumn>()
        for column in [FileColumn.fileExtension, .tags, .added, .git]
            where undecided.contains(column) && (shown.contains(column) || column == .fileExtension) {
            empty.insert(column)
            undecided.remove(column)
        }
        // The hidden ones asked of the files, until the time is up; what is
        // not settled by then is not known, so not greyed.
        var left = undecided.filter(\.isMedia)
            .union(undecided.intersection([.tags, .added]))
        for item in items where !left.isEmpty {
            guard Date() < deadline else { return empty }
            if left.contains(.tags) || left.contains(.added) {
                let values = try? item.url.resourceValues(forKeys: [.tagNamesKey,
                                                                    .addedToDirectoryDateKey])
                if values?.tagNames?.isEmpty == false { left.remove(.tags) }
                if values?.addedToDirectoryDate != nil { left.remove(.added) }
            }
            guard !item.isDirectory, left.contains(where: \.isMedia),
                  let info = item.media ?? MediaCache.shared.info(for: item.url) else { continue }
            for column in left where column.isMedia && !info.text(for: column).isEmpty {
                left.remove(column)
            }
        }
        // Git hidden is not asked: it is not known here.
        return empty.union(left)
    }

    /// A press on a pane's header: when it becomes a drag of a column other
    /// than Name, the drag is followed here, to the mouse coming up, and
    /// true says it was spent. A click, or a press on a column's edge -- a
    /// resize -- is left to the header.
    static func drag(from event: NSEvent, in header: NSTableHeaderView) -> Bool {
        guard let window = header.window, let table = header.tableView else { return false }
        let columns = ConfigStore.shared.configuration.columns
        guard table.tableColumns.count == columns.count else { return false }
        let start = header.convert(event.locationInWindow, from: nil)
        let column = header.column(at: start)
        guard column > 0 else { return false }
        let rect = header.headerRect(ofColumn: column)
        guard start.x - rect.minX > threshold, rect.maxX - start.x > threshold else { return false }

        // Looked at, not taken, until it is a drag: a click's mouse-up stays
        // for the header, which sorts.
        while true {
            guard let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged],
                                              until: .distantFuture, inMode: .eventTracking,
                                              dequeue: false) else { return false }
            if next.type == .leftMouseUp { return false }
            _ = window.nextEvent(matching: [.leftMouseDragged], until: .distantFuture,
                                 inMode: .eventTracking, dequeue: true)
            if abs(header.convert(next.locationInWindow, from: nil).x - start.x) >= threshold {
                break
            }
        }

        // The header of the column, following the mouse; a line where it
        // will go.
        let picture = NSImageView(frame: rect)
        if let bitmap = header.bitmapImageRepForCachingDisplay(in: rect) {
            header.cacheDisplay(in: rect, to: bitmap)
            let image = NSImage(size: rect.size)
            image.addRepresentation(bitmap)
            picture.image = image
        }
        picture.alphaValue = 0.75
        picture.wantsLayer = true
        picture.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        header.addSubview(picture)
        let line = NSView(frame: NSRect(x: 0, y: 0, width: 2, height: header.bounds.height))
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        header.addSubview(line)
        defer {
            picture.removeFromSuperview()
            line.removeFromSuperview()
        }

        var target = column
        func follow(_ x: CGFloat) {
            picture.frame.origin.x = rect.minX + x - start.x
            target = place(for: x, in: header, columns: columns.count, from: column)
            let edge = target > column ? header.headerRect(ofColumn: target).maxX
                                       : header.headerRect(ofColumn: target).minX
            line.frame.origin.x = edge - 1
            line.isHidden = target == column
        }
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged],
                                          until: .distantFuture, inMode: .eventTracking,
                                          dequeue: true) {
            let x = header.convert(next.locationInWindow, from: nil).x
            follow(x)
            if next.type == .leftMouseUp { break }
            header.autoscroll(with: next)
        }

        guard target != column else { return true }
        var arranged = columns
        arranged.insert(arranged.remove(at: column), at: target)
        ConfigStore.shared.arrange(arranged)
        return true
    }

    /// Where a column dragged from `from` goes when the mouse is at `x`: the
    /// place of the column under it -- never Name's.
    static func place(for x: CGFloat, in header: NSTableHeaderView, columns: Int,
                      from: Int) -> Int {
        var under = header.column(at: NSPoint(x: x, y: header.bounds.midY))
        if under < 0 { under = x < header.headerRect(ofColumn: 1).minX ? 1 : columns - 1 }
        return min(max(under, 1), columns - 1)
    }

    /// The header's menu: every column in the settings' order, ticked when
    /// shown; Name cannot be hidden.
    final class HeaderMenu: NSObject, NSMenuDelegate {
        let menu = NSMenu()
        /// Columns with nothing to show in the pane: grey, still choosable.
        var empty: Set<FileColumn> = []

        override init() {
            super.init()
            menu.delegate = self
            menu.autoenablesItems = false
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let configuration = ConfigStore.shared.configuration
            let shown = configuration.columns
            // Those shown first, in their order, then the rest as Settings
            // lists them.
            let all = shown + configuration.columnOrder.filter { !shown.contains($0) }
            for column in all {
                let item = NSMenuItem(title: column.title, action: #selector(toggle(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = column.rawValue
                item.state = shown.contains(column) ? .on : .off
                item.isEnabled = column.isRemovable
                if column.isRemovable, empty.contains(column) {
                    item.attributedTitle = NSAttributedString(
                        string: column.title,
                        attributes: [.foregroundColor: NSColor.tertiaryLabelColor,
                                     .font: NSFont.menuFont(ofSize: 0)])
                    item.toolTip = "Nothing in this column in the pane now"
                }
                menu.addItem(item)
                if column == shown.last, shown.count < all.count { menu.addItem(.separator()) }
            }
        }

        @objc func toggle(_ item: NSMenuItem) {
            guard let raw = item.representedObject as? String,
                  let column = FileColumn(rawValue: raw) else { return }
            let show = item.state != .on
            MainActor.assumeIsolated {
                ConfigStore.shared.setEnabled(column, show)
            }
        }
    }
}
