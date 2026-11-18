import CryptoKit
import Foundation

/// A Windows program, library or driver -- a PE file, `.exe`, `.dll`, `.sys`,
/// `.efi` -- or the MS-DOS or 16-bit Windows program before it, read from its
/// headers, imports, exports, version resource, manifest and Authenticode
/// signature. The signature's hash of the file is checked here; whether the
/// signer is trusted is Windows' question, not asked.
nonisolated struct PEFile {

    enum Problem: Error, CustomStringConvertible {
        case notPE, damaged(String)
        var description: String {
            switch self {
            case .notPE: "It does not start like a Windows or MS-DOS program."
            case .damaged(let why): why
            }
        }
    }

    /// What the "MZ" header leads to.
    enum Format: Equatable {
        case pe, dos, newExecutable, linearExecutable(String)
    }

    struct Section {
        let name: String
        let address: UInt32
        let memorySize: UInt32
        let offset: UInt32
        let fileSize: UInt32
        let characteristics: UInt32
    }

    struct Import: Equatable {
        let library: String
        let functions: Int
        let delayed: Bool
    }

    struct Signature {
        var certificates: [X509] = []
        var signedAt: Date?
        var digestName: String?
        /// nil when not checked; otherwise whether the file hashes as signed.
        var intact: Bool?
        var signer: X509? {
            certificates.first { leaf in
                !certificates.contains { $0.issuerBytes == leaf.subjectBytes && $0.subjectBytes != leaf.subjectBytes }
            } ?? certificates.first
        }
    }

    let format: Format
    var machine: UInt16 = 0
    var characteristics: UInt16 = 0
    var timeStamp: UInt32 = 0
    var is64 = false
    var subsystem: UInt16 = 0
    var dllCharacteristics: UInt16 = 0
    var minimumWindows: (major: UInt16, minor: UInt16) = (0, 0)
    var linker: String?
    var entry: UInt32 = 0
    var sections: [Section] = []
    var imports: [Import] = []
    var exportName: String?
    var exports: [String] = []
    var exportCount = 0
    var version: [(key: String, value: String)] = []
    var fixedVersion: String?
    var executionLevel: String?
    var dotNet: String?
    var dotNetFlags: UInt32 = 0
    var debugFile: String?
    var signature: Signature?

    static func looksLikePE(_ data: Data) -> Bool {
        data.count >= 64 && data.prefix(2).elementsEqual([0x4D, 0x5A])
    }

    init(data: Data, verify: Bool = true) throws {
        guard Self.looksLikePE(data) else { throw Problem.notPE }
        let reader = BinaryReader(data)
        let header = Int(try reader.u32(0x3C))
        let mark = reader.contains(header, 4) ? try reader.bytes(header, 4) : Data()
        switch (mark.first, mark.dropFirst().first) {
        case (0x50, 0x45) where mark.dropFirst(2).elementsEqual([0, 0]): format = .pe
        case (0x4E, 0x45): format = .newExecutable; return
        case (0x4C, 0x45): format = .linearExecutable("LE"); return
        case (0x4C, 0x58): format = .linearExecutable("LX"); return
        default: format = .dos; return
        }

        let coff = header + 4
        machine = try reader.u16(coff)
        let sectionCount = Int(try reader.u16(coff + 2))
        timeStamp = try reader.u32(coff + 4)
        let optionalSize = Int(try reader.u16(coff + 16))
        characteristics = try reader.u16(coff + 18)
        let optional = coff + 20
        guard optionalSize >= 68 else {
            throw Problem.damaged("Its optional header is \(optionalSize) bytes, too short for a program.")
        }
        let magic = try reader.u16(optional)
        guard magic == 0x10B || magic == 0x20B else {
            throw Problem.damaged(String(format: "Its optional header has the unknown kind 0x%04X.", magic))
        }
        is64 = magic == 0x20B
        linker = "\(try reader.u8(optional + 2)).\(try reader.u8(optional + 3))"
        entry = try reader.u32(optional + 16)
        minimumWindows = (try reader.u16(optional + 48), try reader.u16(optional + 50))
        subsystem = try reader.u16(optional + 68)
        dllCharacteristics = try reader.u16(optional + 70)
        let directoryCount = Int(try reader.u32(optional + (is64 ? 108 : 92)))
        let directories = optional + (is64 ? 112 : 96)
        func directory(_ index: Int) -> (address: UInt32, size: UInt32)? {
            guard index < directoryCount, let address = try? reader.u32(directories + index * 8),
                  let size = try? reader.u32(directories + index * 8 + 4), address != 0, size != 0 else { return nil }
            return (address, size)
        }

        let sectionTable = optional + optionalSize
        guard reader.contains(sectionTable, sectionCount * 40) else {
            throw Problem.damaged("Its section table runs past the end of the file.")
        }
        sections = try (0..<sectionCount).map { index in
            let at = sectionTable + index * 40
            return Section(name: reader.string(at, limit: 8), address: try reader.u32(at + 12),
                           memorySize: try reader.u32(at + 8), offset: try reader.u32(at + 20),
                           fileSize: try reader.u32(at + 16), characteristics: try reader.u32(at + 36))
        }

        if let found = directory(1) { imports += readImports(reader, at: found.address, delayed: false) }
        if let found = directory(13) { imports += readImports(reader, at: found.address, delayed: true) }
        if let found = directory(0) { readExports(reader, at: found.address) }
        if let found = directory(2) { readResources(reader, at: found.address) }
        if let found = directory(6) { readDebug(reader, at: found.address, size: found.size) }
        if let found = directory(14) { readCLR(reader, at: found.address) }
        // The certificate table is the one directory given as a file offset.
        if let found = directory(4), reader.contains(Int(found.address), Int(found.size)) {
            signature = readSignature(reader, at: Int(found.address), size: Int(found.size),
                                      checksum: optional + 64, entry: directories + 4 * 8, verify: verify)
        }
    }

    /// Where a relative virtual address is in the file.
    func offset(_ address: UInt32) -> Int? {
        for section in sections where address >= section.address
        && address < section.address + max(section.memorySize, section.fileSize) {
            let within = address - section.address
            guard within < section.fileSize else { return nil }
            return Int(section.offset + within)
        }
        return nil
    }

    private func string(_ reader: BinaryReader, _ address: UInt32) -> String? {
        offset(address).map { reader.string($0, limit: 512) }
    }

    // MARK: - Imports and exports

    private func readImports(_ reader: BinaryReader, at address: UInt32, delayed: Bool) -> [Import] {
        guard var at = offset(address) else { return [] }
        var found: [Import] = []
        let size = delayed ? 32 : 20
        while found.count < 512, reader.contains(at, size) {
            guard let name = try? reader.u32(at + (delayed ? 4 : 12)), name != 0,
                  let library = string(reader, name) else { break }
            // The names table, or for a delayed import its own; the thunks
            // are pointers, of the program's width, until a zero one.
            let names: UInt32 = (try? reader.u32(at)) ?? 0
            let thunks: UInt32 = (try? reader.u32(at + 16)) ?? 0
            let table = delayed || names == 0 ? thunks : names
            var count = 0
            if let start = offset(table) {
                let width = is64 ? 8 : 4
                while count < 65_536, let thunk = try? reader.word(start + count * width, wide: is64), thunk != 0 {
                    count += 1
                }
            }
            found.append(Import(library: library, functions: count, delayed: delayed))
            at += size
        }
        return found
    }

    private mutating func readExports(_ reader: BinaryReader, at address: UInt32) {
        guard let at = offset(address) else { return }
        exportName = (try? reader.u32(at + 12)).flatMap { string(reader, $0) }
        exportCount = Int((try? reader.u32(at + 20)) ?? 0)
        let names = Int((try? reader.u32(at + 24)) ?? 0)
        guard let table = (try? reader.u32(at + 32)).flatMap(offset) else { return }
        exports = (0..<min(names, 1000)).compactMap { index in
            (try? reader.u32(table + index * 4)).flatMap { string(reader, $0) }
        }
    }

    // MARK: - Resources: version and manifest

    private mutating func readResources(_ reader: BinaryReader, at address: UInt32) {
        guard let root = offset(address) else { return }
        /// The entries of one directory: (id or nil for a name, offset, is a directory).
        func entries(_ at: Int) -> [(id: UInt32?, target: Int, isDirectory: Bool)] {
            guard let named = try? reader.u16(at + 12), let numbered = try? reader.u16(at + 14) else { return [] }
            return (0..<min(Int(named) + Int(numbered), 512)).compactMap { index in
                let entry = at + 16 + index * 8
                guard let name = try? reader.u32(entry), let target = try? reader.u32(entry + 4) else { return nil }
                return (name & 0x8000_0000 != 0 ? nil : name, root + Int(target & 0x7FFF_FFFF),
                        target & 0x8000_0000 != 0)
            }
        }
        /// The first data under a type: its bytes.
        func first(ofType type: UInt32) -> Data? {
            guard var level = entries(root).first(where: { $0.id == type }) else { return nil }
            for _ in 0..<2 {
                guard level.isDirectory, let next = entries(level.target).first else { return nil }
                level = next
            }
            guard !level.isDirectory, let data = try? reader.u32(level.target), let size = try? reader.u32(level.target + 4),
                  let at = offset(data), reader.contains(at, Int(size)) else { return nil }
            return try? reader.bytes(at, Int(size))
        }
        if let block = first(ofType: 16) { readVersion(BinaryReader(Data(block))) }
        if let manifest = first(ofType: 24) {
            let text = String(decoding: manifest, as: UTF8.self)
            if let range = text.range(of: #"requestedExecutionLevel[^>]*level\s*=\s*["']([A-Za-z]+)["']"#,
                                      options: .regularExpression) {
                let found = text[range]
                if let quote = found.range(of: #"["'][A-Za-z]+["']"#, options: .regularExpression) {
                    executionLevel = String(found[quote].dropFirst().dropLast())
                }
            }
        }
    }

    /// VS_VERSIONINFO: the fixed numbers, then StringFileInfo's strings.
    private mutating func readVersion(_ reader: BinaryReader) {
        func aligned(_ value: Int) -> Int { (value + 3) & ~3 }
        /// A block: its length, value length, type, key, and where the value starts.
        func block(_ at: Int) -> (length: Int, valueLength: Int, text: Bool, key: String, value: Int)? {
            guard let length = try? Int(reader.u16(at)), length >= 6, let valueLength = try? Int(reader.u16(at + 2)),
                  let type = try? reader.u16(at + 4) else { return nil }
            var key = "", cursor = at + 6
            while let unit = try? reader.u16(cursor), unit != 0, key.count < 64 {
                key.append(Character(Unicode.Scalar(unit) ?? "?"))
                cursor += 2
            }
            return (length, valueLength, type == 1, key, aligned(cursor + 2))
        }
        guard let top = block(0), top.key == "VS_VERSION_INFO" else { return }
        if top.valueLength >= 52, (try? reader.u32(top.value)) == 0xFEEF_04BD,
           let high = try? reader.u32(top.value + 8), let low = try? reader.u32(top.value + 12) {
            fixedVersion = "\(high >> 16).\(high & 0xFFFF).\(low >> 16).\(low & 0xFFFF)"
        }
        func children(_ start: Int, end: Int, _ visit: (Int, (length: Int, valueLength: Int, text: Bool, key: String, value: Int)) -> Void) {
            var at = start, guardCount = 0
            while at + 6 < end, guardCount < 256, let child = block(at) {
                guardCount += 1
                visit(at, child)
                at = aligned(at + child.length)
            }
        }
        children(aligned(top.value + top.valueLength), end: top.length) { at, info in
            guard info.key == "StringFileInfo" else { return }
            children(info.value, end: at + info.length) { tableAt, table in
                children(table.value, end: tableAt + table.length) { _, entry in
                    var text = "", cursor = entry.value
                    for _ in 0..<entry.valueLength {
                        guard let unit = try? reader.u16(cursor), unit != 0 else { break }
                        text.append(Character(Unicode.Scalar(unit) ?? "?"))
                        cursor += 2
                    }
                    let value = text.trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty, !version.contains(where: { $0.key == entry.key }) {
                        version.append((entry.key, value))
                    }
                }
            }
        }
    }

    // MARK: - Debug, .NET

    private mutating func readDebug(_ reader: BinaryReader, at address: UInt32, size: UInt32) {
        guard let start = offset(address) else { return }
        for index in 0..<min(Int(size) / 28, 32) {
            let at = start + index * 28
            guard (try? reader.u32(at + 12)) == 2, let pointer = try? reader.u32(at + 24),
                  (try? reader.u32(Int(pointer))) == 0x5344_5352 else { continue } // "RSDS"
            debugFile = reader.string(Int(pointer) + 24, limit: 512)
        }
    }

    private mutating func readCLR(_ reader: BinaryReader, at address: UInt32) {
        guard let at = offset(address), let metadata = try? reader.u32(at + 8),
              let root = offset(metadata), (try? reader.u32(root)) == 0x424A_5342 else {
            dotNet = dotNet ?? ""
            return
        }
        dotNetFlags = (try? reader.u32(at + 16)) ?? 0
        let length = Int((try? reader.u32(root + 12)) ?? 0)
        dotNet = reader.string(root + 16, limit: min(length, 256))
    }

    // MARK: - Authenticode

    /// WIN_CERTIFICATE holding PKCS#7 SignedData, whose content is the hash
    /// of the file without its checksum, the certificate directory entry and
    /// the certificates themselves.
    private func readSignature(_ reader: BinaryReader, at: Int, size: Int, checksum: Int, entry: Int,
                               verify: Bool) -> Signature? {
        guard let length = try? Int(reader.u32(at)), length > 8, length <= size,
              (try? reader.u16(at + 6)) == 2, let blob = try? reader.bytes(at + 8, length - 8) else { return nil }
        // The length often counts padding after the PKCS#7 too.
        let raw = [UInt8](blob)
        let bytes = (try? DER.leading(raw).encoded) ?? raw
        var signature = Signature()
        (signature.certificates, signature.signedAt) = MachOFile.CodeSignature.details(ofCMS: bytes)
        guard let digest = Self.indirectDigest(bytes) else { return signature }
        signature.digestName = digest.name
        if verify, reader.count <= MachOFile.verifiedSize {
            let data = reader.data, start = data.startIndex
            var parts: [Range<Int>] = [0..<checksum, checksum + 4..<entry, entry + 8..<at]
            if at + size < reader.count { parts.append(at + size..<reader.count) }
            let ranges = parts.filter { !$0.isEmpty }.map { start + $0.lowerBound..<start + $0.upperBound }
            let computed: [UInt8]
            switch digest.name {
            case "SHA-1": var hash = Insecure.SHA1(); ranges.forEach { hash.update(data: data[$0]) }; computed = Array(hash.finalize())
            case "SHA-384": var hash = SHA384(); ranges.forEach { hash.update(data: data[$0]) }; computed = Array(hash.finalize())
            case "SHA-512": var hash = SHA512(); ranges.forEach { hash.update(data: data[$0]) }; computed = Array(hash.finalize())
            default: var hash = SHA256(); ranges.forEach { hash.update(data: data[$0]) }; computed = Array(hash.finalize())
            }
            signature.intact = computed == digest.value
        }
        return signature
    }

    /// SpcIndirectDataContent's DigestInfo: the algorithm and the hash.
    static func indirectDigest(_ bytes: [UInt8]) -> (name: String, value: [UInt8])? {
        guard let info = try? DER(bytes).children(of: DER.sequence), info.count == 2,
              let signed = try? info[1].unwrapped().children(of: DER.sequence), signed.count >= 3,
              let content = try? signed[2].children(), content.count == 2,
              (try? content[0].oid()) == "1.3.6.1.4.1.311.2.1.4",
              let indirect = try? content[1].unwrapped().children(), indirect.count == 2,
              let digestInfo = try? indirect[1].children(), digestInfo.count == 2,
              let algorithm = try? digestInfo[0].children().first?.oid(),
              let value = try? digestInfo[1].octets() else { return nil }
        let names = ["1.3.14.3.2.26": "SHA-1", "2.16.840.1.101.3.4.2.1": "SHA-256",
                     "2.16.840.1.101.3.4.2.2": "SHA-384", "2.16.840.1.101.3.4.2.3": "SHA-512"]
        guard let name = names[algorithm] else { return nil }
        return (name, value)
    }

    // MARK: - Names

    var isLibrary: Bool { characteristics & 0x2000 != 0 }

    var kind: String {
        switch format {
        case .dos: return "MS-DOS program"
        case .newExecutable: return "16-bit Windows program"
        case .linearExecutable(let kind): return kind == "LX" ? "OS/2 program" : "Windows VxD driver or OS/2 program"
        case .pe: break
        }
        if dotNet != nil { return isLibrary ? ".NET library" : ".NET program" }
        switch subsystem {
        case 1: return "Windows driver"
        case 10: return "UEFI application"
        case 11, 12: return "UEFI driver"
        case 16: return "Windows boot application"
        default: break
        }
        if isLibrary { return "Windows library (DLL)" }
        if characteristics & 0x0002 == 0 { return "Windows object" }
        return subsystem == 2 ? "Windows program with windows" : "Windows command-line program"
    }

    static func machine(_ value: UInt16) -> String {
        [0x14C: "x86 (32-bit)", 0x8664: "x64", 0xAA64: "ARM64", 0xA641: "ARM64EC", 0xA64E: "ARM64X",
         0x1C0: "ARM (32-bit)", 0x1C4: "ARM Thumb-2 (32-bit)", 0x200: "Itanium", 0x5032: "RISC-V (32-bit)",
         0x5064: "RISC-V (64-bit)", 0x6264: "LoongArch (64-bit)", 0xEBC: "EFI byte code",
         0x0: "any processor"][value] ?? String(format: "machine 0x%04X", value)
    }

    var subsystemName: String {
        [1: "native (driver)", 2: "windows (GUI)", 3: "console", 5: "OS/2 console", 7: "POSIX console",
         9: "Windows CE", 10: "EFI application", 11: "EFI boot service driver", 12: "EFI runtime driver",
         13: "EFI ROM", 14: "Xbox", 16: "boot application"][subsystem] ?? "subsystem \(subsystem)"
    }

    /// The Windows release a subsystem version first was.
    var windowsName: String? {
        let (major, minor) = minimumWindows
        guard major > 0 else { return nil }
        let names: [String: String] = ["3.10": "Windows NT 3.1", "4.0": "Windows 95 or NT 4.0", "5.0": "Windows 2000",
                                       "5.1": "Windows XP", "5.2": "Windows XP x64 or Server 2003",
                                       "6.0": "Windows Vista", "6.1": "Windows 7", "6.2": "Windows 8",
                                       "6.3": "Windows 8.1", "10.0": "Windows 10"]
        return names["\(major).\(minor)"] ?? "Windows \(major).\(minor)"
    }

    var protections: [String] {
        var out: [String] = []
        if dllCharacteristics & 0x0040 != 0 { out.append("ASLR") }
        if dllCharacteristics & 0x0020 != 0 { out.append("high-entropy ASLR") }
        if dllCharacteristics & 0x0100 != 0 { out.append("DEP") }
        if dllCharacteristics & 0x4000 != 0 { out.append("Control Flow Guard") }
        if dllCharacteristics & 0x1000 != 0 { out.append("AppContainer") }
        return out
    }
}
