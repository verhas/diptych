import CoreGraphics

/// A squarified treemap: given weighted items and a rectangle, lay them out as
/// rectangles whose areas are proportional to the weights and whose shapes are
/// kept as close to square as the layout allows -- the Bruls/Huizing/van Wijk
/// algorithm GrandPerspective and every other treemap uses.
///
/// Pure geometry, no main actor and no file system, so it is tested on its own.
enum Treemap {

    struct Placed<Item>: Sendable where Item: Sendable {
        let item: Item
        let rect: CGRect
    }

    /// Lay `items` out in `rect`, each carrying its weight. Items with a weight
    /// of zero or less are dropped. The result is in the order laid out.
    static func squarify<Item: Sendable>(_ items: [(item: Item, weight: Double)],
                                         in rect: CGRect) -> [Placed<Item>] {
        let positive = items.filter { $0.weight > 0 }
        guard !positive.isEmpty, rect.width > 0, rect.height > 0 else { return [] }

        // Largest first: the algorithm wants it, and the big rectangles landing
        // first is what people expect to read top-left.
        let sorted = positive.sorted { $0.weight > $1.weight }
        let total = sorted.reduce(0.0) { $0 + $1.weight }

        // Weights scaled so their sum is the rectangle's area: then a weight is
        // an area in points directly.
        let area = Double(rect.width) * Double(rect.height)
        let scaled = sorted.map { (item: $0.item, area: $0.weight / total * area) }

        var placed: [Placed<Item>] = []
        var remaining = rect
        var row: [(item: Item, area: Double)] = []

        func shortestSide() -> Double { Double(min(remaining.width, remaining.height)) }

        /// The worst aspect ratio in `row` if it were laid along the shorter
        /// side of `remaining` -- what the algorithm minimises.
        func worst(_ row: [(item: Item, area: Double)]) -> Double {
            guard !row.isEmpty else { return .infinity }
            let side = shortestSide()
            let sum = row.reduce(0.0) { $0 + $1.area }
            let maxArea = row.map(\.area).max() ?? 0
            let minArea = row.map(\.area).min() ?? 0
            let side2 = side * side
            let sum2 = sum * sum
            return max(side2 * maxArea / sum2, sum2 / (side2 * minArea))
        }

        func layRow(_ row: [(item: Item, area: Double)]) {
            let sum = row.reduce(0.0) { $0 + $1.area }
            guard sum > 0 else { return }
            let alongWidth = remaining.width <= remaining.height
            // The row occupies a band across the shorter side; its thickness is
            // its total area divided by that side's length.
            let side = shortestSide()
            let thickness = CGFloat(sum / side)
            var offset: CGFloat = alongWidth ? remaining.minX : remaining.minY
            for entry in row {
                let length = CGFloat(entry.area / sum) * CGFloat(side)
                let cell: CGRect = alongWidth
                    ? CGRect(x: offset, y: remaining.minY, width: length, height: thickness)
                    : CGRect(x: remaining.minX, y: offset, width: thickness, height: length)
                placed.append(Placed(item: entry.item, rect: cell))
                offset += length
            }
            // Shrink the remaining rectangle by the band just laid.
            if alongWidth {
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness,
                                   width: remaining.width,
                                   height: max(0, remaining.height - thickness))
            } else {
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY,
                                   width: max(0, remaining.width - thickness),
                                   height: remaining.height)
            }
        }

        for entry in scaled {
            let extended = row + [entry]
            if row.isEmpty || worst(extended) <= worst(row) {
                row = extended
            } else {
                layRow(row)
                row = [entry]
            }
        }
        if !row.isEmpty { layRow(row) }
        return placed
    }
}
