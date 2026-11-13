import CryptoKit
import Foundation

/// A Java or PKCS#12 key store, read for what is in it: each alias, what kind
/// of entry it is, and its certificates. Keys are never decrypted.
///
/// The password is never asked for. Two are tried because they are the
/// defaults -- none at all, and Java's `changeit` -- and when one fits the page
/// says so, since a store anybody can open is worth knowing about. With any
/// other password a JKS still shows its certificates, which it keeps in the
/// clear; a PKCS#12 shows only what it keeps unencrypted.
nonisolated struct KeyStore: Sendable {

    static let maximumSize = 16 * 1024 * 1024

    /// Tried, in this order, before anything is said to need a password.
    static let defaultPasswords = ["", "changeit"]

    enum Format: String, Sendable {
        case jks = "JKS", jceks = "JCEKS", pkcs12 = "PKCS#12"
    }

    enum Kind: String, Sendable {
        case privateKey = "Private key", trustedCertificate = "Trusted certificate"
        case secretKey = "Secret key", certificate = "Certificate"
    }

    struct Entry: Sendable {
        var alias: String
        var kind: Kind
        var created: Date?
        /// The entry's own certificate first, then each one that vouches for it.
        var chain: [X509] = []
        /// How the key is protected: "PBES2, AES-256-CBC".
        var protection: String?
    }

    enum Password: Sendable, Equatable {
        /// Opened with this one, a default.
        case known(String)
        /// None of the defaults fit.
        case unknown
        /// The store has no integrity check and nothing encrypted to open.
        case notNeeded
    }

    var format: Format
    var version: Int?
    var entries: [Entry] = []
    var password: Password = .unknown
    /// What the page should say beside the entries: an algorithm, an
    /// encrypted part that stayed shut, entries that could not be read.
    var notes: [String] = []
    /// How the store is protected as a whole: "HMAC-SHA256, 10,000 iterations".
    var integrity: String?

    enum Problem: Error, CustomStringConvertible {
        case notAKeyStore
        case damaged(String)

        var description: String {
            switch self {
            case .notAKeyStore: "It is not a JKS, JCEKS or PKCS#12 key store."
            case .damaged(let what): what
            }
        }
    }

    init(format: Format) { self.format = format }

    static func read(_ data: Data) throws -> KeyStore {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { throw Problem.notAKeyStore }
        if bytes.starts(with: [0xFE, 0xED, 0xFE, 0xED]) { return try JavaKeyStore.read(bytes, format: .jks) }
        if bytes.starts(with: [0xCE, 0xCE, 0xCE, 0xCE]) { return try JavaKeyStore.read(bytes, format: .jceks) }
        if bytes[0] == DER.sequence { return try PKCS12.read(bytes) }
        throw Problem.notAKeyStore
    }

    /// Names for the algorithms that wrap keys and stores.
    static func algorithmName(_ oid: String) -> String {
        let names: [String: String] = [
            "1.3.6.1.4.1.42.2.17.1.1": "Sun's own JKS key protection",
            "1.3.6.1.4.1.42.2.19.1": "PBE with MD5 and Triple DES",
            "1.2.840.113549.1.12.1.1": "PBE with SHA-1 and 128-bit RC4",
            "1.2.840.113549.1.12.1.2": "PBE with SHA-1 and 40-bit RC4",
            "1.2.840.113549.1.12.1.3": "PBE with SHA-1 and Triple DES",
            "1.2.840.113549.1.12.1.4": "PBE with SHA-1 and two-key Triple DES",
            "1.2.840.113549.1.12.1.5": "PBE with SHA-1 and 128-bit RC2",
            "1.2.840.113549.1.12.1.6": "PBE with SHA-1 and 40-bit RC2",
            "1.2.840.113549.1.5.13": "PBES2",
            "2.16.840.1.101.3.4.1.2": "AES-128-CBC", "2.16.840.1.101.3.4.1.22": "AES-192-CBC",
            "2.16.840.1.101.3.4.1.42": "AES-256-CBC", "1.2.840.113549.3.7": "Triple DES CBC",
            "1.3.14.3.2.26": "SHA-1", "2.16.840.1.101.3.4.2.1": "SHA-256",
            "2.16.840.1.101.3.4.2.2": "SHA-384", "2.16.840.1.101.3.4.2.3": "SHA-512",
            "1.2.840.113549.2.7": "HMAC-SHA1", "1.2.840.113549.2.9": "HMAC-SHA256",
            "1.2.840.113549.2.10": "HMAC-SHA384", "1.2.840.113549.2.11": "HMAC-SHA512",
        ]
        return names[oid] ?? oid
    }

    /// An EncryptedPrivateKeyInfo's algorithm, said in words; PBES2 with what
    /// it actually encrypts with.
    static func protection(ofEncryptedKey bytes: [UInt8]) -> String? {
        guard let parts = try? DER(bytes).children(of: DER.sequence), let first = parts.first,
              let (oid, parameters) = try? first.algorithm() else { return nil }
        guard oid == "1.2.840.113549.1.5.13", let parameters,
              let scheme = try? parameters.children().last?.algorithm() else { return algorithmName(oid) }
        return "PBES2, " + algorithmName(scheme.oid)
    }
}

// MARK: - JKS and JCEKS

/// Sun's own formats: a header, then each entry with its alias, date and
/// certificates in the clear, then a SHA-1 over the password and all of it.
nonisolated enum JavaKeyStore {

    static func read(_ bytes: [UInt8], format: KeyStore.Format) throws -> KeyStore {
        var store = KeyStore(format: format)
        var reader = ByteReader(bytes)
        try reader.skip(4)
        let version = Int(try reader.u4())
        guard version == 1 || version == 2 else { throw KeyStore.Problem.damaged("Its version, \(version), is not one Java writes.") }
        store.version = version
        let count = Int(try reader.u4())

        entries: for index in 0..<count {
            do {
                let tag = try reader.u4()
                let alias = try reader.javaUTF()
                let created = Date(timeIntervalSince1970: Double(try reader.u8()) / 1000)
                switch tag {
                case 1:
                    let key = try reader.take(Int(try reader.u4()))
                    var entry = KeyStore.Entry(alias: alias, kind: .privateKey, created: created)
                    entry.protection = KeyStore.protection(ofEncryptedKey: key)
                    entry.chain = try (0..<Int(try reader.u4())).compactMap { _ in try certificate(&reader, version) }
                    store.entries.append(entry)
                case 2:
                    var entry = KeyStore.Entry(alias: alias, kind: .trustedCertificate, created: created)
                    entry.chain = [try certificate(&reader, version)].compactMap { $0 }
                    store.entries.append(entry)
                case 3 where format == .jceks:
                    // A secret key is a serialized Java object; it is stepped
                    // over, keeping the name of what sealed it.
                    var skipper = JavaSerialization(reader)
                    try skipper.skipObject()
                    reader = skipper.reader
                    var entry = KeyStore.Entry(alias: alias, kind: .secretKey, created: created)
                    entry.protection = skipper.strings.first { $0.hasPrefix("PBE") }.map { "Sealed with " + $0 }
                    store.entries.append(entry)
                default:
                    throw KeyStore.Problem.damaged("Entry \(index + 1) is of a kind, \(tag), that \(format.rawValue) does not have.")
                }
            } catch {
                store.notes.append("Only \(index) of its \(count) entries could be read: \(error)")
                break entries
            }
        }

        if store.entries.count == count, reader.remaining == 20 {
            let body = Array(bytes[0..<reader.at])
            let digest = Array(bytes[reader.at...])
            if let password = KeyStore.defaultPasswords.first(where: { integrity(body, $0) == digest }) {
                store.password = .known(password)
            }
            store.integrity = "SHA-1 over the password and the contents"
        }
        return store
    }

    private static func certificate(_ reader: inout ByteReader, _ version: Int) throws -> X509? {
        if version == 2 {
            let type = try reader.javaUTF()
            guard type == "X.509" else {
                _ = try reader.take(Int(try reader.u4()))
                return nil
            }
        }
        let der = try reader.take(Int(try reader.u4()))
        return try X509(der: der)
    }

    /// SHA-1 of the password as UTF-16, the words "Mighty Aphrodite", and the
    /// store: how JKS and JCEKS check they were not changed.
    static func integrity(_ body: [UInt8], _ password: String) -> [UInt8] {
        var hash = Insecure.SHA1()
        let utf16 = password.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        hash.update(data: utf16)
        hash.update(data: Array("Mighty Aphrodite".utf8))
        hash.update(data: body)
        return Array(hash.finalize())
    }
}

// MARK: - Bytes

nonisolated struct ByteReader: Sendable {
    let bytes: [UInt8]
    var at = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - at }

    struct Short: Error, CustomStringConvertible {
        var description: String { "The file ends early." }
    }

    mutating func u1() throws -> UInt8 {
        guard at < bytes.count else { throw Short() }
        defer { at += 1 }
        return bytes[at]
    }

    mutating func u2() throws -> Int {
        let high = Int(try u1())
        return high << 8 | Int(try u1())
    }

    mutating func u4() throws -> UInt32 {
        let high = UInt32(try u2())
        return high << 16 | UInt32(try u2())
    }

    mutating func u8() throws -> UInt64 {
        let high = UInt64(try u4())
        return high << 32 | UInt64(try u4())
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw Short() }
        at += count
    }

    mutating func take(_ count: Int) throws -> [UInt8] {
        let start = at
        try skip(count)
        return Array(bytes[start..<at])
    }

    /// Java's `writeUTF`: a two-byte length, then modified UTF-8.
    mutating func javaUTF() throws -> String {
        let length = try u2()
        return JavaSerialization.modifiedUTF8(try take(length))
    }
}

// MARK: - Java serialization

/// Steps over one object in Java's serialization format -- a JCEKS secret
/// key is stored as one -- reading the class descriptions the stream carries
/// to know how long each field is. Nothing is instantiated; the strings met
/// on the way are kept, since they name the algorithms.
nonisolated struct JavaSerialization {
    var reader: ByteReader
    private(set) var strings: [String] = []
    private var handles: [Value] = []
    private var depth = 0

    struct Unsupported: Error, CustomStringConvertible {
        var description: String { "A serialized Java object in it could not be stepped over." }
    }

    private final class ClassDescription {
        let name: String
        var flags: UInt8 = 0
        var fields: [Character] = []
        var superclass: ClassDescription?
        init(name: String) { self.name = name }
    }

    private enum Value { case none, description(ClassDescription), string, other }

    init(_ reader: ByteReader) { self.reader = reader }

    mutating func skipObject() throws {
        guard try reader.u2() == 0xACED, try reader.u2() == 5 else { throw Unsupported() }
        _ = try content()
    }

    private mutating func newHandle(_ value: Value) -> Int {
        handles.append(value)
        return handles.count - 1
    }

    @discardableResult
    private mutating func content() throws -> Value {
        depth += 1
        defer { depth -= 1 }
        guard depth < 64 else { throw Unsupported() }
        switch try reader.u1() {
        case 0x70: return .none // TC_NULL
        case 0x71: // TC_REFERENCE
            let handle = Int(try reader.u4()) - 0x7E0000
            guard handles.indices.contains(handle) else { throw Unsupported() }
            return handles[handle]
        case 0x72: return .description(try classDescription())
        case 0x7D: // TC_PROXYCLASSDESC
            let description = ClassDescription(name: "proxy")
            _ = newHandle(.description(description))
            for _ in 0..<(try reader.u4()) { _ = try reader.javaUTF() }
            try annotations()
            description.superclass = try superclass()
            return .description(description)
        case 0x73: // TC_OBJECT
            guard case .description(let description) = try content() else { throw Unsupported() }
            _ = newHandle(.other)
            var chain: [ClassDescription] = []
            var next: ClassDescription? = description
            while let current = next { chain.insert(current, at: 0); next = current.superclass }
            for current in chain { try classData(current) }
            return .other
        case 0x74: // TC_STRING
            strings.append(try reader.javaUTF())
            _ = newHandle(.string)
            return .string
        case 0x7C: // TC_LONGSTRING
            let length = try reader.u8()
            guard length <= UInt64(reader.remaining) else { throw Unsupported() }
            try reader.skip(Int(length))
            _ = newHandle(.string)
            return .string
        case 0x75: // TC_ARRAY
            guard case .description(let description) = try content() else { throw Unsupported() }
            _ = newHandle(.other)
            let count = Int(try reader.u4())
            let component = description.name.dropFirst().first ?? "L"
            if let size = Self.size(of: component) {
                try reader.skip(count * size)
            } else {
                for _ in 0..<count { try content() }
            }
            return .other
        case 0x76: // TC_CLASS
            try content()
            _ = newHandle(.other)
            return .other
        case 0x7E: // TC_ENUM
            try content()
            _ = newHandle(.other)
            try content()
            return .other
        case 0x77: try reader.skip(Int(try reader.u1())); return .other // TC_BLOCKDATA
        case 0x7A: try reader.skip(Int(try reader.u4())); return .other // TC_BLOCKDATALONG
        case 0x79: handles.removeAll(); return .none // TC_RESET
        default: throw Unsupported()
        }
    }

    private mutating func classDescription() throws -> ClassDescription {
        let description = ClassDescription(name: try reader.javaUTF())
        try reader.skip(8) // serialVersionUID
        _ = newHandle(.description(description))
        description.flags = try reader.u1()
        for _ in 0..<(try reader.u2()) {
            let type = Character(Unicode.Scalar(try reader.u1()))
            _ = try reader.javaUTF()
            if type == "L" || type == "[" { try content() } // the field's class name
            description.fields.append(type)
        }
        try annotations()
        description.superclass = try superclass()
        return description
    }

    private mutating func superclass() throws -> ClassDescription? {
        switch try content() {
        case .description(let description): return description
        case .none: return nil
        default: throw Unsupported()
        }
    }

    /// Block data and objects up to TC_ENDBLOCKDATA.
    private mutating func annotations() throws {
        while true {
            guard reader.remaining > 0 else { throw Unsupported() }
            if reader.bytes[reader.at] == 0x78 { reader.at += 1; return }
            try content()
        }
    }

    private mutating func classData(_ description: ClassDescription) throws {
        let serializable = description.flags & 0x02 != 0
        let externalizable = description.flags & 0x04 != 0
        if externalizable {
            guard description.flags & 0x08 != 0 else { throw Unsupported() }
            try annotations()
            return
        }
        guard serializable else { return }
        for field in description.fields {
            if let size = Self.size(of: field) { try reader.skip(size) } else { try content() }
        }
        if description.flags & 0x01 != 0 { try annotations() } // written by its own writeObject
    }

    private static func size(of type: Character) -> Int? {
        switch type {
        case "B", "Z": 1
        case "C", "S": 2
        case "I", "F": 4
        case "J", "D": 8
        default: nil
        }
    }

    /// Java's UTF-8: a zero is two bytes, and a character beyond the basic
    /// plane is its two UTF-16 halves, three bytes each.
    static func modifiedUTF8(_ bytes: [UInt8]) -> String {
        var units: [UInt16] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte & 0x80 == 0 {
                units.append(UInt16(byte)); index += 1
            } else if byte & 0xE0 == 0xC0, index + 1 < bytes.count {
                units.append(UInt16(byte & 0x1F) << 6 | UInt16(bytes[index + 1] & 0x3F)); index += 2
            } else if byte & 0xF0 == 0xE0, index + 2 < bytes.count {
                units.append(UInt16(byte & 0x0F) << 12 | UInt16(bytes[index + 1] & 0x3F) << 6
                             | UInt16(bytes[index + 2] & 0x3F))
                index += 3
            } else {
                units.append(0xFFFD); index += 1
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
}
