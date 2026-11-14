import CryptoKit
import Foundation

/// SSH keys as `ssh-keygen -l` and `-L` describe them: type, size,
/// SHA-256 fingerprint, comment -- and for a certificate, who it is for, who
/// signed it and until when. A private key is described by its public half
/// and whether a passphrase protects it; its secret is never read.
nonisolated enum SSHKey {

    struct Public: Sendable {
        /// The wire name: `ssh-ed25519`, `ecdsa-sha2-nistp256`, `ssh-rsa-cert-v01@openssh.com`.
        var type: String
        /// As ssh-keygen labels it: ED25519, RSA, ECDSA, ECDSA-SK.
        var label: String
        var bits: Int?
        /// `SHA256:` and the unpadded base64 of the key's SHA-256.
        var fingerprint: String
        var comment: String?
        /// authorized_keys options before the key: `from="…",no-pty`.
        var options: String?
        var certificate: Certificate?
    }

    struct Certificate: Sendable {
        var isHost: Bool
        var keyID: String
        var serial: UInt64
        var principals: [String]
        var validAfter: Date?
        var validBefore: Date?
        var criticalOptions: [String]
        var extensions: [String]
        /// The signing CA: its label and fingerprint.
        var signedBy: String
    }

    struct Private: Sendable {
        var keys: [Public]
        /// nil when there is no passphrase.
        var encryption: String?
    }

    struct Bad: Error {}

    // MARK: - Public keys

    static let typePrefixes = ["ssh-", "ecdsa-sha2-", "sk-"]

    static func looksLikeKeyType(_ word: Substring) -> Bool {
        typePrefixes.contains { word.hasPrefix($0) }
    }

    /// A `.pub` line or an authorized_keys line: options, type, key, comment.
    static func publicLine(_ line: Substring) -> Public? {
        var rest = line.drop { $0 == " " || $0 == "\t" }
        guard !rest.isEmpty, !rest.hasPrefix("#") else { return nil }
        var options: String?
        if !looksLikeKeyType(rest.prefix { !$0.isWhitespace }) {
            // Options run to the first blank outside quotes.
            var inQuotes = false
            var end = rest.startIndex
            while end < rest.endIndex {
                let character = rest[end]
                if character == "\"" { inQuotes.toggle() }
                if character.isWhitespace, !inQuotes { break }
                end = rest.index(after: end)
            }
            options = String(rest[..<end])
            rest = rest[end...].drop { $0.isWhitespace }
        }
        let fields = rest.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2, looksLikeKeyType(fields[0]),
              let blob = Data(base64Encoded: String(fields[1])),
              var key = try? describe([UInt8](blob)), key.type == String(fields[0]) else { return nil }
        key.comment = fields.count > 2 ? String(fields[2]).trimmingCharacters(in: .whitespaces) : nil
        key.options = options
        return key
    }

    /// SSH protocol 1's RSA key: `bits exponent modulus comment`, in decimal.
    /// OpenSSH dropped the protocol long ago; macOS still keeps such a host key.
    static func protocol1Line(_ line: Substring) -> Public? {
        let fields = line.split(maxSplits: 3, whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 3, let bits = Int(fields[0]), (512...16384).contains(bits),
              fields[1].allSatisfy(\.isNumber), fields[2].count >= 100, fields[2].allSatisfy(\.isNumber) else { return nil }
        return Public(type: "rsa1", label: "RSA1, SSH protocol 1 (obsolete)", bits: bits, fingerprint: "",
                      comment: fields.count > 3 ? String(fields[3]) : nil)
    }

    /// RFC 4716: `---- BEGIN SSH2 PUBLIC KEY ----`, headers, base64.
    static func rfc4716(_ text: String) -> [Public] {
        var keys: [Public] = []
        var inside = false
        var comment: String?
        var body = ""
        var continuing = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "---- BEGIN SSH2 PUBLIC KEY ----" {
                inside = true; comment = nil; body = ""; continuing = false
            } else if line == "---- END SSH2 PUBLIC KEY ----" {
                if inside, let blob = Data(base64Encoded: body), var key = try? describe([UInt8](blob)) {
                    key.comment = comment
                    keys.append(key)
                }
                inside = false
            } else if inside {
                if continuing {
                    continuing = line.hasSuffix("\\")
                } else if let colon = line.firstIndex(of: ":") { // base64 never has a colon: a header
                    let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                    var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    continuing = value.hasSuffix("\\")
                    if name.lowercased() == "comment" {
                        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
                        comment = value
                    }
                } else {
                    body += line
                }
            }
        }
        return keys
    }

    // MARK: - The key blob

    /// Type, size and fingerprint from the wire form of a public key or certificate.
    static func describe(_ blob: [UInt8]) throws -> Public {
        var reader = Wire(blob)
        let type = try reader.text()
        if type.hasSuffix("-cert-v01@openssh.com") { return try certificate(blob, type: type) }
        let (label, bits) = try fields(&reader, type: type)
        return Public(type: type, label: label, bits: bits, fingerprint: fingerprint(blob))
    }

    /// The key's own fields, after the type: what tells its size.
    private static func fields(_ reader: inout Wire, type: String) throws -> (String, Int?) {
        switch type {
        case "ssh-rsa":
            _ = try reader.string() // e
            return ("RSA", X509.bitLength(try reader.string()))
        case "ssh-dss":
            let p = try reader.string()
            for _ in 0..<3 { _ = try reader.string() }
            return ("DSA", X509.bitLength(p))
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            _ = try reader.string(); _ = try reader.string()
            return ("ECDSA", Int(type.suffix(3)))
        case "ssh-ed25519":
            _ = try reader.string()
            return ("ED25519", 256)
        case "ssh-ed448":
            _ = try reader.string()
            return ("ED448", 456)
        case "sk-ecdsa-sha2-nistp256@openssh.com":
            _ = try reader.string(); _ = try reader.string(); _ = try reader.string()
            return ("ECDSA-SK", 256)
        case "sk-ssh-ed25519@openssh.com":
            _ = try reader.string(); _ = try reader.string()
            return ("ED25519-SK", 256)
        default:
            throw Bad()
        }
    }

    /// An OpenSSH certificate (PROTOCOL.certkeys). Its fingerprint, as
    /// ssh-keygen gives it, is the plain key's: the key fields under the
    /// plain type, without nonce or signature.
    private static func certificate(_ blob: [UInt8], type: String) throws -> Public {
        var reader = Wire(blob)
        _ = try reader.string() // type
        _ = try reader.string() // nonce
        let plainType = type.hasPrefix("sk-")
            ? type.replacingOccurrences(of: "-cert-v01@openssh.com", with: "@openssh.com")
            : type.replacingOccurrences(of: "-cert-v01@openssh.com", with: "")
        let start = reader.at
        let (label, bits) = try fields(&reader, type: plainType)
        let plainKey = Wire.encode(Array(plainType.utf8)) + Array(blob[start..<reader.at])

        let serial = try reader.u64()
        let kind = try reader.u32()
        let keyID = try reader.text()
        var principals: [String] = []
        var packed = Wire(try reader.string())
        while packed.remaining > 0 { principals.append(try packed.text()) }
        let after = try reader.u64()
        let before = try reader.u64()
        let critical = try pairs(try reader.string())
        let extensions = try pairs(try reader.string())
        _ = try reader.string() // reserved
        let signer = try reader.string()
        let signerKey = try describe(signer)

        let certificate = Certificate(
            isHost: kind == 2, keyID: keyID, serial: serial, principals: principals,
            validAfter: after == 0 ? nil : Date(timeIntervalSince1970: Double(after)),
            validBefore: before == UInt64.max ? nil : Date(timeIntervalSince1970: Double(min(before, UInt64(Int64.max)))),
            criticalOptions: critical, extensions: extensions,
            signedBy: "\(signerKey.label) \(signerKey.fingerprint)")
        return Public(type: type, label: label + "-CERT", bits: bits, fingerprint: fingerprint(plainKey),
                      certificate: certificate)
    }

    /// Critical options and extensions: names, with a value when there is one.
    private static func pairs(_ bytes: [UInt8]) throws -> [String] {
        var reader = Wire(bytes)
        var list: [String] = []
        while reader.remaining > 0 {
            let name = try reader.text()
            let data = try reader.string()
            var inner = Wire(data)
            if data.isEmpty { list.append(name) } else if let value = try? inner.text() { list.append("\(name) \(value)") }
            else { list.append(name) }
        }
        return list
    }

    static func fingerprint(_ blob: [UInt8]) -> String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    // MARK: - OpenSSH private keys

    /// `openssh-key-v1`: whether it is encrypted, the public keys, and -- when
    /// it is not encrypted -- the comment stored beside the secret.
    static func openSSHPrivate(_ bytes: [UInt8]) throws -> Private {
        let magic = Array("openssh-key-v1".utf8) + [0]
        guard bytes.starts(with: magic) else { throw Bad() }
        var reader = Wire(Array(bytes.dropFirst(magic.count)))
        let cipher = try reader.text()
        let kdf = try reader.text()
        let kdfOptions = try reader.string()
        let count = Int(try reader.u32())
        guard count > 0, count < 64 else { throw Bad() }
        var keys = try (0..<count).map { _ in try describe(try reader.string()) }
        let secret = try reader.string()

        var encryption: String?
        if cipher != "none" {
            var options = Wire(kdfOptions)
            var text = "\(cipher), key derived with \(kdf)"
            if kdf == "bcrypt", (try? options.string()) != nil, let rounds = try? options.u32() {
                text += ", \(rounds) round\(rounds == 1 ? "" : "s")"
            }
            encryption = text
        } else {
            // Unencrypted: the comment follows each key's secret fields.
            var section = Wire(secret)
            _ = try? section.u32(); _ = try? section.u32() // check words
            for index in keys.indices {
                guard let type = try? section.text(), skipSecret(&section, type: type),
                      let comment = try? section.text() else { break }
                keys[index].comment = comment.isEmpty ? nil : comment
            }
        }
        return Private(keys: keys, encryption: encryption)
    }

    /// Steps over one key's secret fields without keeping them.
    private static func skipSecret(_ reader: inout Wire, type: String) -> Bool {
        let counts: [String: Int] = [
            "ssh-ed25519": 2, "ssh-rsa": 6, "ssh-dss": 5,
            "ecdsa-sha2-nistp256": 3, "ecdsa-sha2-nistp384": 3, "ecdsa-sha2-nistp521": 3,
        ]
        if let count = counts[type] {
            for _ in 0..<count { guard (try? reader.string()) != nil else { return false } }
            return true
        }
        // Security keys: public fields, application, a flags byte, handle, reserved.
        let publicFields = type == "sk-ssh-ed25519@openssh.com" ? 1 : type == "sk-ecdsa-sha2-nistp256@openssh.com" ? 2 : 0
        guard publicFields > 0 else { return false }
        for _ in 0..<(publicFields + 1) { guard (try? reader.string()) != nil else { return false } }
        guard (try? reader.u8()) != nil, (try? reader.string()) != nil, (try? reader.string()) != nil else { return false }
        return true
    }

    // MARK: - Wire format

    /// SSH's encoding: big-endian integers, and strings as a length and bytes.
    struct Wire {
        let bytes: [UInt8]
        var at = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var remaining: Int { bytes.count - at }

        mutating func u8() throws -> UInt8 {
            guard at < bytes.count else { throw Bad() }
            defer { at += 1 }
            return bytes[at]
        }

        mutating func u32() throws -> UInt32 {
            guard remaining >= 4 else { throw Bad() }
            defer { at += 4 }
            return bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }

        mutating func u64() throws -> UInt64 {
            let high = UInt64(try u32())
            return high << 32 | UInt64(try u32())
        }

        mutating func string() throws -> [UInt8] {
            let length = Int(try u32())
            guard length <= remaining else { throw Bad() }
            defer { at += length }
            return Array(bytes[at..<at + length])
        }

        mutating func text() throws -> String { String(decoding: try string(), as: UTF8.self) }

        static func encode(_ string: [UInt8]) -> [UInt8] {
            let count = UInt32(string.count)
            return [UInt8(count >> 24), UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)] + string
        }
    }
}
