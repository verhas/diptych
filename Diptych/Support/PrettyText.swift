import Foundation

/// JSON and XML laid out to be read: one value or element to a line,
/// indented by depth. For Quick Look's Format button, where a file written
/// as one enormous line -- an API's answer, a minified config -- is
/// otherwise unreadable.
nonisolated enum PrettyText {

    /// The text laid out for `languageID` (`json`, `jsonc`, `xml`, `xsl`);
    /// nil when it is not one of those, does not parse, or is laid out
    /// already exactly so.
    static func format(_ text: String, languageID: String) -> String? {
        let formatted: String?
        switch languageID {
        case "json": formatted = json(text, comments: false)
        case "jsonc": formatted = json(text, comments: true)
        case "xml", "xsl": formatted = xml(text)
        default: formatted = nil
        }
        guard let formatted,
              formatted.trimmingCharacters(in: .whitespacesAndNewlines)
                != text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return formatted
    }

    // MARK: - JSON

    /// Indented two spaces a level. Not parsed and written again but
    /// re-spaced token by token, so that nothing but the white space
    /// changes: the order of the keys, how each number is written, every
    /// escape in a string. Checked to be JSON first; with `comments`, JSON
    /// with comments, which are kept where they were.
    static func json(_ text: String, comments: Bool) -> String? {
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(
                with: data, options: comments ? [.fragmentsAllowed, .json5Allowed] : [.fragmentsAllowed])) != nil
        else { return nil }

        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count + scalars.count / 4)
        var depth = 0
        var i = 0

        func newline() {
            out.append("\n")
            for _ in 0..<(depth * 2) { out.append(" ") }
        }
        func nextSignificant(after index: Int) -> Unicode.Scalar? {
            var j = index
            while j < scalars.count, isSpace(scalars[j]) { j += 1 }
            return j < scalars.count ? scalars[j] : nil
        }

        while i < scalars.count {
            let c = scalars[i]
            switch c {
            case "\"":
                // A string, copied whole, escapes and all.
                out.append(c)
                i += 1
                while i < scalars.count {
                    let s = scalars[i]
                    out.append(s)
                    i += 1
                    if s == "\\", i < scalars.count {
                        out.append(scalars[i])
                        i += 1
                    } else if s == "\"" {
                        break
                    }
                }
                continue
            case "{", "[":
                out.append(c)
                let close: Unicode.Scalar = c == "{" ? "}" : "]"
                if nextSignificant(after: i + 1) == close {
                    // Empty: {} and [] stay on one line.
                    var j = i + 1
                    while scalars[j] != close { j += 1 }
                    out.append(close)
                    i = j + 1
                    continue
                }
                depth += 1
                newline()
            case "}", "]":
                depth = max(0, depth - 1)
                newline()
                out.append(c)
            case ",":
                out.append(c)
                newline()
            case ":":
                out.append(":")
                out.append(" ")
            case "/" where comments && i + 1 < scalars.count && scalars[i + 1] == "/":
                // A line comment: to the end of its line, and the next
                // value on a line of its own.
                while i < scalars.count, scalars[i] != "\n" {
                    out.append(scalars[i])
                    i += 1
                }
                if nextSignificant(after: i) != nil, !"}]".unicodeScalars.contains(nextSignificant(after: i)!) {
                    newline()
                }
                continue
            case "/" where comments && i + 1 < scalars.count && scalars[i + 1] == "*":
                let start = i
                while i < scalars.count {
                    out.append(scalars[i])
                    if scalars[i] == "/", i > start + 1, scalars[i - 1] == "*" { i += 1; break }
                    i += 1
                }
                continue
            default:
                // Space between tokens is made anew; anything else -- a
                // number, true, false, null -- copied.
                if !isSpace(c) { out.append(c) }
            }
            i += 1
        }
        return String(out)
    }

    private static func isSpace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\n" || c == "\r" || c == "\t"
    }

    // MARK: - XML

    /// Indented by `XMLDocument`, with CDATA, empty elements and the order of
    /// attributes and namespaces kept. Nothing outside the text is ever
    /// read: no external DTD or entity.
    static func xml(_ text: String) -> String? {
        let options: Foundation.XMLNode.Options = [.nodeLoadExternalEntitiesNever, .nodePreserveCDATA,
                                        .nodePreserveEmptyElements, .nodePreserveAttributeOrder,
                                        .nodePreserveNamespaceOrder, .nodePreserveCharacterReferences]
        guard let document = try? Foundation.XMLDocument(xmlString: text, options: options) else { return nil }
        return document.xmlString(options: options.union(.nodePrettyPrint))
    }
}
