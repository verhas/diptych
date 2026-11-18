import Foundation

/// A static or import library: an `ar` archive, Windows' `.lib` and Unix's
/// `.a`. Its members are object files -- COFF, ELF or Mach-O -- or, in a
/// Windows import library, short records naming a DLL and one function each.
nonisolated struct ArArchive {

    static let magic = Array("!<arch>\n".utf8)
    /// Thin archives hold only the names of their members.
    static let thinMagic = Array("!<thin>\n".utf8)

    enum Problem: Error, CustomStringConvertible {
        case notArchive, damaged(String)
        var description: String {
            switch self {
            case .notArchive: "It does not start like an ar archive."
            case .damaged(let why): why
            }
        }
    }

    struct Member {
        let name: String
        let size: Int
        /// "COFF x64", "ELF x86-64", "Mach-O arm64", or what else it is.
        let kind: String
    }

    let thin: Bool
    var members: [Member] = []
    /// Symbols in the archive's index.
    var symbols = 0
    /// Import library: the DLLs and how many functions from each.
    var importedFrom: [(library: String, functions: Int)] = []
    /// Architectures of the object members, most common first.
    var architectures: [String] = []

    static func looksLikeArchive(_ data: Data) -> Bool {
        data.starts(with: magic) || data.starts(with: thinMagic)
    }

    init(data: Data) throws {
        guard Self.looksLikeArchive(data) else { throw Problem.notArchive }
        thin = data.starts(with: Self.thinMagic)
        let reader = BinaryReader(data)
        var at = 8
        var longNames = Data()
        var dlls: [String: Int] = [:], order: [String] = []
        var machines: [String: Int] = [:]
        while at + 60 <= data.count, members.count < 100_000 {
            let header = try reader.bytes(at, 60)
            guard header.suffix(2).elementsEqual([0x60, 0x0A]) else {
                throw Problem.damaged("A member header at byte \(at.formatted()) is damaged.")
            }
            func field(_ from: Int, _ length: Int) -> String {
                String(decoding: header.dropFirst(from).prefix(length), as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
            }
            guard let size = Int(field(48, 10)) else { throw Problem.damaged("A member has no size.") }
            var name = field(0, 16)
            var body = at + 60
            var length = size
            if name.hasPrefix("#1/"), let nameLength = Int(name.dropFirst(3)) {
                // BSD: the name follows the header, counted in the size.
                name = reader.string(body, limit: nameLength)
                body += nameLength
                length -= nameLength
            }
            let stored = thin && !(name == "/" || name == "//" || name.hasPrefix("__.SYMDEF")) ? 0 : size
            let content = reader.contains(body, max(length, 0)) && stored > 0
                ? try reader.bytes(body, max(length, 0)) : Data()

            if name == "/" || name == "/SYM64/" || name.hasPrefix("__.SYMDEF") {
                // The index: the first one counts the symbols.
                if symbols == 0, content.count >= 4 {
                    let big = BinaryReader(content, bigEndian: !name.hasPrefix("__.SYMDEF"))
                    if name.hasPrefix("__.SYMDEF") {
                        symbols = Int((try? big.u32(0)) ?? 0) / 8
                    } else if name == "/SYM64/" {
                        symbols = Int((try? big.u64(0)) ?? 0)
                    } else {
                        symbols = Int((try? big.u32(0)) ?? 0)
                    }
                }
            } else if name == "//" {
                longNames = content
            } else {
                if name.hasPrefix("/"), let offset = Int(name.dropFirst()), offset < longNames.count {
                    let rest = longNames.dropFirst(offset)
                    let end = rest.firstIndex { $0 == 0x0A || $0 == 0 } ?? rest.endIndex
                    name = String(decoding: rest[rest.startIndex..<end], as: UTF8.self)
                }
                if name.hasSuffix("/") { name.removeLast() }
                let kind = Self.kind(of: content)
                if let dll = Self.importedLibrary(content) {
                    if dlls[dll] == nil { order.append(dll) }
                    dlls[dll, default: 0] += 1
                } else {
                    machines[kind, default: 0] += 1
                }
                members.append(Member(name: name, size: length, kind: kind))
            }
            at = body + (stored > 0 ? max(length, 0) : 0)
            if at % 2 == 1 { at += 1 }
        }
        importedFrom = order.map { ($0, dlls[$0]!) }
        architectures = machines.sorted { $0.value > $1.value }.map(\.key).filter { !$0.isEmpty }
    }

    /// A Windows short import record: Sig1 0, Sig2 0xFFFF, then the
    /// function's name and the DLL's.
    static func importedLibrary(_ content: Data) -> String? {
        guard content.count > 20, content.prefix(4).elementsEqual([0, 0, 0xFF, 0xFF]) else { return nil }
        let reader = BinaryReader(content)
        let symbol = reader.string(20, limit: 512)
        let dll = reader.string(20 + symbol.utf8.count + 1, limit: 512)
        return dll.isEmpty ? nil : dll
    }

    /// What an object member is.
    static func kind(of content: Data) -> String {
        if content.isEmpty { return "" }
        if importedLibrary(content) != nil { return "import record" }
        if ELF.looksLikeELF(content), let file = try? ELF(data: content) { return "ELF \(file.machine)" }
        if MachOFile.looksLikeMachO(content), let image = try? MachOFile.image(content, verify: false) {
            return "Mach-O \(image.architecture)"
        }
        if let machine = COFFObject.machine(of: content) { return "COFF \(PEFile.machine(machine))" }
        if content.starts(with: [0x42, 0x43, 0xC0, 0xDE]) { return "LLVM bitcode" }
        return "other"
    }

    /// "import library for sample.dll", "static library".
    var kind: String {
        // GNU and LLVM tools add a few small COFF objects of their own --
        // the import descriptor, the null thunk -- named after the DLL.
        if !importedFrom.isEmpty { return "Windows import library" }
        if architectures.contains(where: { $0.hasPrefix("COFF") }) { return "Windows static library" }
        return thin ? "Thin static library" : "Static library"
    }
}

/// A Windows object file (`.obj`): no magic, only a COFF header whose
/// machine is known and whose sizes make sense.
nonisolated enum COFFObject {
    static func machine(of data: Data) -> UInt16? {
        let reader = BinaryReader(data)
        guard data.count >= 20, let machine = try? reader.u16(0), let sections = try? reader.u16(2),
              let optional = try? reader.u16(16) else { return nil }
        let known: Set<UInt16> = [0x14C, 0x8664, 0xAA64, 0xA641, 0x1C0, 0x1C4, 0x200, 0x5064]
        guard known.contains(machine), sections > 0, sections < 4096, optional == 0,
              data.count >= 20 + Int(sections) * 40 else { return nil }
        return machine
    }
}
