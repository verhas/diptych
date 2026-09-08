import Foundation

/// A decoder for `.DS_Store`.
///
/// The file is a `Bud1` "buddy allocator" -- Apple's generic block store -- and
/// inside it, one named block holds a B-tree. The tree's records describe the
/// entries *of the directory the file sits in*, not the directory itself: where
/// each icon was, how the window was sized, which columns were showing.
///
/// Nothing about the format is documented by Apple, and files in the wild are
/// written by other tools and sometimes truncated, so every read here is bounds
/// checked and every limit is explicit. A file manager that crashes on a file it
/// merely tried to preview would be worse than one that previews nothing.
struct DSStore {

    struct Record {
        /// The directory entry this says something about.
        let entry: String
        /// The four-character structure id: `Iloc`, `bwsp`, `moDD`, ...
        let key: String
        let value: Value
    }

    enum Value {
        case flag(Bool)
        /// `long` and `shor`, both four bytes on disk.
        case integer(UInt32)
        /// `comp` and `dutc`, eight bytes.
        case long(UInt64)
        /// `type`: four characters naming something else.
        case code(String)
        case text(String)
        case blob(Data)
    }

    let records: [Record]
    let levels: UInt32
    let declaredRecords: UInt32
    let nodes: UInt32
    let pageSize: UInt32

    /// Records grouped by the entry they describe, in the tree's own order --
    /// which is sorted by name, so the grouping comes out sorted for free.
    var byEntry: [(entry: String, records: [Record])] {
        var order: [String] = []
        var grouped: [String: [Record]] = [:]
        for record in records {
            if grouped[record.entry] == nil { order.append(record.entry) }
            grouped[record.entry, default: []].append(record)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    // MARK: - Limits

    /// A real one is 6-32 KB. Anything past this is not a Finder file, and the
    /// point of the ceiling is that we never allocate on a corrupt length.
    static let maximumFileSize = 1 << 20
    private static let maximumRecords = 20_000
    private static let maximumValueSize = 1 << 20

    enum Failure: Error, Equatable {
        case notADSStore
        case tooLarge
        case truncated
        case malformed(String)
    }

    // MARK: - Reading

    /// Bounds-checked cursor. Every read throws rather than trapping, because
    /// the input is untrusted and a Swift array subscript is not a bounds check
    /// you can recover from.
    private struct Cursor {
        let bytes: [UInt8]
        var offset: Int

        init(_ data: [UInt8], at offset: Int = 0) {
            bytes = data
            self.offset = offset
        }

        mutating func read(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, offset + count <= bytes.count, offset + count >= offset
            else { throw Failure.truncated }
            defer { offset += count }
            return bytes[offset ..< offset + count]
        }

        mutating func u32() throws -> UInt32 {
            try read(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }

        mutating func u64() throws -> UInt64 {
            try read(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }

        mutating func u8() throws -> UInt8 {
            guard let byte = try read(1).first else { throw Failure.truncated }
            return byte
        }

        /// Four characters, the format's way of naming both keys and types.
        mutating func code() throws -> String {
            String(decoding: try read(4), as: UTF8.self)
        }

        /// Names are UTF-16 big-endian, counted in code *units*, not bytes.
        mutating func name(units: Int) throws -> String {
            let raw = try read(units * 2)
            var scalars = [UInt16]()
            scalars.reserveCapacity(units)
            for index in stride(from: raw.startIndex, to: raw.endIndex, by: 2) {
                scalars.append(UInt16(raw[index]) << 8 | UInt16(raw[index + 1]))
            }
            return String(decoding: scalars, as: UTF16.self)
        }
    }

    init(data: Data) throws {
        guard data.count <= Self.maximumFileSize else { throw Failure.tooLarge }

        // The magic is checked before the length, so that a file which merely
        // borrowed the name is reported as what it is. One such was sitting in
        // a project directory here, sixteen bytes reading "Input length = 1".
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0...3] == [0, 0, 0, 1],
              Array(bytes[4...7]) == Array("Bud1".utf8) else {
            throw Failure.notADSStore
        }
        guard bytes.count > 36 else { throw Failure.truncated }

        var header = Cursor(bytes, at: 8)
        let directoryOffset = Int(try header.u32())
        let directorySize = Int(try header.u32())

        // Every offset in the allocator is relative to byte 4, not byte 0: the
        // first four bytes are the outer file's magic, and the allocator itself
        // begins after them.
        var allocator = Cursor(bytes, at: 4 + directoryOffset)
        guard 4 + directoryOffset + directorySize <= bytes.count else { throw Failure.truncated }

        let addressCount = Int(try allocator.u32())
        _ = try allocator.u32()
        guard addressCount >= 0, addressCount <= Self.maximumRecords else {
            throw Failure.malformed("implausible block count \(addressCount)")
        }
        var addresses: [UInt32] = []
        addresses.reserveCapacity(addressCount)
        for _ in 0 ..< addressCount { addresses.append(try allocator.u32()) }

        // The address table is padded to a whole multiple of 256 entries.
        let padding = addressCount % 256 == 0 ? 0 : 256 - addressCount % 256
        _ = try allocator.read(padding * 4)

        // A short table of named blocks. Only DSDB matters; the rest are the
        // allocator's own bookkeeping.
        let namedCount = Int(try allocator.u32())
        var named: [String: Int] = [:]
        for _ in 0 ..< min(namedCount, 64) {
            let length = Int(try allocator.u8())
            let name = String(decoding: try allocator.read(length), as: UTF8.self)
            named[name] = Int(try allocator.u32())
        }
        guard let masterIndex = named["DSDB"] else { throw Failure.malformed("no DSDB block") }

        /// An address packs offset and size together: the low five bits are
        /// log2 of the block's size, the rest is the offset.
        func block(_ index: Int) throws -> [UInt8] {
            guard addresses.indices.contains(index) else { throw Failure.malformed("bad block") }
            let address = addresses[index]
            let offset = 4 + Int(address & ~0x1F)
            let size = 1 << Int(address & 0x1F)
            guard size <= Self.maximumFileSize, offset >= 0, offset + size <= bytes.count
            else { throw Failure.truncated }
            return Array(bytes[offset ..< offset + size])
        }

        var master = Cursor(try block(masterIndex))
        let root = Int(try master.u32())
        levels = try master.u32()
        declaredRecords = try master.u32()
        nodes = try master.u32()
        pageSize = try master.u32()

        var collected: [Record] = []
        // Cycle guard: a corrupt tree can point a child back at its parent, and
        // the levels field cannot be trusted to stop the walk.
        var visited: Set<Int> = []

        func walk(_ index: Int) throws {
            guard visited.insert(index).inserted else { return }
            guard collected.count < Self.maximumRecords else { return }

            var node = Cursor(try block(index))
            let mode = Int(try node.u32())
            let count = Int(try node.u32())
            guard count >= 0, count <= Self.maximumRecords else {
                throw Failure.malformed("implausible record count \(count)")
            }

            for _ in 0 ..< count {
                // An internal node interleaves child pointers with records: the
                // child holding everything *before* this record comes first.
                if mode != 0 { try walk(Int(try node.u32())) }
                collected.append(try Self.record(from: &node))
                if collected.count >= Self.maximumRecords { return }
            }
            // ...and the rightmost child trails the last record. Forgetting it
            // loses everything past the final key -- silently, with no error and
            // a plausible-looking result, which is the worst kind of bug.
            if mode != 0 { try walk(mode) }
        }
        try walk(root)

        records = collected
    }

    private static func record(from cursor: inout Cursor) throws -> Record {
        let units = Int(try cursor.u32())
        guard units >= 0, units <= 4096 else { throw Failure.malformed("name of \(units) units") }
        let entry = try cursor.name(units: units)
        let key = try cursor.code()
        let type = try cursor.code()

        let value: Value
        switch type {
        case "bool": value = .flag(try cursor.u8() != 0)
        case "long", "shor": value = .integer(try cursor.u32())
        case "comp", "dutc": value = .long(try cursor.u64())
        case "type": value = .code(try cursor.code())
        case "blob":
            let length = Int(try cursor.u32())
            guard length >= 0, length <= maximumValueSize else {
                throw Failure.malformed("blob of \(length) bytes")
            }
            value = .blob(Data(try cursor.read(length)))
        case "ustr":
            let length = Int(try cursor.u32())
            guard length >= 0, length * 2 <= maximumValueSize else {
                throw Failure.malformed("string of \(length) units")
            }
            value = .text(try cursor.name(units: length))
        default:
            // Unknown types cannot be skipped: the value's length is implied by
            // its type, so once one is missed the rest of the node is garbage.
            throw Failure.malformed("unknown value type \(type)")
        }
        return Record(entry: entry, key: key, value: value)
    }
}
