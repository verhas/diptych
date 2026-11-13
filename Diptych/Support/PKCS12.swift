import CommonCrypto
import CryptoKit
import Foundation

/// A PKCS#12 store (`.p12`, `.pfx`, and Java's default `.keystore` since 9):
/// bags of keys and certificates, some kept in the clear, some encrypted with
/// the password, the whole sealed with a MAC the password keys.
///
/// What is in the clear is read as it is. The encrypted parts are opened only
/// with a default password that the MAC confirms -- or, in a store with no
/// MAC, that decrypts to well-formed certificates. Keys are never decrypted.
nonisolated enum PKCS12 {

    private enum OID {
        static let data = "1.2.840.113549.1.7.1", encryptedData = "1.2.840.113549.1.7.6"
        static let envelopedData = "1.2.840.113549.1.7.3"
        static let keyBag = "1.2.840.113549.1.12.10.1.1", shroudedKeyBag = "1.2.840.113549.1.12.10.1.2"
        static let certBag = "1.2.840.113549.1.12.10.1.3", crlBag = "1.2.840.113549.1.12.10.1.4"
        static let secretBag = "1.2.840.113549.1.12.10.1.5", safeContentsBag = "1.2.840.113549.1.12.10.1.6"
        static let x509Certificate = "1.2.840.113549.1.9.22.1"
        static let friendlyName = "1.2.840.113549.1.9.20", localKeyId = "1.2.840.113549.1.9.21"
        /// Java marks the certificates it trusts with this attribute.
        static let javaTrusted = "2.16.840.1.113894.746875.1.1"
        static let pbes2 = "1.2.840.113549.1.5.13", pbkdf2 = "1.2.840.113549.1.5.12"
        static let pbmac1 = "1.2.840.113549.1.5.14"
    }

    private struct Bag {
        var kind: KeyStore.Kind
        var alias: String?
        var keyId: [UInt8]?
        var trusted = false
        var certificate: X509?
        var protection: String?
    }

    static func read(_ bytes: [UInt8]) throws -> KeyStore {
        guard let pfx = try? DER(bytes).children(of: DER.sequence), pfx.count >= 2,
              (try? pfx[0].int()) == 3 else { throw KeyStore.Problem.notAKeyStore }
        var store = KeyStore(format: .pkcs12)
        store.version = 3

        let (type, wrapped) = try contentInfo(pfx[1])
        guard type == OID.data, let wrapped else {
            throw KeyStore.Problem.damaged("Its contents are signed with a public key rather than a password, which this does not read.")
        }
        let authenticatedSafe = try wrapped.octets()

        // The MAC says which password is right, when it is a default one.
        var confirmed: String?
        if pfx.count > 2 {
            let mac = verifyMAC(pfx[2], over: authenticatedSafe)
            store.integrity = mac.description
            confirmed = mac.password
            store.password = mac.password.map { .known($0) } ?? .unknown
        } else {
            store.password = .notNeeded
        }

        var bags: [Bag] = []
        var shut: [String] = []
        for part in try DER(authenticatedSafe).children(of: DER.sequence) {
            let (type, content) = try contentInfo(part)
            switch type {
            case OID.data:
                if let content { bags += try safeContents(try content.octets()) }
            case OID.encryptedData:
                guard let content else { continue }
                let (opened, algorithm, password) = open(content, tryingFirst: confirmed, withMAC: pfx.count > 2)
                if let opened {
                    bags += try safeContents(opened)
                    if store.password == .notNeeded, let password { store.password = .known(password) }
                } else {
                    shut.append(algorithm)
                }
            case OID.envelopedData:
                shut.append("a public key")
            default:
                break
            }
        }
        if !shut.isEmpty {
            store.notes.append("\(shut.count == 1 ? "One part is" : "\(shut.count) parts are") encrypted "
                               + "(\(Set(shut).sorted().joined(separator: "; "))) and needs the store's password: "
                               + "the certificates in it are not shown.")
            if store.password == .notNeeded { store.password = .unknown }
        }
        store.entries = entries(from: bags)
        return store
    }

    // MARK: - Structure

    private static func contentInfo(_ node: DER) throws -> (String, DER?) {
        let parts = try node.children(of: DER.sequence)
        guard let first = parts.first else { throw DER.Bad() }
        let content = parts.count > 1 ? try parts[1].unwrapped() : nil
        return (try first.oid(), content)
    }

    private static func safeContents(_ bytes: [UInt8], depth: Int = 0) throws -> [Bag] {
        guard depth < 4 else { return [] }
        return try DER(bytes).children(of: DER.sequence).flatMap { bag -> [Bag] in
            let parts = try bag.children(of: DER.sequence)
            guard parts.count >= 2 else { throw DER.Bad() }
            let id = try parts[0].oid()
            let value = try parts[1].unwrapped()
            var result = Bag(kind: .certificate)
            if parts.count > 2 { attributes(parts[2], into: &result) }
            switch id {
            case OID.keyBag:
                result.kind = .privateKey
                result.protection = "Not encrypted"
            case OID.shroudedKeyBag:
                result.kind = .privateKey
                result.protection = KeyStore.protection(ofEncryptedKey: value.encoded)
            case OID.certBag:
                let cert = try value.children(of: DER.sequence)
                guard cert.count == 2, try cert[0].oid() == OID.x509Certificate else { return [] }
                result.certificate = try X509(der: try cert[1].unwrapped().octets())
            case OID.secretBag:
                result.kind = .secretKey
                let inner = try? value.children(of: DER.sequence)
                if let wrapped = try? inner?.last?.unwrapped() {
                    result.protection = KeyStore.protection(ofEncryptedKey: (try? wrapped.octets()) ?? wrapped.encoded)
                }
            case OID.safeContentsBag:
                return try safeContents(value.encoded, depth: depth + 1)
            default:
                return []
            }
            return [result]
        }
    }

    private static func attributes(_ set: DER, into bag: inout Bag) {
        for attribute in (try? set.children()) ?? [] {
            guard let parts = try? attribute.children(of: DER.sequence), parts.count == 2,
                  let id = try? parts[0].oid(), let values = try? parts[1].children() else { continue }
            switch id {
            case OID.friendlyName: bag.alias = try? values.first?.string()
            case OID.localKeyId: bag.keyId = values.first?.content
            case OID.javaTrusted: bag.trusted = true
            default: break
            }
        }
    }

    /// Keys with the certificates that go with them -- by local key ID, then
    /// up the chain by issuer -- and the certificates no key claims.
    private static func entries(from bags: [Bag]) -> [KeyStore.Entry] {
        let certificates = bags.filter { $0.certificate != nil }
        var used = Set<Int>()
        var entries: [KeyStore.Entry] = []

        func chain(from start: Int) -> [X509] {
            var list: [X509] = []
            var current: Int? = start
            while let index = current, list.count < 10, let certificate = certificates[index].certificate {
                used.insert(index)
                list.append(certificate)
                guard !certificate.isSelfIssued else { break }
                current = certificates.indices.first {
                    !used.contains($0) && certificates[$0].certificate?.subjectBytes == certificate.issuerBytes
                }
            }
            return list
        }

        for bag in bags where bag.kind != .certificate {
            var entry = KeyStore.Entry(alias: bag.alias ?? "", kind: bag.kind)
            entry.protection = bag.protection
            if let id = bag.keyId, let leaf = certificates.firstIndex(where: { $0.keyId == id }) {
                entry.chain = chain(from: leaf)
                if entry.alias.isEmpty { entry.alias = certificates[leaf].alias ?? "" }
            }
            entries.append(entry)
        }
        for (index, bag) in certificates.enumerated() where bag.trusted && !used.contains(index) {
            used.insert(index)
            entries.append(KeyStore.Entry(alias: bag.alias ?? "", kind: .trustedCertificate,
                                          chain: [bag.certificate].compactMap { $0 }))
        }
        for (index, bag) in certificates.enumerated() where !used.contains(index) {
            entries.append(KeyStore.Entry(alias: bag.alias ?? "", kind: .certificate,
                                          chain: [bag.certificate].compactMap { $0 }))
        }
        return entries
    }

    // MARK: - MAC

    private struct MAC {
        var description: String
        var password: String?
    }

    /// The MAC over the contents, checked with each default password.
    private static func verifyMAC(_ node: DER, over content: [UInt8]) -> MAC {
        guard let parts = try? node.children(of: DER.sequence), parts.count >= 2,
              let digestInfo = try? parts[0].children(of: DER.sequence), digestInfo.count == 2,
              let (oid, _) = try? digestInfo[0].algorithm() else {
            return MAC(description: "a MAC it was not possible to read", password: nil)
        }
        if oid == OID.pbmac1 { return MAC(description: "PBMAC1", password: nil) }
        let salt = parts[1].content
        let iterations = parts.count > 2 ? ((try? parts[2].int()) ?? 1) : 1
        let digest = digestInfo[1].content
        guard let hash = Hash(oid: oid) else {
            return MAC(description: "a MAC with \(KeyStore.algorithmName(oid))", password: nil)
        }
        let description = "HMAC-\(hash.name), \(iterations.formatted()) iteration\(iterations == 1 ? "" : "s")"
        guard iterations <= Hash.mostIterations else { return MAC(description: description, password: nil) }
        for password in KeyStore.defaultPasswords {
            for encoded in pkcs12Encodings(password) {
                let key = kdf(hash, password: encoded, salt: salt, id: 3, iterations: iterations, length: hash.size)
                if hash.hmac(key: key, data: content) == digest { return MAC(description: description, password: password) }
            }
        }
        return MAC(description: description, password: nil)
    }

    // MARK: - Opening encrypted parts

    /// EncryptedData, opened with the confirmed password -- or, without a
    /// MAC to confirm one, with each default that decrypts to a store's bags.
    private static func open(_ node: DER, tryingFirst confirmed: String?, withMAC: Bool)
        -> (bytes: [UInt8]?, algorithm: String, password: String?) {
        guard let parts = try? node.children(of: DER.sequence), parts.count >= 2,
              let info = try? parts[1].children(of: DER.sequence), info.count >= 3,
              let encrypted = try? info[2].octets() else {
            return (nil, "in a form that could not be read", nil)
        }
        let algorithm = info[1]
        let name = describe(algorithm)
        let candidates = withMAC ? [confirmed].compactMap { $0 } : KeyStore.defaultPasswords
        for password in candidates {
            if let plain = decrypt(encrypted, with: algorithm, password: password),
               (try? DER(plain).children(of: DER.sequence)) != nil {
                return (plain, name, password)
            }
        }
        return (nil, name, nil)
    }

    private static func describe(_ algorithm: DER) -> String {
        guard let (oid, parameters) = try? algorithm.algorithm() else { return "an unknown algorithm" }
        guard oid == OID.pbes2, let scheme = try? parameters?.children().last?.algorithm() else {
            return KeyStore.algorithmName(oid)
        }
        return "PBES2, " + KeyStore.algorithmName(scheme.oid)
    }

    static func decrypt(_ data: [UInt8], with algorithm: DER, password: String) -> [UInt8]? {
        guard let (oid, parameters) = try? algorithm.algorithm(), let parameters else { return nil }
        if oid == OID.pbes2 { return pbes2(data, parameters, password) }

        // PKCS#12's own: SHA-1 and its key derivation, then 3DES or RC2.
        let ciphers: [String: (algorithm: CCAlgorithm, key: Int, block: Int)] = [
            "1.2.840.113549.1.12.1.3": (CCAlgorithm(kCCAlgorithm3DES), 24, 8),
            "1.2.840.113549.1.12.1.4": (CCAlgorithm(kCCAlgorithm3DES), 16, 8),
            "1.2.840.113549.1.12.1.5": (CCAlgorithm(kCCAlgorithmRC2), 16, 8),
            "1.2.840.113549.1.12.1.6": (CCAlgorithm(kCCAlgorithmRC2), 5, 8),
        ]
        guard let cipher = ciphers[oid], let fields = try? parameters.children(of: DER.sequence),
              fields.count == 2, let iterations = try? fields[1].int(),
              iterations <= Hash.mostIterations else { return nil }
        let salt = fields[0].content
        for encoded in pkcs12Encodings(password) {
            var key = kdf(.sha1, password: encoded, salt: salt, id: 1, iterations: iterations, length: cipher.key)
            if oid == "1.2.840.113549.1.12.1.4" { key += key.prefix(8) } // two-key 3DES: K1 K2 K1
            let iv = kdf(.sha1, password: encoded, salt: salt, id: 2, iterations: iterations, length: cipher.block)
            if let plain = crypt(data, algorithm: cipher.algorithm, key: key, iv: iv) { return plain }
        }
        return nil
    }

    private static func pbes2(_ data: [UInt8], _ parameters: DER, _ password: String) -> [UInt8]? {
        guard let parts = try? parameters.children(of: DER.sequence), parts.count == 2,
              let (kdfOID, kdfParameters) = try? parts[0].algorithm(), kdfOID == OID.pbkdf2,
              let fields = try? kdfParameters?.children(of: DER.sequence), fields.count >= 2,
              let iterations = try? fields[1].int(), iterations <= 10_000_000,
              let (schemeOID, ivNode) = try? parts[1].algorithm(), let iv = ivNode?.content else { return nil }
        let salt = fields[0].content
        var prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        if let last = fields.last, last.identifier == DER.sequence, let (prfOID, _) = try? last.algorithm() {
            switch prfOID {
            case "1.2.840.113549.2.9": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
            case "1.2.840.113549.2.10": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
            case "1.2.840.113549.2.11": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
            case "1.2.840.113549.2.7": break
            default: return nil
            }
        }
        let schemes: [String: (CCAlgorithm, Int)] = [
            "2.16.840.1.101.3.4.1.2": (CCAlgorithm(kCCAlgorithmAES), 16),
            "2.16.840.1.101.3.4.1.22": (CCAlgorithm(kCCAlgorithmAES), 24),
            "2.16.840.1.101.3.4.1.42": (CCAlgorithm(kCCAlgorithmAES), 32),
            "1.2.840.113549.3.7": (CCAlgorithm(kCCAlgorithm3DES), 24),
        ]
        guard let (cipher, keyLength) = schemes[schemeOID] else { return nil }
        let passwordBytes = Array(password.utf8)
        var key = [UInt8](repeating: 0, count: keyLength)
        let status = passwordBytes.withUnsafeBufferPointer { passwordBuffer in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 passwordBuffer.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                                 passwordBytes.count, salt, salt.count, prf, UInt32(iterations), &key, keyLength)
        }
        guard status == kCCSuccess else { return nil }
        return crypt(data, algorithm: cipher, key: key, iv: iv)
    }

    private static func crypt(_ data: [UInt8], algorithm: CCAlgorithm, key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: data.count + 16)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), algorithm, CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, data, data.count, &out, out.count, &moved)
        guard status == kCCSuccess else { return nil }
        return Array(out.prefix(moved))
    }

    // MARK: - PKCS#12 key derivation (RFC 7292, appendix B)

    enum Hash {
        case sha1, sha256, sha384, sha512

        /// Beyond this a store is not worth the preview's time to try.
        static let mostIterations = 250_000

        init?(oid: String) {
            switch oid {
            case "1.3.14.3.2.26": self = .sha1
            case "2.16.840.1.101.3.4.2.1": self = .sha256
            case "2.16.840.1.101.3.4.2.2": self = .sha384
            case "2.16.840.1.101.3.4.2.3": self = .sha512
            default: return nil
            }
        }

        var name: String {
            switch self { case .sha1: "SHA1"; case .sha256: "SHA256"; case .sha384: "SHA384"; case .sha512: "SHA512" }
        }
        var size: Int { switch self { case .sha1: 20; case .sha256: 32; case .sha384: 48; case .sha512: 64 } }
        var block: Int { switch self { case .sha1, .sha256: 64; case .sha384, .sha512: 128 } }

        func digest(_ data: [UInt8]) -> [UInt8] {
            switch self {
            case .sha1: Array(Insecure.SHA1.hash(data: data))
            case .sha256: Array(SHA256.hash(data: data))
            case .sha384: Array(SHA384.hash(data: data))
            case .sha512: Array(SHA512.hash(data: data))
            }
        }

        func hmac(key: [UInt8], data: [UInt8]) -> [UInt8] {
            let key = SymmetricKey(data: key)
            switch self {
            case .sha1: return Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key))
            case .sha256: return Array(HMAC<SHA256>.authenticationCode(for: data, using: key))
            case .sha384: return Array(HMAC<SHA384>.authenticationCode(for: data, using: key))
            case .sha512: return Array(HMAC<SHA512>.authenticationCode(for: data, using: key))
            }
        }
    }

    /// The password as PKCS#12 hashes it: UTF-16 big-endian with a closing
    /// zero. An empty one is written both ways in the wild -- as that zero
    /// alone, and as nothing at all -- so both are tried.
    static func pkcs12Encodings(_ password: String) -> [[UInt8]] {
        let units: [UInt8] = password.utf16.flatMap { unit -> [UInt8] in [UInt8(unit >> 8), UInt8(unit & 0xFF)] } + [0, 0]
        return password.isEmpty ? [units, []] : [units]
    }

    static func kdf(_ hash: Hash, password: [UInt8], salt: [UInt8], id: UInt8, iterations: Int, length: Int) -> [UInt8] {
        let v = hash.block
        func stretched(_ bytes: [UInt8]) -> [UInt8] {
            guard !bytes.isEmpty else { return [] }
            let count = v * ((bytes.count + v - 1) / v)
            return (0..<count).map { bytes[$0 % bytes.count] }
        }
        let diversifier = [UInt8](repeating: id, count: v)
        var input = stretched(salt) + stretched(password)
        var out: [UInt8] = []
        while out.count < length {
            var a = hash.digest(diversifier + input)
            for _ in 1..<max(iterations, 1) { a = hash.digest(a) }
            out += a
            guard out.count < length else { break }
            let b = stretched(a)
            // Each v-byte block of the input becomes (block + B + 1) mod 2^(8v).
            for start in stride(from: 0, to: input.count, by: v) {
                var carry = 1
                for offset in stride(from: v - 1, through: 0, by: -1) {
                    let sum = Int(input[start + offset]) + Int(b[offset]) + carry
                    input[start + offset] = UInt8(sum & 0xFF)
                    carry = sum >> 8
                }
            }
        }
        return Array(out.prefix(length))
    }
}
