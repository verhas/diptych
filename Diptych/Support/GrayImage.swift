import CoreGraphics
import Foundation

/// A picture reduced to what a comparison looks at: one brightness per pixel,
/// 0 for black and 1 for white, row by row from the top.
///
/// Grey, because whether two pages are the same page is a question about
/// where the ink is; colour adds three times the work and changes no answer a
/// scan comparison gives.
struct GrayImage: Sendable {

    let width: Int
    let height: Int
    var pixels: [Float]

    init(width: Int, height: Int, pixels: [Float]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// `image` drawn at exactly `width` x `height`, on white: a transparent
    /// part of a PNG is paper, not black.
    init?(_ image: CGImage, width: Int, height: Int) {
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height)
        let stride = context.bytesPerRow
        var pixels = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = Float(bytes[y * stride + x]) / 255
            }
        }
        self.init(width: width, height: height, pixels: pixels)
    }

    /// Half the size each way, each pixel the mean of the four it replaces.
    func halved() -> GrayImage {
        let w = max(width / 2, 1), h = max(height / 2, 1)
        var out = [Float](repeating: 0, count: w * h)
        pixels.withUnsafeBufferPointer { p in
            for y in 0..<h {
                let y0 = min(2 * y, height - 1), y1 = min(2 * y + 1, height - 1)
                for x in 0..<w {
                    let x0 = min(2 * x, width - 1), x1 = min(2 * x + 1, width - 1)
                    out[y * w + x] = (p[y0 * width + x0] + p[y0 * width + x1]
                                      + p[y1 * width + x0] + p[y1 * width + x1]) / 4
                }
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }

    /// Each pixel the mean of the 3 x 3 around it: scanner noise and JPEG's
    /// ringing averaged away, a changed letter not.
    func blurred() -> GrayImage {
        var out = [Float](repeating: 0, count: pixels.count)
        pixels.withUnsafeBufferPointer { p in
            for y in 0..<height {
                for x in 0..<width {
                    var sum: Float = 0
                    var count: Float = 0
                    for dy in -1...1 {
                        let yy = y + dy
                        guard yy >= 0, yy < height else { continue }
                        for dx in -1...1 {
                            let xx = x + dx
                            guard xx >= 0, xx < width else { continue }
                            sum += p[yy * width + xx]
                            count += 1
                        }
                    }
                    out[y * width + x] = sum / count
                }
            }
        }
        return GrayImage(width: width, height: height, pixels: out)
    }

    /// Shifted to a mean of zero and scaled to a spread of one, so two scans
    /// made at different exposures can be compared at all.
    func normalized() -> GrayImage {
        let n = Float(pixels.count)
        guard n > 0 else { return self }
        let mean = pixels.reduce(0, +) / n
        let variance = pixels.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        let spread = max(variance.squareRoot(), 1e-4)
        return GrayImage(width: width, height: height, pixels: pixels.map { ($0 - mean) / spread })
    }

    /// The picture turned by `angle` radians clockwise about its centre: each
    /// pixel of the result, with whether it came from inside the original.
    func rotated(by angle: Double) -> (pixels: [Float], valid: [Float]) {
        var out = [Float](repeating: 0, count: pixels.count)
        var valid = [Float](repeating: 0, count: pixels.count)
        let c = cos(angle), s = sin(angle)
        let cx = Double(width - 1) / 2, cy = Double(height - 1) / 2
        pixels.withUnsafeBufferPointer { p in
            for y in 0..<height {
                let py = Double(y) - cy
                for x in 0..<width {
                    let px = Double(x) - cx
                    // The inverse turn: where in the original this pixel was.
                    let sx = c * px + s * py + cx
                    let sy = -s * px + c * py + cy
                    guard sx >= 0, sy >= 0, sx <= Double(width - 1), sy <= Double(height - 1)
                    else { continue }
                    let x0 = Int(sx), y0 = Int(sy)
                    let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
                    let fx = Float(sx - Double(x0)), fy = Float(sy - Double(y0))
                    let top = p[y0 * width + x0] * (1 - fx) + p[y0 * width + x1] * fx
                    let bottom = p[y1 * width + x0] * (1 - fx) + p[y1 * width + x1] * fx
                    out[y * width + x] = top * (1 - fy) + bottom * fy
                    valid[y * width + x] = 1
                }
            }
        }
        return (out, valid)
    }

    /// This picture with `transform` applied -- turned, then moved -- and
    /// paper wherever nothing of it lands.
    func transformed(_ transform: ImageAlignment.Transform) -> GrayImage {
        let (turned, valid) = rotated(by: transform.angle)
        let tx = Int((transform.dx * Double(width)).rounded())
        let ty = Int((transform.dy * Double(height)).rounded())
        var out = [Float](repeating: 1, count: pixels.count)
        for y in 0..<height {
            let sy = y - ty
            guard sy >= 0, sy < height else { continue }
            for x in 0..<width {
                let sx = x - tx
                guard sx >= 0, sx < width, valid[sy * width + sx] > 0 else { continue }
                out[y * width + x] = turned[sy * width + sx]
            }
        }
        return GrayImage(width: width, height: height, pixels: out)
    }

    // MARK: - How alike two are

    /// The structural similarity of two pictures of one size, in 8 x 8
    /// blocks: 1 for the same, falling towards 0 as light, contrast and
    /// structure part. The mean over the blocks.
    static func ssim(_ a: GrayImage, _ b: GrayImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return 0 }
        let block = 8
        let c1 = 0.01 * 0.01, c2 = 0.03 * 0.03
        var total = 0.0
        var blocks = 0
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                var by = 0
                while by + block <= a.height {
                    var bx = 0
                    while bx + block <= a.width {
                        var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
                        for y in by..<(by + block) {
                            for x in bx..<(bx + block) {
                                let va = Double(pa[y * a.width + x]), vb = Double(pb[y * a.width + x])
                                sa += va; sb += vb
                                saa += va * va; sbb += vb * vb; sab += va * vb
                            }
                        }
                        let n = Double(block * block)
                        let ma = sa / n, mb = sb / n
                        let va = max(saa / n - ma * ma, 0), vb = max(sbb / n - mb * mb, 0)
                        let cov = sab / n - ma * mb
                        total += ((2 * ma * mb + c1) * (2 * cov + c2))
                            / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                        blocks += 1
                        bx += block
                    }
                    by += block
                }
            }
        }
        return blocks == 0 ? 1 : total / Double(blocks)
    }

    /// The worst-looking spot: in 16 x 16 blocks of the two pictures, each
    /// blurred first, the largest mean difference in brightness. Small for
    /// noise spread everywhere, large for one changed word -- which a mean
    /// over the whole page would dilute to nothing.
    ///
    /// A block that differs is given the benefit of a shift of up to
    /// `slack` pixels each way: a PDF written again can set a line of text a
    /// fraction of a pixel further along, which nobody can see and every
    /// block along the line would otherwise report. A changed letter is
    /// still a changed letter wherever it is moved.
    static func worstBlock(_ a: GrayImage, _ b: GrayImage, slack: Int = 2,
                           suspicious: Double = 0.03) -> Double {
        worstSpot(a, b, slack: slack, suspicious: suspicious).difference
    }

    /// `worstBlock`, and where that block is: its centre, as fractions of
    /// the width and the height from the top left.
    static func worstSpot(_ a: GrayImage, _ b: GrayImage, slack: Int = 2,
                          suspicious: Double = 0.03) -> (difference: Double, x: Double, y: Double) {
        guard a.width == b.width, a.height == b.height else { return (1, 0.5, 0.5) }
        let ba = a.blurred(), bb = b.blurred()
        let block = 16
        let w = a.width, h = a.height
        var worst = 0.0
        var at = (x: 0.5, y: 0.5)
        ba.pixels.withUnsafeBufferPointer { pa in
            bb.pixels.withUnsafeBufferPointer { pb in
                func difference(_ bx: Int, _ by: Int, _ dx: Int, _ dy: Int) -> Double {
                    var sum = 0.0
                    var count = 0
                    for y in by..<min(by + block, h) {
                        let sy = y + dy
                        guard sy >= 0, sy < h else { continue }
                        for x in bx..<min(bx + block, w) {
                            let sx = x + dx
                            guard sx >= 0, sx < w else { continue }
                            sum += Double(abs(pa[y * w + x] - pb[sy * w + sx]))
                            count += 1
                        }
                    }
                    return count == 0 ? 1 : sum / Double(count)
                }
                var by = 0
                while by < h {
                    var bx = 0
                    while bx < w {
                        var here = difference(bx, by, 0, 0)
                        if here > suspicious, slack > 0 {
                            for dy in -slack...slack {
                                for dx in -slack...slack where dx != 0 || dy != 0 {
                                    here = min(here, difference(bx, by, dx, dy))
                                }
                            }
                        }
                        if here > worst {
                            worst = here
                            at = (Double(bx + block / 2) / Double(w), Double(by + block / 2) / Double(h))
                        }
                        bx += block
                    }
                    by += block
                }
            }
        }
        return (worst, at.x, at.y)
    }

    /// "near the top left", "in the middle": where on a page a spot is.
    static func place(x: Double, y: Double) -> String {
        let row = y < 1.0 / 3 ? "top" : y < 2.0 / 3 ? "middle" : "bottom"
        let column = x < 1.0 / 3 ? "left" : x < 2.0 / 3 ? "" : "right"
        if row == "middle" { return column.isEmpty ? "in the middle" : "in the middle on the \(column)" }
        return column.isEmpty ? "near the \(row)" : "near the \(row) \(column)"
    }
}
