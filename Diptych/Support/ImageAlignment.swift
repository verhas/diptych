import Foundation

/// The turn, the size and the move that lay one picture over another best:
/// what makes two scans of one page comparable, since no two land on the
/// glass the same, and a copy may have been scaled to fit.
///
/// Searched, coarse to fine, rather than solved. On a picture a hundred
/// pixels across, every turn up to `maxDegrees` either way, every size up to
/// `maxScale` larger or smaller and every move up to `maxShift` of its size is
/// tried; each finer level, twice the size, only looks around the best of the
/// one before. What is minimised is the mean squared difference of the two
/// after each is brought to the same brightness and contrast -- two scans are
/// rarely exposed alike -- over the part where both have something.
///
/// The turns and sizes are tried side by side, one per processor core.
enum ImageAlignment {

    /// B turned `quarterTurns` quarters clockwise -- drawn so, as a page of
    /// that shape, by `PagePair.render` -- then `angle` radians clockwise and
    /// made `scale` times its size, both about its centre, then moved by `dx`
    /// and `dy`: as fractions of its width and height, so the answer holds at
    /// any size it is shown at.
    ///
    /// `angle`, `scale` and the move are what the pixel search finds; the
    /// quarter turns are chosen before it, since a picture cannot be turned
    /// a quarter within the frame of another shape without losing its ends.
    struct Transform: Sendable, Equatable, Hashable, Codable {
        var angle: Double
        var dx: Double
        var dy: Double
        var scale: Double = 1
        var quarterTurns: Int = 0

        static let identity = Transform(angle: 0, dx: 0, dy: 0)

        /// The fine turn alone, in degrees.
        var degrees: Double { angle * 180 / .pi }

        /// The whole turn, quarter turns and all, from -180 to 180 degrees.
        var totalDegrees: Double {
            var total = Double(quarterTurns) * 90 + degrees
            while total > 180 { total -= 360 }
            while total <= -180 { total += 360 }
            return total
        }

        /// This transform without its quarter turns: what is applied to a B
        /// already drawn turned.
        var fine: Transform {
            var fine = self
            fine.quarterTurns = 0
            return fine
        }

        /// "turned 0.42° clockwise, made 3.0% larger, moved 1.2% right and 0.3% down".
        var description: String {
            var parts: [String] = []
            let total = totalDegrees
            let turn = abs(total)
            if turn >= 0.05 {
                parts.append("turned " + String(format: "%.2f", turn) + "\u{B0} "
                             + (total > 0 ? "clockwise" : "anticlockwise"))
            }
            if abs(scale - 1) >= 0.0005 {
                parts.append("made " + String(format: "%.1f", abs(scale - 1) * 100) + "% "
                             + (scale > 1 ? "larger" : "smaller"))
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

    /// How far a search has got: the share done, once that can be told how
    /// long the rest will take, and the best fit found so far.
    struct Progress: Sendable {
        var fraction: Double
        var secondsLeft: Double?
        var best: Transform? = nil
        var similarity: Double? = nil
    }

    static let maxDegrees = 10.0
    static let maxScale = 0.10
    static let maxShift = 0.15

    /// How alike two pictures are, 0 to 1, from the cost of laying one over
    /// the other: for two brought to a mean of 0 and a spread of 1, the mean
    /// squared difference is twice one less their correlation. Paper counts
    /// for nothing in it, so two pages of other text do not come out alike
    /// for being mostly white.
    static func similarity(cost: Double) -> Double {
        cost.isFinite ? min(max(1 - cost / 2, 0), 1) : 0
    }

    /// How alike `a` and `b` are with `transform` applied to `b`.
    static func similarity(_ a: GrayImage, _ b: GrayImage, _ transform: Transform = .identity) -> Double {
        guard a.width == b.width, a.height == b.height else { return 0 }
        let na = a.normalized(), nb = b.normalized()
        let (warped, valid) = nb.warped(angle: transform.angle, scale: transform.scale)
        let x = Int((transform.dx * Double(a.width)).rounded())
        let y = Int((transform.dy * Double(a.height)).rounded())
        return similarity(cost: cost(na, warped, valid, x, y))
    }

    /// A transform found, how alike the two are laid so, and how fine a
    /// picture it was found on: the longer side, in pixels. The transform
    /// holds at any size; only its precision is that of `finest`.
    struct Fit: Sendable, Equatable, Codable {
        var transform: Transform
        var similarity: Double
        var finest: Int
    }

    /// The transform that lays `b` best over `a`, two pictures of one size,
    /// and how alike they are laid so.
    ///
    /// `finest` is the largest size, on the longer side, the search refines
    /// at: the full size for the preview, where a pixel shows, less for a
    /// verdict, where it does not. Given `around`, a fit found before at a
    /// coarser size, the search does not start over: it looks around that fit
    /// at its size and refines from there, a fraction of the work. Nil when
    /// cancelled.
    static func find(_ a: GrayImage, _ b: GrayImage, finest: Int = .max, around: Fit? = nil,
                     cancel: CancellationFlag? = nil,
                     progress: (@Sendable (Progress) -> Void)? = nil) -> Fit? {
        guard a.width == b.width, a.height == b.height, a.width > 1, a.height > 1 else {
            return Fit(transform: .identity, similarity: 1, finest: max(a.width, a.height))
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
        func longSide(_ index: Int) -> Int { max(normalized[index].0.width, normalized[index].0.height) }

        // Where the local search begins: the level the earlier fit was found
        // at, or the one above the coarse level searched in full.
        var first = 1
        if let around {
            first = (0..<normalized.count).last { Double(longSide($0)) <= Double(around.finest) * 1.1 } ?? 0
        }

        // The coarse level's steps: a turn or a size that moves the edge by
        // about a pixel.
        let coarse = normalized[0].0
        let radius = Double(max(coarse.width, coarse.height)) / 2
        let coarseStep = max(1 / radius, 0.25 * .pi / 180)
        let angleCount = Int((maxDegrees * .pi / 180) / coarseStep)
        let scaleCount = Int(maxScale / coarseStep)
        let shiftX = max(Int(Double(coarse.width) * maxShift), 1)
        let shiftY = max(Int(Double(coarse.height) * maxShift), 1)

        // How far around the best of the level before each level looks: on
        // the small ones two steps each way, to make up for how little a few
        // pixels tell; on the large ones one, which is all the level before
        // leaves open -- its step is two of these, its pixel two of these.
        // Most of the work is on the largest.
        func reach(_ index: Int) -> (angles: Int, scales: Int, shift: Int) {
            longSide(index) <= 400 ? (2, 1, 2) : (1, 1, 1)
        }
        func work(_ index: Int) -> Double {
            let r = reach(index)
            return Double((2 * r.angles + 1) * (2 * r.scales + 1) * (2 * r.shift + 1) * (2 * r.shift + 1))
                * Double(normalized[index].0.pixels.count)
        }
        var total = 0.0
        if around == nil {
            let shifts = Double((2 * shiftX + 1) * (2 * shiftY + 1))
            let candidates = Double((2 * angleCount + 1) * (2 * scaleCount + 1))
            total += candidates * shifts * Double(coarse.pixels.count)
        }
        for index in first..<max(first, normalized.count) { total += work(index) }
        let turns = around?.transform.quarterTurns ?? 0
        let search = Search(total: total, quarterTurns: turns, progress: progress)

        if let around {
            // From the fit before, in pixels of the level it was found at.
            let level = normalized[first].0
            search.seed(Candidate(angle: around.transform.angle, scale: around.transform.scale,
                                  x: Int((around.transform.dx * Double(level.width)).rounded()),
                                  y: Int((around.transform.dy * Double(level.height)).rounded()),
                                  cost: .infinity))
        } else {
            // The coarse level: everything.
            var candidates: [(angle: Double, scale: Double)] = []
            for a in -angleCount...angleCount {
                for s in -scaleCount...scaleCount {
                    candidates.append((Double(a) * coarseStep, 1 + Double(s) * coarseStep))
                }
            }
            search.level(width: coarse.width, height: coarse.height)
            search.run(candidates, shiftsX: -shiftX...shiftX, shiftsY: -shiftY...shiftY,
                       level: normalized[0], cancel: cancel)
            if cancel?.isCancelled == true { return nil }
        }

        // Each finer level: around the best of the one before, in steps that
        // move its edge by about a pixel.
        for index in first..<max(first, normalized.count) {
            let level = normalized[index]
            let step = 2 / Double(longSide(index))
            let near = search.restart(scaledBy: index == first && around != nil ? 1 : 2)
            search.level(width: level.0.width, height: level.0.height)
            let r = reach(index)
            var candidates: [(angle: Double, scale: Double)] = []
            for a in -r.angles...r.angles {
                for s in -r.scales...r.scales {
                    candidates.append((near.angle + Double(a) * step, near.scale + Double(s) * step))
                }
            }
            search.run(candidates, shiftsX: (near.x - r.shift)...(near.x + r.shift),
                       shiftsY: (near.y - r.shift)...(near.y + r.shift),
                       level: level, cancel: cancel)
            if cancel?.isCancelled == true { return nil }
        }
        let best = search.best
        let finestLevel = normalized.last!.0
        let found = Transform(angle: best.angle, dx: Double(best.x) / Double(finestLevel.width),
                              dy: Double(best.y) / Double(finestLevel.height), scale: best.scale,
                              quarterTurns: turns)
        progress?(Progress(fraction: 1, secondsLeft: 0, best: found, similarity: similarity(cost: best.cost)))
        return Fit(transform: found, similarity: similarity(cost: best.cost), finest: longSide(normalized.count - 1))
    }

    /// One candidate: a turn, a size and a move, in pixels of its level.
    private struct Candidate {
        var angle: Double
        var scale: Double
        var x: Int
        var y: Int
        var cost: Double
    }

    /// The best so far and the work done, shared by the cores searching.
    private final class Search: @unchecked Sendable {
        private let lock = NSLock()
        private let total: Double
        private let quarterTurns: Int
        private let progress: (@Sendable (Progress) -> Void)?
        private let start = Date()
        private var done = 0.0
        private var lastReport = Date.distantPast
        private var width = 1
        private var height = 1
        private(set) var best = Candidate(angle: 0, scale: 1, x: 0, y: 0, cost: .infinity)

        init(total: Double, quarterTurns: Int, progress: (@Sendable (Progress) -> Void)?) {
            self.total = total
            self.quarterTurns = quarterTurns
            self.progress = progress
        }

        /// The size of the level now searched, to give a move as a fraction.
        func level(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        /// Where a search that does not start from nothing starts.
        func seed(_ candidate: Candidate) {
            best = candidate
        }

        /// The best of the level before, brought to the next one, and the
        /// search begun anew around it.
        func restart(scaledBy factor: Int) -> Candidate {
            var around = best
            around.x *= factor
            around.y *= factor
            best.cost = .infinity
            return around
        }

        func run(_ candidates: [(angle: Double, scale: Double)], shiftsX: ClosedRange<Int>,
                 shiftsY: ClosedRange<Int>, level: (GrayImage, GrayImage), cancel: CancellationFlag?) {
            let work = Double(shiftsX.count * shiftsY.count * level.0.pixels.count)
            DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
                if cancel?.isCancelled == true { return }
                let (angle, scale) = candidates[index]
                let (warped, valid) = level.1.warped(angle: angle, scale: scale)
                var local = Candidate(angle: angle, scale: scale, x: 0, y: 0, cost: .infinity)
                for y in shiftsY {
                    for x in shiftsX {
                        let cost = ImageAlignment.cost(level.0, warped, valid, x, y)
                        if cost < local.cost { local.x = x; local.y = y; local.cost = cost }
                    }
                }
                offer(local, work: work)
            }
        }

        private func offer(_ candidate: Candidate, work: Double) {
            lock.lock()
            done += work
            if candidate.cost < best.cost { best = candidate }
            let now = Date()
            guard let progress, now.timeIntervalSince(lastReport) > 0.1 else {
                lock.unlock()
                return
            }
            lastReport = now
            let fraction = min(done / total, 1)
            let elapsed = now.timeIntervalSince(start)
            let report = Progress(
                fraction: fraction,
                secondsLeft: fraction > 0.02 ? elapsed / fraction * (1 - fraction) : nil,
                best: best.cost.isFinite
                    ? Transform(angle: best.angle, dx: Double(best.x) / Double(width),
                                dy: Double(best.y) / Double(height), scale: best.scale,
                                quarterTurns: quarterTurns)
                    : nil,
                similarity: best.cost.isFinite ? ImageAlignment.similarity(cost: best.cost) : nil)
            lock.unlock()
            progress(report)
        }
    }

    /// The mean squared difference of `a` and the warped `b` moved by
    /// (`dx`, `dy`), over where both are; infinite when that is less than
    /// half of the picture, so the search cannot win by sliding the two apart.
    fileprivate static func cost(_ a: GrayImage, _ turned: [Float], _ valid: [Float],
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
