import CryptoKit
import Foundation
import Security

/// What a `.jar`, `.war` or `.ear` says about itself, read from the zip
/// without unpacking it: its manifest, who signed it, the Maven artifact it
/// was built as, its module, and which Java releases its classes are for.
///
/// Only the entries that answer those questions are inflated, and of the
/// class files only their first eight bytes.
nonisolated struct JarArchive: Sendable {

    static let extensions: Set<String> = ["jar", "war", "ear"]

    /// The manifest's main section, in order.
    var manifest: [(name: String, value: String)] = []
    /// Per-entry sections of the manifest: in a signed jar, one per file.
    var manifestSections = 0
    var hasManifest = false

    struct Signer: Sendable {
        /// `META-INF/SIGNER.SF`'s base name, as `jarsigner -sigfile` named it.
        var name: String
        var certificate: X509?
        var chain: [X509] = []
        /// When a timestamp authority vouched it was signed, or the signer's
        /// own claim.
        var signedAt: Date?
        var timestamped = false
        /// The signature over the `.SF` file holds.
        var signatureValid: Bool?
        /// The `.SF` file's digest of the manifest matches the manifest.
        var manifestDigest: Bool?
        var digestAlgorithm: String?
        /// This Mac trusts the signer's chain, without the network.
        var trusted: Bool?
        var trustText: String?
    }
    var signers: [Signer] = []
    /// Signature files with no block beside them, or the other way round.
    var strayCount = 0

    struct Maven: Sendable, Equatable {
        var group: String
        var artifact: String
        var version: String
    }
    var maven: [Maven] = []

    var module: ClassFile.Module?
    /// The release folder module-info.class is in, for a multi-release jar.
    var moduleRelease: Int?

    /// Class files outside `META-INF/versions`, and the versions read of them.
    var classCount = 0
    var classesRead = 0
    var lowestMajor: Int?
    var highestMajor: Int?
    var previewClasses = 0
    /// `META-INF/versions/N`, with the classes in each.
    var releases: [(release: Int, classes: Int)] = []

    /// A web application's: `WEB-INF/web.xml`, and the jars in `WEB-INF/lib`.
    var webXML = false
    var webLibraries = 0
    /// An enterprise archive's: `META-INF/application.xml`, and its modules.
    var applicationXML = false
    var enterpriseModules: [String] = []

    var entryCount = 0
    var encryptedEntries = 0
    var trouble: String?

    /// How many class files are opened for their version, at most.
    static let mostClassesRead = 20_000

    // MARK: - Reading

    static func read(_ url: URL) -> JarArchive {
        var jar = JarArchive()
        guard let zip = ZipReader(url) else {
            jar.trouble = "It is not a zip archive that can be read: its table of contents is missing or damaged."
            return jar
        }
        defer { zip.close() }
        let entries = zip.entries
        jar.entryCount = entries.count
        jar.encryptedEntries = entries.count { $0.encrypted }
        var byName: [String: ZipReader.Entry] = [:]
        var byUpper: [String: ZipReader.Entry] = [:]
        for entry in entries {
            byName[entry.name] = entry
            byUpper[entry.name.uppercased()] = entry
        }

        var manifestBytes: Data?
        if let entry = byUpper["META-INF/MANIFEST.MF"], let data = zip.data(of: entry, limit: 8 << 20) {
            jar.hasManifest = true
            manifestBytes = data
            let sections = Self.sections(of: data)
            jar.manifest = sections.first ?? []
            jar.manifestSections = max(0, sections.count - 1)
        }

        // Signatures: META-INF/NAME.SF, with its block NAME.RSA/.DSA/.EC.
        let signatureFiles = entries.filter {
            let upper = $0.name.uppercased()
            return upper.hasPrefix("META-INF/") && upper.hasSuffix(".SF") && !upper.dropFirst(9).contains("/")
        }
        for file in signatureFiles {
            let base = String(file.name.dropFirst(9).dropLast(3))
            let block = ["RSA", "DSA", "EC"].lazy.compactMap { byUpper["META-INF/\(base.uppercased()).\($0)"] }.first
            guard let block, let sf = zip.data(of: file, limit: 64 << 20),
                  let signature = zip.data(of: block, limit: 1 << 20) else {
                jar.strayCount += 1
                continue
            }
            jar.signers.append(Self.signer(named: base, sf: sf, block: signature, manifest: manifestBytes))
        }

        for entry in entries {
            let name = entry.name
            if name.hasPrefix("META-INF/maven/"), name.hasSuffix("/pom.properties"),
               let data = zip.data(of: entry, limit: 1 << 20) {
                var values: [String: String] = [:]
                for property in JavaProperties(data: data).entries { values[property.key] = property.value }
                if let group = values["groupId"], let artifact = values["artifactId"] {
                    jar.maven.append(Maven(group: group, artifact: artifact, version: values["version"] ?? ""))
                }
            }
            if name == "WEB-INF/web.xml" { jar.webXML = true }
            if name.hasPrefix("WEB-INF/lib/"), name.lowercased().hasSuffix(".jar") { jar.webLibraries += 1 }
            if name.uppercased() == "META-INF/APPLICATION.XML" { jar.applicationXML = true }
            if !name.contains("/"), ["jar", "war", "rar"].contains((name as NSString).pathExtension.lowercased()) {
                jar.enterpriseModules.append(name)
            }
        }

        // module-info.class: at the top, or -- a multi-release jar's -- in
        // the newest release folder that has one.
        let moduleEntries = entries.compactMap { entry -> (Int?, ZipReader.Entry)? in
            if entry.name == "module-info.class" { return (nil, entry) }
            if let release = Self.release(of: entry.name), entry.name.hasSuffix("/module-info.class"),
               entry.name.split(separator: "/").count == 4 {
                return (release, entry)
            }
            return nil
        }
        if let (release, entry) = moduleEntries.max(by: { ($0.0 ?? 0) < ($1.0 ?? 0) }),
           let data = zip.data(of: entry, limit: 1 << 20),
           let module = (try? ClassFile(data: data))?.module {
            jar.module = module
            jar.moduleRelease = release
        }

        var releases: [Int: Int] = [:]
        for entry in entries where entry.name.hasSuffix(".class") && !entry.encrypted {
            if let release = Self.release(of: entry.name) {
                releases[release, default: 0] += 1
                continue
            }
            if entry.name.hasSuffix("module-info.class") { continue }
            jar.classCount += 1
            guard jar.classesRead < mostClassesRead,
                  let head = zip.prefix(of: entry, count: 8), ClassFile.looksLikeClass(head) else { continue }
            jar.classesRead += 1
            let bytes = [UInt8](head)
            let minor = Int(bytes[4]) << 8 | Int(bytes[5])
            let major = Int(bytes[6]) << 8 | Int(bytes[7])
            jar.lowestMajor = min(jar.lowestMajor ?? major, major)
            jar.highestMajor = max(jar.highestMajor ?? major, major)
            if major >= 56, minor == 0xFFFF { jar.previewClasses += 1 }
        }
        jar.releases = releases.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        return jar
    }

    /// N for an entry in `META-INF/versions/N/`.
    static func release(of name: String) -> Int? {
        guard name.hasPrefix("META-INF/versions/") else { return nil }
        let rest = name.dropFirst("META-INF/versions/".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return Int(rest[..<slash])
    }

    var isMultiRelease: Bool {
        manifest.contains { $0.name.caseInsensitiveCompare("Multi-Release") == .orderedSame && $0.value.lowercased() == "true" }
    }

    func value(_ name: String) -> String? {
        manifest.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    // MARK: - The manifest format

    /// A manifest, or a signature file, as its sections of attributes: lines
    /// of at most 72 bytes, a line starting with one space continuing the one
    /// before, a blank line between sections.
    static func sections(of data: Data) -> [[(name: String, value: String)]] {
        let text = String(decoding: data, as: UTF8.self)
        var sections: [[(name: String, value: String)]] = []
        var current: [(name: String, value: String)] = []
        var pending: String?
        func flush() {
            guard let line = pending else { return }
            pending = nil
            guard let colon = line.firstIndex(of: ":") else { return }
            let name = String(line[..<colon])
            var value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
            current.append((name, String(value)))
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            if line.isEmpty {
                flush()
                if !current.isEmpty { sections.append(current) }
                current = []
            } else if line.first == " ", pending != nil {
                pending! += line.dropFirst()
            } else {
                flush()
                pending = String(line)
            }
        }
        flush()
        if !current.isEmpty { sections.append(current) }
        return sections
    }

    // MARK: - Signatures

    private static func signer(named name: String, sf: Data, block: Data, manifest: Data?) -> Signer {
        var signer = Signer(name: name)
        let attributes = sections(of: sf).first ?? []
        if let manifest, let (algorithm, expected) = attributes.lazy.compactMap({ attribute -> (String, String)? in
            guard attribute.name.hasSuffix("-Digest-Manifest") else { return nil }
            return (String(attribute.name.dropLast("-Digest-Manifest".count)), attribute.value)
        }).first(where: { digest(manifest, algorithm: $0.0) != nil }) {
            signer.digestAlgorithm = algorithm
            signer.manifestDigest = digest(manifest, algorithm: algorithm) == expected
        }

        var made: CMSDecoder?
        guard CMSDecoderCreate(&made) == errSecSuccess, let decoder = made else { return signer }
        let fed = block.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count) }
        guard fed == errSecSuccess, CMSDecoderSetDetachedContent(decoder, sf as CFData) == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess else {
            signer.signatureValid = false
            return signer
        }
        var count = 0
        CMSDecoderGetNumSigners(decoder, &count)
        guard count > 0 else {
            signer.signatureValid = false
            return signer
        }
        var time = CFAbsoluteTime()
        if CMSDecoderCopySignerTimestamp(decoder, 0, &time) == errSecSuccess {
            signer.signedAt = Date(timeIntervalSinceReferenceDate: time)
            signer.timestamped = true
        } else if CMSDecoderCopySignerSigningTime(decoder, 0, &time) == errSecSuccess {
            signer.signedAt = Date(timeIntervalSinceReferenceDate: time)
        }
        var certificate: SecCertificate?
        if CMSDecoderCopySignerCert(decoder, 0, &certificate) == errSecSuccess, let certificate {
            signer.certificate = try? X509(der: [UInt8](SecCertificateCopyData(certificate) as Data))
        }
        var all: CFArray?
        if CMSDecoderCopyAllCerts(decoder, &all) == errSecSuccess, let all = all as? [SecCertificate] {
            signer.chain = all.compactMap { try? X509(der: [UInt8](SecCertificateCopyData($0) as Data)) }
        }

        var status = CMSSignerStatus.unsigned
        var trust: SecTrust?
        var result = OSStatus(0)
        guard CMSDecoderCopySignerStatus(decoder, 0, SecPolicyCreateBasicX509(), false,
                                         &status, &trust, &result) == errSecSuccess else { return signer }
        // A certificate that cannot be checked still leaves the signature
        // itself good; whether the certificate is trusted is said apart.
        switch status {
        case .valid, .invalidCert: signer.signatureValid = true
        case .invalidSignature, .invalidIndex: signer.signatureValid = false
        default: break
        }
        if let trust {
            SecTrustSetNetworkFetchAllowed(trust, false)
            if signer.timestamped, let signedAt = signer.signedAt { SecTrustSetVerifyDate(trust, signedAt as CFDate) }
            var error: CFError?
            signer.trusted = SecTrustEvaluateWithError(trust, &error)
            if signer.trusted != true, let error { signer.trustText = CFErrorCopyDescription(error) as String? }
        }
        return signer
    }

    /// The digest Java names `algorithm` (`SHA-256`, `SHA1`…), base64, as a
    /// signature file writes it.
    static func digest(_ data: Data, algorithm: String) -> String? {
        switch algorithm.uppercased().replacingOccurrences(of: "-", with: "") {
        case "SHA256": Data(SHA256.hash(data: data)).base64EncodedString()
        case "SHA384": Data(SHA384.hash(data: data)).base64EncodedString()
        case "SHA512": Data(SHA512.hash(data: data)).base64EncodedString()
        case "SHA1", "SHA": Data(Insecure.SHA1.hash(data: data)).base64EncodedString()
        default: nil
        }
    }
}

// MARK: - Zip entries

/// The entries of a zip by name, and the bytes of any one of them -- read
/// where they are, never the whole archive.
nonisolated struct ZipReader {

    struct Entry: Sendable {
        let name: String
        let method: Int
        let encrypted: Bool
        let compressedSize: UInt64
        let size: UInt64
        let local: UInt64
    }

    private let handle: FileHandle
    private let fileSize: UInt64
    let entries: [Entry]

    init?(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = try? handle.seekToEnd(), size >= 22 else { return nil }
        self.handle = handle
        fileSize = size
        let tailSize = Int(min(size, 65_557))
        guard let tail = Self.read(handle, size, size - UInt64(tailSize), tailSize),
              let end = stride(from: tailSize - 22, through: 0, by: -1).first(where: {
                  Self.integer(tail, $0, 4) == 0x0605_4B50 })
        else { try? handle.close(); return nil }
        var offset = Self.integer(tail, end + 16, 4)
        var length = Self.integer(tail, end + 12, 4)
        var shift: UInt64 = 0
        if offset == 0xFFFF_FFFF || length == 0xFFFF_FFFF, end >= 20,
           Self.integer(tail, end - 20, 4) == 0x0706_4B50,
           let record = Self.read(handle, size, Self.integer(tail, end - 12, 8), 56),
           Self.integer(record, 0, 4) == 0x0606_4B50 {
            length = Self.integer(record, 40, 8)
            offset = Self.integer(record, 48, 8)
        } else {
            // Something before the zip -- a launcher script, a stub -- and
            // offsets counted from where the zip itself starts: the
            // directory ends where the end record begins.
            let endAt = size - UInt64(tailSize) + UInt64(end)
            if endAt >= length, endAt - length > offset {
                shift = endAt - length - offset
                offset += shift
            }
        }
        guard length < 512 << 20, let directory = Self.read(handle, size, offset, Int(length)) else {
            try? handle.close()
            return nil
        }
        var found: [Entry] = []
        var at = 0
        while at + 46 <= directory.count, Self.integer(directory, at, 4) == 0x0201_4B50 {
            let flags = Self.integer(directory, at + 8, 2)
            let method = Int(Self.integer(directory, at + 10, 2))
            var compressed = Self.integer(directory, at + 20, 4)
            var uncompressed = Self.integer(directory, at + 24, 4)
            let nameLength = Int(Self.integer(directory, at + 28, 2))
            let extraLength = Int(Self.integer(directory, at + 30, 2))
            let commentLength = Int(Self.integer(directory, at + 32, 2))
            var local = Self.integer(directory, at + 42, 4)
            guard at + 46 + nameLength + extraLength <= directory.count else { break }
            let nameBytes = Array(directory[(at + 46)..<(at + 46 + nameLength)])
            let name = flags & 0x800 != 0 ? String(decoding: nameBytes, as: UTF8.self)
                : String(validating: nameBytes, as: UTF8.self) ?? String(bytes: nameBytes, encoding: .isoLatin1) ?? ""
            // Zip64: the sizes and offset that did not fit, in that order.
            var extra = at + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = Self.integer(directory, extra, 2)
                let count = Int(Self.integer(directory, extra + 2, 2))
                if id == 1 {
                    var field = extra + 4
                    if uncompressed == 0xFFFF_FFFF { uncompressed = Self.integer(directory, field, 8); field += 8 }
                    if compressed == 0xFFFF_FFFF { compressed = Self.integer(directory, field, 8); field += 8 }
                    if local == 0xFFFF_FFFF { local = Self.integer(directory, field, 8) }
                }
                extra += 4 + count
            }
            found.append(Entry(name: name, method: method, encrypted: flags & 1 != 0,
                               compressedSize: compressed, size: uncompressed, local: local + shift))
            at += 46 + nameLength + extraLength + commentLength
        }
        entries = found
    }

    func close() { try? handle.close() }

    /// Where an entry's bytes start: after its local header, whose name and
    /// extra field may differ in length from the central directory's.
    private func dataOffset(of entry: Entry) -> UInt64? {
        guard let header = Self.read(handle, fileSize, entry.local, 30),
              Self.integer(header, 0, 4) == 0x0403_4B50 else { return nil }
        return entry.local + 30 + Self.integer(header, 26, 2) + Self.integer(header, 28, 2)
    }

    /// The whole entry, inflated, when it is at most `limit` bytes.
    func data(of entry: Entry, limit: Int) -> Data? {
        guard !entry.encrypted, entry.size <= UInt64(limit), entry.compressedSize <= UInt64(limit) * 2 + 1024,
              let offset = dataOffset(of: entry),
              let raw = Self.read(handle, fileSize, offset, Int(entry.compressedSize)) else { return nil }
        switch entry.method {
        case 0: return Data(raw)
        case 8:
            if entry.size == 0 { return Data() }
            return Decompress.decode(Data(raw), .deflate, limit: Int(entry.size))
        default: return nil
        }
    }

    /// The first `count` bytes of an entry, inflating no more than it takes.
    func prefix(of entry: Entry, count: Int) -> Data? {
        guard !entry.encrypted, entry.size >= UInt64(count), let offset = dataOffset(of: entry) else { return nil }
        switch entry.method {
        case 0:
            return Self.read(handle, fileSize, offset, count).map { Data($0) }
        case 8:
            let take = Int(min(entry.compressedSize, 16 * 1024))
            guard let raw = Self.read(handle, fileSize, offset, take) else { return nil }
            return Decompress.decode(Data(raw), .deflate, limit: count).flatMap { $0.count == count ? $0 : nil }
        default:
            return nil
        }
    }

    static func read(_ handle: FileHandle, _ size: UInt64, _ offset: UInt64, _ count: Int) -> [UInt8]? {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset,
              (try? handle.seek(toOffset: offset)) != nil else { return nil }
        if count == 0 { return [] }
        guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return [UInt8](data)
    }

    static func integer(_ bytes: [UInt8], _ at: Int, _ width: Int) -> UInt64 {
        guard at >= 0, at + width <= bytes.count else { return 0 }
        return (0..<width).reduce(UInt64(0)) { $0 | UInt64(bytes[at + $1]) << (8 * UInt64($1)) }
    }
}
