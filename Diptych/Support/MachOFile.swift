import CryptoKit
import Foundation

/// A Mach-O file -- a program, library, bundle or object file -- thin or
/// universal, read from its load commands and code signature. Nothing is run
/// and nothing is looked up online: whether the code still matches its
/// signature is checked here by hashing its pages, as the kernel does.
nonisolated struct MachOFile {

    /// Pages are hashed only up to this size; past it the check is skipped.
    static let verifiedSize = 512 * 1024 * 1024

    enum Problem: Error, CustomStringConvertible {
        case notMachO, damaged(String)
        var description: String {
            switch self {
            case .notMachO: "It does not start like a Mach-O file."
            case .damaged(let why): why
            }
        }
    }

    struct Slice {
        let architecture: String
        let offset: Int
        let size: Int
        /// nil when the slice could not be read; `problem` says why.
        let image: Image?
        let problem: String?
    }

    struct Library: Equatable {
        enum Kind: String { case load = "", weak, reexported = "re-exported", lazy, upward }
        let path: String
        let kind: Kind
        let current: String
        let compatible: String
    }

    struct Segment {
        let name: String
        let fileSize: UInt64
        let memorySize: UInt64
        let sections: [String]
    }

    struct Image {
        let architecture: String
        let is64: Bool
        let fileType: UInt32
        let flags: UInt32
        var platform: String?
        var minimumOS: String?
        var sdk: String?
        var tools: [String] = []
        var libraries: [Library] = []
        var identity: Library?
        var rpaths: [String] = []
        var uuid: String?
        var hasMain = false
        var dynamicLinker: String?
        var sourceVersion: String?
        var encrypted = false
        var segments: [Segment] = []
        var signature: CodeSignature?
    }

    struct CodeSignature {
        var identifier = ""
        var teamID: String?
        var flags: UInt32 = 0
        var hashName = ""
        var pageSize = 0
        var pages = 0
        var platformBinary = false
        /// Every page and the signed blobs hash as recorded: nil when not
        /// checked, otherwise the first difference, or "" for none.
        var mismatch: String?
        var entitlements: [(key: String, value: String)] = []
        var entitlementsXML: String?
        var certificates: [X509] = []
        var signedAt: Date?
        /// What the signature records for the files beside the code, by slot:
        /// 1 the Info.plist, 3 the resource seal (`CodeResources`).
        var special: [Int: [UInt8]] = [:]
        var hashType: Directory.Hash?
        /// Each code directory's hash, cut to 20 bytes: what a bundle's seal
        /// records for code nested in it.
        var cdhashes: [[UInt8]] = []

        /// Whether `data` hashes as the signature recorded for `slot`; nil
        /// when nothing is recorded there.
        func matches(slot: Int, _ data: Data) -> Bool? {
            guard let expected = special[slot], let hashType, expected.contains(where: { $0 != 0 }) else { return nil }
            return Array(hashType.digest(data).prefix(expected.count)) == expected
        }

        var isAdHoc: Bool { flags & 0x2 != 0 }
        var isLinkerSigned: Bool { flags & 0x2_0000 != 0 }
        var hasHardenedRuntime: Bool { flags & 0x1_0000 != 0 }
        var isIntact: Bool? { mismatch.map { $0.isEmpty } }

        /// The certificate that signed, the first whose subject issued no other.
        var signer: X509? {
            certificates.first { leaf in
                !certificates.contains { $0.issuerBytes == leaf.subjectBytes && $0.subjectBytes != leaf.subjectBytes }
            } ?? certificates.first
        }
    }

    let universal: Bool
    let slices: [Slice]

    // MARK: - Recognising

    static func looksLikeMachO(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let magic = data.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        switch magic {
        case 0xFEED_FACE, 0xFEED_FACF, 0xCEFA_EDFE, 0xCFFA_EDFE: return true
        case 0xCAFE_BABE, 0xCAFE_BABF: return !ClassFile.looksLikeClass(data)
        default: return false
        }
    }

    // MARK: - Reading

    init(data: Data, verify: Bool = true) throws {
        guard Self.looksLikeMachO(data) else { throw Problem.notMachO }
        let reader = BinaryReader(data, bigEndian: true)
        let magic = try reader.u32(0)
        if magic == 0xCAFE_BABE || magic == 0xCAFE_BABF {
            let wide = magic == 0xCAFE_BABF
            let count = Int(try reader.u32(4))
            guard count > 0, count < 64 else { throw Problem.damaged("It says it holds \(count) architectures.") }
            universal = true
            slices = try (0..<count).map { index in
                let at = 8 + index * (wide ? 32 : 20)
                let type = try reader.i32(at), subtype = try reader.i32(at + 4)
                let offset = Int(wide ? try reader.u64(at + 8) : UInt64(try reader.u32(at + 8)))
                let size = Int(wide ? try reader.u64(at + 16) : UInt64(try reader.u32(at + 12)))
                let name = Self.architecture(type, subtype)
                guard reader.contains(offset, size) else {
                    return Slice(architecture: name, offset: offset, size: size, image: nil,
                                 problem: "The file ends before this part does.")
                }
                return Self.slice(try reader.bytes(offset, size), name: name, offset: offset, verify: verify)
            }
        } else {
            universal = false
            let image = try Self.image(data, verify: verify)
            slices = [Slice(architecture: image.architecture, offset: 0, size: data.count, image: image, problem: nil)]
        }
    }

    private static func slice(_ data: Data, name: String, offset: Int, verify: Bool) -> Slice {
        do {
            let image = try image(data, verify: verify)
            return Slice(architecture: image.architecture, offset: offset, size: data.count, image: image, problem: nil)
        } catch {
            return Slice(architecture: name, offset: offset, size: data.count, image: nil,
                         problem: String(describing: error))
        }
    }

    static func image(_ data: Data, verify: Bool = true) throws -> Image {
        var reader = BinaryReader(data, bigEndian: true)
        let magic = try reader.u32(0)
        guard [0xFEED_FACE, 0xFEED_FACF, 0xCEFA_EDFE, 0xCFFA_EDFE].contains(magic) else {
            throw Problem.damaged("This part does not start like a Mach-O image.")
        }
        reader.bigEndian = magic == 0xFEED_FACE || magic == 0xFEED_FACF
        let is64 = magic == 0xFEED_FACF || magic == 0xCFFA_EDFE
        let type = try reader.i32(4), subtype = try reader.i32(8)
        var image = Image(architecture: architecture(type, subtype), is64: is64,
                          fileType: try reader.u32(12), flags: try reader.u32(24))
        let count = Int(try reader.u32(16)), commandsSize = Int(try reader.u32(20))
        let first = is64 ? 32 : 28
        guard reader.contains(first, commandsSize) else {
            throw Problem.damaged("Its load commands run past the end of the file.")
        }
        var at = first
        for _ in 0..<count {
            let command = try reader.u32(at) & ~0x8000_0000, size = Int(try reader.u32(at + 4))
            guard size >= 8, at + size <= first + commandsSize else {
                throw Problem.damaged("A load command has a size of \(size), which does not fit.")
            }
            try read(command, at: at, size: size, reader, into: &image, data: data, verify: verify)
            at += size
        }
        return image
    }

    private static func read(_ command: UInt32, at: Int, size: Int, _ reader: BinaryReader,
                             into image: inout Image, data: Data, verify: Bool) throws {
        func text(_ offsetField: Int) throws -> String {
            let offset = Int(try reader.u32(at + offsetField))
            return offset < size ? reader.string(at + offset, limit: size - offset) : ""
        }
        switch command {
        case 0x1, 0x19: // LC_SEGMENT, LC_SEGMENT_64
            let wide = command == 0x19
            let name = reader.string(at + 8, limit: 16)
            let memory = try reader.word(at + (wide ? 32 : 28), wide: wide)
            let file = try reader.word(at + (wide ? 48 : 36), wide: wide)
            let sectionCount = Int(try reader.u32(at + (wide ? 64 : 48)))
            let firstSection = at + (wide ? 72 : 56), sectionSize = wide ? 80 : 68
            let sections = (0..<min(sectionCount, 256)).map { reader.string(firstSection + $0 * sectionSize, limit: 16) }
            image.segments.append(Segment(name: name, fileSize: file, memorySize: memory, sections: sections))
        case 0xC, 0xD, 0x18, 0x1F, 0x20, 0x23: // dylibs, and the library's own identity
            let library = Library(path: try text(8),
                                  kind: [0x18: .weak, 0x1F: .reexported, 0x20: .lazy, 0x23: .upward][command] ?? .load,
                                  current: version(try reader.u32(at + 16)),
                                  compatible: version(try reader.u32(at + 20)))
            if command == 0xD { image.identity = library } else { image.libraries.append(library) }
        case 0xE: image.dynamicLinker = try text(8)
        case 0x1C: image.rpaths.append(try text(8))
        case 0x1B: // LC_UUID
            image.uuid = uuid(try reader.bytes(at + 8, 16))
        case 0x28: image.hasMain = true
        case 0x2A: image.sourceVersion = sourceVersion(try reader.u64(at + 8))
        case 0x21, 0x2C:
            let id = try reader.u32(at + 16)
            image.encrypted = image.encrypted || id != 0
        case 0x24, 0x25, 0x2F, 0x30: // LC_VERSION_MIN_*
            image.platform = image.platform ?? [0x24: "macOS", 0x25: "iOS", 0x2F: "tvOS", 0x30: "watchOS"][command]
            let minimum = version(try reader.u32(at + 8)), sdk = version(try reader.u32(at + 12))
            image.minimumOS = image.minimumOS ?? minimum
            image.sdk = image.sdk ?? sdk
        case 0x32: // LC_BUILD_VERSION
            image.platform = platform(try reader.u32(at + 8))
            image.minimumOS = version(try reader.u32(at + 12))
            image.sdk = version(try reader.u32(at + 16))
            let tools = Int(try reader.u32(at + 20))
            for index in 0..<min(tools, 16) where 24 + index * 8 + 8 <= size {
                let tool = try reader.u32(at + 24 + index * 8)
                let name = [1: "clang", 2: "swift", 3: "ld", 4: "lld", 1024: "Metal"][tool] ?? "tool \(tool)"
                image.tools.append("\(name) \(version(try reader.u32(at + 28 + index * 8)))")
            }
        case 0x1D: // LC_CODE_SIGNATURE
            let offset = Int(try reader.u32(at + 8)), length = Int(try reader.u32(at + 12))
            guard reader.contains(offset, length) else {
                throw Problem.damaged("Its code signature lies past the end of the file.")
            }
            image.signature = try CodeSignature.read(BinaryReader(try reader.bytes(offset, length), bigEndian: true),
                                                     code: data, verify: verify)
        default: break
        }
    }

    // MARK: - Names

    static func architecture(_ type: Int32, _ subtype: Int32) -> String {
        let sub = subtype & 0x00FF_FFFF
        switch UInt32(bitPattern: type) {
        case 0x0100_0007: return sub == 8 ? "x86_64h" : "x86_64"
        case 7: return "i386"
        case 0x0100_000C: return [0: "arm64", 1: "arm64v8", 2: "arm64e"][sub] ?? "arm64 (subtype \(sub))"
        case 0x0200_000C: return "arm64_32"
        case 12: return [5: "armv4t", 6: "armv6", 7: "armv5", 9: "armv7", 11: "armv7s", 12: "armv7k",
                         14: "armv6m", 15: "armv7m", 16: "armv7em"][sub] ?? "arm"
        case 18: return "ppc"
        case 0x0100_0012: return "ppc64"
        default: return "CPU type \(type)"
        }
    }

    /// The architecture as people know it.
    static func processor(_ architecture: String, platform: String?) -> String {
        switch architecture {
        case _ where architecture.hasPrefix("arm64") && architecture != "arm64_32":
            platform == nil || platform == "macOS" ? "Apple silicon" : "64-bit ARM"
        case "x86_64", "x86_64h": "Intel, 64-bit"
        case "i386": "Intel, 32-bit"
        case "ppc", "ppc64": "PowerPC"
        case "arm64_32": "Apple Watch"
        default: architecture.hasPrefix("arm") ? "32-bit ARM" : architecture
        }
    }

    static func kind(_ fileType: UInt32) -> String {
        [1: "Object file", 2: "Executable", 3: "Fixed VM library", 4: "Core dump", 5: "Preloaded executable",
         6: "Dynamic library", 7: "Dynamic linker", 8: "Bundle", 9: "Library stub", 10: "Debug symbols (dSYM)",
         11: "Kernel extension", 12: "Kernel file set"][fileType] ?? "File type \(fileType)"
    }

    static func platform(_ number: UInt32) -> String {
        [1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 5: "bridgeOS", 6: "Mac Catalyst", 7: "iOS Simulator",
         8: "tvOS Simulator", 9: "watchOS Simulator", 10: "DriverKit", 11: "visionOS",
         12: "visionOS Simulator"][number] ?? "platform \(number)"
    }

    /// xxxx.yy.zz in nibbles of 16, 8 and 8 bits; a zero patch is left off.
    static func version(_ packed: UInt32) -> String {
        let major = packed >> 16, minor = packed >> 8 & 0xFF, patch = packed & 0xFF
        return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    /// A.B.C.D.E packed in 24, 10, 10, 10 and 10 bits; trailing zeros dropped.
    static func sourceVersion(_ packed: UInt64) -> String {
        var parts = [packed >> 40, packed >> 30 & 0x3FF, packed >> 20 & 0x3FF, packed >> 10 & 0x3FF, packed & 0x3FF]
        while parts.count > 2, parts.last == 0 { parts.removeLast() }
        return parts.map(String.init).joined(separator: ".")
    }

    static func uuid(_ bytes: Data) -> String {
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        let cuts = [8, 4, 4, 4, 12]
        var out: [String] = [], at = hex.startIndex
        for length in cuts {
            let end = hex.index(at, offsetBy: length)
            out.append(String(hex[at..<end]))
            at = end
        }
        return out.joined(separator: "-")
    }
}

// MARK: - Code signature

nonisolated extension MachOFile.CodeSignature {

    /// The embedded signature: a SuperBlob of a CodeDirectory (or two, SHA-1
    /// and SHA-256), the requirements, the entitlements and a CMS signature.
    static func read(_ reader: BinaryReader, code: Data, verify: Bool) throws -> MachOFile.CodeSignature {
        guard try reader.u32(0) == 0xFADE_0CC0 else {
            throw MachOFile.Problem.damaged("Its code signature does not start like one.")
        }
        var blobs: [(type: UInt32, at: Int, length: Int)] = []
        for index in 0..<min(Int(try reader.u32(8)), 64) {
            let type = try reader.u32(12 + index * 8), at = Int(try reader.u32(16 + index * 8))
            guard let length = try? Int(reader.u32(at + 4)), reader.contains(at, length) else { continue }
            blobs.append((type, at, length))
        }
        // The SHA-256 directory when there are two: the one current systems use.
        let directories = blobs.filter { $0.type == 0 || ($0.type >= 0x1000 && $0.type < 0x1005) }
        let parsed = directories.compactMap { blob in try? Directory(reader, at: blob.at) }
        guard let directory = parsed.max(by: { $0.hashType.rank < $1.hashType.rank }) else {
            throw MachOFile.Problem.damaged("Its code signature has no code directory.")
        }

        var signature = MachOFile.CodeSignature()
        signature.identifier = directory.identifier
        signature.teamID = directory.teamID
        signature.flags = directory.flags
        signature.hashName = directory.hashType.name
        signature.pageSize = directory.pageSize
        signature.pages = directory.codeSlots
        signature.platformBinary = directory.platform != 0
        signature.hashType = directory.hashType
        for slot in stride(from: 1, through: min(directory.specialSlots, 7), by: 1) {
            let at = directory.at + directory.hashOffset - slot * directory.hashSize
            if let bytes = try? reader.bytes(at, directory.hashSize) { signature.special[slot] = Array(bytes) }
        }
        for blob in directories {
            guard let parsed = try? Directory(reader, at: blob.at),
                  let bytes = try? reader.bytes(blob.at, blob.length) else { continue }
            signature.cdhashes.append(Array(parsed.hashType.digest(Data(bytes)).prefix(20)))
        }

        for blob in blobs {
            switch blob.type {
            case 5: // entitlements, an XML property list
                let xml = try reader.bytes(blob.at + 8, blob.length - 8)
                signature.entitlementsXML = String(decoding: xml, as: UTF8.self)
                signature.entitlements = entitlementRows(Data(xml))
            case 0x1_0000: // the CMS signature; empty when ad hoc
                if blob.length > 8 {
                    let cms = [UInt8](try reader.bytes(blob.at + 8, blob.length - 8))
                    (signature.certificates, signature.signedAt) = details(ofCMS: cms)
                }
            default: break
            }
        }

        if verify, code.count <= MachOFile.verifiedSize {
            signature.mismatch = directory.mismatch(code: code, reader: reader, blobs: blobs)
        }
        return signature
    }

    /// The signature of a file that is not Mach-O -- a script, a header, an
    /// image sealed as code -- which codesign keeps in extended attributes,
    /// one blob each.
    static func fromAttributes(of url: URL, code: Data, verify: Bool) -> MachOFile.CodeSignature? {
        assembled(code: code, verify: verify) { AppBundle.attribute("com.apple.cs." + $0, of: url) }
    }

    /// A bundle whose executable is a script keeps the same blobs as files
    /// in `_CodeSignature`.
    static func fromFolder(_ folder: URL, code: Data, verify: Bool) -> MachOFile.CodeSignature? {
        assembled(code: code, verify: verify) { try? Data(contentsOf: folder.appendingPathComponent($0)) }
    }

    /// The blobs put back together as the SuperBlob they would be inside a
    /// Mach-O file, and read the same way. The whole file is the code.
    private static func assembled(code: Data, verify: Bool, _ blob: (String) -> Data?) -> MachOFile.CodeSignature? {
        var blobs: [(UInt32, Data)] = []
        func add(_ name: String, _ type: UInt32) {
            if let data = blob(name), data.count >= 8 { blobs.append((type, data)) }
        }
        add("CodeDirectory", 0)
        add("CodeRequirements", 2)
        // codesign stores the alternate code directories under this name.
        for index in 1...4 { add("CodeRequirements-\(index)", 0x1000 + UInt32(index - 1)) }
        add("CodeEntitlements", 5)
        add("CodeSignature", 0x1_0000)
        guard blobs.contains(where: { $0.0 == 0 }) else { return nil }
        var header = Data(), body = Data()
        func word(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        var offset = 12 + blobs.count * 8
        for (type, data) in blobs {
            header += word(type) + word(UInt32(offset))
            body += data
            offset += data.count
        }
        let superBlob = word(0xFADE_0CC0) + word(UInt32(offset)) + word(UInt32(blobs.count)) + header + body
        return try? read(BinaryReader(superBlob, bigEndian: true), code: code, verify: verify)
    }

    /// The parts of a CodeDirectory read here.
    struct Directory {
        enum Hash: UInt8 {
            case sha1 = 1, sha256 = 2, sha256Truncated = 3, sha384 = 4
            var name: String { [.sha1: "SHA-1", .sha256: "SHA-256", .sha256Truncated: "SHA-256 (truncated)",
                                .sha384: "SHA-384"][self]! }
            var rank: Int { [.sha1: 0, .sha256Truncated: 1, .sha256: 2, .sha384: 3][self]! }
            func digest(_ data: Data) -> [UInt8] {
                switch self {
                case .sha1: Array(Insecure.SHA1.hash(data: data))
                case .sha256, .sha256Truncated: Array(SHA256.hash(data: data))
                case .sha384: Array(SHA384.hash(data: data))
                }
            }
        }
        let at: Int
        let flags: UInt32
        let hashOffset: Int
        let identifier: String
        let specialSlots: Int
        let codeSlots: Int
        let codeLimit: Int
        let hashSize: Int
        let hashType: Hash
        let platform: UInt8
        let pageSize: Int
        let teamID: String?

        init(_ reader: BinaryReader, at: Int) throws {
            guard try reader.u32(at) == 0xFADE_0C02 else { throw MachOFile.Problem.damaged("Not a code directory.") }
            self.at = at
            let version = try reader.u32(at + 8)
            flags = try reader.u32(at + 12)
            hashOffset = Int(try reader.u32(at + 16))
            identifier = reader.string(at + Int(try reader.u32(at + 20)), limit: 1024)
            specialSlots = Int(try reader.u32(at + 24))
            codeSlots = Int(try reader.u32(at + 28))
            var limit = Int(try reader.u32(at + 32))
            hashSize = Int(try reader.u8(at + 36))
            guard let hash = Hash(rawValue: try reader.u8(at + 37)) else {
                throw MachOFile.Problem.damaged("Its code directory uses an unknown hash.")
            }
            hashType = hash
            platform = try reader.u8(at + 38)
            let shift = Int(try reader.u8(at + 39))
            pageSize = shift == 0 ? 0 : 1 << min(shift, 30)
            let team = version >= 0x2_0200 ? Int(try reader.u32(at + 48)) : 0
            teamID = team == 0 ? nil : reader.string(at + team, limit: 64)
            if version >= 0x2_0300, let wide = try? reader.u64(at + 56), wide != 0 { limit = Int(wide) }
            codeLimit = limit
        }

        /// "" when the code pages and the signed blobs hash as recorded,
        /// otherwise what differs.
        func mismatch(code: Data, reader: BinaryReader,
                      blobs: [(type: UInt32, at: Int, length: Int)]) -> String {
            let hashes = at + hashOffset
            func recorded(_ slot: Int) -> [UInt8]? {
                guard let bytes = try? reader.bytes(hashes + slot * hashSize, hashSize) else { return nil }
                return Array(bytes)
            }
            guard codeLimit <= code.count else { return "The signature covers more than the file holds." }
            let page = pageSize == 0 ? max(codeLimit, 1) : pageSize
            let changed = (0..<codeSlots).filter { slot in
                let start = slot * page, end = min(start + page, codeLimit)
                guard start < end, let expected = recorded(slot) else { return true }
                let slice = code[code.startIndex + start..<code.startIndex + end]
                return Array(hashType.digest(Data(slice)).prefix(hashSize)) != expected
            }
            if let first = changed.first {
                return changed.count == 1 ? "Page \(first + 1) of \(codeSlots) changed since it was signed."
                    : "\(changed.count) of \(codeSlots) pages changed since it was signed, the first page \(first + 1)."
            }
            // The blobs signed with the code: requirements (2), entitlements (5, 7).
            for (slot, name) in [(2, "requirements"), (5, "entitlements"), (7, "entitlements (DER)")]
            where slot <= specialSlots {
                guard let expected = recorded(-slot), expected.contains(where: { $0 != 0 }) else { continue }
                guard let blob = blobs.first(where: { $0.type == UInt32(slot) }),
                      let bytes = try? reader.bytes(blob.at, blob.length) else {
                    return "Its \(name) were signed but are missing."
                }
                if Array(hashType.digest(Data(bytes)).prefix(hashSize)) != expected {
                    return "Its \(name) changed since it was signed."
                }
            }
            return ""
        }
    }

    /// Entitlements as rows, the well-known ones in words.
    static func entitlementRows(_ xml: Data) -> [(key: String, value: String)] {
        guard let list = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any] else {
            return []
        }
        func show(_ value: Any) -> String {
            switch value {
            case let flag as Bool: flag ? "yes" : "no"
            case let text as String: text
            case let number as NSNumber: number.stringValue
            case let list as [Any]: list.map(show).joined(separator: ", ")
            case let dictionary as [String: Any]:
                dictionary.keys.sorted().map { "\($0) = \(show(dictionary[$0]!))" }.joined(separator: "; ")
            default: String(describing: value)
            }
        }
        return list.keys.sorted().map { (key: $0, value: show(list[$0]!)) }
    }

    static let entitlementNames: [String: String] = [
        "com.apple.security.app-sandbox": "App Sandbox",
        "com.apple.security.get-task-allow": "Can be debugged",
        "get-task-allow": "Can be debugged",
        "com.apple.security.cs.allow-jit": "Runtime: may generate code (JIT)",
        "com.apple.security.cs.allow-unsigned-executable-memory": "Runtime: unsigned executable memory",
        "com.apple.security.cs.disable-library-validation": "Runtime: loads libraries others signed",
        "com.apple.security.cs.allow-dyld-environment-variables": "Runtime: obeys DYLD_ variables",
        "com.apple.security.cs.disable-executable-page-protection": "Runtime: no executable page protection",
        "com.apple.security.cs.debugger": "Debugs other programs",
        "com.apple.security.network.client": "Network: outgoing connections",
        "com.apple.security.network.server": "Network: incoming connections",
        "com.apple.security.files.user-selected.read-only": "Files the user chooses, to read",
        "com.apple.security.files.user-selected.read-write": "Files the user chooses, to read and write",
        "com.apple.security.files.downloads.read-write": "The Downloads folder",
        "com.apple.security.device.camera": "Camera",
        "com.apple.security.device.audio-input": "Microphone",
        "com.apple.security.device.usb": "USB devices",
        "com.apple.security.device.bluetooth": "Bluetooth",
        "com.apple.security.personal-information.location": "Location",
        "com.apple.security.personal-information.addressbook": "Contacts",
        "com.apple.security.personal-information.calendars": "Calendars",
        "com.apple.security.personal-information.photos-library": "Photos library",
        "com.apple.security.automation.apple-events": "Controls other apps (Apple events)",
        "com.apple.security.application-groups": "App groups",
        "com.apple.developer.team-identifier": "Team",
        "com.apple.application-identifier": "Application identifier",
        "keychain-access-groups": "Keychain groups",
    ]

    /// The certificates in the CMS signature and the time it was made: the
    /// signer's own signing time, or -- Authenticode keeps it there -- the
    /// time a timestamp authority counter-signed it. Bytes after the
    /// signature, padding, are left alone.
    static func details(ofCMS raw: [UInt8]) -> ([X509], Date?) {
        let bytes = (try? DER.leading(raw).encoded) ?? raw
        let certificates: [X509] = ((try? CertificateFile.pkcs7(bytes)) ?? []).compactMap {
            if case .certificate(let certificate, _) = $0 { return certificate }
            return nil
        }
        guard let signer = signerInfo(bytes) else { return (certificates, nil) }
        if let time = signingTime(in: signer, attributes: 0) { return (certificates, time) }
        for set in signer where set.identifier == DER.context(1, constructed: true) {
            for attribute in (try? set.children()) ?? [] {
                guard let parts = try? attribute.children(), parts.count == 2,
                      let kind = try? parts[0].oid(), let value = try? parts[1].children().first else { continue }
                if kind == "1.2.840.113549.1.9.6", let counter = try? value.children(),
                   let time = signingTime(in: counter, attributes: 0) {
                    return (certificates, time)
                }
                // An RFC 3161 token: SignedData whose content is TSTInfo, genTime fifth.
                if kind == "1.3.6.1.4.1.311.3.3.1",
                   let token = try? value.children(), token.count == 2,
                   let signed = try? token[1].unwrapped().children(), signed.count >= 3,
                   let content = try? signed[2].children(), content.count == 2,
                   let octets = try? content[1].unwrapped().octets(),
                   let info = try? DER.leading(octets).children(), info.count > 4,
                   let time = try? info[4].time() {
                    return (certificates, time)
                }
            }
        }
        return (certificates, nil)
    }

    /// The first SignerInfo's parts.
    private static func signerInfo(_ bytes: [UInt8]) -> [DER]? {
        guard let info = try? DER(bytes).children(of: DER.sequence), info.count == 2,
              let signed = try? info[1].unwrapped().children(of: DER.sequence),
              let infos = signed.last, infos.identifier == DER.set else { return nil }
        return try? infos.children().first?.children()
    }

    /// signingTime among a SignerInfo's signed ([0]) or unsigned ([1]) attributes.
    private static func signingTime(in signer: [DER], attributes tag: UInt8) -> Date? {
        for set in signer where set.identifier == DER.context(tag, constructed: true) {
            for attribute in (try? set.children()) ?? [] {
                guard let parts = try? attribute.children(), parts.count == 2,
                      (try? parts[0].oid()) == "1.2.840.113549.1.9.5",
                      let value = try? parts[1].children().first else { continue }
                if let time = try? value.time() { return time }
            }
        }
        return nil
    }
}
