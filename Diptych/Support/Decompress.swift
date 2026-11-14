import Compression
import Foundation

/// Compressed blocks inside the formats previewed here -- disk image chunks,
/// xar entries, gzip streams -- decoded in memory, never larger than asked.
nonisolated enum Decompress {

    enum Method { case deflate, lzfse, lzma }

    /// The raw decoded bytes, at most `limit`; nil when they cannot be decoded.
    static func decode(_ data: Data, _ method: Method, limit: Int) -> Data? {
        guard !data.isEmpty, limit > 0 else { return nil }
        let algorithm: compression_algorithm = switch method {
        case .deflate: COMPRESSION_ZLIB
        case .lzfse: COMPRESSION_LZFSE
        case .lzma: COMPRESSION_LZMA
        }
        // The whole limit at once when it is moderate (callers that know
        // the size pass it); otherwise a buffer that grows up to the limit.
        // A decoder that runs out of room may report nothing at all (LZMA
        // does), so an empty result means "larger", until the limit.
        var capacity = limit <= 64 * 1024 * 1024 ? limit : min(limit, max(data.count * 4, 64 * 1024))
        while true {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { target in
                data.withUnsafeBytes { source in
                    compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                              nil, algorithm)
                }
            }
            if written == 0 {
                if capacity >= limit { return nil }
                capacity = min(limit, capacity * 4)
                continue
            }
            if written < capacity || capacity >= limit {
                output.count = written
                return output
            }
            capacity = min(limit, capacity * 4)
        }
    }

    /// A zlib stream (two header bytes, DEFLATE, a checksum): what xar calls
    /// "application/x-gzip" and the disk image chunks use.
    static func zlib(_ data: Data, limit: Int) -> Data? {
        guard data.count > 2, data[data.startIndex] & 0x0F == 8 else { return nil }
        return decode(data.dropFirst(2), .deflate, limit: limit)
    }

    /// A gzip file: its header skipped, then DEFLATE.
    static func gzip(_ data: Data, limit: Int) -> Data? {
        let bytes = [UInt8](data.prefix(10))
        guard bytes.count == 10, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var at = data.startIndex + 10
        func skipString() { while at < data.endIndex, data[at] != 0 { at += 1 }; at += 1 }
        if flags & 4 != 0, at + 2 <= data.endIndex {
            at += 2 + Int(data[at]) + Int(data[at + 1]) << 8
        }
        if flags & 8 != 0 { skipString() }
        if flags & 16 != 0 { skipString() }
        if flags & 2 != 0 { at += 2 }
        guard at < data.endIndex, data.count >= 18 else { return nil }
        // The trailer holds the decoded size (modulo 4 GB): the buffer needed.
        let tail = [UInt8](data.suffix(4))
        let recorded = Int(tail[0]) | Int(tail[1]) << 8 | Int(tail[2]) << 16 | Int(tail[3]) << 24
        return decode(data[at...], .deflate, limit: recorded > 0 ? min(limit, recorded) : limit)
    }

    static func isGzip(_ data: Data) -> Bool {
        data.count > 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }
}
