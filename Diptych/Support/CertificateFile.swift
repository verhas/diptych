import CryptoKit
import Foundation

/// A file of certificates and keys -- PEM, DER, PKCS#7, or SSH's own forms --
/// read into the things in it, in order: certificates, signing requests,
/// revocation lists, private and public keys.
///
/// A private key is described, never shown: its type and size, and whether a
/// password protects it. Its public half is worked out only to say which
/// certificate in the same file it belongs to.
nonisolated struct CertificateFile: Sendable {

    static let maximumSize = 8 * 1024 * 1024

    enum Item: Sendable {
        case certificate(X509, trusted: Bool)
        case request(Request)
        case revocationList(RevocationList)
        case privateKey(PrivateKey)
        case publicKey(PublicKey)
        case sshPublicKey(SSHKey.Public)
        case sshPrivateKey(SSHKey.Private)
        /// EC or DH parameters: not a key, said in words.
        case parameters(String)
        /// A block that is there but could not be read, and why.
        case unreadable(label: String, reason: String)
    }

    struct Request: Sendable {
        var subject: [(String, String)]
        var key: String
        var signatureAlgorithm: String
        var alternativeNames: [String]
        var hasChallengePassword: Bool
        var match: [UInt8]
    }

    struct RevocationList: Sendable {
        struct Revoked: Sendable { var serial: String; var date: Date; var reason: String? }
        var issuer: [(String, String)]
        var thisUpdate: Date
        var nextUpdate: Date?
        var number: String?
        var signatureAlgorithm: String
        var revoked: [Revoked]
    }

    struct PrivateKey: Sendable {
        /// PKCS#8, PKCS#1, SEC1 -- the container, said for the reader.
        var format: String
        /// "RSA 2048"; nil when the encryption hides even that.
        var key: String?
        /// nil when it is not encrypted.
        var protection: String?
        /// What it is matched to a certificate by: an RSA modulus, an EC or
        /// EdDSA public point.
        var match: [UInt8]?
    }

    struct PublicKey: Sendable {
        var format: String
        var key: String
        var match: [UInt8]
        var sha256: String
    }

    /// PEM, DER, OpenSSH, RFC 4716, authorized_keys.
    var encoding: String
    var items: [Item]

    struct NotRecognised: Error, CustomStringConvertible {
        var description: String { "It holds no certificate, key or request in any form this reads: PEM, DER, PKCS#7 or SSH." }
    }

    // MARK: - Reading

    static func read(_ data: Data) throws -> CertificateFile {
        let bytes = [UInt8](data)
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            if text.contains("-----BEGIN ") {
                let items = pemBlocks(text).flatMap(items)
                let openSSH = items.allSatisfy { if case .sshPrivateKey = $0 { return true } else { return false } }
                if !items.isEmpty { return CertificateFile(encoding: openSSH ? "OpenSSH" : "PEM", items: items) }
            }
            if text.contains("---- BEGIN SSH2 PUBLIC KEY ----") {
                let keys = SSHKey.rfc4716(text)
                if !keys.isEmpty { return CertificateFile(encoding: "RFC 4716", items: keys.map { .sshPublicKey($0) }) }
            }
            let lines = text.split(whereSeparator: \.isNewline)
            var keys = lines.compactMap(SSHKey.publicLine)
            if keys.isEmpty { keys = lines.compactMap(SSHKey.protocol1Line) }
            if !keys.isEmpty {
                let hasOptions = keys.contains { $0.options != nil } || keys.count > 1
                return CertificateFile(encoding: hasOptions ? "authorized_keys" : "OpenSSH",
                                       items: keys.map { .sshPublicKey($0) })
            }
        }
        if let items = der(bytes) { return CertificateFile(encoding: "DER", items: items) }
        throw NotRecognised()
    }

    // MARK: - PEM

    struct Block {
        var label: String
        var headers: [String: String]
        var body: [UInt8]
    }

    static func pemBlocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var label: String?
        var headers: [String: String] = [:]
        var base64 = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("-----BEGIN "), line.hasSuffix("-----") {
                label = String(line.dropFirst(11).dropLast(5))
                headers = [:]
                base64 = ""
            } else if line.hasPrefix("-----END "), let current = label {
                blocks.append(Block(label: current, headers: headers,
                                    body: [UInt8](Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data())))
                label = nil
            } else if label != nil {
                if let colon = line.firstIndex(of: ":") {
                    headers[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                } else {
                    base64 += line
                }
            }
        }
        return blocks
    }

    /// One block's items: one, or a PKCS#7 bundle's several.
    private static func items(_ block: Block) -> [Item] {
        if block.label == "PKCS7" || block.label == "CMS" {
            guard let found = try? pkcs7(block.body) else {
                return [.unreadable(label: block.label, reason: "It is damaged or not what its label says.")]
            }
            return found
        }
        return [item(block)]
    }

    private static func item(_ block: Block) -> Item {
        let body = block.body
        guard !body.isEmpty else { return .unreadable(label: block.label, reason: "It is empty, or its base64 is broken.") }
        do {
            switch block.label {
            case "CERTIFICATE", "X509 CERTIFICATE":
                return .certificate(try X509(der: body), trusted: false)
            case "TRUSTED CERTIFICATE":
                return .certificate(try X509(der: try DER.leading(body).encoded), trusted: true)
            case "CERTIFICATE REQUEST", "NEW CERTIFICATE REQUEST":
                return .request(try request(body))
            case "X509 CRL":
                return .revocationList(try revocationList(body))
            case "PRIVATE KEY":
                return .privateKey(try pkcs8(body))
            case "ENCRYPTED PRIVATE KEY":
                return .privateKey(try encryptedPKCS8(body))
            case "RSA PRIVATE KEY", "EC PRIVATE KEY", "DSA PRIVATE KEY":
                let kind = String(block.label.prefix { $0 != " " })
                if block.headers["Proc-Type"]?.contains("ENCRYPTED") == true {
                    let cipher = block.headers["DEK-Info"]?.split(separator: ",").first.map(String.init) ?? "an unnamed cipher"
                    return .privateKey(PrivateKey(format: formatName(kind), key: kind,
                                                  protection: "\(cipher), the old OpenSSL way (MD5 key derivation)"))
                }
                return .privateKey(try traditional(body, kind: kind))
            case "OPENSSH PRIVATE KEY":
                return .sshPrivateKey(try SSHKey.openSSHPrivate(body))
            case "PUBLIC KEY":
                return .publicKey(try publicKey(body))
            case "RSA PUBLIC KEY":
                let modulus = try DER(body).children(of: DER.sequence).first?.content ?? []
                return .publicKey(PublicKey(format: "PKCS#1", key: "RSA \(X509.bitLength(modulus))",
                                            match: stripped(modulus), sha256: hex(SHA256.hash(data: body))))
            case "EC PARAMETERS":
                let curve = (try? DER(body).oid()).map { X509.curveName($0) } ?? "an explicit curve"
                return .parameters("EC parameters for \(curve)")
            case "DH PARAMETERS", "X9.42 DH PARAMETERS":
                let prime = (try? DER(body).children().first?.content) ?? []
                return .parameters("Diffie-Hellman parameters, \(X509.bitLength(prime))-bit prime")
            default:
                return .unreadable(label: block.label, reason: "Not a kind of block this reads.")
            }
        } catch {
            return .unreadable(label: block.label, reason: "It is damaged or not what its label says.")
        }
    }

    // MARK: - DER

    /// A binary file: a certificate, a request, a CRL, a PKCS#7 bundle, or a key.
    private static func der(_ bytes: [UInt8]) -> [Item]? {
        guard bytes.first == DER.sequence, (try? DER(bytes)) != nil else { return nil }
        if let certificate = try? X509(der: bytes) { return [.certificate(certificate, trusted: false)] }
        if let request = try? request(bytes) { return [.request(request)] }
        if let list = try? revocationList(bytes) { return [.revocationList(list)] }
        if let items = try? pkcs7(bytes) { return items }
        if let key = try? pkcs8(bytes) { return [.privateKey(key)] }
        if let key = try? encryptedPKCS8(bytes) { return [.privateKey(key)] }
        if let key = try? publicKey(bytes) { return [.publicKey(key)] }
        if let key = try? traditional(bytes, kind: "RSA") { return [.privateKey(key)] }
        return nil
    }

    // MARK: - Requests and lists

    static func request(_ bytes: [UInt8]) throws -> Request {
        let parts = try DER(bytes).children(of: DER.sequence)
        guard parts.count == 3 else { throw DER.Bad() }
        let info = try parts[0].children(of: DER.sequence)
        guard info.count >= 3, (try info[0].int()) == 0 else { throw DER.Bad() }
        var request = Request(subject: try X509.name(info[1]), key: try X509.keyDescription(info[2]),
                              signatureAlgorithm: X509.algorithmName(try parts[1].algorithm().oid),
                              alternativeNames: [], hasChallengePassword: false,
                              match: matchValue(try X509.publicKeyBits(info[2]), key: try X509.keyDescription(info[2])))
        if info.count > 3, info[3].identifier == DER.context(0) {
            for attribute in try info[3].children() {
                let fields = try attribute.children(of: DER.sequence)
                guard fields.count == 2 else { continue }
                switch try fields[0].oid() {
                case "1.2.840.113549.1.9.14":
                    for extensionNode in try fields[1].children().first?.children() ?? [] {
                        let parts = try extensionNode.children()
                        if try parts.first?.oid() == "2.5.29.17", let value = try parts.last?.octets() {
                            request.alternativeNames = X509.readAlternativeNames(try DER(value))
                        }
                    }
                case "1.2.840.113549.1.9.7": request.hasChallengePassword = true
                default: break
                }
            }
        }
        return request
    }

    static func revocationList(_ bytes: [UInt8]) throws -> RevocationList {
        let parts = try DER(bytes).children(of: DER.sequence)
        guard parts.count == 3 else { throw DER.Bad() }
        var tbs = try parts[0].children(of: DER.sequence)
        if tbs.first?.identifier == DER.integer { tbs.removeFirst() } // version
        // A CRL's second field is an AlgorithmIdentifier, then a Name and a
        // time: a certificate has a serial first, which keeps the two apart.
        guard tbs.count >= 3, tbs[0].identifier == DER.sequence,
              (try? tbs[0].algorithm()) != nil else { throw DER.Bad() }
        var list = RevocationList(issuer: try X509.name(tbs[1]), thisUpdate: try tbs[2].time(), nextUpdate: nil,
                                  number: nil, signatureAlgorithm: X509.algorithmName(try parts[1].algorithm().oid),
                                  revoked: [])
        for part in tbs.dropFirst(3) {
            if part.identifier == DER.utcTime || part.identifier == DER.generalizedTime {
                list.nextUpdate = try part.time()
            } else if part.identifier == DER.sequence {
                list.revoked = try part.children().map { entry in
                    let fields = try entry.children(of: DER.sequence)
                    guard fields.count >= 2 else { throw DER.Bad() }
                    var reason: String?
                    if fields.count > 2 {
                        for extensionNode in (try? fields[2].children()) ?? [] {
                            let parts = try extensionNode.children()
                            if try parts.first?.oid() == "2.5.29.21", let value = try parts.last?.octets(),
                               let code = try DER(value).content.first {
                                reason = reasons[Int(code)] ?? "reason \(code)"
                            }
                        }
                    }
                    return .init(serial: fields[0].hex, date: try fields[1].time(), reason: reason)
                }
            } else if part.identifier == DER.context(0) {
                for extensionNode in (try? part.unwrapped().children()) ?? [] {
                    let parts = try extensionNode.children()
                    if try parts.first?.oid() == "2.5.29.20", let value = try parts.last?.octets() {
                        list.number = String(Int((try? DER(value).int()) ?? 0))
                    }
                }
            }
        }
        return list
    }

    private static let reasons = [
        0: "unspecified", 1: "key compromise", 2: "CA compromise", 3: "affiliation changed",
        4: "superseded", 5: "cessation of operation", 6: "certificate hold", 8: "remove from CRL",
        9: "privilege withdrawn", 10: "AA compromise",
    ]

    /// SignedData's certificates and CRLs; nothing else in it is a reader's concern.
    static func pkcs7(_ bytes: [UInt8]) throws -> [Item] {
        let info = try DER(bytes).children(of: DER.sequence)
        guard info.count == 2, try info[0].oid() == "1.2.840.113549.1.7.2" else { throw DER.Bad() }
        let signed = try info[1].unwrapped().children(of: DER.sequence)
        var items: [Item] = []
        for part in signed {
            if part.identifier == DER.context(0) {
                items += try part.children().map { .certificate(try X509(der: $0.encoded), trusted: false) }
            } else if part.identifier == DER.context(1) {
                items += try part.children().map { .revocationList(try revocationList($0.encoded)) }
            }
        }
        return items
    }

    // MARK: - Keys

    private static func formatName(_ kind: String) -> String {
        kind == "EC" ? "SEC1" : kind == "RSA" ? "PKCS#1" : "OpenSSL's traditional"
    }

    /// PKCS#8 PrivateKeyInfo: the algorithm, then the key in its own form.
    static func pkcs8(_ bytes: [UInt8]) throws -> PrivateKey {
        let parts = try DER(bytes).children(of: DER.sequence)
        guard parts.count >= 3, parts[0].identifier == DER.integer, parts[2].identifier == DER.octetString else { throw DER.Bad() }
        let (oid, parameters) = try parts[1].algorithm()
        let inner = parts[2].content
        // OneAsymmetricKey (v2) may carry the public key as [1].
        let attached = parts.dropFirst(3).first { $0.identifier == DER.context(1, constructed: false) }
            .map { Array($0.content.dropFirst()) }
        switch oid {
        case "1.2.840.113549.1.1.1", "1.2.840.113549.1.1.10":
            var key = try traditional(inner, kind: "RSA")
            key.format = "PKCS#8"
            return key
        case "1.2.840.10045.2.1":
            let curve = (try? parameters?.oid()) ?? nil
            var key = try sec1(inner, curve: curve)
            key.format = "PKCS#8"
            return key
        case "1.3.101.112":
            let seed = try DER(inner).content
            let derived = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
            return PrivateKey(format: "PKCS#8", key: "Ed25519", match: attached ?? derived.map { [UInt8]($0) })
        case "1.3.101.110":
            let seed = try DER(inner).content
            let derived = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
            return PrivateKey(format: "PKCS#8", key: "X25519", match: attached ?? derived.map { [UInt8]($0) })
        case "1.2.840.10040.4.1":
            let prime = (try? parameters?.children().first?.content) ?? []
            return PrivateKey(format: "PKCS#8", key: "DSA \(X509.bitLength(prime))")
        default:
            return PrivateKey(format: "PKCS#8", key: X509.algorithmName(oid), match: attached)
        }
    }

    static func encryptedPKCS8(_ bytes: [UInt8]) throws -> PrivateKey {
        let parts = try DER(bytes).children(of: DER.sequence)
        guard parts.count == 2, parts[1].identifier == DER.octetString, (try? parts[0].algorithm()) != nil else { throw DER.Bad() }
        return PrivateKey(format: "PKCS#8", key: nil,
                          protection: KeyStore.protection(ofEncryptedKey: bytes) ?? "an unnamed algorithm")
    }

    /// PKCS#1 RSA, SEC1 EC, or OpenSSL's DSA: the key's own structure.
    static func traditional(_ bytes: [UInt8], kind: String) throws -> PrivateKey {
        switch kind {
        case "EC": return try sec1(bytes, curve: nil)
        case "RSA":
            let fields = try DER(bytes).children(of: DER.sequence)
            guard fields.count >= 9, fields.allSatisfy({ $0.identifier == DER.integer }) else { throw DER.Bad() }
            return PrivateKey(format: "PKCS#1", key: "RSA \(X509.bitLength(fields[1].content))",
                              match: stripped(fields[1].content))
        default:
            let fields = try DER(bytes).children(of: DER.sequence)
            guard fields.count == 6 else { throw DER.Bad() }
            return PrivateKey(format: formatName(kind), key: "DSA \(X509.bitLength(fields[1].content))")
        }
    }

    /// SEC1 ECPrivateKey: the curve inside, or from PKCS#8 around it; the
    /// public point when it is written, or worked out from the secret.
    private static func sec1(_ bytes: [UInt8], curve outer: String?) throws -> PrivateKey {
        let fields = try DER(bytes).children(of: DER.sequence)
        guard fields.count >= 2, fields[1].identifier == DER.octetString else { throw DER.Bad() }
        var curve = outer
        var point: [UInt8]?
        for field in fields.dropFirst(2) {
            if field.identifier == DER.context(0) { curve = try? field.unwrapped().oid() }
            if field.identifier == DER.context(1) { point = try? field.unwrapped().bits() }
        }
        if point == nil {
            let secret = fields[1].content
            switch curve {
            case "1.2.840.10045.3.1.7": point = (try? P256.Signing.PrivateKey(rawRepresentation: secret)).map { [UInt8]($0.publicKey.x963Representation) }
            case "1.3.132.0.34": point = (try? P384.Signing.PrivateKey(rawRepresentation: secret)).map { [UInt8]($0.publicKey.x963Representation) }
            case "1.3.132.0.35": point = (try? P521.Signing.PrivateKey(rawRepresentation: secret)).map { [UInt8]($0.publicKey.x963Representation) }
            default: break
            }
        }
        return PrivateKey(format: "SEC1", key: "EC " + (curve.map(X509.curveName) ?? "curve unnamed"), match: point)
    }

    static func publicKey(_ bytes: [UInt8]) throws -> PublicKey {
        let node = try DER(bytes)
        let key = try X509.keyDescription(node)
        return PublicKey(format: "SubjectPublicKeyInfo", key: key,
                         match: matchValue(try X509.publicKeyBits(node), key: key), sha256: hex(SHA256.hash(data: bytes)))
    }

    // MARK: - Matching

    /// What a certificate's key is compared by: the RSA modulus, or the
    /// public point as it stands.
    static func matchValue(_ publicBits: [UInt8], key: String) -> [UInt8] {
        guard key.hasPrefix("RSA"), let modulus = try? DER(publicBits).children(of: DER.sequence).first?.content else {
            return publicBits
        }
        return stripped(modulus)
    }

    static func matchValue(of certificate: X509) -> [UInt8] {
        matchValue(certificate.publicKey, key: certificate.key)
    }

    private static func stripped(_ integer: [UInt8]) -> [UInt8] {
        Array(integer.drop { $0 == 0 })
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
