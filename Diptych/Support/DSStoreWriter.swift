import Foundation

/// Writes `.DS_Store` files, as `DSStore` reads them -- so that an icon placed
/// by hand in Diptych is where Finder shows it too.
///
/// The file is rebuilt whole, from every record the old one held, rather than
/// patched in place: patching means carrying Finder's own allocator forward,
/// and a mistake there corrupts records nobody here even looked at. A fresh
/// file is laid out the way Finder lays its own out, measured on real ones:
///
///  * a buddy allocator over a 2^31-byte space, every block a power of two in
///    size and aligned to it; its header takes the first 32 bytes;
///  * block 0 is the allocator's own bookkeeping -- the address of every
///    block, the named block `DSDB`, and the free lists, which must say
///    exactly what is not in use, since Finder allocates from them later;
///  * `DSDB` names the root of a B-tree of records, sorted by file name
///    without regard to case and then by key, in nodes of up to 4096 bytes
///    each -- but each node only as large as it needs to be, as Finder's are.
enum DSStoreWriter {

    enum Failure: Error, Equatable {
        /// One record is too big for a node of its own.
        case recordTooLarge(String)
    }

    /// The largest a tree node may be: what `DSDB` declares as its page size.
    static let pageSize = 4096

    /// Finder's order: the name compared without regard to case, then the key.
    static func sorted(_ records: [DSStore.Record]) -> [DSStore.Record] {
        records.enumerated().sorted { a, b in
            let left = a.element.entry.lowercased(), right = b.element.entry.lowercased()
            if left != right { return left < right }
            if a.element.key != b.element.key { return a.element.key < b.element.key }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The file. `headerTail` is the 16 bytes after the root block's address
    /// in an old file, whose meaning nobody has worked out -- carried over
    /// unchanged; a new file has zeros there, as other writers' files do.
    static func encode(_ records: [DSStore.Record], headerTail: [UInt8]? = nil) throws -> Data {
        let encoded = try sorted(records).map(record)

        // The tree, from the leaves up. Each node is the bytes of its body;
        // its block number is its index here plus 2 -- block 0 is the
        // bookkeeping, block 1 is DSDB.
        var nodes: [[UInt8]] = []
        var level = pack(encoded, children: nil, into: &nodes)
        var levels: UInt32 = 0
        while level.nodes.count > 1 {
            level = pack(level.separators, children: level.nodes, into: &nodes)
            levels += 1
        }
        let rootNode = level.nodes[0]

        // Space, the way the buddy allocator hands it out: the header first,
        // at offset 0, then DSDB and the nodes.
        var allocator = Buddy()
        _ = allocator.allocate(32)
        var dsdb = Writer()
        dsdb.u32(UInt32(rootNode + 2))
        dsdb.u32(levels)
        dsdb.u32(UInt32(encoded.count))
        dsdb.u32(UInt32(nodes.count))
        dsdb.u32(UInt32(pageSize))
        var blocks: [(offset: UInt32, sizeClass: Int, body: [UInt8])] = []
        // A placeholder for block 0, filled in once the free lists are final.
        blocks.append((0, 0, []))
        for body in [dsdb.bytes] + nodes {
            let sizeClass = Buddy.sizeClass(of: body.count)
            blocks.append((allocator.allocate(1 << sizeClass), sizeClass, body))
        }

        // The bookkeeping block describes the free lists *after* it is itself
        // allocated -- so its size is taken from an upper bound first: one
        // allocation adds at most one free entry per size class it splits.
        let toc: [UInt8] = [4] + Array("DSDB".utf8) + Writer.bigEndian(UInt32(1))
        let addressSlots = (blocks.count + 255) / 256 * 256
        let bound = 8 + 4 * addressSlots + 4 + toc.count + 32 * 4
            + 4 * (allocator.freeEntries + 32)
        let rootClass = Buddy.sizeClass(of: bound)
        let rootOffset = allocator.allocate(1 << rootClass)

        var root = Writer()
        root.u32(UInt32(blocks.count))
        root.u32(0)
        let addresses = [(rootOffset, rootClass)] + blocks.dropFirst().map { ($0.offset, $0.sizeClass) }
        for (offset, sizeClass) in addresses { root.u32(offset | UInt32(sizeClass)) }
        for _ in addresses.count ..< addressSlots { root.u32(0) }
        root.u32(1)
        root.bytes += toc
        for list in allocator.free {
            root.u32(UInt32(list.count))
            for offset in list { root.u32(offset) }
        }
        blocks[0] = (rootOffset, rootClass, root.bytes)

        // The file: its magic, then the allocator's space from offset 4 on.
        let end = blocks.map { Int($0.offset) + (1 << $0.sizeClass) }.max() ?? 32
        var file = [UInt8](repeating: 0, count: 4 + end)
        file.replaceSubrange(0 ..< 4, with: [0, 0, 0, 1])
        var header = Writer()
        header.bytes += Array("Bud1".utf8)
        header.u32(rootOffset)
        header.u32(UInt32(1 << rootClass))
        header.u32(rootOffset)
        let tail = headerTail.flatMap { $0.count == 16 ? $0 : nil } ?? [UInt8](repeating: 0, count: 16)
        header.bytes += tail
        file.replaceSubrange(4 ..< 4 + header.bytes.count, with: header.bytes)
        for block in blocks {
            let at = 4 + Int(block.offset)
            file.replaceSubrange(at ..< at + block.body.count, with: block.body)
        }
        return Data(file)
    }

    /// The 16 bytes after the root's address in an existing file, to carry over.
    static func headerTail(of data: Data) -> [UInt8]? {
        guard data.count >= 36 else { return nil }
        return Array(data[data.startIndex + 20 ..< data.startIndex + 36])
    }

    // MARK: - The tree

    /// One level of the tree: `items` packed into nodes of at most a page,
    /// with -- when `children` is given -- the child before each item in
    /// front of it and the last child as the node's own pointer. An item that
    /// does not fit closes the node and goes up a level, as the separator
    /// between it and the next: in this tree the records in the inner nodes
    /// are real records, not copies.
    static func pack(_ items: [[UInt8]], children: [Int]?,
                     into nodes: inout [[UInt8]]) -> (nodes: [Int], separators: [[UInt8]]) {
        let extra = children == nil ? 0 : 4

        // Which items go in which node, by index; `start` is where a node's
        // items begin, which an empty node still needs for its pointer.
        var groups: [(start: Int, items: [Int])] = []
        var separators: [Int] = []
        var current: (start: Int, items: [Int]) = (0, [])
        var size = 8
        for index in items.indices {
            let cost = extra + items[index].count
            if !current.items.isEmpty, size + cost > pageSize {
                // Full: this item goes up, between this node and the next.
                groups.append(current)
                separators.append(index)
                current = (index + 1, [])
                size = 8
                continue
            }
            current.items.append(index)
            size += cost
        }
        // The very last item went up, which would leave the last node empty:
        // send the one before it up instead, and keep the last as a node.
        if current.items.isEmpty, let separator = separators.last,
           let previous = groups.last, previous.items.count >= 2,
           let promoted = previous.items.last {
            groups[groups.count - 1].items.removeLast()
            separators[separators.count - 1] = promoted
            current = (separator, [separator])
        }
        groups.append(current)

        var made: [Int] = []
        for group in groups {
            var node = Writer()
            // A leaf says 0; an inner node names the child after its last item.
            let after = (group.items.last ?? group.start - 1) + 1
            node.u32(children.map { UInt32($0[after] + 2) } ?? 0)
            node.u32(UInt32(group.items.count))
            for index in group.items {
                if let children { node.u32(UInt32(children[index] + 2)) }
                node.bytes += items[index]
            }
            nodes.append(node.bytes)
            made.append(nodes.count - 1)
        }
        return (made, separators.map { items[$0] })
    }

    /// One record as the tree holds it: the name in UTF-16 units, the key,
    /// the value's type and the value.
    private static func record(_ record: DSStore.Record) throws -> [UInt8] {
        var out = Writer()
        let units = Array(record.entry.utf16)
        out.u32(UInt32(units.count))
        for unit in units { out.u16(unit) }
        out.code(record.key)
        switch record.value {
        case .flag(let on):
            out.code("bool")
            out.bytes.append(on ? 1 : 0)
        case .integer(let value):
            out.code(record.valueType == "shor" ? "shor" : "long")
            out.u32(value)
        case .long(let value):
            out.code(record.valueType == "dutc" ? "dutc" : "comp")
            out.u64(value)
        case .code(let value):
            out.code("type")
            out.code(value)
        case .text(let text):
            out.code("ustr")
            let units = Array(text.utf16)
            out.u32(UInt32(units.count))
            for unit in units { out.u16(unit) }
        case .blob(let data):
            out.code("blob")
            out.u32(UInt32(data.count))
            out.bytes += data
        }
        // A record must fit a node by itself, with room for the node's header
        // and a child pointer.
        guard out.bytes.count + 12 <= pageSize else {
            throw Failure.recordTooLarge("\(record.entry) \(record.key)")
        }
        return out.bytes
    }

    // MARK: - Pieces

    /// Big-endian, as everything in the file is.
    private struct Writer {
        var bytes: [UInt8] = []

        mutating func u16(_ value: UInt16) { bytes += [UInt8(value >> 8), UInt8(value & 0xFF)] }
        mutating func u32(_ value: UInt32) { bytes += Writer.bigEndian(value) }
        mutating func u64(_ value: UInt64) {
            u32(UInt32(value >> 32))
            u32(UInt32(value & 0xFFFF_FFFF))
        }
        /// Four characters, padded with spaces or cut to four.
        mutating func code(_ text: String) {
            let raw = Array(text.utf8.prefix(4))
            bytes += raw + [UInt8](repeating: 0x20, count: 4 - raw.count)
        }

        static func bigEndian(_ value: UInt32) -> [UInt8] {
            [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
    }

    /// The buddy allocator Finder's files are laid out by: free blocks kept
    /// in a list per size class, 2^5 to 2^31 bytes, each sorted; a request
    /// takes the smallest free block that fits and splits it, the upper
    /// halves going back on the lists.
    struct Buddy {
        private(set) var free: [[UInt32]]

        init() {
            free = Array(repeating: [], count: 32)
            free[31] = [0]
        }

        static func sizeClass(of size: Int) -> Int {
            var sizeClass = 5
            while (1 << sizeClass) < size { sizeClass += 1 }
            return sizeClass
        }

        var freeEntries: Int { free.reduce(0) { $0 + $1.count } }

        mutating func allocate(_ size: Int) -> UInt32 {
            let wanted = Self.sizeClass(of: size)
            var sizeClass = wanted
            while sizeClass < 32, free[sizeClass].isEmpty { sizeClass += 1 }
            precondition(sizeClass < 32, "the allocator's space is used up")
            let offset = free[sizeClass].removeFirst()
            while sizeClass > wanted {
                sizeClass -= 1
                free[sizeClass].append(offset + (1 << UInt32(sizeClass)))
                free[sizeClass].sort()
            }
            return offset
        }
    }
}
