import SwiftUI
import AppKit

/// The Disk Usage window: what is taking up the room under a folder, drawn
/// three ways -- a treemap sized by bytes, a heat map coloured by size, and
/// GrandPerspective-style rectangles with one per file. A segmented control
/// rotates between them, one shown at a time.
@MainActor
@Observable
final class DiskUsageModel {

    enum Mode: String, CaseIterable, Identifiable {
        case treemap, heatMap, grandPerspective
        var id: String { rawValue }
        var label: String {
            switch self {
            case .treemap:          "Treemap"
            case .heatMap:          "Heat Map"
            case .grandPerspective: "Files"
            }
        }
        var symbol: String {
            switch self {
            case .treemap:          "square.grid.2x2"
            case .heatMap:          "thermometer.medium"
            case .grandPerspective: "squareshape.split.3x3"
            }
        }
    }

    let root: URL
    private(set) var tree: DiskUsage.Node?
    private(set) var loading = true
    private(set) var progress = 0
    var mode: Mode = .treemap

    /// Where the view has drilled to, deepest last; the root when empty.
    private(set) var stack: [DiskUsage.Node] = []
    @ObservationIgnored private var cancelled = CancellationFlag()

    var current: DiskUsage.Node? { stack.last ?? tree }

    init(url: URL) { self.root = url }

    func scan() async {
        loading = true
        progress = 0
        stack = []
        cancelled = CancellationFlag()
        let flag = cancelled
        let url = root
        let node = await BlockingWork.run {
            DiskUsage.scan(url, cancelled: flag) { count in
                Task { @MainActor in DiskUsageModel.report(count, to: url) }
            }
        }
        guard !flag.isCancelled else { return }
        tree = node
        loading = false
    }

    /// Progress hops back to whichever live model is scanning this url.
    private static func report(_ count: Int, to url: URL) {
        NotificationCenter.default.post(name: .diskUsageProgress, object: url,
                                        userInfo: ["count": count])
    }

    func receive(progress count: Int) { if loading { progress = count } }

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
}

struct DiskUsageView: View {

    @State private var model: DiskUsageModel
    @State private var hovered: DiskUsage.Node?
    /// The rectangles last drawn, newest layout, for hit-testing taps and hover.
    @State private var placements: [Treemap.Placed<DiskUsage.Node>] = []
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
                .disabled(model.current?.id == model.tree?.id)
                .help("Up one level")

            breadcrumb

            Spacer()

            Picker("", selection: $model.mode) {
                ForEach(DiskUsageModel.Mode.allCases) { mode in
                    Image(systemName: mode.symbol).tag(mode).help(mode.label)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Button {
                Task { await model.scan() }
            } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.loading)
                .help("Scan again")
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
        }
    }

    // MARK: - The map

    @ViewBuilder private var map: some View {
        if model.loading {
            VStack(spacing: 10) {
                ProgressView()
                Text(model.progress > 0 ? "Measuring\u{2026} \(model.progress) files"
                                        : "Measuring\u{2026}")
                    .foregroundStyle(.secondary)
                Button("Stop") { model.cancel() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let current = model.current, !items(of: current).isEmpty {
            GeometryReader { geo in
                let placed = Treemap.squarify(items(of: current), in: CGRect(origin: .zero,
                                                                             size: geo.size))
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
                    .onAppear { placements = placed }
                    .onChange(of: geo.size) { placements = placed }
                    .onChange(of: model.mode) { placements = placed }
            }
            .padding(6)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "externaldrive").font(.largeTitle).foregroundStyle(.secondary)
                Text("Nothing to show here.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// What a mode lays out for `node`: its children for the treemap and heat
    /// map, every file under it for the GrandPerspective view.
    private func items(of node: DiskUsage.Node) -> [(item: DiskUsage.Node, weight: Double)] {
        switch model.mode {
        case .treemap, .heatMap:
            return node.children.map { ($0, Double($0.size)) }
        case .grandPerspective:
            var files: [DiskUsage.Node] = []
            node.files(into: &files)
            return files.map { ($0, Double($0.size)) }
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

    private func colour(of node: DiskUsage.Node, maxSize: Int64) -> Color {
        switch model.mode {
        case .treemap:
            return node.isDirectory ? Color.accentColor.opacity(0.75)
                                    : Color.teal.opacity(0.7)
        case .heatMap:
            // Big is hot: hue runs blue (cool, 0.62) to red (hot, 0.0).
            let fraction = maxSize > 0 ? Double(node.size) / Double(maxSize) : 0
            return Color(hue: 0.62 * (1 - fraction), saturation: 0.85, brightness: 0.9)
        case .grandPerspective:
            return Self.extensionColour(node.url.pathExtension)
        }
    }

    /// A stable colour per file extension, as GrandPerspective colours by kind.
    static func extensionColour(_ ext: String) -> Color {
        guard !ext.isEmpty else { return Color(hue: 0, saturation: 0, brightness: 0.6) }
        var hasher = Hasher()
        hasher.combine(ext.lowercased())
        let hue = Double(abs(hasher.finalize()) % 360) / 360
        return Color(hue: hue, saturation: 0.6, brightness: 0.85)
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
                Text(model.mode == .grandPerspective
                     ? "Each rectangle is a file, sized by bytes and coloured by kind. Hover for its path."
                     : "Rectangles are sized by bytes. Click a folder to go into it; the arrow goes back.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .textSelection(.enabled)
    }
}
