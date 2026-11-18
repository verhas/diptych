import Foundation

/// A Java class file read for its outline: what the class is, what it
/// extends, its fields and methods with their types as the source wrote them,
/// and the Java release it was compiled for. The bytecode is skipped; nothing
/// is loaded or run, and no JDK is needed.
///
/// The format is the JVM specification's, chapter 4. Attributes this does not
/// know, or cannot read, are passed over rather than failing the whole file:
/// a compiler's private attribute should not cost the outline.
nonisolated struct ClassFile: Sendable {

    /// A class file is at most this big in any real build; a bigger one is
    /// not worth a preview's time.
    static let maximumSize = 16 * 1024 * 1024

    var minor: Int
    var major: Int
    var access: Int
    /// Internal form: `com/example/Outer$Inner`.
    var name: String
    var superName: String?
    var interfaces: [String]
    var fields: [Member]
    var methods: [Member]
    var sourceFile: String?
    var signature: String?
    var annotations: [Annotation] = []
    var innerClasses: [Inner] = []
    var enclosingMethod: String?
    var nestHost: String?
    var nestMembers: [String] = []
    var permitted: [String] = []
    var record: [RecordComponent]?
    var module: Module?
    var deprecated = false
    /// Every class the constant pool names, but this one: what it uses.
    var referencedClasses: [String] = []
    /// String literals in the code, in pool order, each once.
    var strings: [String] = []

    struct Member: Sendable {
        var access: Int
        var name: String
        var descriptor: String
        var signature: String?
        /// `= 42` of a constant field, as source would write it.
        var constantValue: String?
        var exceptions: [String] = []
        var annotations: [Annotation] = []
        /// From `MethodParameters`, or the local-variable table when the class
        /// was compiled with debugging information.
        var parameterNames: [String]?
        var deprecated = false
    }

    struct Annotation: Sendable {
        /// `@Retention(RUNTIME)`, as source would write it.
        var text: String
        /// Kept for reflection at run time, or only in the class file.
        var visible: Bool
    }

    struct Inner: Sendable {
        var inner: String
        var outer: String?
        var simpleName: String?
        var access: Int
    }

    struct RecordComponent: Sendable {
        var name: String
        var descriptor: String
        var signature: String?
    }

    struct Module: Sendable {
        struct Requires: Sendable { var name: String; var flags: Int; var version: String? }
        struct Exports: Sendable { var package: String; var to: [String] }
        struct Provides: Sendable { var service: String; var with: [String] }
        var name: String
        var flags: Int
        var version: String?
        var requires: [Requires] = []
        var exports: [Exports] = []
        var opens: [Exports] = []
        var uses: [String] = []
        var provides: [Provides] = []
    }

    enum Problem: Error, CustomStringConvertible {
        case notAClass
        case truncated(at: Int)
        case badConstant(Int)

        var description: String {
            switch self {
            case .notAClass: "It does not start the way a Java class file does (CAFEBABE and a class-file version)."
            case .truncated(let at): "The file ends early, at byte \(at), in the middle of what it describes."
            case .badConstant(let index): "Entry \(index) of its constant pool is not what the rest of the file says it is."
            }
        }
    }

    // MARK: - Flags

    enum Flag {
        static let `public` = 0x0001, `private` = 0x0002, protected = 0x0004, `static` = 0x0008
        static let final = 0x0010, synchronized = 0x0020, volatile = 0x0040, bridge = 0x0040
        static let transient = 0x0080, varargs = 0x0080, native = 0x0100, interface = 0x0200
        static let abstract = 0x0400, strict = 0x0800, synthetic = 0x1000, annotation = 0x2000
        static let `enum` = 0x4000, module = 0x8000, mandated = 0x8000
    }

    // MARK: - Version

    /// The Java release a class-file version belongs to: 52 is Java 8, 65 is Java 21.
    static func release(major: Int) -> String {
        switch major {
        case ..<45: "before Java 1.0"
        case 45: "Java 1.0/1.1"
        case 46...48: "Java 1.\(major - 44)"
        default: "Java \(major - 44)"
        }
    }

    /// Classes compiled with `--enable-preview` carry minor version 0xFFFF.
    var usesPreviewFeatures: Bool { major >= 56 && minor == 0xFFFF }

    /// CAFEBABE starts universal Mach-O binaries too; there the next word is
    /// a count of architectures, which is never as high as the first class-file
    /// version, 45.
    static func looksLikeClass(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let bytes = [UInt8](data.prefix(8))
        guard bytes[0] == 0xCA, bytes[1] == 0xFE, bytes[2] == 0xBA, bytes[3] == 0xBE else { return false }
        let major = Int(bytes[6]) << 8 | Int(bytes[7])
        return major >= 45 && major < 200
    }

    // MARK: - Reading

    init(data: Data) throws {
        guard Self.looksLikeClass(data) else { throw Problem.notAClass }
        var reader = Reader(bytes: [UInt8](data))
        try reader.skip(4)
        minor = try reader.u2()
        major = try reader.u2()
        let pool = try Pool(&reader)

        access = try reader.u2()
        name = try pool.className(reader.u2())
        let superIndex = try reader.u2()
        superName = superIndex == 0 ? nil : try pool.className(superIndex)
        interfaces = try (0..<reader.u2()).map { _ in try pool.className(reader.u2()) }

        fields = try (0..<reader.u2()).map { _ in try Self.member(&reader, pool, isMethod: false) }
        methods = try (0..<reader.u2()).map { _ in try Self.member(&reader, pool, isMethod: true) }

        try pool.attributes(&reader) { attribute, body in
            switch attribute {
            case "SourceFile": sourceFile = try pool.utf8(body.u2())
            case "Signature": signature = try pool.utf8(body.u2())
            case "Deprecated": deprecated = true
            case "RuntimeVisibleAnnotations", "RuntimeInvisibleAnnotations":
                annotations += try pool.annotations(&body, visible: attribute.hasPrefix("RuntimeVisible"))
            case "InnerClasses":
                innerClasses = try (0..<body.u2()).map { _ in
                    let inner = try body.u2(), outer = try body.u2(), simple = try body.u2(), flags = try body.u2()
                    return Inner(inner: try pool.className(inner),
                                 outer: outer == 0 ? nil : try pool.className(outer),
                                 simpleName: simple == 0 ? nil : try pool.utf8(simple),
                                 access: flags)
                }
            case "EnclosingMethod":
                let owner = try pool.className(body.u2())
                let method = try body.u2()
                enclosingMethod = method == 0 ? owner : owner + "." + (try pool.nameAndType(method).name)
            case "NestHost": nestHost = try pool.className(body.u2())
            case "NestMembers": nestMembers = try (0..<body.u2()).map { _ in try pool.className(body.u2()) }
            case "PermittedSubclasses": permitted = try (0..<body.u2()).map { _ in try pool.className(body.u2()) }
            case "Record":
                record = try (0..<body.u2()).map { _ in
                    var component = RecordComponent(name: try pool.utf8(body.u2()),
                                                    descriptor: try pool.utf8(body.u2()))
                    try pool.attributes(&body) { attribute, inner in
                        if attribute == "Signature" { component.signature = try pool.utf8(inner.u2()) }
                    }
                    return component
                }
            case "Module": module = try pool.module(&body)
            default: break
            }
        }

        let own = name
        referencedClasses = pool.classNames.filter { $0 != own }
        strings = pool.strings
    }

    private static func member(_ reader: inout Reader, _ pool: Pool, isMethod: Bool) throws -> Member {
        var member = Member(access: try reader.u2(), name: try pool.utf8(reader.u2()),
                            descriptor: try pool.utf8(reader.u2()))
        var fromTable: [Int: String] = [:]
        try pool.attributes(&reader) { attribute, body in
            switch attribute {
            case "Signature": member.signature = try pool.utf8(body.u2())
            case "Deprecated": member.deprecated = true
            case "ConstantValue": member.constantValue = try pool.constantText(body.u2(), descriptor: member.descriptor)
            case "Exceptions": member.exceptions = try (0..<body.u2()).map { _ in try pool.className(body.u2()) }
            case "RuntimeVisibleAnnotations", "RuntimeInvisibleAnnotations":
                member.annotations += try pool.annotations(&body, visible: attribute.hasPrefix("RuntimeVisible"))
            case "MethodParameters":
                member.parameterNames = try (0..<body.u1()).map { _ in
                    let index = try body.u2()
                    _ = try body.u2()
                    return index == 0 ? "" : try pool.utf8(index)
                }
            case "Code" where isMethod:
                try body.skip(4)
                let codeLength = Int(try body.u4())
                try body.skip(codeLength)
                let handlers = try body.u2()
                try body.skip(handlers * 8)
                try pool.attributes(&body) { attribute, table in
                    guard attribute == "LocalVariableTable" else { return }
                    for _ in 0..<(try table.u2()) {
                        let start = try table.u2()
                        try table.skip(2)
                        let name = try pool.utf8(table.u2())
                        try table.skip(2)
                        let slot = try table.u2()
                        if start == 0 { fromTable[slot] = name }
                    }
                }
            default: break
            }
        }
        if isMethod, member.parameterNames == nil, !fromTable.isEmpty {
            // Parameters are the first local variables: slot 0 is `this` for an
            // instance method, and a long or a double takes two slots.
            var slot = member.access & Flag.static != 0 ? 0 : 1
            var names: [String] = []
            for wide in JavaSignature.parameterWidths(member.descriptor) {
                guard let name = fromTable[slot] else { names = []; break }
                names.append(name)
                slot += wide ? 2 : 1
            }
            if !names.isEmpty { member.parameterNames = names }
        }
        return member
    }
}

// MARK: - Bytes

nonisolated private struct Reader {
    let bytes: [UInt8]
    var at = 0

    mutating func u1() throws -> Int {
        guard at < bytes.count else { throw ClassFile.Problem.truncated(at: at) }
        defer { at += 1 }
        return Int(bytes[at])
    }

    mutating func u2() throws -> Int {
        let high = try u1()
        return high << 8 | (try u1())
    }

    mutating func u4() throws -> UInt32 {
        let high = UInt32(try u2())
        return high << 16 | UInt32(try u2())
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, at + count <= bytes.count else { throw ClassFile.Problem.truncated(at: bytes.count) }
        at += count
    }

    mutating func take(_ count: Int) throws -> [UInt8] {
        let start = at
        try skip(count)
        return Array(bytes[start..<at])
    }
}

// MARK: - Constant pool

nonisolated private struct Pool {
    enum Entry {
        case utf8(String), integer(Int32), float(Float), long(Int64), double(Double)
        case classRef(Int), string(Int), member(Int, Int), nameAndType(Int, Int)
        case methodHandle(Int), methodType(Int), dynamic(Int, Int)
        case module(Int), package(Int)
    }

    private var entries: [Entry?]

    init(_ reader: inout Reader) throws {
        let count = try reader.u2()
        entries = Array(repeating: nil, count: max(count, 1))
        var index = 1
        while index < count {
            let tag = try reader.u1()
            switch tag {
            case 1:
                let length = try reader.u2()
                entries[index] = .utf8(Self.modifiedUTF8(try reader.take(length)))
            case 3: entries[index] = .integer(Int32(bitPattern: try reader.u4()))
            case 4: entries[index] = .float(Float(bitPattern: try reader.u4()))
            case 5, 6:
                let high = UInt64(try reader.u4()), low = UInt64(try reader.u4())
                let bits = high << 32 | low
                entries[index] = tag == 5 ? .long(Int64(bitPattern: bits)) : .double(Double(bitPattern: bits))
                index += 1 // A long or a double takes two entries.
            case 7: entries[index] = .classRef(try reader.u2())
            case 8: entries[index] = .string(try reader.u2())
            case 9, 10, 11: entries[index] = .member(try reader.u2(), try reader.u2())
            case 12: entries[index] = .nameAndType(try reader.u2(), try reader.u2())
            case 15: _ = try reader.u1(); entries[index] = .methodHandle(try reader.u2())
            case 16: entries[index] = .methodType(try reader.u2())
            case 17, 18: entries[index] = .dynamic(try reader.u2(), try reader.u2())
            case 19: entries[index] = .module(try reader.u2())
            case 20: entries[index] = .package(try reader.u2())
            default: throw ClassFile.Problem.badConstant(index)
            }
            index += 1
        }
    }

    /// Java's own UTF-8: a zero is two bytes, and a character beyond the
    /// basic plane is its two UTF-16 halves, three bytes each.
    static func modifiedUTF8(_ bytes: [UInt8]) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte & 0x80 == 0 {
                units.append(UInt16(byte)); index += 1
            } else if byte & 0xE0 == 0xC0, index + 1 < bytes.count {
                units.append(UInt16(byte & 0x1F) << 6 | UInt16(bytes[index + 1] & 0x3F)); index += 2
            } else if byte & 0xF0 == 0xE0, index + 2 < bytes.count {
                units.append(UInt16(byte & 0x0F) << 12 | UInt16(bytes[index + 1] & 0x3F) << 6
                             | UInt16(bytes[index + 2] & 0x3F))
                index += 3
            } else {
                units.append(0xFFFD); index += 1
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    private func entry(_ index: Int) throws -> Entry {
        guard index > 0, index < entries.count, let entry = entries[index] else {
            throw ClassFile.Problem.badConstant(index)
        }
        return entry
    }

    func utf8(_ index: Int) throws -> String {
        guard case .utf8(let text) = try entry(index) else { throw ClassFile.Problem.badConstant(index) }
        return text
    }

    func className(_ index: Int) throws -> String {
        guard case .classRef(let name) = try entry(index) else { throw ClassFile.Problem.badConstant(index) }
        return try utf8(name)
    }

    func nameAndType(_ index: Int) throws -> (name: String, descriptor: String) {
        guard case .nameAndType(let name, let type) = try entry(index) else {
            throw ClassFile.Problem.badConstant(index)
        }
        return (try utf8(name), try utf8(type))
    }

    private func moduleName(_ index: Int) throws -> String {
        guard case .module(let name) = try entry(index) else { throw ClassFile.Problem.badConstant(index) }
        return try utf8(name)
    }

    private func packageName(_ index: Int) throws -> String {
        guard case .package(let name) = try entry(index) else { throw ClassFile.Problem.badConstant(index) }
        return try utf8(name).replacingOccurrences(of: "/", with: ".")
    }

    var classNames: [String] {
        var seen = Set<String>()
        return entries.compactMap { entry -> String? in
            guard case .classRef(let index)? = entry, let name = try? utf8(index),
                  seen.insert(name).inserted else { return nil }
            return name
        }
    }

    var strings: [String] {
        var seen = Set<String>()
        return entries.compactMap { entry -> String? in
            guard case .string(let index)? = entry, let text = try? utf8(index),
                  seen.insert(text).inserted else { return nil }
            return text
        }
    }

    /// A constant as source would write it, typed by the field holding it:
    /// an int pool entry is a boolean, a char or a number by the field's type.
    func constantText(_ index: Int, descriptor: String) throws -> String {
        switch try entry(index) {
        case .integer(let value):
            switch descriptor {
            case "Z": return value == 0 ? "false" : "true"
            case "C":
                guard let scalar = Unicode.Scalar(UInt32(UInt16(truncatingIfNeeded: value))) else { return "\(value)" }
                return JavaSignature.quoted(String(Character(scalar)), quote: "'")
            default: return "\(value)"
            }
        case .long(let value): return "\(value)L"
        case .float(let value): return value.isNaN ? "Float.NaN" : "\(value)f"
        case .double(let value): return value.isNaN ? "Double.NaN" : "\(value)"
        case .string(let text): return JavaSignature.quoted(try utf8(text))
        default: throw ClassFile.Problem.badConstant(index)
        }
    }

    /// Each attribute handed over with a reader of its own bytes only, so one
    /// that is read wrong -- or not at all -- leaves the rest of the file in step.
    func attributes(_ reader: inout Reader, _ handle: (String, inout Reader) throws -> Void) throws {
        for _ in 0..<(try reader.u2()) {
            let name = try utf8(reader.u2())
            let length = Int(try reader.u4())
            var body = Reader(bytes: try reader.take(length))
            try? handle(name, &body)
        }
    }

    // MARK: Annotations

    /// Long values -- Kotlin's metadata is a page of encoded strings -- are
    /// cut, so an annotation stays a line.
    private static let longestValue = 80, mostItems = 8

    func annotations(_ reader: inout Reader, visible: Bool) throws -> [ClassFile.Annotation] {
        try (0..<reader.u2()).map { _ in ClassFile.Annotation(text: try annotation(&reader), visible: visible) }
    }

    private func annotation(_ reader: inout Reader) throws -> String {
        let type = JavaSignature.typeName(descriptor: try utf8(reader.u2()))
        let pairs = try (0..<reader.u2()).map { _ in (try utf8(reader.u2()), try elementValue(&reader)) }
        guard !pairs.isEmpty else { return "@" + type }
        if pairs.count == 1, pairs[0].0 == "value" { return "@\(type)(\(pairs[0].1))" }
        return "@\(type)(" + pairs.map { "\($0.0) = \($0.1)" }.joined(separator: ", ") + ")"
    }

    private func elementValue(_ reader: inout Reader) throws -> String {
        let tag = Character(Unicode.Scalar(UInt8(try reader.u1())))
        switch tag {
        case "B", "C", "D", "F", "I", "J", "S", "Z":
            let text = try constantText(reader.u2(), descriptor: String(tag))
            return tag == "J" ? String(text.dropLast()) + "L" : text
        case "s":
            let text = try utf8(reader.u2())
            return JavaSignature.quoted(text.count > Self.longestValue
                                        ? String(text.prefix(Self.longestValue)) + "\u{2026}" : text)
        case "e":
            let type = JavaSignature.typeName(descriptor: try utf8(reader.u2()))
            return JavaSignature.simpleName(type) + "." + (try utf8(reader.u2()))
        case "c":
            let descriptor = try utf8(reader.u2())
            return (descriptor == "V" ? "void" : JavaSignature.typeName(descriptor: descriptor)) + ".class"
        case "@":
            return try annotation(&reader)
        case "[":
            let count = try reader.u2()
            let items = try (0..<count).map { _ in try elementValue(&reader) }
            let shown = items.prefix(Self.mostItems).joined(separator: ", ")
            return "{" + shown + (count > Self.mostItems ? ", \u{2026} \(count - Self.mostItems) more" : "") + "}"
        default:
            throw ClassFile.Problem.badConstant(0)
        }
    }

    // MARK: Module

    func module(_ reader: inout Reader) throws -> ClassFile.Module {
        func version(_ index: Int) throws -> String? { index == 0 ? nil : try utf8(index) }
        func exports() throws -> [ClassFile.Module.Exports] {
            try (0..<reader.u2()).map { _ in
                let package = try packageName(reader.u2())
                _ = try reader.u2()
                return .init(package: package, to: try (0..<reader.u2()).map { _ in try moduleName(reader.u2()) })
            }
        }
        var module = ClassFile.Module(name: try moduleName(reader.u2()), flags: try reader.u2(),
                                      version: try version(reader.u2()))
        module.requires = try (0..<reader.u2()).map { _ in
            .init(name: try moduleName(reader.u2()), flags: try reader.u2(), version: try version(reader.u2()))
        }
        module.exports = try exports()
        module.opens = try exports()
        module.uses = try (0..<reader.u2()).map { _ in try className(reader.u2()) }
        module.provides = try (0..<reader.u2()).map { _ in
            .init(service: try className(reader.u2()),
                  with: try (0..<reader.u2()).map { _ in try className(reader.u2()) })
        }
        return module
    }
}
