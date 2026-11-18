import CoreGraphics
import Foundation

/// Where each icon of a pane's icon view goes.
///
/// Two ways, as in Finder: a grid in name order, filling the width row by
/// row; or where Finder last put each icon in that folder -- read from its
/// `.DS_Store` -- with the icons Finder never placed filling the grid's free
/// cells in name order, as Finder fills them itself.
///
/// A point is an icon's centre, which is what Finder stores; the name sits
/// under the icon, in a cell as wide as the grid's.
struct IconLayout: Equatable {

    /// The sizes everything is drawn at.
    struct Metrics: Equatable {
        var iconSize: CGFloat
        /// Grid pitch: one icon and its name, with the space around them.
        var cellWidth: CGFloat
        var cellHeight: CGFloat
        /// Room under the icon for two lines of its name.
        var labelHeight: CGFloat
        var margin: CGFloat

        /// `fontSize` is the panes' text; names are drawn at it. Finder's
        /// default icon is 64 points, and its grid spacing widens the cell --
        /// 54 unless the folder says otherwise.
        init(iconSize: CGFloat = 64, fontSize: CGFloat = 12, gridSpacing: CGFloat? = nil) {
            self.iconSize = iconSize
            let lineHeight = (fontSize * 1.25).rounded(.up)
            labelHeight = lineHeight * 2 + 4
            let spacing = gridSpacing ?? 54
            cellWidth = (iconSize + max(36, spacing * 0.8)).rounded()
            cellHeight = (iconSize + 6 + labelHeight + 10).rounded()
            margin = 10
        }
    }

    let metrics: Metrics
    /// The centre of each icon.
    private(set) var centres: [URL: CGPoint] = [:]
    /// In the order the icons are read: by name, and so for the keyboard.
    private(set) var order: [URL] = []
    private(set) var contentSize: CGSize = .zero

    /// The grid: `ids` in the order given, row by row across `width`.
    static func grid(_ ids: [URL], width: CGFloat, metrics: Metrics) -> IconLayout {
        var layout = IconLayout(metrics: metrics)
        let columns = layout.columns(for: width)
        for (index, id) in ids.enumerated() {
            layout.place(id, at: layout.slot(index % columns, index / columns))
        }
        layout.order = ids
        layout.fit(width: width)
        return layout
    }

    /// Finder's places: each of `items` at its saved position when it has one,
    /// the rest in the grid's free cells, in the order given.
    static func saved(_ items: [(id: URL, name: String)], positions: [String: CGPoint],
                      width: CGFloat, metrics: Metrics) -> IconLayout {
        var layout = IconLayout(metrics: metrics)
        var unplaced: [URL] = []
        for item in items {
            if let point = positions[item.name] {
                layout.place(item.id, at: point)
            } else {
                unplaced.append(item.id)
            }
        }
        // A cell is taken when an icon placed by hand sits in it.
        let columns = layout.columns(for: width)
        let taken = layout.centres.values
        var cell = 0
        for id in unplaced {
            while true {
                let point = layout.slot(cell % columns, cell / columns)
                cell += 1
                let rect = layout.cellRect(around: point)
                if !taken.contains(where: { rect.contains($0) }) {
                    layout.place(id, at: point)
                    break
                }
            }
        }
        layout.order = items.map(\.id)
        layout.fit(width: width)
        return layout
    }

    private init(metrics: Metrics) { self.metrics = metrics }

    // MARK: - Geometry

    private func columns(for width: CGFloat) -> Int {
        max(1, Int((width - 2 * metrics.margin) / metrics.cellWidth))
    }

    /// The centre of the icon in grid cell (column, row).
    private func slot(_ column: Int, _ row: Int) -> CGPoint {
        CGPoint(x: metrics.margin + metrics.cellWidth * (CGFloat(column) + 0.5),
                y: metrics.margin + metrics.iconSize / 2 + 4 + metrics.cellHeight * CGFloat(row))
    }

    private mutating func place(_ id: URL, at point: CGPoint) { centres[id] = point }

    private mutating func fit(width: CGFloat) {
        let right = centres.values.map { $0.x + metrics.cellWidth / 2 }.max() ?? 0
        let bottom = centres.values.map { cellRect(around: $0).maxY }.max() ?? 0
        contentSize = CGSize(width: max(width, right + metrics.margin),
                             height: bottom + metrics.margin)
    }

    /// The whole cell an icon and its name take up.
    func cellRect(around centre: CGPoint) -> CGRect {
        CGRect(x: centre.x - metrics.cellWidth / 2, y: centre.y - metrics.iconSize / 2 - 4,
               width: metrics.cellWidth, height: metrics.cellHeight)
    }

    /// Where the icon itself is drawn.
    func iconRect(of id: URL) -> CGRect? {
        centres[id].map {
            CGRect(x: $0.x - metrics.iconSize / 2, y: $0.y - metrics.iconSize / 2,
                   width: metrics.iconSize, height: metrics.iconSize)
        }
    }

    /// Where its name is drawn, under the icon.
    func labelRect(of id: URL) -> CGRect? {
        centres[id].map {
            CGRect(x: $0.x - metrics.cellWidth / 2 + 2, y: $0.y + metrics.iconSize / 2 + 4,
                   width: metrics.cellWidth - 4, height: metrics.labelHeight)
        }
    }

    // MARK: - Finding

    /// The item whose icon or name is under the point; the last drawn wins,
    /// as it is on top.
    func item(at point: CGPoint) -> URL? {
        order.last { id in
            (iconRect(of: id)?.contains(point) ?? false) || (labelRect(of: id)?.contains(point) ?? false)
        }
    }

    /// Every item whose icon or name the rectangle touches -- a rubber band.
    func items(in rect: CGRect) -> [URL] {
        order.filter { id in
            (iconRect(of: id)?.intersects(rect) ?? false) || (labelRect(of: id)?.intersects(rect) ?? false)
        }
    }

    /// Finder's Clean Up: every icon moved to the nearest free point of the
    /// grid, so none sits between them -- in no new order; each stays as near
    /// where it was put as the grid allows. The icons nearest to a point are
    /// settled first, so one placed with care keeps its point and one dropped
    /// between points is the one that moves -- to the nearest free point
    /// around it. Equally near, top to bottom and left to right.
    func cleanedUp(width: CGFloat) -> [URL: CGPoint] {
        let columns = max(self.columns(for: width),
                          centres.values.map { cell(of: $0).column + 1 }.max() ?? 1)
        var taken: Set<Int> = []
        var result: [URL: CGPoint] = [:]
        func offGrid(_ point: CGPoint) -> CGFloat {
            let near = cell(of: point), at = slot(near.column, near.row)
            return hypot(at.x - point.x, at.y - point.y)
        }
        let reading = centres.sorted { a, b in
            let x = offGrid(a.value), y = offGrid(b.value)
            if abs(x - y) > 0.5 { return x < y }
            return a.value.y != b.value.y ? a.value.y < b.value.y : a.value.x < b.value.x
        }
        for (id, point) in reading {
            let near = cell(of: point)
            var best: (column: Int, row: Int, distance: CGFloat)?
            // Rings around the nearest point, until one has a free point.
            var ring = 0
            while best == nil {
                for row in max(0, near.row - ring) ... near.row + ring {
                    for column in max(0, near.column - ring) ... min(columns - 1, near.column + ring)
                    where max(abs(row - near.row), abs(column - near.column)) == ring
                        && !taken.contains(row * columns + column) {
                        let slot = slot(column, row)
                        let distance = hypot(slot.x - point.x, slot.y - point.y)
                        if best == nil || distance < best!.distance { best = (column, row, distance) }
                    }
                }
                ring += 1
            }
            if let best {
                taken.insert(best.row * columns + best.column)
                result[id] = slot(best.column, best.row)
            }
        }
        return result
    }

    /// Icons just put down, kept clear of the rest: each of `moving` that
    /// lands on another icon goes to the nearest point of the grid that is
    /// free, as Finder settles icons dropped on each other. Icons not moving
    /// stay exactly where they are, and so does a moved one in open space.
    static func clearingOverlaps(_ centres: [URL: CGPoint], moving: Set<URL>, width: CGFloat,
                                 metrics: Metrics) -> [URL: CGPoint] {
        let grid = IconLayout(metrics: metrics)
        var settled = centres.filter { !moving.contains($0.key) }
        // Touching is not overlapping; more than a sliver is.
        func clashes(_ point: CGPoint) -> Bool {
            let mine = grid.cellRect(around: point).insetBy(dx: 6, dy: 6)
            return settled.values.contains { grid.cellRect(around: $0).insetBy(dx: 6, dy: 6).intersects(mine) }
        }
        let columns = max(grid.columns(for: width),
                          centres.values.map { grid.cell(of: $0).column + 1 }.max() ?? 1)
        // Top to bottom, left to right, so a group settles in its own order.
        let moved = centres.filter { moving.contains($0.key) }
            .sorted { $0.value.y != $1.value.y ? $0.value.y < $1.value.y : $0.value.x < $1.value.x }
        for (id, point) in moved {
            guard clashes(point) else {
                settled[id] = point
                continue
            }
            let near = grid.cell(of: point)
            var best: (point: CGPoint, distance: CGFloat)?
            var ring = 0
            while best == nil, ring < 200 {
                for row in max(0, near.row - ring) ... near.row + ring {
                    for column in max(0, near.column - ring) ... max(near.column, min(columns - 1, near.column + ring))
                    where max(abs(row - near.row), abs(column - near.column)) == ring {
                        let slot = grid.slot(column, row)
                        guard !clashes(slot) else { continue }
                        let distance = hypot(slot.x - point.x, slot.y - point.y)
                        if best == nil || distance < best!.distance { best = (slot, distance) }
                    }
                }
                ring += 1
            }
            settled[id] = best?.point ?? point
        }
        return settled
    }

    /// The grid cell whose point is nearest.
    private func cell(of point: CGPoint) -> (column: Int, row: Int) {
        let column = Int(((point.x - metrics.margin) / metrics.cellWidth - 0.5).rounded())
        let row = Int(((point.y - metrics.margin - metrics.iconSize / 2 - 4) / metrics.cellHeight).rounded())
        return (max(0, column), max(0, row))
    }

    enum Direction { case left, right, up, down }

    /// The icon the arrow key goes to from `id`: the nearest one that way,
    /// preferring those in line with it -- in a grid, the next cell; among
    /// icons placed by hand, the one a person would point at.
    func neighbour(of id: URL, _ direction: Direction) -> URL? {
        guard let from = centres[id] else { return order.first }
        var best: (id: URL, score: CGFloat)?
        for (other, point) in centres where other != id {
            let dx = point.x - from.x, dy = point.y - from.y
            let along: CGFloat, across: CGFloat
            switch direction {
            case .left:  (along, across) = (-dx, dy)
            case .right: (along, across) = (dx, dy)
            case .up:    (along, across) = (-dy, dx)
            case .down:  (along, across) = (dy, dx)
            }
            guard along > 1 else { continue }
            // Off to the side counts against it more than distance ahead.
            let score = along + abs(across) * 3
            if best == nil || score < best!.score { best = (other, score) }
        }
        return best?.id
    }
}
