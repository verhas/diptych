import XCTest
@testable import Diptych

/// Writing `.DS_Store`: what is written reads back as it was, laid out the
/// way Finder lays its own files out.
final class DSStoreWriterTests: XCTestCase {

    private func records(_ count: Int, blob: Int = 16) -> [DSStore.Record] {
        (0 ..< count).flatMap { index -> [DSStore.Record] in
            let name = "file \(String(format: "%05d", index)).txt"
            return [
                DSStore.Record(entry: name, key: "Iloc",
                               value: .blob(Data(repeating: UInt8(index & 0xFF), count: blob))),
                DSStore.Record(entry: name, key: "moDD", value: .long(UInt64(index)),
                               valueType: "dutc"),
            ]
        }
    }

    private func same(_ a: [DSStore.Record], _ b: [DSStore.Record]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { x, y in
            x.entry == y.entry && x.key == y.key && "\(x.value)" == "\(y.value)"
        }
    }

    func testEveryKindOfValueComesBack() throws {
        let written: [DSStore.Record] = [
            .init(entry: ".", key: "vstl", value: .code("icnv")),
            .init(entry: ".", key: "ICVO", value: .flag(true)),
            .init(entry: "a", key: "dscl", value: .flag(false)),
            .init(entry: "a", key: "lg1S", value: .long(1 << 40)),
            .init(entry: "a", key: "vSrn", value: .integer(1)),
            .init(entry: "a", key: "cmmt", value: .text("Grüße, 日本")),
            .init(entry: "b", key: "Iloc", value: .blob(FinderIconPositions.iloc(CGPoint(x: 10, y: 20)))),
        ]
        let store = try DSStore(data: DSStoreWriter.encode(written))
        XCTAssertTrue(store.isComplete)
        XCTAssertTrue(same(store.records, DSStoreWriter.sorted(written)))
    }

    func testTypeCodesAreKept() throws {
        let written: [DSStore.Record] = [
            .init(entry: "a", key: "moDD", value: .long(5), valueType: "dutc"),
            .init(entry: "a", key: "lg1S", value: .long(5), valueType: "comp"),
            .init(entry: "a", key: "fwvh", value: .integer(5), valueType: "shor"),
        ]
        let store = try DSStore(data: DSStoreWriter.encode(written))
        XCTAssertEqual(Set(store.records.map(\.valueType)), ["dutc", "comp", "shor"])
    }

    func testRecordsAreInFindersOrder() throws {
        let written: [DSStore.Record] = [
            .init(entry: "b", key: "Iloc", value: .flag(true)),
            .init(entry: "A", key: "moDD", value: .flag(true)),
            .init(entry: "a", key: "Iloc", value: .flag(true)),
        ]
        let read = try DSStore(data: DSStoreWriter.encode(written)).records
        // By name without regard to case, then by key: "Iloc" before "moDD".
        XCTAssertEqual(read.map { $0.entry + $0.key }, ["aIloc", "AmoDD", "bIloc"])
    }

    func testAnEmptyStoreIsAValidFile() throws {
        let store = try DSStore(data: DSStoreWriter.encode([]))
        XCTAssertEqual(store.records.count, 0)
        XCTAssertEqual(store.nodes, 1)
    }

    /// Thousands of records need more than one node, and then inner nodes
    /// whose records are real records -- all of which must come back.
    func testABigTreeComesBackWhole() throws {
        let written = records(3000)
        let store = try DSStore(data: DSStoreWriter.encode(written))
        XCTAssertTrue(store.isComplete)
        XCTAssertGreaterThan(store.nodes, 1)
        XCTAssertGreaterThan(store.levels, 0)
        XCTAssertTrue(same(store.records, DSStoreWriter.sorted(written)))
    }

    /// Every size up to a few nodes' worth, so that where the last record
    /// lands -- in a node, or up as a separator -- is tried every way.
    func testEveryBoundaryComesBack() throws {
        for count in stride(from: 1, through: 400, by: 7) {
            let written = records(count, blob: 300)
            let store = try DSStore(data: DSStoreWriter.encode(written))
            XCTAssertTrue(store.isComplete, "\(count)")
            XCTAssertTrue(same(store.records, DSStoreWriter.sorted(written)), "\(count)")
        }
    }

    func testNodesAreNoBiggerThanAPage() {
        var nodes: [[UInt8]] = []
        let items = (0 ..< 50).map { [UInt8](repeating: UInt8($0), count: 500) }
        let level = DSStoreWriter.pack(items, children: nil, into: &nodes)
        XCTAssertTrue(nodes.allSatisfy { $0.count <= DSStoreWriter.pageSize })
        XCTAssertEqual(level.nodes.count, level.separators.count + 1)
        XCTAssertFalse(nodes.contains { $0.count <= 8 }, "no empty node")
    }

    func testARecordTooBigForANodeIsRefused() {
        let huge = DSStore.Record(entry: "a", key: "bwsp", value: .blob(Data(count: 5000)))
        XCTAssertThrowsError(try DSStoreWriter.encode([huge]))
    }

    /// The bookkeeping must say exactly what is free: no block also listed as
    /// free, no two blocks overlapping, every block aligned to its size.
    func testTheAllocatorsBooksAreRight() throws {
        let data = try DSStoreWriter.encode(records(3000))
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> UInt32 { bytes[at ..< at + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        XCTAssertEqual(Array(bytes[0 ..< 8]), [0, 0, 0, 1] + Array("Bud1".utf8))
        let rootOffset = Int(u32(8))
        XCTAssertEqual(u32(16), u32(8))

        var at = 4 + rootOffset
        let count = Int(u32(at)); at += 8
        var used: [(Int, Int)] = [(0, 32)]
        for index in 0 ..< count {
            let address = u32(at + 4 * index)
            let offset = Int(address & ~0x1F), size = 1 << Int(address & 0x1F)
            XCTAssertEqual(offset % size, 0, "aligned")
            used.append((offset, size))
        }
        at += 4 * ((count + 255) / 256 * 256)
        let named = Int(u32(at)); at += 4
        for _ in 0 ..< named { at += 1 + Int(bytes[at]) + 4 }
        var free: [(Int, Int)] = []
        for sizeClass in 0 ..< 32 {
            let entries = Int(u32(at)); at += 4
            for _ in 0 ..< entries { free.append((Int(u32(at)), 1 << sizeClass)); at += 4 }
        }
        let all = (used + free).sorted { $0.0 < $1.0 }
        for (a, b) in zip(all, all.dropFirst()) {
            XCTAssertLessThanOrEqual(a.0 + a.1, b.0, "overlap at \(b.0)")
        }
        // Used and free together cover the whole space, with nothing lost.
        XCTAssertEqual(all.reduce(0) { $0 + $1.1 }, 1 << 31)
    }

    func testTheOldHeaderTailIsKept() throws {
        let tail: [UInt8] = [0, 0, 0x10, 0x0B] + [UInt8](repeating: 0, count: 12)
        let data = try DSStoreWriter.encode(records(3), headerTail: tail)
        XCTAssertEqual(DSStoreWriter.headerTail(of: data), tail)
    }

    // MARK: - Icon positions

    func testPlacingReplacesThePositionAndKeepsTheRest() throws {
        let old: [DSStore.Record] = [
            .init(entry: "a", key: "Iloc", value: .blob(FinderIconPositions.iloc(CGPoint(x: 1, y: 2)))),
            .init(entry: "a", key: "cmmt", value: .text("keep me")),
            .init(entry: "b", key: "Iloc", value: .blob(FinderIconPositions.iloc(CGPoint(x: 3, y: 4)))),
        ]
        let placed = FinderIconPositions.placing(["a": CGPoint(x: 100, y: 200)],
                                                 iconSize: 64, in: old)
        let layout = FinderIconPositions.layout(of: placed)
        XCTAssertEqual(layout.positions["a"], CGPoint(x: 100, y: 200))
        XCTAssertEqual(layout.positions["b"], CGPoint(x: 3, y: 4))
        XCTAssertTrue(placed.contains { $0.key == "cmmt" })
        XCTAssertEqual(placed.filter { $0.entry == "a" && $0.key == "Iloc" }.count, 1)
        XCTAssertEqual(layout.arrangeBy, "none")
        XCTAssertEqual(layout.iconSize, 64)
    }

    func testPlacingKeepsFindersOwnViewOptionsButStopsSorting() throws {
        let options: [String: Any] = ["arrangeBy": "name", "iconSize": 48.0, "gridSpacing": 100.0,
                                      "textSize": 16.0]
        let data = try PropertyListSerialization.data(fromPropertyList: options,
                                                      format: .binary, options: 0)
        let placed = FinderIconPositions.placing(
            ["a": .zero], iconSize: 64,
            in: [.init(entry: ".", key: "icvp", value: .blob(data))])
        let layout = FinderIconPositions.layout(of: placed)
        XCTAssertEqual(layout.arrangeBy, "none")
        XCTAssertEqual(layout.iconSize, 48, "Finder's size stays")
        XCTAssertEqual(layout.gridSpacing, 100)
    }

    func testTakingOverTheLayoutSetsTheIconSizeToo() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["arrangeBy": "name", "iconSize": 48.0], format: .binary, options: 0)
        let placed = FinderIconPositions.placing(
            ["a": .zero], iconSize: 64, settingSize: true,
            in: [.init(entry: ".", key: "icvp", value: .blob(data))])
        XCTAssertEqual(FinderIconPositions.layout(of: placed).iconSize, 64)
    }

    func testPositionsAreSigned() {
        let point = CGPoint(x: -20, y: 300)
        XCTAssertEqual(FinderIconPositions.position(from: FinderIconPositions.iloc(point)), point)
    }

    func testWritingMakesAStoreFinderAndDiptychRead() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSStoreWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try FinderIconPositions.write(["one": CGPoint(x: 50, y: 60)], iconSize: 64, in: folder)
        try FinderIconPositions.write(["two": CGPoint(x: 150, y: 60)], iconSize: 64, in: folder)
        let layout = FinderIconPositions.read(folder)
        XCTAssertEqual(layout.positions, ["one": CGPoint(x: 50, y: 60), "two": CGPoint(x: 150, y: 60)])
    }

    func testAStoreThatCannotBeReadIsNotOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSStoreWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let junk = Data([0, 0, 0, 1] + Array("Bud1".utf8) + [UInt8](repeating: 0xEE, count: 40))
        try junk.write(to: FinderIconPositions.storeURL(in: folder))

        XCTAssertThrowsError(try FinderIconPositions.write(["a": .zero], iconSize: 64, in: folder))
        XCTAssertEqual(try Data(contentsOf: FinderIconPositions.storeURL(in: folder)), junk)
    }
}
