import Foundation

/// Java's type strings -- descriptors (`(ILjava/lang/String;)V`) and generic
/// signatures (`<T:Ljava/lang/Object;>(TT;)Ljava/util/List<TT;>;`) -- written
/// back the way source writes them: `List<T> of(T)`.
///
/// `java.lang` is left off top-level names, as source leaves it off; every
/// other package is kept, since a preview cannot know the imports.
nonisolated enum JavaSignature {

    struct Method: Equatable {
        var typeParameters: String?
        var parameters: [String]
        var result: String
        var exceptions: [String]
    }

    struct Class: Equatable {
        var typeParameters: String?
        var superclass: String?
        var interfaces: [String]
    }

    // MARK: - Names

    /// `java/util/List` -> `java.util.List`; `java/lang/String` -> `String`.
    static func className(_ binary: String) -> String {
        if binary.hasPrefix("[") { return typeName(descriptor: binary) }
        let dotted = binary.replacingOccurrences(of: "/", with: ".")
        let lang = "java.lang."
        if dotted.hasPrefix(lang), !dotted.dropFirst(lang.count).contains(".") {
            return String(dotted.dropFirst(lang.count))
        }
        return dotted
    }

    /// `com.example.Outer$Inner` -> `Inner`.
    static func simpleName(_ name: String) -> String {
        let last = name.split(separator: ".").last.map(String.init) ?? name
        return last.split(separator: "$").last.map(String.init) ?? last
    }

    /// The package part of an internal name, dotted; empty for the default package.
    static func packageName(_ binary: String) -> String {
        guard let slash = binary.lastIndex(of: "/") else { return "" }
        return binary[..<slash].replacingOccurrences(of: "/", with: ".")
    }

    static func typeName(descriptor: String) -> String {
        var parser = Parser(descriptor)
        return (try? parser.javaType()) ?? descriptor
    }

    // MARK: - Members

    static func field(descriptor: String, signature: String?) -> String {
        if let signature {
            var parser = Parser(signature)
            if let type = try? parser.javaType(), parser.atEnd { return type }
        }
        return typeName(descriptor: descriptor)
    }

    /// The generic signature when it has as many parameters as the
    /// descriptor; otherwise the descriptor. They differ for an enum's or an
    /// inner class's constructor, whose signature leaves out what the
    /// compiler adds -- and the parameter names follow the descriptor.
    static func method(descriptor: String, signature: String?) -> Method? {
        guard let plain = try? parseMethod(descriptor) else { return nil }
        if let signature, let generic = try? parseMethod(signature),
           generic.parameters.count == plain.parameters.count {
            return generic
        }
        return plain
    }

    static func classDeclaration(signature: String) -> Class? {
        var parser = Parser(signature)
        guard let typeParameters = try? parser.typeParameters(),
              let superclass = try? parser.javaType() else { return nil }
        var interfaces: [String] = []
        while !parser.atEnd {
            guard let interface = try? parser.javaType() else { return nil }
            interfaces.append(interface)
        }
        return Class(typeParameters: typeParameters, superclass: superclass, interfaces: interfaces)
    }

    /// For each parameter of a method descriptor, whether it takes two
    /// local-variable slots: a long or a double does.
    static func parameterWidths(_ descriptor: String) -> [Bool] {
        let characters = Array(descriptor)
        guard characters.first == "(" else { return [] }
        var widths: [Bool] = []
        var index = 1
        while index < characters.count, characters[index] != ")" {
            let start = characters[index]
            while index < characters.count, characters[index] == "[" { index += 1 }
            guard index < characters.count else { break }
            if characters[index] == "L" {
                while index < characters.count, characters[index] != ";" { index += 1 }
            }
            index += 1
            widths.append(start == "J" || start == "D")
        }
        return widths
    }

    private static func parseMethod(_ text: String) throws -> Method {
        var parser = Parser(text)
        let typeParameters = try parser.typeParameters()
        try parser.expect("(")
        var parameters: [String] = []
        while parser.peek != ")" { parameters.append(try parser.javaType()) }
        try parser.expect(")")
        let result = try parser.javaType()
        var exceptions: [String] = []
        while parser.peek == "^" {
            try parser.expect("^")
            exceptions.append(try parser.javaType())
        }
        guard parser.atEnd else { throw Parser.Bad() }
        return Method(typeParameters: typeParameters, parameters: parameters, result: result, exceptions: exceptions)
    }

    // MARK: - Literals

    /// A string or char literal, escaped as Java source escapes it.
    static func quoted(_ text: String, quote: Character = "\"") -> String {
        var out = String(quote)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\0": out += "\\0"
            default:
                if Character(scalar) == quote { out += "\\" + String(quote) }
                else if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + String(quote)
    }

    // MARK: - Parser

    private struct Parser {
        struct Bad: Error {}

        let characters: [Character]
        var index = 0

        init(_ text: String) { characters = Array(text) }

        var atEnd: Bool { index >= characters.count }
        var peek: Character? { atEnd ? nil : characters[index] }

        mutating func next() throws -> Character {
            guard !atEnd else { throw Bad() }
            defer { index += 1 }
            return characters[index]
        }

        mutating func expect(_ character: Character) throws {
            guard try next() == character else { throw Bad() }
        }

        /// Up to, not including, any of `stops`.
        mutating func identifier(until stops: Set<Character>) throws -> String {
            let start = index
            while let character = peek, !stops.contains(character) { index += 1 }
            guard index > start else { throw Bad() }
            return String(characters[start..<index])
        }

        mutating func javaType() throws -> String {
            switch try next() {
            case "B": return "byte"
            case "C": return "char"
            case "D": return "double"
            case "F": return "float"
            case "I": return "int"
            case "J": return "long"
            case "S": return "short"
            case "Z": return "boolean"
            case "V": return "void"
            case "[": return try javaType() + "[]"
            case "T":
                let name = try identifier(until: [";"])
                try expect(";")
                return name
            case "L": return try classType()
            default: throw Bad()
            }
        }

        /// After the `L`: `java/util/Map<TK;TV;>.Entry<…>;`.
        private mutating func classType() throws -> String {
            var name = className(try identifier(until: ["<", ";", "."]))
            while true {
                if peek == "<" { name += try typeArguments() }
                switch try next() {
                case ";": return name
                case ".": name += "." + (try identifier(until: ["<", ";", "."]))
                default: throw Bad()
                }
            }
        }

        private mutating func typeArguments() throws -> String {
            try expect("<")
            var arguments: [String] = []
            while peek != ">" {
                switch peek {
                case "*": index += 1; arguments.append("?")
                case "+": index += 1; arguments.append("? extends " + (try javaType()))
                case "-": index += 1; arguments.append("? super " + (try javaType()))
                default: arguments.append(try javaType())
                }
            }
            try expect(">")
            return "<" + arguments.joined(separator: ", ") + ">"
        }

        /// `<T:Ljava/lang/Object;U::Ljava/lang/Comparable<TU;>;>` ->
        /// `<T, U extends Comparable<U>>`; nil when there are none.
        mutating func typeParameters() throws -> String? {
            guard peek == "<" else { return nil }
            index += 1
            var parameters: [String] = []
            while peek != ">" {
                let name = try identifier(until: [":"])
                var bounds: [String] = []
                while peek == ":" {
                    index += 1
                    // The class bound is empty when every bound is an interface.
                    if peek == ":" || peek == ">" { continue }
                    bounds.append(try javaType())
                }
                bounds.removeAll { $0 == "Object" }
                parameters.append(bounds.isEmpty ? name : name + " extends " + bounds.joined(separator: " & "))
            }
            try expect(">")
            return "<" + parameters.joined(separator: ", ") + ">"
        }
    }
}
