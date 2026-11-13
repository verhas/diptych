import XCTest
@testable import Diptych

/// Where icons go in the icon view, and how the keyboard moves among them.
final class IconLayoutTests: XCTestCase {

    private let metrics = IconLayout.Metrics(iconSize: 64, fontSize: 12)
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }
    private func ids(_ count: Int) -> [URL] { (0 ..< count).map { url("f\($0)") } }

    /// Room for exactly three cells across.
    private var threeWide: CGFloat { metrics.cellWidth * 3 + 2 * metrics.margin }

    func testTheGridFillsRowsAcrossTheWidth() throws {
        let layout = IconLayout.grid(ids(7), width: threeWide, metrics: metrics)
        let rows = Set(ids(7).map { layout.iconRect(of: $0)!.midY })
        XCTAssertEqual(rows.count, 3)
        // The fourth starts the second row, under the first.
        let first = try XCTUnwrap(layout.iconRect(of: url("f0")))
        let fourth = try XCTUnwrap(layout.iconRect(of: url("f3")))
        XCTAssertEqual(first.midX, fourth.midX)
        XCTAssertGreaterThan(fourth.midY, first.midY)
        XCTAssertLessThanOrEqual(layout.contentSize.width, threeWide)
    }

    func testANarrowPaneStillHasOneColumn() {
        let layout = IconLayout.grid(ids(3), width: 10, metrics: metrics)
        XCTAssertEqual(Set(ids(3).map { layout.iconRect(of: $0)!.midX }).count, 1)
    }

    func testSavedPositionsAreUsedAndTheRestFillFreeCells() throws {
        let grid = IconLayout.grid(ids(2), width: threeWide, metrics: metrics)
        // Something placed by hand in the first cell of the grid.
        let firstCell = try XCTUnwrap(grid.iconRect(of: url("f0"))).center
        let far = CGPoint(x: 900, y: 700)
        let layout = IconLayout.saved(
            [(url("a"), "a"), (url("b"), "b"), (url("c"), "c")],
            positions: ["b": firstCell, "c": far], width: threeWide, metrics: metrics)
        XCTAssertEqual(layout.iconRect(of: url("b"))?.center, firstCell)
        XCTAssertEqual(layout.iconRect(of: url("c"))?.center, far)
        // a was never placed: the first free cell, which is the second one.
        XCTAssertEqual(layout.iconRect(of: url("a"))?.center,
                       try XCTUnwrap(grid.iconRect(of: url("f1"))).center)
        // The content reaches the icon placed far off.
        XCTAssertGreaterThan(layout.contentSize.width, far.x)
        XCTAssertGreaterThan(layout.contentSize.height, far.y)
    }

    func testHittingAnIconOrItsName() throws {
        let layout = IconLayout.grid(ids(3), width: threeWide, metrics: metrics)
        let icon = try XCTUnwrap(layout.iconRect(of: url("f1")))
        let label = try XCTUnwrap(layout.labelRect(of: url("f1")))
        XCTAssertEqual(layout.item(at: icon.center), url("f1"))
        XCTAssertEqual(layout.item(at: label.center), url("f1"))
        XCTAssertNil(layout.item(at: CGPoint(x: 1, y: 1)))
    }

    func testARubberBandTakesWhatItTouches() throws {
        let layout = IconLayout.grid(ids(6), width: threeWide, metrics: metrics)
        let a = try XCTUnwrap(layout.iconRect(of: url("f0")))
        let b = try XCTUnwrap(layout.iconRect(of: url("f1")))
        let band = a.union(b).insetBy(dx: 10, dy: 10)
        XCTAssertEqual(layout.items(in: band), [url("f0"), url("f1")])
    }

    func testCleanUpPutsEveryIconOnAGridPointInNoNewOrder() throws {
        let grid = IconLayout.grid(ids(6), width: threeWide, metrics: metrics)
        func point(_ id: String) throws -> CGPoint { try XCTUnwrap(grid.iconRect(of: url(id))).center }
        // Placed by hand, a little off the grid: b right of a, c below a,
        // and d just off the very point a is nearest to.
        let off = CGPoint(x: 9, y: -7)
        let placed: [String: CGPoint] = [
            "a": try point("f0") + off,
            "b": try point("f1") + off,
            "c": try point("f3") + off,
            "d": try point("f0") + CGPoint(x: 20, y: 12),
        ]
        let layout = IconLayout.saved(["a", "b", "c", "d"].map { (url($0), $0) },
                                      positions: placed, width: threeWide, metrics: metrics)
        let cleaned = layout.cleanedUp(width: threeWide)
        let points = Set(try (0 ..< 6).map { try point("f\($0)") })
        XCTAssertTrue(cleaned.values.allSatisfy { points.contains($0) }, "all on the grid")
        XCTAssertEqual(Set(cleaned.values).count, 4, "no two on one point")
        // Each as near as it can be: a, b and c on their own points; a was
        // first there, so d goes next door.
        XCTAssertEqual(cleaned[url("a")], try point("f0"))
        XCTAssertEqual(cleaned[url("b")], try point("f1"))
        XCTAssertEqual(cleaned[url("c")], try point("f3"))
    }

    func testADroppedIconDoesNotLandOnAnother() throws {
        let grid = IconLayout.grid(ids(6), width: threeWide, metrics: metrics)
        func point(_ id: String) throws -> CGPoint { try XCTUnwrap(grid.iconRect(of: url(id))).center }
        // b dropped almost on top of a; c dropped in open space.
        let open = try point("f5") + CGPoint(x: 7, y: 9)
        let centres: [URL: CGPoint] = [
            url("a"): try point("f0"),
            url("b"): try point("f0") + CGPoint(x: 10, y: 5),
            url("c"): open,
        ]
        let cleared = IconLayout.clearingOverlaps(centres, moving: [url("b"), url("c")],
                                                  width: threeWide, metrics: metrics)
        XCTAssertEqual(cleared[url("a")], try point("f0"), "what was not moved stays")
        XCTAssertEqual(cleared[url("c")], open, "open space is kept as dropped")
        // b goes to the nearest free point: next to a, not on it.
        let b = try XCTUnwrap(cleared[url("b")])
        XCTAssertNotEqual(b, try point("f0"))
        XCTAssertTrue([try point("f1"), try point("f3")].contains(b))
    }

    func testAGroupDroppedOnOthersFindsRoomForEach() {
        let grid = IconLayout.grid(ids(9), width: threeWide, metrics: metrics)
        let first = grid.iconRect(of: url("f0"))!.center
        // Three icons sit in the first row; three more dropped on the first.
        var centres: [URL: CGPoint] = [:]
        for index in 0 ..< 3 { centres[url("still\(index)")] = grid.iconRect(of: url("f\(index)"))!.center }
        for index in 0 ..< 3 { centres[url("moved\(index)")] = first + CGPoint(x: CGFloat(index), y: 0) }
        let cleared = IconLayout.clearingOverlaps(
            centres, moving: Set((0 ..< 3).map { url("moved\($0)") }), width: threeWide, metrics: metrics)
        XCTAssertEqual(Set(cleared.values).count, 6, "no two in one place")
    }

    func testArrowsMoveThroughTheGrid() {
        let layout = IconLayout.grid(ids(7), width: threeWide, metrics: metrics)
        XCTAssertEqual(layout.neighbour(of: url("f0"), .right), url("f1"))
        XCTAssertEqual(layout.neighbour(of: url("f1"), .left), url("f0"))
        XCTAssertEqual(layout.neighbour(of: url("f1"), .down), url("f4"))
        XCTAssertEqual(layout.neighbour(of: url("f4"), .up), url("f1"))
        XCTAssertNil(layout.neighbour(of: url("f0"), .left))
        XCTAssertNil(layout.neighbour(of: url("f0"), .up))
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

private func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
