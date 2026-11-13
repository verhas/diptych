import Foundation

/// ASN.1 read from its BER/DER bytes: what certificates, PKCS#12 key stores
/// and private-key wrappers are made of. Only reading, and only as much of
/// BER as those files use -- indefinite lengths and constructed strings, which
/// some Windows exports still write, included.
nonisolated struct DER: Sendable {

    struct Bad: Error, CustomStringConvertible {
        var description: String { "The ASN.1 structure is damaged or cut short." }
    }

    enum TagClass: UInt8, Sendable { case universal = 0, application = 1, context = 2, `private` = 3 }

    /// The identifier byte as written: class, constructed bit and number.
    let identifier: UInt8
    /// The value bytes. For an indefinite length, without the end marker.
    let content: [UInt8]
    /// The whole element, header included: what a fingerprint is taken of.
    let encoded: [UInt8]

    var tagClass: TagClass { TagClass(rawValue: identifier >> 6) ?? .universal }
    var isConstructed: Bool { identifier & 0x20 != 0 }
    var number: UInt8 { identifier & 0x1F }

    static let boolean: UInt8 = 0x01, integer: UInt8 = 0x02, bitString: UInt8 = 0x03
    static let octetString: UInt8 = 0x04, null: UInt8 = 0x05, oid: UInt8 = 0x06
    static let utf8String: UInt8 = 0x0C, sequence: UInt8 = 0x30, set: UInt8 = 0x31
    static let printableString: UInt8 = 0x13, t61String: UInt8 = 0x14, ia5String: UInt8 = 0x16
    static let utcTime: UInt8 = 0x17, generalizedTime: UInt8 = 0x18
    static let universalString: UInt8 = 0x1C, bmpString: UInt8 = 0x1E

    /// Context-specific tag `[n]`, constructed or not.
    static func context(_ n: UInt8, constructed: Bool = true) -> UInt8 { 0x80 | (constructed ? 0x20 : 0) | n }

    // MARK: - Reading

    /// The one element the bytes hold; trailing bytes are an error.
    init(_ bytes: [UInt8]) throws {
        var at = 0
        self = try DER.element(bytes, &at, depth: 0)
        guard at == bytes.count else { throw Bad() }
    }

    init(_ data: Data) throws { try self.init([UInt8](data)) }

    private init(identifier: UInt8, content: [UInt8], encoded: [UInt8]) {
        self.identifier = identifier
        self.content = content
        self.encoded = encoded
    }

    /// Nesting beyond this is not a key store; it is a file built to hurt.
    private static let deepest = 64

    private static func element(_ bytes: [UInt8], _ at: inout Int, depth: Int) throws -> DER {
        guard depth < deepest, at + 2 <= bytes.count else { throw Bad() }
        let start = at
        let identifier = bytes[at]
        guard identifier & 0x1F != 0x1F else { throw Bad() } // high tag numbers: never in these files
        at += 1
        let first = Int(bytes[at])
        at += 1
        if first == 0x80 {
            // Indefinite: children until the 00 00 end marker.
            guard identifier & 0x20 != 0 else { throw Bad() }
            let contentStart = at
            while true {
                guard at + 2 <= bytes.count else { throw Bad() }
                if bytes[at] == 0, bytes[at + 1] == 0 { break }
                _ = try element(bytes, &at, depth: depth + 1)
            }
            let content = Array(bytes[contentStart..<at])
            at += 2
            return DER(identifier: identifier, content: content, encoded: Array(bytes[start..<at]))
        }
        var length = first
        if first & 0x80 != 0 {
            let count = first & 0x7F
            guard count > 0, count <= 4, at + count <= bytes.count else { throw Bad() }
            length = 0
            for _ in 0..<count { length = length << 8 | Int(bytes[at]); at += 1 }
        }
        guard length >= 0, at + length <= bytes.count else { throw Bad() }
        let content = Array(bytes[at..<at + length])
        at += length
        return DER(identifier: identifier, content: content, encoded: Array(bytes[start..<at]))
    }

    /// The elements inside a constructed one.
    func children() throws -> [DER] {
        guard isConstructed else { throw Bad() }
        var list: [DER] = []
        var at = 0
        while at < content.count { list.append(try DER.element(content, &at, depth: 1)) }
        return list
    }

    /// The children, failing unless this is the given constructed tag.
    func children(of tag: UInt8) throws -> [DER] {
        guard identifier == tag else { throw Bad() }
        return try children()
    }

    /// The one element an explicit `[n]` wraps.
    func unwrapped() throws -> DER {
        let inside = try children()
        guard inside.count == 1 else { throw Bad() }
        return inside[0]
    }

    // MARK: - Values

    /// Bytes of an OCTET STRING, or of an implicitly tagged one, joined from
    /// its pieces when BER wrote it constructed.
    func octets() throws -> [UInt8] {
        guard isConstructed else { return content }
        return try children().flatMap { try $0.octets() }
    }

    /// Dotted form: `1.2.840.113549.1.1.1`.
    func oid() throws -> String {
        guard identifier == DER.oid, !content.isEmpty else { throw Bad() }
        var parts: [String] = []
        var value = 0
        for byte in content {
            value = value << 7 | Int(byte & 0x7F)
            guard value < Int.max >> 8 else { throw Bad() }
            guard byte & 0x80 == 0 else { continue }
            if parts.isEmpty {
                // The first number holds the first two arcs: 40 * a + b.
                let first = min(value / 40, 2)
                parts.append(String(first))
                parts.append(String(value - first * 40))
            } else {
                parts.append(String(value))
            }
            value = 0
        }
        guard content.last.map({ $0 & 0x80 == 0 }) == true else { throw Bad() }
        return parts.joined(separator: ".")
    }

    /// A small non-negative INTEGER -- a version, a count of iterations.
    func int() throws -> Int {
        guard identifier == DER.integer, !content.isEmpty, content.count <= 8 else { throw Bad() }
        var value = 0
        for byte in content { value = value << 8 | Int(byte) }
        return value
    }

    /// An INTEGER as hex, without the sign byte DER adds: a serial number.
    var hex: String {
        let bytes = content.count > 1 && content[0] == 0 ? Array(content.dropFirst()) : content
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// The bits of a BIT STRING, the unused-bits count dropped.
    func bits() throws -> [UInt8] {
        guard identifier == DER.bitString, !content.isEmpty else { throw Bad() }
        return Array(content.dropFirst())
    }

    /// Any of the string types names and certificates are written in.
    func string() throws -> String {
        switch identifier {
        case DER.utf8String, DER.printableString, DER.ia5String, 0x12, 0x1A:
            return String(decoding: content, as: UTF8.self)
        case DER.t61String:
            // Teletex is in practice Latin-1.
            return String(content.map { Character(Unicode.Scalar($0)) })
        case DER.bmpString:
            guard content.count % 2 == 0 else { throw Bad() }
            let units = stride(from: 0, to: content.count, by: 2).map { UInt16(content[$0]) << 8 | UInt16(content[$0 + 1]) }
            return String(decoding: units, as: UTF16.self)
        case DER.universalString:
            guard content.count % 4 == 0 else { throw Bad() }
            var text = ""
            for index in stride(from: 0, to: content.count, by: 4) {
                let value = content[index..<index + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                text.unicodeScalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
            }
            return text
        default:
            throw Bad()
        }
    }

    /// UTCTime or GeneralizedTime, as the certificate's validity writes them.
    func time() throws -> Date {
        guard identifier == DER.utcTime || identifier == DER.generalizedTime else { throw Bad() }
        var text = String(decoding: content, as: UTF8.self)
        guard text.hasSuffix("Z") else { throw Bad() }
        text.removeLast()
        if let dot = text.firstIndex(of: ".") { text = String(text[..<dot]) }
        if identifier == DER.utcTime {
            // Two-digit years: 50 and above are the 1900s (RFC 5280).
            guard let year = Int(text.prefix(2)) else { throw Bad() }
            text = (year >= 50 ? "19" : "20") + text
        }
        if text.count == 12 { text += "00" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        guard text.count == 14, let date = formatter.date(from: text) else { throw Bad() }
        return date
    }

    /// An AlgorithmIdentifier: its OID and the parameters, when there are any.
    func algorithm() throws -> (oid: String, parameters: DER?) {
        let parts = try children(of: DER.sequence)
        guard let first = parts.first else { throw Bad() }
        let parameters = parts.count > 1 && parts[1].identifier != DER.null ? parts[1] : nil
        return (try first.oid(), parameters)
    }
}
