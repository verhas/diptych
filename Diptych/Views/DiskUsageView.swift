import SwiftUI
import AppKit

/// The Disk Usage window: what is taking up the room under a folder, drawn as a
/// heat map -- a rectangle per item in the folder, sized by bytes and coloured
/// by size so the big ones are warm and easy to pick out. Click a folder to go
/// into it; the arrow goes back.
///
/// The scan runs off the main thread and hands over each top-level item the
/// moment it is measured, so the picture fills in as it goes instead of hiding
/// behind a spinner on a large folder.
@MainActor
@Observable
final class DiskUsageModel {

    let root: URL
    private(set) var tree: DiskUsage.Node?
    private(set) var loading = true
    private(set) var progress = 0

    /// The top-level items measured so far, during a scan -- what the heat map
    /// draws before the whole folder is done.
    private var partialChildren: [DiskUsage.Node] = []
    /// A stable id for the root across the partial updates and the final tree,
    /// so drawing and hit-testing do not flicker as children arrive.
    @ObservationIgnored private var rootId = UUID()

    /// Where the view has drilled to, deepest last; the root when empty.
    private(set) var stack: [DiskUsage.Node] = []
    @ObservationIgnored private var cancelled = CancellationFlag()

    var current: DiskUsage.Node? { stack.last ?? tree }
    var atRoot: Bool { stack.isEmpty }

    init(url: URL) { self.root = url }

    func scan() async {
        loading = true
        progress = 0
        stack = []
        partialChildren = []
        tree = nil
        rootId = UUID()
        cancelled = CancellationFlag()
        let flag = cancelled
        let url = root
        let node = await BlockingWork.run {
            DiskUsage.scan(url, cancelled: flag,
                           onProgress: { count in
                               Task { @MainActor in DiskUsageModel.report(.diskUsageProgress, count, to: url) }
                           },
                           onChild: { child in
                               Task { @MainActor in DiskUsageModel.deliver(child, to: url) }
                           })
        }
        guard !flag.isCancelled else { return }
        if let node {
            // Keep the id stable so the final, authoritative tree does not read
            // as a different root than the one that was filling in.
            tree = DiskUsage.Node(id: rootId, name: node.name, url: node.url,
                                  isDirectory: true, size: node.size, children: node.children)
        }
        loading = false
    }

    /// Progress and each finished child hop back to whichever live model is
    /// scanning this url.
    private static func report(_ name: Notification.Name, _ count: Int, to url: URL) {
        NotificationCenter.default.post(name: name, object: url, userInfo: ["count": count])
    }

    private static func deliver(_ child: DiskUsage.Node, to url: URL) {
        NotificationCenter.default.post(name: .diskUsageChild, object: url,
                                        userInfo: ["child": child])
    }

    func receive(progress count: Int) { if loading { progress = count } }

    func receive(child: DiskUsage.Node) {
        guard loading else { return }
        partialChildren.append(child)
        partialChildren.sort { $0.size > $1.size }
        let total = partialChildren.reduce(Int64(0)) { $0 + $1.size }
        tree = DiskUsage.Node(id: rootId, name: root.path, url: root, isDirectory: true,
                              size: total, children: partialChildren)
    }

    func drill(into node: DiskUsage.Node) {
        guard node.isDirectory, !node.children.isEmpty else { return }
        stack.append(node)
    }

    func goUp() { if !stack.isEmpty { stack.removeLast() } }
    func goToRoot() { stack.removeAll() }
    func cancel() { cancelled.cancel() }
}

extension Notification.Name {
    static let diskUsageProgress = Notification.Name("dev.verhas.Diptych.diskUsageProgress")
    static let diskUsageChild = Notification.Name("dev.verhas.Diptych.diskUsageChild")
}

struct DiskUsageView: View {

    @State private var model: DiskUsageModel
    @State private var hovered: DiskUsage.Node?
    @Environment(\.openWindow) private var openWindow

    init(url: URL) {
        _model = State(initialValue: DiskUsageModel(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            map
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 480)
        .navigationTitle("Disk Usage \u{2014} \(model.root.lastPathComponent)")
        .task { await model.scan() }
        .onReceive(NotificationCenter.default.publisher(for: .diskUsageProgress)) { note in
            if (note.object as? URL) == model.root, let count = note.userInfo?["count"] as? Int {
                model.receive(progress: count)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .diskUsageChild)) { note in
            if (note.object as? URL) == model.root,
               let child = note.userInfo?["child"] as? DiskUsage.Node {
                withAnimation(.easeOut(duration: 0.35)) { model.receive(child: child) }
            }
        }
        .background(WindowAccessor { window in
            if let window {
                AppWindows.shared.register(window)
                WindowSubjects.shared.register(window, kind: "diskUsage", description: model.root.path)
            }
        })
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                model.goUp()
            } label: { Image(systemName: "chevron.up") }
                .disabled(model.atRoot)
                .help("Up one level")

            breadcrumb

            Spacer()

            if model.loading {
                ProgressView().controlSize(.small)
                Button("Stop") { model.cancel() }
                    .controlSize(.small)
            } else {
                Button {
                    Task { await model.scan() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .help("Scan again")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Text(model.current.map { $0.name == model.root.path ? model.root.lastPathComponent
                                                                : $0.name } ?? "")
                .font(.headline).lineLimit(1).truncationMode(.middle)
            if let current = model.current {
                Text(ByteCountFormatter.string(fromByteCount: current.size, countStyle: .file))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if model.loading, model.progress > 0 {
                Text("\u{2014} measuring\u{2026} \(model.progress) files")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - The map

    @ViewBuilder private var map: some View {
        if let current = model.current, !current.children.isEmpty {
            GeometryReader { geo in
                let items = current.children.map { (item: $0, weight: Double($0.size)) }
                let placed = Treemap.squarify(items, in: CGRect(origin: .zero, size: geo.size))
                Canvas { context, _ in draw(placed, in: context) }
                    .onContinuousHover { phase in
                        if case .active(let point) = phase {
                            hovered = placed.last { $0.rect.contains(point) }?.item
                        } else {
                            hovered = nil
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { event in
                        if let hit = placed.last(where: { $0.rect.contains(event.location) })?.item {
                            tapped(hit)
                        }
                    })
            }
            .padding(6)
        } else if model.loading {
            VStack(spacing: 10) {
                ProgressView()
                Text(model.progress > 0 ? "Measuring\u{2026} \(model.progress) files"
                                        : "Measuring\u{2026}")
                    .foregroundStyle(.secondary)
                Button("Stop") { model.cancel() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "externaldrive").font(.largeTitle).foregroundStyle(.secondary)
                Text("Nothing to show here.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func draw(_ placed: [Treemap.Placed<DiskUsage.Node>], in context: GraphicsContext) {
        let maxSize = placed.map(\.item.size).max() ?? 1
        for placement in placed {
            let rect = placement.rect.insetBy(dx: 0.5, dy: 0.5)
            guard rect.width > 1, rect.height > 1 else { continue }
            let path = Path(roundedRect: rect, cornerRadius: 2)
            context.fill(path, with: .color(colour(of: placement.item, maxSize: maxSize)))
            context.stroke(path, with: .color(.black.opacity(0.25)), lineWidth: 0.5)
            if placement.item.id == hovered?.id {
                context.stroke(Path(roundedRect: placement.rect, cornerRadius: 2),
                               with: .color(.white), lineWidth: 2)
            }
            // A label where there is room for one.
            if rect.width > 46, rect.height > 16 {
                let name = Text(placement.item.name).font(.system(size: 10))
                    .foregroundStyle(.white)
                context.draw(context.resolve(name),
                             at: CGPoint(x: rect.minX + 4, y: rect.minY + 9), anchor: .leading)
            }
        }
    }

    /// Big is hot: hue runs blue (cool, 0.62) to red (hot, 0.0) with the item's
    /// share of the largest here.
    private func colour(of node: DiskUsage.Node, maxSize: Int64) -> Color {
        let fraction = maxSize > 0 ? Double(node.size) / Double(maxSize) : 0
        return Color(hue: 0.62 * (1 - fraction), saturation: 0.85, brightness: 0.9)
    }

    private func tapped(_ node: DiskUsage.Node) {
        if node.isDirectory { model.drill(into: node) }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let hovered {
                Image(systemName: hovered.isDirectory ? "folder" : "doc")
                    .foregroundStyle(.secondary)
                Text(hovered.url.path)
                    .lineLimit(1).truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: hovered.size, countStyle: .file))
                    .foregroundStyle(.secondary)
            } else {
                Text("Rectangles are sized by bytes and coloured by size \u{2014} warm is bigger. "
                     + "Click a folder to go into it; the arrow goes back.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .textSelection(.enabled)
    }
}
