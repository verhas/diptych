import Foundation

/// The turn and the move that lay one picture over another best: what makes
/// two scans of one page comparable, since no two land on the glass the same.
///
/// Searched, coarse to fine, rather than solved. On a picture a hundred
/// pixels across, every turn up to `maxDegrees` either way and every move up
/// to `maxShift` of its size is tried; each finer level, twice the size, only
/// looks around the best of the one before. What is minimised is the mean
/// squared difference of the two after each is brought to the same brightness
/// and contrast -- two scans are rarely exposed alike -- over the part where
/// both have something.
enum ImageAlignment {

    /// B turned `angle` radians clockwise about its centre, then moved by
    /// `dx` and `dy` -- as fractions of its width and height, so the answer
    /// holds at any size it is shown at.
    struct Transform: Sendable, Equatable, Hashable {
        var angle: Double
        var dx: Double
        var dy: Double

        static let identity = Transform(angle: 0, dx: 0, dy: 0)

        var degrees: Double { angle * 180 / .pi }

        /// "turned 0.42° clockwise, moved 1.2% right and 0.3% down".
        var description: String {
            var parts: [String] = []
            let turn = abs(degrees)
            if turn >= 0.05 {
                parts.append("turned " + String(format: "%.2f", turn) + "\u{B0} "
                             + (degrees > 0 ? "clockwise" : "anticlockwise"))
            }
            var moves: [String] = []
            if abs(dx) >= 0.0005 {
                moves.append(String(format: "%.1f", abs(dx) * 100) + "% " + (dx > 0 ? "right" : "left"))
            }
            if abs(dy) >= 0.0005 {
                moves.append(String(format: "%.1f", abs(dy) * 100) + "% " + (dy > 0 ? "down" : "up"))
            }
            if !moves.isEmpty { parts.append("moved " + moves.joined(separator: " and ")) }
            return parts.isEmpty ? "already in place" : parts.joined(separator: ", ")
        }
    }

    /// How far a search has got: the share done and, once that can be told,
    /// how long the rest will take.
    struct Progress: Sendable {
        var fraction: Double
        var secondsLeft: Double?
    }

    static let maxDegrees = 10.0
    static let maxShift = 0.15

    /// The transform that lays `b` best over `a`, two pictures of one size.
    ///
    /// `finest` is the largest size, on the longer side, the search refines
    /// at: the full size for the preview, where a pixel shows, less for a
    /// verdict, where it does not. Nil when cancelled.
    static func find(_ a: GrayImage, _ b: GrayImage, finest: Int = .max,
                     cancel: CancellationFlag? = nil,
                     progress: (@Sendable (Progress) -> Void)? = nil) -> (Transform, cost: Double)? {
        guard a.width == b.width, a.height == b.height, a.width > 1, a.height > 1 else {
            return (.identity, 0)
        }
        // The pyramid, finest first, as far down as about a hundred pixels.
        var levels: [(GrayImage, GrayImage)] = [(a, b)]
        while let last = levels.last, max(last.0.width, last.0.height) > 100 {
            levels.append((last.0.halved(), last.1.halved()))
        }
        levels.reverse()
        // Not finer than asked: the levels above it are left out.
        while levels.count > 1, Double(max(levels.last!.0.width, levels.last!.0.height)) > Double(finest) * 1.5 {
            levels.removeLast()
        }
        let normalized = levels.map { ($0.0.normalized(), $0.1.normalized()) }

        // The work, in pixel comparisons, for the progress bar.
        let coarse = normalized[0].0
        let radius = Double(max(coarse.width, coarse.height)) / 2
        let coarseStep = max(1 / radius, 0.25 * .pi / 180)
        let angleCount = Int((maxDegrees * .pi / 180) / coarseStep)
        let shiftX = max(Int(Double(coarse.width) * maxShift), 1)
        let shiftY = max(Int(Double(coarse.height) * maxShift), 1)
        let shiftsPerAngle: Int = (2 * shiftX + 1) * (2 * shiftY + 1)
        let coarsePixels = Double(coarse.pixels.count)
        let coarseAngles: Int = 2 * angleCount + 1
        let coarseWork = Double(coarseAngles * shiftsPerAngle) * coarsePixels
        let fineAngles = 5, fineShift = 2
        let fineSide: Int = 2 * fineShift + 1
        let finePerPixel = Double(fineAngles * fineSide * fineSide)
        var fineWork = 0.0
        for level in normalized.dropFirst() { fineWork += finePerPixel * Double(level.0.pixels.count) }
        let total = coarseWork + fineWork
        var done = 0.0
        let start = Date()
        var lastReport = Date.distantPast
        func advance(_ work: Double) {
            done += work
            guard let progress, Date().timeIntervalSince(lastReport) > 0.1 else { return }
            lastReport = Date()
            let fraction = min(done / total, 1)
            let elapsed = Date().timeIntervalSince(start)
            progress(Progress(fraction: fraction,
                              secondsLeft: fraction > 0.02 ? elapsed / fraction * (1 - fraction) : nil))
        }

        // The coarse level: everything.
        var best = (angle: 0.0, x: 0, y: 0, cost: Double.infinity)
        for step in -angleCount...angleCount {
            if cancel?.isCancelled == true { return nil }
            let angle = Double(step) * coarseStep
            let (turned, valid) = normalized[0].1.rotated(by: angle)
            for y in -shiftY...shiftY {
                for x in -shiftX...shiftX {
                    let cost = Self.cost(normalized[0].0, turned, valid, x, y)
                    if cost < best.cost { best = (angle, x, y, cost) }
                }
            }
            advance(Double(shiftsPerAngle) * coarsePixels)
        }

        // Each finer level: around the best of the one before.
        var angleStep = coarseStep
        for level in normalized.dropFirst() {
            if cancel?.isCancelled == true { return nil }
            angleStep /= 2
            let around = (angle: best.angle, x: best.x * 2, y: best.y * 2)
            best.cost = .infinity
            for step in -(fineAngles / 2)...(fineAngles / 2) {
                if cancel?.isCancelled == true { return nil }
                let angle = around.angle + Double(step) * angleStep
                let (turned, valid) = level.1.rotated(by: angle)
                for y in (around.y - fineShift)...(around.y + fineShift) {
                    for x in (around.x - fineShift)...(around.x + fineShift) {
                        let cost = Self.cost(level.0, turned, valid, x, y)
                        if cost < best.cost { best = (angle, x, y, cost) }
                    }
                }
                advance(Double(fineSide * fineSide) * Double(level.0.pixels.count))
            }
        }
        progress?(Progress(fraction: 1, secondsLeft: 0))
        let finestLevel = normalized.last!.0
        return (Transform(angle: best.angle,
                          dx: Double(best.x) / Double(finestLevel.width),
                          dy: Double(best.y) / Double(finestLevel.height)), best.cost)
    }

    /// The mean squared difference of `a` and the turned `b` moved by
    /// (`dx`, `dy`), over where both are; infinite when that is less than
    /// half of the picture, so the search cannot win by sliding the two apart.
    private static func cost(_ a: GrayImage, _ turned: [Float], _ valid: [Float],
                             _ dx: Int, _ dy: Int) -> Double {
        let w = a.width, h = a.height
        let x0 = max(0, dx), x1 = min(w, w + dx)
        let y0 = max(0, dy), y1 = min(h, h + dy)
        guard x1 > x0, y1 > y0 else { return .infinity }
        var sum: Float = 0
        var count: Float = 0
        a.pixels.withUnsafeBufferPointer { pa in
            turned.withUnsafeBufferPointer { pb in
                valid.withUnsafeBufferPointer { pv in
                    for y in y0..<y1 {
                        let rowA = y * w, rowB = (y - dy) * w - dx
                        var rowSum: Float = 0
                        var rowCount: Float = 0
                        for x in x0..<x1 {
                            let m = pv[rowB + x]
                            let d = pa[rowA + x] - pb[rowB + x]
                            rowSum += m * d * d
                            rowCount += m
                        }
                        sum += rowSum
                        count += rowCount
                    }
                }
            }
        }
        guard count >= Float(w * h) / 2 else { return .infinity }
        return Double(sum / count)
    }
}
