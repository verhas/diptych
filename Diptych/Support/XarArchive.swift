import CryptoKit
import Foundation
import Security

/// A xar archive, the container of a flat installer package: a header, a
/// zlib-compressed XML table of contents, then the heap the table points
/// into. Read only; nothing is extracted to disk.
nonisolated struct XarArchive {

    struct Entry {
        var path: String
        var isDirectory: Bool
        var offset: UInt64 = 0
        var length: UInt64 = 0
        var size: UInt64 = 0
        var encoding = ""
    }

    struct Signature {
        var certificates: [X509] = []
        /// From the CMS signature, when there is one: the time it was made.
        var signedAt: Date?
        /// Whether the table of contents hashes as recorded, and the RSA
        /// signature over that hash verifies with the signer's key.
        var intact: Bool?
        var problem: String?
        var hasCMS = false

        var signer: X509? {
            certificates.first { leaf in
                !certificates.contains { $0.issuerBytes == leaf.subjectBytes && $0.subjectBytes != leaf.subjectBytes }
            } ?? certificates.first
        }
    }

    enum Problem: Error, CustomStringConvertible {
        case damaged(String)
        var description: String { switch self { case .damaged(let why): why } }
    }

    static let maximumTable = 64 * 1024 * 1024

    let data: Data
    let heap: Int
    let entries: [Entry]
    let created: Date?
    let checksumName: String
    let signature: Signature?

    static func looksLikeXar(_ data: Data) -> Bool {
        data.count >= 28 && data.prefix(4) == Data("xar!".utf8)
    }

    init(data: Data) throws {
        guard Self.looksLikeXar(data) else { throw Problem.damaged("It is not a xar archive.") }
        let reader = BinaryReader(data, bigEndian: true)
        let header = Int(try reader.u16(4))
        let compressed = try reader.u64(8), expanded = try reader.u64(16)
        guard header >= 28, compressed > 0, compressed < UInt64(Self.maximumTable), expanded < UInt64(Self.maximumTable),
              reader.contains(header, Int(compressed)) else {
            throw Problem.damaged("Its table of contents is cut short or too large.")
        }
        let packed = try reader.bytes(header, Int(compressed))
        guard let tocData = Decompress.zlib(packed, limit: Int(expanded) + 1),
              let document = try? XMLDocument(data: tocData, options: []) else {
            throw Problem.damaged("Its table of contents cannot be read.")
        }
        self.data = data
        heap = header + Int(compressed)
        let toc = document.rootElement()?.elements(forName: "toc").first

        var entries: [Entry] = []
        func walk(_ element: XMLElement, prefix: String, depth: Int = 0) {
            for file in element.elements(forName: "file") {
                let name = file.elements(forName: "name").first?.stringValue ?? ""
                let path = prefix.isEmpty ? name : prefix + "/" + name
                let type = file.elements(forName: "type").first?.stringValue ?? "file"
                var entry = Entry(path: path, isDirectory: type == "directory")
                if let content = file.elements(forName: "data").first {
                    func number(_ name: String) -> UInt64 {
                        UInt64(content.elements(forName: name).first?.stringValue ?? "") ?? 0
                    }
                    entry.offset = number("offset")
                    entry.length = number("length")
                    entry.size = number("size")
                    entry.encoding = content.elements(forName: "encoding").first?.attribute(forName: "style")?.stringValue ?? ""
                }
                entries.append(entry)
                if entries.count < 100_000, depth < 256 { walk(file, prefix: path, depth: depth + 1) }
            }
        }
        if let toc { walk(toc, prefix: "") }
        self.entries = entries

        created = toc?.elements(forName: "creation-time").first?.stringValue.flatMap(Self.date)
        let checksum = toc?.elements(forName: "checksum").first
        checksumName = checksum?.attribute(forName: "style")?.stringValue ?? ""
        signature = Self.signature(toc, checksum: checksum, packed: packed, data: data, heap: heap)
    }

    /// The bytes of an entry, decoded; nil when too large or not decodable.
    func contents(of path: String, limit: Int = 16 * 1024 * 1024) -> Data? {
        guard let entry = entries.first(where: { $0.path == path && !$0.isDirectory }),
              entry.length <= UInt64(limit) * 4, entry.size <= UInt64(limit) else { return nil }
        let reader = BinaryReader(data)
        let (at, overflow) = heap.addingReportingOverflow(Int(clamping: entry.offset))
        guard !overflow, let stored = try? reader.bytes(at, Int(entry.length)) else { return nil }
        switch entry.encoding {
        case "application/x-gzip": return Decompress.zlib(stored, limit: max(Int(entry.size), 1))
        case "", "application/octet-stream": return stored
        default: return nil
        }
    }

    func entry(_ path: String) -> Entry? { entries.first { $0.path == path } }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withFullTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: text) ?? formatter.date(from: text + "Z")
    }

    // MARK: - Signature

    private static func signature(_ toc: XMLElement?, checksum: XMLElement?, packed: Data, data: Data,
                                  heap: Int) -> Signature? {
        guard let toc else { return nil }
        let rsa = toc.elements(forName: "signature").first
        let cms = toc.elements(forName: "x-signature").first
        guard rsa != nil || cms != nil else { return nil }
        var result = Signature()
        let reader = BinaryReader(data)
        func place(_ element: XMLElement?) -> (Int, Int)? {
            guard let element,
                  let offset = Int(element.elements(forName: "offset").first?.stringValue ?? ""),
                  let size = Int(element.elements(forName: "size").first?.stringValue ?? ""),
                  case let (at, overflow) = heap.addingReportingOverflow(offset), !overflow,
                  reader.contains(at, size) else { return nil }
            return (at, size)
        }
        func certificates(_ element: XMLElement?) -> [X509] {
            let texts = element?.elements(forName: "KeyInfo").first?.elements(forName: "X509Data").first?
                .elements(forName: "X509Certificate").compactMap(\.stringValue) ?? []
            return texts.compactMap { text in
                Data(base64Encoded: text, options: .ignoreUnknownCharacters).flatMap { try? X509(der: [UInt8]($0)) }
            }
        }
        result.certificates = certificates(rsa ?? cms)

        if let cms, let (at, size) = place(cms), let raw = try? reader.bytes(at, size) {
            result.hasCMS = true
            let (found, time) = MachOFile.CodeSignature.details(ofCMS: [UInt8](raw))
            if result.certificates.isEmpty { result.certificates = found }
            result.signedAt = time
        }

        // The checksum of the packed table, stored at the start of the heap,
        // is what the RSA signature signs.
        let style = checksum?.attribute(forName: "style")?.stringValue ?? ""
        let digest: [UInt8]
        let algorithm: SecKeyAlgorithm
        switch style {
        case "sha1": digest = Array(Insecure.SHA1.hash(data: packed)); algorithm = .rsaSignatureDigestPKCS1v15SHA1
        case "sha256": digest = Array(SHA256.hash(data: packed)); algorithm = .rsaSignatureDigestPKCS1v15SHA256
        case "sha512": digest = Array(SHA512.hash(data: packed)); algorithm = .rsaSignatureDigestPKCS1v15SHA512
        default:
            result.problem = "Its checksum (\(style.isEmpty ? "none" : style)) is not one checked here."
            return result
        }
        guard let (at, size) = place(checksum), size == digest.count,
              let stored = try? reader.bytes(at, size) else {
            result.intact = false
            result.problem = "Its table of contents has no checksum where it says."
            return result
        }
        guard Array(stored) == digest else {
            result.intact = false
            result.problem = "Its table of contents changed after signing."
            return result
        }
        guard let rsa, let (signatureAt, signatureSize) = place(rsa),
              let signatureBytes = try? reader.bytes(signatureAt, signatureSize),
              let signer = result.certificates.first,
              let certificate = SecCertificateCreateWithData(nil, Data(signer.encoded) as CFData),
              let key = SecCertificateCopyKey(certificate) else {
            result.intact = nil
            return result
        }
        var error: Unmanaged<CFError>?
        let verified = SecKeyVerifySignature(key, algorithm, Data(digest) as CFData, signatureBytes as CFData, &error)
        result.intact = verified
        if !verified { result.problem = "Its signature does not verify with the signer's key." }
        return result
    }
}
