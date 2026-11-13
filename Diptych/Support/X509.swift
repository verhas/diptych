import CryptoKit
import Foundation

/// An X.509 certificate, read for what a person checks: who it is for, who
/// vouches for it, when it is good, what key it carries, and its fingerprint.
nonisolated struct X509: Sendable {

    var subject: [(String, String)]
    var issuer: [(String, String)]
    var serial: String
    var notBefore: Date
    var notAfter: Date
    /// "RSA 2048", "EC P-256", "Ed25519".
    var key: String
    var signatureAlgorithm: String
    var alternativeNames: [String] = []
    var isAuthority = false
    var sha256: String
    var sha1: String
    /// The subject and issuer are the same name: nobody else vouches for it.
    var isSelfIssued: Bool
    let encoded: [UInt8]
    let subjectBytes: [UInt8]
    let issuerBytes: [UInt8]

    init(der bytes: [UInt8]) throws {
        let certificate = try DER(bytes).children(of: DER.sequence)
        guard certificate.count == 3 else { throw DER.Bad() }
        var tbs = try certificate[0].children(of: DER.sequence)
        if tbs.first?.identifier == DER.context(0) { tbs.removeFirst() } // version
        guard tbs.count >= 6 else { throw DER.Bad() }

        encoded = bytes
        serial = tbs[0].hex
        issuerBytes = tbs[2].encoded
        issuer = try X509.name(tbs[2])
        let validity = try tbs[3].children(of: DER.sequence)
        guard validity.count == 2 else { throw DER.Bad() }
        notBefore = try validity[0].time()
        notAfter = try validity[1].time()
        subjectBytes = tbs[4].encoded
        subject = try X509.name(tbs[4])
        key = (try? X509.keyDescription(tbs[5])) ?? "unknown key"
        signatureAlgorithm = X509.algorithmName((try? certificate[1].algorithm().oid) ?? "")
        isSelfIssued = subjectBytes == issuerBytes

        for part in tbs.dropFirst(6) where part.identifier == DER.context(3) {
            for extensionNode in (try? part.unwrapped().children()) ?? [] {
                guard let fields = try? extensionNode.children(), let id = try? fields.first?.oid(),
                      let value = try? fields.last?.octets(), let inner = try? DER(value) else { continue }
                switch id {
                case "2.5.29.17": alternativeNames = X509.readAlternativeNames(inner)
                case "2.5.29.19":
                    isAuthority = (try? inner.children().first)?.map { $0.identifier == DER.boolean && $0.content.first != 0 } ?? false
                default: break
                }
            }
        }
        sha256 = SHA256.hash(data: bytes).map { String(format: "%02X", $0) }.joined(separator: ":")
        sha1 = Insecure.SHA1.hash(data: bytes).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// The name as keytool prints it: most specific first, `CN=…, O=…, C=…`.
    static func text(of name: [(String, String)]) -> String {
        name.reversed().map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
    }

    /// The common name, or the whole name when there is none.
    static func shortName(_ name: [(String, String)]) -> String {
        name.last { $0.0 == "CN" }?.1 ?? text(of: name)
    }

    func isExpired(at now: Date = Date()) -> Bool { notAfter < now }
    func isNotYetValid(at now: Date = Date()) -> Bool { notBefore > now }

    // MARK: - Pieces

    private static let attributeNames: [String: String] = [
        "2.5.4.3": "CN", "2.5.4.6": "C", "2.5.4.7": "L", "2.5.4.8": "ST", "2.5.4.9": "STREET",
        "2.5.4.10": "O", "2.5.4.11": "OU", "2.5.4.5": "SERIALNUMBER", "2.5.4.12": "T",
        "2.5.4.42": "GIVENNAME", "2.5.4.4": "SURNAME", "2.5.4.97": "ORGID",
        "1.2.840.113549.1.9.1": "EMAILADDRESS", "0.9.2342.19200300.100.1.25": "DC",
        "0.9.2342.19200300.100.1.1": "UID",
    ]

    private static func name(_ node: DER) throws -> [(String, String)] {
        try node.children(of: DER.sequence).flatMap { relative in
            try relative.children(of: DER.set).map { pair in
                let parts = try pair.children(of: DER.sequence)
                guard parts.count == 2 else { throw DER.Bad() }
                let oid = try parts[0].oid()
                let value = (try? parts[1].string()) ?? parts[1].hex
                return (attributeNames[oid] ?? oid, value)
            }
        }
    }

    private static let curves: [String: String] = [
        "1.2.840.10045.3.1.7": "P-256", "1.3.132.0.34": "P-384", "1.3.132.0.35": "P-521",
        "1.3.132.0.10": "secp256k1", "1.2.840.10045.3.1.1": "P-192", "1.3.132.0.33": "P-224",
        "1.3.36.3.3.2.8.1.1.7": "brainpoolP256r1", "1.3.36.3.3.2.8.1.1.11": "brainpoolP384r1",
    ]

    private static func keyDescription(_ node: DER) throws -> String {
        let parts = try node.children(of: DER.sequence)
        guard parts.count == 2 else { throw DER.Bad() }
        let (oid, parameters) = try parts[0].algorithm()
        let bits = try parts[1].bits()
        switch oid {
        case "1.2.840.113549.1.1.1", "1.2.840.113549.1.1.10":
            let modulus = try DER(bits).children(of: DER.sequence).first?.content ?? []
            return "RSA \(bitLength(modulus))"
        case "1.2.840.10045.2.1":
            let curve = (try? parameters?.oid()).flatMap { curves[$0] ?? $0 } ?? "curve unnamed"
            return "EC \(curve)"
        case "1.2.840.10040.4.1":
            let prime = (try? parameters?.children().first?.content) ?? []
            return "DSA \(bitLength(prime))"
        case "1.3.101.112": return "Ed25519"
        case "1.3.101.113": return "Ed448"
        case "1.3.101.110": return "X25519"
        case "1.3.101.111": return "X448"
        default: return algorithmName(oid)
        }
    }

    private static func bitLength(_ integer: [UInt8]) -> Int {
        guard let first = integer.firstIndex(where: { $0 != 0 }) else { return 0 }
        return (integer.count - first) * 8 - integer[first].leadingZeroBitCount
    }

    static func algorithmName(_ oid: String) -> String {
        let names: [String: String] = [
            "1.2.840.113549.1.1.1": "RSA", "1.2.840.113549.1.1.4": "MD5 with RSA",
            "1.2.840.113549.1.1.5": "SHA-1 with RSA", "1.2.840.113549.1.1.10": "RSASSA-PSS",
            "1.2.840.113549.1.1.11": "SHA-256 with RSA", "1.2.840.113549.1.1.12": "SHA-384 with RSA",
            "1.2.840.113549.1.1.13": "SHA-512 with RSA", "1.2.840.10045.4.1": "ECDSA with SHA-1",
            "1.2.840.10045.4.3.2": "ECDSA with SHA-256", "1.2.840.10045.4.3.3": "ECDSA with SHA-384",
            "1.2.840.10045.4.3.4": "ECDSA with SHA-512", "1.3.101.112": "Ed25519", "1.3.101.113": "Ed448",
            "1.2.840.10040.4.3": "DSA with SHA-1", "2.16.840.1.101.3.4.3.2": "DSA with SHA-256",
        ]
        return names[oid] ?? oid
    }

    private static func readAlternativeNames(_ node: DER) -> [String] {
        ((try? node.children()) ?? []).compactMap { name in
            switch name.identifier {
            case 0x82: return "DNS:" + String(decoding: name.content, as: UTF8.self)
            case 0x81: return "email:" + String(decoding: name.content, as: UTF8.self)
            case 0x86: return "URI:" + String(decoding: name.content, as: UTF8.self)
            case 0x87 where name.content.count == 4:
                return "IP:" + name.content.map(String.init).joined(separator: ".")
            case 0x87 where name.content.count == 16:
                return "IP:" + stride(from: 0, to: 16, by: 2).map {
                    String(UInt16(name.content[$0]) << 8 | UInt16(name.content[$0 + 1]), radix: 16)
                }.joined(separator: ":")
            default: return nil
            }
        }
    }
}
