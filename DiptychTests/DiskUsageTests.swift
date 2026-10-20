import XCTest
import CoreGraphics
@testable import Diptych

/// The Disk Usage window's two pure pieces: the squarified treemap layout and
/// the folder scan that feeds it.
final class DiskUsageTests: XCTestCase {

    // MARK: - Treemap

    func testSquarifyFillsTheRectangleWithProportionalAreas() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)   // area 20,000
        let items: [(item: String, weight: Double)] =
            [("a", 50), ("b", 30), ("c", 20)]                    // total 100
        let placed = Treemap.squarify(items, in: rect)
        XCTAssertEqual(placed.count, 3)

        // Each area is proportional to its weight (half the total area for a,
        // and so on), within rounding.
        let total = 20_000.0
        for placement in placed {
            let expected = (items.first { $0.item == placement.item }!.weight / 100) * total
            let area = Double(placement.rect.width * placement.rect.height)
            XCTAssertEqual(area, expected, accuracy: expected * 0.02,
                           "\(placement.item) area off")
        }

        // Everything stays inside the rectangle.
        for placement in placed {
            XCTAssertTrue(rect.insetBy(dx: -0.5, dy: -0.5).contains(placement.rect),
                          "\(placement.item) escaped the rectangle")
        }
    }

    func testSquarifyCoversTheAreaWithoutOverlap() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 200)
        let items: [(item: Int, weight: Double)] = (1...12).map { ($0, Double($0 * $0)) }
        let placed = Treemap.squarify(items, in: rect)

        // The pieces add up to the whole rectangle's area.
        let covered = placed.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        XCTAssertEqual(covered, Double(rect.width * rect.height), accuracy: 1)

        // No two rectangles overlap (beyond the shared edges).
        for i in placed.indices {
            for j in (i + 1)..<placed.count {
                let overlap = placed[i].rect.insetBy(dx: 0.5, dy: 0.5)
                    .intersection(placed[j].rect.insetBy(dx: 0.5, dy: 0.5))
                XCTAssertTrue(overlap.isNull || overlap.width < 0.5 || overlap.height < 0.5,
                              "\(placed[i].item) overlaps \(placed[j].item)")
            }
        }
    }

    func testSquarifyDropsZeroAndNegativeWeights() {
        let placed = Treemap.squarify([("keep", 10), ("zero", 0), ("neg", -5)],
                                      in: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(placed.map(\.item), ["keep"])
    }

    // MARK: - Scanning

    func testScanSumsSizesUpTheTree() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychUsage-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data(repeating: 0, count: 4096).write(to: root.appendingPathComponent("a.bin"))
        try Data(repeating: 0, count: 8192).write(to: sub.appendingPathComponent("b.bin"))

        let node = try XCTUnwrap(DiskUsage.scan(root, cancelled: CancellationFlag()))
        XCTAssertTrue(node.isDirectory)
        // The total is at least the logical bytes written (allocation rounds up).
        XCTAssertGreaterThanOrEqual(node.size, 4096 + 8192)

        // Children are largest first: the sub-folder (8 KB) before the 4 KB file.
        XCTAssertEqual(node.children.first?.name, "sub")
        XCTAssertTrue(node.children.first?.isDirectory ?? false)

        // Flattening gives one leaf per file, both of them.
        var files: [DiskUsage.Node] = []
        node.files(into: &files)
        XCTAssertEqual(Set(files.map(\.name)), ["a.bin", "b.bin"])
    }

    func testScanReturnsNilWhenCancelledUpFront() {
        let flag = CancellationFlag()
        flag.cancel()
        XCTAssertNil(DiskUsage.scan(URL(fileURLWithPath: "/"), cancelled: flag))
    }
}
