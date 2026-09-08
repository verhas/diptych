import XCTest
@testable import Diptych

/// The `.DS_Store` decoder.
///
/// Fixtures are built byte by byte rather than checked in, because the shapes
/// that matter -- a tree deep enough to have children, a truncated file, a value
/// type nobody has seen -- are exactly the ones you cannot count on finding.
final class DSStoreTests: XCTestCase {

    // MARK: - Building a Bud1 file

    /// Blocks are addressed as `offset | log2(size)` in the low five bits, so
    /// every block has to start on a 32-byte boundary.
    private struct Builder {
        /// (relative offset, size class) per block, and the block bodies.
        private var blocks: [[UInt8]] = []

        mutating func add(_ body: [UInt8]) -> Int {
            blocks.append(body)
            return blocks.count - 1
        }

        func build() -> Data {
            var payload: [UInt8] = []
            var addresses: [UInt32] = []
            // Block bodies start at relative offset 32; the first 32 bytes are
            // the outer header, which is not part of the allocator's space.
            var relative = 32

            for body in blocks {
                var sizeClass = 5
                while (1 << sizeClass) < max(body.count, 1) { sizeClass += 1 }
                let size = 1 << sizeClass
                addresses.append(UInt32(relative | sizeClass))
                payload += body + [UInt8](repeating: 0, count: size - body.count)
                relative += size
            }

            var directory: [UInt8] = []
            directory += be32(UInt32(addresses.count)) + be32(0)
            for address in addresses { directory += be32(address) }
            let padding = addresses.count % 256 == 0 ? 0 : 256 - addresses.count % 256
            directory += [UInt8](repeating: 0, count: padding * 4)
            directory += be32(1)                       // one named block
            directory += [4] + Array("DSDB".utf8) + be32(0)

            var file: [UInt8] = [0, 0, 0, 1] + Array("Bud1".utf8)
            file += be32(UInt32(relative)) + be32(UInt32(directory.count))
            file += be32(UInt32(relative))
            file += [UInt8](repeating: 0, count: 16)   // unused header tail
            file += payload
            file += directory
            return Data(file)
        }
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
         UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
    private func be32(_ value: UInt32) -> [UInt8] { Self.be32(value) }
    private static func be32(_ value: Int) -> [UInt8] { be32(UInt32(value)) }

    /// One record: name, four-character key, four-character type, value.
    private func record(_ name: String, _ key: String, _ type: String,
                        _ value: [UInt8]) -> [UInt8] {
        let units = Array(name.utf16)
        var out = Self.be32(units.count)
        for unit in units { out += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        return out + Array(key.utf8) + Array(type.utf8) + value
    }

    private func leaf(_ records: [[UInt8]]) -> [UInt8] {
        Self.be32(0) + Self.be32(records.count) + records.flatMap { $0 }
    }

    private func master(root: Int, levels: Int, records: Int, nodes: Int) -> [UInt8] {
        Self.be32(root) + Self.be32(levels) + Self.be32(records)
            + Self.be32(nodes) + Self.be32(4096)
    }

    private func blob(_ bytes: [UInt8]) -> [UInt8] { Self.be32(bytes.count) + bytes }

    // MARK: - Values

    func testEveryValueTypeDecodes() throws {
        var builder = Builder()
        _ = builder.add(master(root: 1, levels: 0, records: 6, nodes: 1))
        _ = builder.add(leaf([
            record("notes.txt", "vSrn", "long", Self.be32(1)),
            record("notes.txt", "dscl", "bool", [1]),
            record("notes.txt", "vstl", "type", Array("Nlsv".utf8)),
            record("notes.txt", "lg1S", "comp", [0, 0, 0, 0, 0, 0, 0x10, 0]),
            record("notes.txt", "cmmt", "ustr", Self.be32(2) + [0x00, 0x68, 0x00, 0x69]),
            record("notes.txt", "Iloc", "blob",
                   blob([0, 0, 0, 100, 0, 0, 0, 50] + [UInt8](repeating: 0xFF, count: 8))),
        ]))

        let store = try DSStore(data: builder.build())

        XCTAssertEqual(store.records.count, 6)
        guard case .integer(let version) = store.records[0].value else { return XCTFail() }
        XCTAssertEqual(version, 1)
        guard case .flag(let open) = store.records[1].value else { return XCTFail() }
        XCTAssertTrue(open)
        guard case .code(let style) = store.records[2].value else { return XCTFail() }
        XCTAssertEqual(style, "Nlsv")
        guard case .long(let size) = store.records[3].value else { return XCTFail() }
        XCTAssertEqual(size, 4096)
        guard case .text(let comment) = store.records[4].value else { return XCTFail() }
        XCTAssertEqual(comment, "hi")
        guard case .blob(let location) = store.records[5].value else { return XCTFail() }
        let point = try XCTUnwrap(DSStoreReport.iconPosition(location))
        XCTAssertEqual(point.x, 100)
        XCTAssertEqual(point.y, 50)
    }

    func testNamesAreReadAsUTF16() throws {
        var builder = Builder()
        _ = builder.add(master(root: 1, levels: 0, records: 1, nodes: 1))
        _ = builder.add(leaf([record("café-日本語", "vSrn", "long", Self.be32(1))]))

        let store = try DSStore(data: builder.build())

        XCTAssertEqual(store.records.first?.entry, "café-日本語")
    }

    // MARK: - The tree

    func testRecordsPastTheLastKeyAreNotLost() throws {
        // The rightmost child of an internal node trails the final record.
        // Missing it loses everything after that key -- with no error, and a
        // plausible-looking result, which is how the first version of this
        // decoder read 2 records out of a file that held 80.
        var builder = Builder()
        _ = builder.add(master(root: 1, levels: 1, records: 3, nodes: 3))
        _ = builder.add(Self.be32(3)                       // mode: rightmost child
                        + Self.be32(1)                     // one record in this node
                        + Self.be32(2)                     // child holding everything before it
                        + record("middle", "vSrn", "long", Self.be32(2)))
        _ = builder.add(leaf([record("first", "vSrn", "long", Self.be32(1))]))
        _ = builder.add(leaf([record("last", "vSrn", "long", Self.be32(3))]))

        let store = try DSStore(data: builder.build())

        XCTAssertEqual(store.records.map(\.entry), ["first", "middle", "last"],
                       "the tree must be walked in key order, rightmost child included")
    }

    func testRecordsAreGroupedByEntryInTreeOrder() throws {
        var builder = Builder()
        _ = builder.add(master(root: 1, levels: 0, records: 3, nodes: 1))
        _ = builder.add(leaf([
            record("alpha", "vSrn", "long", Self.be32(1)),
            record("alpha", "dscl", "bool", [0]),
            record("beta", "vSrn", "long", Self.be32(1)),
        ]))

        let grouped = try DSStore(data: builder.build()).byEntry

        XCTAssertEqual(grouped.map(\.entry), ["alpha", "beta"])
        XCTAssertEqual(grouped.first?.records.count, 2)
    }

    // MARK: - Refusing what it should refuse

    func testAFileThatMerelyBorrowedTheNameIsRejected() {
        // There is one of these on this machine: sixteen bytes of ASCII reading
        // "Input length = 1", written by something that was not Finder.
        let data = Data("Input length = 1".utf8)

        XCTAssertThrowsError(try DSStore(data: data)) { error in
            XCTAssertEqual(error as? DSStore.Failure, .notADSStore)
        }
    }

    func testTruncationThrowsRatherThanTrapping() throws {
        var builder = Builder()
        _ = builder.add(master(root: 1, levels: 0, records: 1, nodes: 1))
        _ = builder.add(leaf([record("notes.txt", "vSrn", "long", Self.be32(1))]))
        let whole = builder.build()

        // Every prefix must fail cleanly. An array subscript is not a bounds
        // check you can recover from, and this input is untrusted.
        for length in stride(from: 8, to: whole.count, by: 37) {
            XCTAssertThrowsError(try DSStore(data: whole.prefix(length)),
                                 "a \(length)-byte prefix parsed")
        }
    }

    func testAnUnknownValueTypeIsAnErrorRatherThanASkip() throws {
        // A value's length is implied by its type, so an unrecognised type
        // cannot be stepped over: everything after it would be garbage read as
        // records. Failing is the honest answer.
        var builder = Builder()
        _ = builder.add(master(root: 1, levels: 0, records: 1, nodes: 1))
        _ = builder.add(leaf([record("notes.txt", "xxxx", "zzzz", [0, 0, 0, 0])]))

        XCTAssertThrowsError(try DSStore(data: builder.build()))
    }

    func testAnOversizedFileIsNotParsed() {
        let data = Data(count: DSStore.maximumFileSize + 1)
        XCTAssertThrowsError(try DSStore(data: data)) { error in
            XCTAssertEqual(error as? DSStore.Failure, .tooLarge)
        }
    }

    // MARK: - Rendering

    func testTheOneLittleEndianNumberInABigEndianFormat() throws {
        // moDD is an IEEE double of seconds since 2001, stored little-endian,
        // where every other number in the file is a big-endian integer. These
        // are the actual bytes from ~/Downloads/.DS_Store.
        let bytes = Data([0x48, 0x90, 0x19, 0x65, 0xBB, 0xA6, 0xC5, 0x41])

        let date = try XCTUnwrap(DSStoreReport.timestamp(bytes))

        XCTAssertEqual(date.timeIntervalSinceReferenceDate, 726496970.199, accuracy: 0.01)
    }

    func testUnsetIconPositionsAreNotDrawn() {
        // Finder writes 0xFFFFFFFF for "no position of its own", which would
        // otherwise plot at four billion and flatten the map.
        XCTAssertNil(DSStoreReport.iconPosition(Data([UInt8](repeating: 0xFF, count: 16))))
        XCTAssertNil(DSStoreReport.iconPosition(Data([0, 0])))
    }

    func testWindowRectanglesAreNamedRatherThanQuoted() {
        XCTAssertEqual(DSStoreReport.rectangle("{{310, 275}, {1727, 1040}}"),
                       "1727 \u{00D7} 1040 at (310, 275)")
        XCTAssertEqual(DSStoreReport.rectangle("{{-2335, 261}, {1727, 1040}}"),
                       "1727 \u{00D7} 1040 at (-2335, 261)")
        XCTAssertNil(DSStoreReport.rectangle("Nlsv"), "not everything is a rectangle")
    }

    func testTheReportSurvivesEveryFixture() throws {
        var builder = Builder()
        _ = builder.add(master(root: 1, levels: 0, records: 2, nodes: 1))
        _ = builder.add(leaf([
            record("a & b<c>", "cmmt", "ustr", Self.be32(1) + [0x00, 0x3C]),
            record("a & b<c>", "wxyz", "blob", blob([0xDE, 0xAD])),
        ]))

        let html = DSStoreReport.html(for: try DSStore(data: builder.build()),
                                      name: ".DS_Store", path: "/tmp")

        XCTAssertTrue(html.contains("a &amp; b&lt;c&gt;"), "names must be escaped")
        XCTAssertFalse(html.contains("a & b<c>"))
        XCTAssertTrue(html.contains("de ad"), "an unknown key still shows its bytes")
        XCTAssertTrue(html.contains("<i>unknown</i>"), "and says that it is unknown")
    }
}
