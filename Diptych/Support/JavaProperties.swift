import Foundation

/// A Java `.properties` file read as `java.util.Properties.load` reads it:
/// logical lines joined across a trailing backslash, the key ending at the
/// first unescaped `=`, `:` or blank, `\uXXXX` and the other escapes
/// decoded -- with the comments kept where they are.
nonisolated struct JavaProperties: Sendable {

    static let extensions: Set<String> = ["properties"]
    static let maximumSize = 8 * 1024 * 1024

    enum Line: Sendable {
        case comment(String, line: Int)
        case blank
        case entry(Entry)
    }

    struct Entry: Sendable {
        var key: String
        var value: String
        /// The first line of it in the file, and how many it spans.
        var line: Int
        var lines: Int
        /// A `\u` not followed by four hex digits: Java refuses the whole file.
        var badEscape = false
        /// A later line sets the same key: this value is not the one used.
        var overriddenAt: Int?
    }

    var lines: [Line] = []
    /// Read as UTF-8 though it holds more than ASCII: Java 9's resource
    /// bundles read it so, `Properties.load(InputStream)` as ISO 8859-1.
    var utf8 = false
    var hasNonASCII = false

    var entries: [Entry] {
        lines.compactMap { if case .entry(let entry) = $0 { entry } else { nil } }
    }

    static func looksLikeText(_ data: Data) -> Bool {
        !data.prefix(8192).contains(0)
    }

    init(data: Data) {
        hasNonASCII = data.contains { $0 >= 0x80 }
        let text: String
        if let decoded = String(data: data, encoding: .utf8) {
            text = decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded
            utf8 = hasNonASCII
        } else {
            text = String(data: data, encoding: .isoLatin1) ?? ""
        }
        // Natural lines: \n, \r or \r\n each end one.
        let natural = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0
        var lastLine: [String: Int] = [:]
        while index < natural.count, lines.count < 200_000 {
            let start = index
            let first = natural[index].drop(while: Self.isBlank)
            index += 1
            if first.isEmpty { lines.append(.blank); continue }
            if first.first == "#" || first.first == "!" {
                lines.append(.comment(String(first.dropFirst()).trimmingCharacters(in: .whitespaces), line: start + 1))
                continue
            }
            // A logical line: joined while it ends in an odd number of backslashes.
            var logical = String(first)
            while Self.continues(logical), index < natural.count {
                logical.removeLast()
                logical += natural[index].drop(while: Self.isBlank)
                index += 1
            }
            if Self.continues(logical) { logical.removeLast() }
            var entry = Self.entry(logical)
            entry.line = start + 1
            entry.lines = index - start
            if let earlier = lastLine[entry.key], case .entry(var previous) = lines[earlier] {
                previous.overriddenAt = entry.line
                lines[earlier] = .entry(previous)
            }
            lastLine[entry.key] = lines.count
            lines.append(.entry(entry))
        }
    }

    private static func isBlank(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\u{0C}"
    }

    private static func continues(_ line: String) -> Bool {
        var count = 0
        for character in line.reversed() {
            guard character == "\\" else { break }
            count += 1
        }
        return count % 2 == 1
    }

    /// Key and value of one logical line, unescaped.
    private static func entry(_ line: String) -> Entry {
        let characters = Array(line)
        var at = 0
        var keyEnd = characters.count
        var escaped = false
        while at < characters.count {
            let character = characters[at]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "=" || character == ":" || isBlank(character) {
                keyEnd = at
                break
            }
            at += 1
        }
        var valueStart = keyEnd
        while valueStart < characters.count, isBlank(characters[valueStart]) { valueStart += 1 }
        if valueStart < characters.count, characters[valueStart] == "=" || characters[valueStart] == ":" {
            valueStart += 1
            while valueStart < characters.count, isBlank(characters[valueStart]) { valueStart += 1 }
        }
        let (key, badKey) = unescape(characters[0..<keyEnd])
        let (value, badValue) = unescape(characters[min(valueStart, characters.count)...])
        return Entry(key: key, value: value, line: 0, lines: 1, badEscape: badKey || badValue)
    }

    private static func unescape(_ characters: ArraySlice<Character>) -> (String, Bool) {
        var out = ""
        var bad = false
        var index = characters.startIndex
        while index < characters.endIndex {
            let character = characters[index]
            index += 1
            guard character == "\\", index < characters.endIndex else { out.append(character); continue }
            let next = characters[index]
            index += 1
            switch next {
            case "t": out.append("\t")
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "f": out.append("\u{0C}")
            case "u":
                let digits = String(characters[index..<min(index + 4, characters.endIndex)])
                if digits.count == 4, let code = UInt32(digits, radix: 16) {
                    index += 4
                    // Surrogate pairs come as two escapes.
                    if (0xD800...0xDBFF).contains(code), index + 6 <= characters.endIndex,
                       characters[index] == "\\", characters[index + 1] == "u",
                       let low = UInt32(String(characters[(index + 2)..<(index + 6)]), radix: 16), (0xDC00...0xDFFF).contains(low),
                       let scalar = UnicodeScalar(0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)) {
                        out.unicodeScalars.append(scalar)
                        index += 6
                    } else {
                        out.unicodeScalars.append(UnicodeScalar(code) ?? "\u{FFFD}")
                    }
                } else {
                    bad = true
                    out += "\\u"
                }
            default: out.append(next)
            }
        }
        return (out, bad)
    }
}
