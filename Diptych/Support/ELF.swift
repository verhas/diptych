import Foundation

/// An ELF file -- a Linux, BSD or embedded program, library, object or core
/// dump -- from its headers, dynamic section and notes.
nonisolated struct ELF {

    enum Problem: Error, CustomStringConvertible {
        case notELF, damaged(String)
        var description: String {
            switch self {
            case .notELF: "It does not start like an ELF file."
            case .damaged(let why): why
            }
        }
    }

    struct Segment {
        let type: String
        let offset: UInt64
        let address: UInt64
        let fileSize: UInt64
        let memorySize: UInt64
        let flags: String
    }

    let is64: Bool
    let bigEndian: Bool
    let osABI: String
    let fileType: UInt16
    let machine: String
    let entry: UInt64
    var interpreter: String?
    var needed: [String] = []
    var soname: String?
    var rpath: [String] = []
    var runpath: [String] = []
    var isPIE = false
    var hasDynamic = false
    var buildID: String?
    /// "Linux 3.2.0" from the GNU ABI tag note.
    var minimumKernel: String?
    var noteOwners: [String] = []
    var executableStack = false
    var segments: [Segment] = []
    var sections: [String] = []
    /// Highest versions needed per library family: "GLIBC" -> "2.34".
    var versionsNeeded: [(family: String, version: String)] = []

    static func looksLikeELF(_ data: Data) -> Bool {
        data.count >= 16 && data.prefix(4).elementsEqual([0x7F, 0x45, 0x4C, 0x46])
    }

    init(data: Data) throws {
        guard Self.looksLikeELF(data) else { throw Problem.notELF }
        var reader = BinaryReader(data)
        let elfClass = try reader.u8(4), encoding = try reader.u8(5)
        guard elfClass == 1 || elfClass == 2 else { throw Problem.damaged("Its class, \(elfClass), is neither 32 nor 64-bit.") }
        guard encoding == 1 || encoding == 2 else { throw Problem.damaged("Its byte order, \(encoding), is unknown.") }
        is64 = elfClass == 2
        bigEndian = encoding == 2
        reader.bigEndian = bigEndian
        osABI = Self.abi(try reader.u8(7))
        fileType = try reader.u16(16)
        machine = Self.machine(try reader.u16(18))
        let wide = is64
        entry = try reader.word(24, wide: wide)
        let programOffset = Int(try reader.word(wide ? 32 : 28, wide: wide))
        let sectionOffset = Int(try reader.word(wide ? 40 : 32, wide: wide))
        let programSize = Int(try reader.u16(wide ? 54 : 42)), programCount = Int(try reader.u16(wide ? 56 : 44))
        let sectionSize = Int(try reader.u16(wide ? 58 : 46)), sectionCount = Int(try reader.u16(wide ? 60 : 48))
        let names = Int(try reader.u16(wide ? 62 : 50))

        // Program headers: what is loaded, by what, and with which notes.
        var dynamic: (offset: Int, size: Int)?
        if programOffset > 0 {
            guard programSize >= (wide ? 56 : 32), reader.contains(programOffset, programSize * programCount) else {
                throw Problem.damaged("Its program headers run past the end of the file.")
            }
            for index in 0..<programCount {
                let at = programOffset + index * programSize
                let type = try reader.u32(at)
                let flags = try reader.u32(at + (wide ? 4 : 24))
                let offset = try reader.word(at + (wide ? 8 : 4), wide: wide)
                let address = try reader.word(at + (wide ? 16 : 8), wide: wide)
                let fileSize = try reader.word(at + (wide ? 32 : 16), wide: wide)
                let memorySize = try reader.word(at + (wide ? 40 : 20), wide: wide)
                segments.append(Segment(type: Self.segmentType(type), offset: offset, address: address,
                                        fileSize: fileSize, memorySize: memorySize, flags: Self.permissions(flags)))
                guard reader.contains(Int(clamping: offset), Int(clamping: fileSize)) else { continue }
                switch type {
                case 3: interpreter = reader.string(Int(offset), limit: Int(fileSize))
                case 2: dynamic = (Int(offset), Int(fileSize))
                case 4: readNotes(reader, at: Int(offset), size: Int(fileSize))
                case 0x6474_E551: executableStack = flags & 1 != 0
                default: break
                }
            }
        }

        // Section headers: names, and the version needs of the dynamic symbols.
        var sectionTable: [(name: Int, type: UInt32, offset: Int, size: Int, link: Int)] = []
        if sectionOffset > 0, sectionCount > 0, sectionSize >= (wide ? 64 : 40),
           reader.contains(sectionOffset, sectionSize * sectionCount) {
            for index in 0..<sectionCount {
                let at = sectionOffset + index * sectionSize
                sectionTable.append((Int(try reader.u32(at)), try reader.u32(at + 4),
                                     Int(clamping: try reader.word(at + (wide ? 24 : 16), wide: wide)),
                                     Int(clamping: try reader.word(at + (wide ? 32 : 20), wide: wide)),
                                     Int(try reader.u32(at + (wide ? 40 : 24)))))
            }
            if names < sectionTable.count {
                let table = sectionTable[names]
                sections = sectionTable.dropFirst().map { reader.string(table.offset + $0.name, limit: 256) }
            }
            if noteOwners.isEmpty {
                for section in sectionTable where section.type == 7 {
                    readNotes(reader, at: section.offset, size: section.size)
                }
            }
            if let needs = sectionTable.first(where: { $0.type == 0x6FFF_FFFE }), needs.link < sectionTable.count {
                versionsNeeded = Self.versionNeeds(reader, at: needs.offset, size: needs.size,
                                                   strings: sectionTable[needs.link].offset)
            }
        }

        if let dynamic { try readDynamic(reader, at: dynamic.offset, size: dynamic.size) }
    }

    // MARK: - Dynamic section

    private mutating func readDynamic(_ reader: BinaryReader, at: Int, size: Int) throws {
        hasDynamic = true
        let entrySize = is64 ? 16 : 8
        var entries: [(tag: UInt64, value: UInt64)] = []
        for index in 0..<size / entrySize {
            let tag = try reader.word(at + index * entrySize, wide: is64)
            if tag == 0 { break }
            entries.append((tag, try reader.word(at + index * entrySize + entrySize / 2, wide: is64)))
        }
        // DT_STRTAB is an address; the loaded segments say where it is in the file.
        guard let table = entries.first(where: { $0.tag == 5 }),
              let strings = fileOffset(ofAddress: table.value) else { return }
        func text(_ value: UInt64) -> String { reader.string(strings + Int(clamping: value)) }
        for entry in entries {
            switch entry.tag {
            case 1: needed.append(text(entry.value))
            case 14: soname = text(entry.value)
            case 15: rpath += text(entry.value).split(separator: ":").map(String.init)
            case 29: runpath += text(entry.value).split(separator: ":").map(String.init)
            case 0x6FFF_FFFB: isPIE = isPIE || entry.value & 0x0800_0000 != 0
            default: break
            }
        }
    }

    private func fileOffset(ofAddress address: UInt64) -> Int? {
        for segment in segments where segment.type == "LOAD"
        && address >= segment.address && address < segment.address + segment.fileSize {
            return Int(clamping: segment.offset + (address - segment.address))
        }
        return nil
    }

    // MARK: - Notes

    private mutating func readNotes(_ reader: BinaryReader, at start: Int, size: Int) {
        var at = start
        func aligned(_ value: Int) -> Int { (value + 3) & ~3 }
        while at + 12 <= start + size,
              let nameSize = try? Int(reader.u32(at)), let descSize = try? Int(reader.u32(at + 4)),
              let type = try? reader.u32(at + 8) {
            let name = reader.string(at + 12, limit: nameSize)
            let desc = at + 12 + aligned(nameSize)
            guard nameSize < 256, descSize < 1 << 20, reader.contains(desc, descSize) else { return }
            if !name.isEmpty, !noteOwners.contains(name) { noteOwners.append(name) }
            if name == "GNU", type == 3, let bytes = try? reader.bytes(desc, descSize) {
                buildID = bytes.map { String(format: "%02x", $0) }.joined()
            } else if name == "GNU", type == 1, descSize >= 16,
                      let os = try? reader.u32(desc), let major = try? reader.u32(desc + 4),
                      let minor = try? reader.u32(desc + 8), let patch = try? reader.u32(desc + 12) {
                let system = [0: "Linux", 1: "GNU Hurd", 2: "Solaris", 3: "FreeBSD"][os] ?? "OS \(os)"
                minimumKernel = "\(system) \(major).\(minor).\(patch)"
            }
            at = desc + aligned(descSize)
        }
    }

    /// SHT_GNU_verneed: for each library, the symbol versions it must offer.
    /// The highest per family (GLIBC_2.34, GLIBCXX_3.4.29) is what the
    /// program needs of the system it runs on.
    private static func versionNeeds(_ reader: BinaryReader, at start: Int, size: Int,
                                     strings: Int) -> [(family: String, version: String)] {
        var highest: [String: [Int]] = [:]
        var at = start, guardCount = 0
        while at + 16 <= start + size, guardCount < 256 {
            guardCount += 1
            guard let count = try? Int(reader.u16(at + 2)), let auxiliary = try? Int(reader.u32(at + 8)),
                  let next = try? Int(reader.u32(at + 12)) else { break }
            var item = at + auxiliary
            for _ in 0..<min(count, 256) {
                guard let name = try? Int(reader.u32(item + 8)), let following = try? Int(reader.u32(item + 12)) else { break }
                let text = reader.string(strings + name, limit: 128)
                if let cut = text.lastIndex(of: "_") {
                    let family = String(text[..<cut])
                    let numbers = text[text.index(after: cut)...].split(separator: ".").compactMap { Int($0) }
                    if !numbers.isEmpty, highest[family].map({ numbers.lexicographicallyPrecedes($0) }) != true {
                        highest[family] = numbers
                    }
                }
                if following == 0 { break }
                item += following
            }
            if next == 0 { break }
            at += next
        }
        return highest.keys.sorted().map { ($0, highest[$0]!.map(String.init).joined(separator: ".")) }
    }

    // MARK: - Names

    var kind: String {
        switch fileType {
        case 1: "Relocatable object file"
        case 2: "Executable"
        case 3:
            // glibc's libc.so.6 has a loader too, and runs: the name decides.
            if isPIE { "Executable (position-independent)" }
            else if soname != nil { "Shared library" }
            else if interpreter != nil { "Executable (position-independent)" }
            else { "Shared library" }
        case 4: "Core dump"
        default: "File type \(fileType)"
        }
    }

    /// How it is linked: by which loader, or not at all.
    var linking: String {
        if let interpreter { return "Dynamically, loaded by \(interpreter)" }
        if fileType == 3 && isPIE { return "Statically (position-independent)" }
        if fileType == 2 && !hasDynamic { return "Statically" }
        if hasDynamic { return "Dynamically" }
        return "Not linked yet"
    }

    var system: String {
        if osABI != "System V" { return osABI }
        if noteOwners.contains("FreeBSD") { return "FreeBSD" }
        if noteOwners.contains("OpenBSD") { return "OpenBSD" }
        if noteOwners.contains("NetBSD") { return "NetBSD" }
        if noteOwners.contains("Android") { return "Android" }
        if let minimumKernel, minimumKernel.hasPrefix("Linux") { return "Linux" }
        if interpreter?.contains("ld-linux") == true || interpreter?.contains("ld-musl") == true { return "Linux" }
        return "Linux or another Unix"
    }

    static func abi(_ value: UInt8) -> String {
        [0: "System V", 1: "HP-UX", 2: "NetBSD", 3: "Linux", 4: "GNU Hurd", 6: "Solaris", 7: "AIX", 8: "IRIX",
         9: "FreeBSD", 10: "Tru64", 12: "OpenBSD", 13: "OpenVMS", 64: "ARM EABI", 97: "ARM",
         255: "Standalone"][value] ?? "ABI \(value)"
    }

    static func machine(_ value: UInt16) -> String {
        [2: "SPARC", 3: "x86 (32-bit)", 4: "Motorola 68000", 8: "MIPS", 20: "PowerPC", 21: "PowerPC 64-bit",
         22: "IBM S/390", 40: "ARM (32-bit)", 42: "SuperH", 43: "SPARC V9", 50: "IA-64", 62: "x86-64",
         183: "AArch64 (64-bit ARM)", 243: "RISC-V", 247: "eBPF", 258: "LoongArch",
         94: "Xtensa", 83: "AVR", 105: "TI MSP430"][value] ?? "machine \(value)"
    }

    static func segmentType(_ value: UInt32) -> String {
        [0: "NULL", 1: "LOAD", 2: "DYNAMIC", 3: "INTERP", 4: "NOTE", 5: "SHLIB", 6: "PHDR", 7: "TLS",
         0x6474_E550: "GNU_EH_FRAME", 0x6474_E551: "GNU_STACK", 0x6474_E552: "GNU_RELRO",
         0x6474_E553: "GNU_PROPERTY", 0x7000_0001: "ARM_EXIDX"][value] ?? String(format: "0x%08X", value)
    }

    static func permissions(_ flags: UInt32) -> String {
        (flags & 4 != 0 ? "r" : "-") + (flags & 2 != 0 ? "w" : "-") + (flags & 1 != 0 ? "x" : "-")
    }
}
