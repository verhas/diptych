import Foundation

/// Fixed-width numbers read at offsets in a file of either byte order, for
/// formats -- Mach-O, ELF -- that are tables of offsets rather than a stream.
/// Reads straight from the (usually memory-mapped) data: a 200 MB binary is
/// not copied to read its header.
nonisolated struct BinaryReader {
    let data: Data
    var bigEndian: Bool

    struct Short: Error, CustomStringConvertible {
        var description: String { "It ends before the end of a table it describes." }
    }

    init(_ data: Data, bigEndian: Bool = false) {
        self.data = data
        self.bigEndian = bigEndian
    }

    var count: Int { data.count }

    func u8(_ at: Int) throws -> UInt8 { UInt8(try uint(at, 1)) }
    func u16(_ at: Int) throws -> UInt16 { UInt16(try uint(at, 2)) }
    func u32(_ at: Int) throws -> UInt32 { UInt32(try uint(at, 4)) }
    func u64(_ at: Int) throws -> UInt64 { try uint(at, 8) }
    func i32(_ at: Int) throws -> Int32 { Int32(bitPattern: try u32(at)) }

    /// A 32- or 64-bit word, as ELF's class decides.
    func word(_ at: Int, wide: Bool) throws -> UInt64 { wide ? try u64(at) : UInt64(try u32(at)) }

    func bytes(_ at: Int, _ length: Int) throws -> Data {
        guard contains(at, length) else { throw Short() }
        let start = data.startIndex + at
        return data[start..<start + length]
    }

    /// A NUL-terminated string, at most `limit` bytes long.
    func string(_ at: Int, limit: Int = 4096) -> String {
        guard at >= 0, at < data.count, limit > 0 else { return "" }
        let start = data.startIndex + at
        let end = min(data.endIndex, start + limit)
        let stop = data[start..<end].firstIndex(of: 0) ?? end
        return String(decoding: data[start..<stop], as: UTF8.self)
    }

    func contains(_ at: Int, _ length: Int) -> Bool {
        at >= 0 && length >= 0 && at <= data.count && length <= data.count - at
    }

    private func uint(_ at: Int, _ size: Int) throws -> UInt64 {
        guard contains(at, size) else { throw Short() }
        let base = data.startIndex + at
        var value: UInt64 = 0
        for index in 0..<size {
            value = value << 8 | UInt64(data[base + (bigEndian ? index : size - 1 - index)])
        }
        return value
    }
}
