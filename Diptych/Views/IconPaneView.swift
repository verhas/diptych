import AppKit
import SwiftUI

/// A pane's folder as big icons with their names under them, as Finder's icon
/// view: in a grid in name order, or where Finder last put each icon.
///
/// Everything else about the pane is as it is in the list -- the selection,
/// the right-click menu, renaming, the keys, dragging and dropping -- because
/// all of it goes through the same `PaneModel` and `AppModel`. What is its
/// own is where things are: `IconLayout` says, and the layout is left on the
/// pane for the keyboard and for drops to read.
struct IconPaneView: View {

    @Bindable var pane: PaneModel
    let model: AppModel
    let side: AppModel.Side
    let activate: () -> Void
    @FocusState.Binding var focusedSide: AppModel.Side?
    /// The pane's right-click menu for these items; empty, for the pane itself.
    let menu: (Set<FileItem.ID>) -> AnyView

    @State private var viewport: CGSize = .zero
    @State private var visible: CGRect = .zero
    @State private var scroll = ScrollPosition()
    /// The rubber band being drawn, and what was selected before it began.
    @State private var band: CGRect?
    @State private var bandBase: Set<FileItem.ID> = []
    /// Set while an icon is being dragged out, so one drag starts one session.
    @GestureState private var dragging = false

    private static let space = "icons"

    var body: some View {
        // Read once: `rows` sorts the whole folder each time it is asked.
        let rows = pane.rows
        let layout = layout(of: rows)
        ScrollView([.vertical, .horizontal]) {
            ZStack(alignment: .topLeading) {
                background(layout)
                ForEach(shown(rows, in: layout)) { item in
                    cell(item, layout)
                }
                if let band {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.7)))
                        .frame(width: band.width, height: band.height)
                        .position(x: band.midX, y: band.midY)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: max(layout.contentSize.width, viewport.width),
                   height: max(layout.contentSize.height, viewport.height),
                   alignment: .topLeading)
            .coordinateSpace(name: Self.space)
            .background(IconSurface { pane.iconSurface = $0 })
        }
        .scrollPosition($scroll)
        .onScrollGeometryChange(for: CGRect.self, of: { $0.visibleRect }) { _, rect in
            visible = rect
        }
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { viewport = $0 }
        // One menu for the whole view, for what is selected -- or the
        // folder's, with nothing selected. A right-click selects the icon
        // under it first, as in Finder (see ClickRouter). A menu on every icon
        // was built on every redraw, each reading the whole listing: a home
        // folder's worth of icons kept the processor busy for good.
        .contextMenu { menu(pane.selection) }
        .background(Color(nsColor: .controlBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .focused($focusedSide, equals: side)
        .onChange(of: layout, initial: true) { _, new in pane.iconLayout = new }
        .onChange(of: pane.iconScrollRequest) { _, _ in reveal(layout) }
        // Something dropped or pasted here has come: put where it was put.
        .onChange(of: pane.items.count) { _, _ in model.settleArrivals(in: pane) }
        // Finder's places, read again whenever the folder or what is in it
        // changes; nothing to read for the grid.
        .task(id: FinderKey(directory: pane.directory, count: pane.items.count, flat: pane.isFlat)) {
            await loadFinderLayout()
        }
    }

    // MARK: - Layout

    /// Finder's own size for the folder's icons when its places are used --
    /// they were placed for that size -- otherwise Finder's default, 64.
    private var metrics: IconLayout.Metrics { pane.iconMetrics(placed: usesFinderPlaces) }

    private var usesFinderPlaces: Bool { pane.iconArrangement == .finder && !pane.isFlat }

    private func layout(of rows: [FileItem]) -> IconLayout {
        let rows = ordered(rows)
        let width = max(viewport.width, 1)
        if usesFinderPlaces {
            return .saved(rows.map { ($0.id, $0.name) }, positions: pane.finderLayout.positions,
                          width: width, metrics: metrics)
        }
        return .grid(rows.map(\.id), width: width, metrics: metrics)
    }

    /// Name order, as Finder sorts by name -- folders first when Settings
    /// say so, and ".." before everything. A flat view sorts by the whole
    /// path, so a folder's files stay together.
    private func ordered(_ rows: [FileItem]) -> [FileItem] { PaneModel.iconOrder(rows) }

    /// Only the icons near what is on screen are made: a flat view can hold
    /// tens of thousands.
    private func shown(_ rows: [FileItem], in layout: IconLayout) -> [FileItem] {
        let near = visible.isEmpty
            ? CGRect(origin: .zero, size: viewport)
            : visible.insetBy(dx: -layout.metrics.cellWidth, dy: -layout.metrics.cellHeight * 2)
        let ids = Set(layout.order.filter { id in
            layout.iconRect(of: id).map { layout.cellRect(around: CGPoint(x: $0.midX, y: $0.midY)).intersects(near) } ?? false
        })
        return rows.filter { ids.contains($0.id) }
    }

    private func loadFinderLayout() async {
        // Read in name order too: dragging an icon there switches to the
        // placed icons, which then have to be where they were placed.
        guard !pane.isFlat else {
            pane.finderLayout = FinderIconPositions.Layout()
            return
        }
        // A server's folder has no `.DS_Store` worth reading; only what was
        // placed here.
        guard !pane.isServerListing else {
            pane.adoptFinderLayout(FinderIconPositions.Layout())
            return
        }
        let folder = pane.directory
        let read = await Task.detached { FinderIconPositions.read(folder) }.value
        guard folder == pane.directory else { return }
        pane.adoptFinderLayout(read)
    }

    private struct FinderKey: Equatable {
        let directory: URL
        let count: Int
        let flat: Bool
    }

    // MARK: - Pieces

    private func cell(_ item: FileItem, _ layout: IconLayout) -> some View {
        let rect = layout.iconRect(of: item.id) ?? .zero
        let cell = layout.cellRect(around: CGPoint(x: rect.midX, y: rect.midY))
        let selected = pane.selection.contains(item.id)
        let dimmed = !pane.matchesFilter(item)
        return IconCell(item: item, metrics: layout.metrics, isSelected: selected,
                        isActive: model.activeSide == side || model.isSinglePane,
                        isSpringLoadTarget: model.springLoadPane === pane
                            && model.springLoadTarget?.id == item.id,
                        pane: pane, model: model)
            .frame(width: cell.width, height: cell.height, alignment: .top)
            .opacity(dimmed ? 0.35 : 1)
            .contentShape(Rectangle())
            .position(x: cell.midX, y: cell.midY)
            .gesture(dimmed ? nil : dragOut(item, layout))
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard !dimmed else { return }
                activate()
                model.open(id: item.id, in: pane)
            })
            .simultaneousGesture(TapGesture().onEnded { click(item) })
    }

    /// Empty space: a click there clears the selection, a drag there draws a
    /// rubber band.
    private func background(_ layout: IconLayout) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: max(layout.contentSize.width, viewport.width),
                   height: max(layout.contentSize.height, viewport.height))
            .gesture(rubberBand(layout))
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named(Self.space)).onEnded { tap in
                activate()
                focusedSide = side
                // Where a paste lands, when the pointer is not over the view.
                pane.lastIconClick = tap.location
                if !NSEvent.modifierFlags.contains(.command), !NSEvent.modifierFlags.contains(.shift) {
                    pane.selection = []
                }
            })
    }

    // MARK: - Mouse

    /// A click selects; with Command or Shift it adds or takes away, as in
    /// Finder's icon view.
    private func click(_ item: FileItem) {
        guard pane.matchesFilter(item) else { return }
        activate()
        focusedSide = side
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) || flags.contains(.shift) {
            if pane.selection.contains(item.id) {
                pane.selection.remove(item.id)
            } else {
                pane.selection.insert(item.id)
            }
        } else {
            pane.selection = [item.id]
        }
        pane.iconCursor = item.id
    }

    private func rubberBand(_ layout: IconLayout) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if band == nil {
                    activate()
                    focusedSide = side
                    let flags = NSEvent.modifierFlags
                    bandBase = flags.contains(.command) || flags.contains(.shift) ? pane.selection : []
                }
                let rect = CGRect(x: min(value.startLocation.x, value.location.x),
                                  y: min(value.startLocation.y, value.location.y),
                                  width: abs(value.location.x - value.startLocation.x),
                                  height: abs(value.location.y - value.startLocation.y))
                band = rect
                let greyed = Set(pane.rows.filter { !pane.matchesFilter($0) }.map(\.id))
                let inside = layout.items(in: rect).filter { !greyed.contains($0) }
                pane.selection = bandBase.union(inside)
            }
            .onEnded { _ in band = nil }
    }

    /// Dragging an icon drags every selected file -- or this one alone, when
    /// it was not selected -- as Finder's do. Started in AppKit: SwiftUI's own
    /// drag carries one item.
    private func dragOut(_ item: FileItem, _ layout: IconLayout) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragging) { _, started, _ in
                guard !started, !item.isParent else { return }
                started = true
                guard let event = NSApp.currentEvent, event.type == .leftMouseDragged,
                      let surface = pane.iconSurface as? IconSurfaceView else { return }
                if !pane.selection.contains(item.id) { pane.selection = [item.id] }
                activate()
                let chosen = pane.rows.filter {
                    pane.selection.contains($0.id) && !$0.isParent && pane.matchesFilter($0)
                }
                for file in chosen { model.dragStarted(from: pane, url: file.url) }
                surface.beginDrag(chosen.map { file in
                    (file, IconCache.icon(for: file, side: layout.metrics.iconSize),
                     layout.iconRect(of: file.id) ?? .zero)
                }, event: event)
            }
    }

    // MARK: - Scrolling

    /// The selection brought into sight, by as little scrolling as will do.
    private func reveal(_ layout: IconLayout) {
        guard let id = pane.iconCursor.flatMap({ pane.selection.contains($0) ? $0 : nil })
                ?? layout.order.first(where: { pane.selection.contains($0) }),
              let icon = layout.iconRect(of: id) else { return }
        let target = layout.cellRect(around: CGPoint(x: icon.midX, y: icon.midY)).insetBy(dx: -6, dy: -6)
        let view = visible.isEmpty ? CGRect(origin: .zero, size: viewport) : visible
        guard !view.contains(target) else { return }
        var origin = view.origin
        if target.minY < view.minY { origin.y = target.minY }
        else if target.maxY > view.maxY { origin.y = target.maxY - view.height }
        if target.minX < view.minX { origin.x = target.minX }
        else if target.maxX > view.maxX { origin.x = target.maxX - view.width }
        scroll.scrollTo(point: CGPoint(x: max(0, origin.x), y: max(0, origin.y)))
    }
}

/// One icon and its name.
private struct IconCell: View {
    let item: FileItem
    let metrics: IconLayout.Metrics
    let isSelected: Bool
    /// The pane has the keyboard: its selection is drawn in the accent colour,
    /// the other pane's in grey, as Finder draws a window that is not in front.
    let isActive: Bool
    let isSpringLoadTarget: Bool
    @Bindable var pane: PaneModel
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: IconCache.icon(for: item, side: metrics.iconSize))
                .resizable()
                .interpolation(.high)
                .frame(width: metrics.iconSize, height: metrics.iconSize)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.secondary.opacity(0.22) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSpringLoadTarget ? Color.accentColor : .clear, lineWidth: 2))
            if pane.renamingID == item.id {
                RenameField(text: $pane.renameText,
                            onCommit: { advance in model.commitInlineRename(advance: advance) },
                            onCancel: { model.cancelInlineRename() })
                    .frame(width: metrics.cellWidth - 4, height: PaneFont.size * 1.6)
            } else {
                Text(item.isParent ? ".." : item.name)
                    .font(PaneFont.swiftUI)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected && isActive ? Color.white
                                     : CellView.gitColour(item.gitState) ?? .primary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? (isActive ? Color.accentColor : Color.secondary.opacity(0.3))
                                         : .clear))
                    .frame(maxWidth: metrics.cellWidth - 4)
                    .help(item.name)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The icon view's drawing surface, as AppKit sees it: laid out behind the
/// icons at the size of the whole layout and scrolled with them, so a point
/// in it is a point of the layout -- which is how a drop finds the icon under
/// the pointer. It takes no clicks of its own. It is also where a drag of the
/// selected icons starts.
final class IconSurfaceView: NSView, NSDraggingSource {

    /// Nonisolated, as a constant may be: dragging many icons at once has
    /// AppKit lay out their images on several threads, each asking this --
    /// and asked off the main thread, a main-actor answer stopped the app.
    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The files, each drawn at its icon, as Finder drags them: the file URL
    /// and nothing else -- see the list's drag for why -- and a server's file
    /// as its address.
    func beginDrag(_ items: [(item: FileItem, image: NSImage, frame: CGRect)], event: NSEvent) {
        let dragged = items.map { entry -> NSDraggingItem in
            let writer = NSPasteboardItem()
            if RemoteBrowsing.isInside(entry.item.url) {
                writer.setString(RemoteBrowsing.reportedPath(entry.item.url), forType: .string)
            } else {
                writer.setString(entry.item.url.absoluteString, forType: .fileURL)
            }
            let dragging = NSDraggingItem(pasteboardWriter: writer)
            dragging.setDraggingFrame(entry.frame, contents: entry.image)
            return dragging
        }
        guard !dragged.isEmpty else { return }
        beginDraggingSession(with: dragged, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy, .generic] : [.copy, .move, .link, .generic]
    }
}

private struct IconSurface: NSViewRepresentable {
    let found: (NSView) -> Void

    func makeNSView(context: Context) -> IconSurfaceView {
        let view = IconSurfaceView()
        DispatchQueue.main.async { found(view) }
        return view
    }

    func updateNSView(_ view: IconSurfaceView, context: Context) {}
}
