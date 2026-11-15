import Foundation

/// A TextMate grammar's regular expression, compiled for `NSRegularExpression`.
///
/// Grammars are written for Oniguruma, and ICU -- what `NSRegularExpression`
/// is -- reads nearly all of it the same way. What differs is rewritten here:
///
/// - `\h` is a hex digit to Oniguruma and horizontal space to ICU;
/// - a `{` that does not start a repeat count is a literal to Oniguruma and
///   an error to ICU;
/// - `\G` -- "where the last match ended" -- has no such meaning in a search
///   that starts afresh, so each pattern that uses it is compiled twice: once
///   with `\G` holding at the start of the search, once where it never holds.
///
/// A pattern ICU still refuses is nil: its rule never matches, and the rest
/// of the grammar goes on.
nonisolated final class TextMateRegex: @unchecked Sendable {

    let source: String
    /// For a search starting where the last match ended.
    let anchored: NSRegularExpression?
    /// For any other search; the same object when there is no `\G`.
    let free: NSRegularExpression?
    let usesG: Bool

    init(_ source: String) {
        self.source = source
        let translated = Self.translate(source)
        usesG = translated.contains("\\G")
        anchored = Self.compile(translated)
        free = usesG ? Self.compile(Self.replacingG(translated)) : anchored
    }

    func expression(atAnchor: Bool) -> NSRegularExpression? {
        atAnchor ? anchored : free
    }

    /// `^` only at the real start of the line, lookbehind able to see what
    /// is before the search: TextMate's semantics, not ICU's defaults.
    static let options: NSRegularExpression.MatchingOptions = [.withoutAnchoringBounds, .withTransparentBounds]
    /// For the `\G` variant: with transparent bounds ICU's `\G` no longer
    /// holds inside a lookahead -- `(?!\G)` matched right where the last
    /// match ended. Measured. The price is a lookbehind there that cannot see
    /// before the search, which patterns using `\G` seldom need.
    static let anchoredOptions: NSRegularExpression.MatchingOptions = [.withoutAnchoringBounds]

    func options(atAnchor: Bool) -> NSRegularExpression.MatchingOptions {
        atAnchor && usesG ? Self.anchoredOptions : Self.options
    }

    private static func compile(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [])
    }

    // MARK: - Translating

    static func translate(_ source: String) -> String {
        // ICU refuses an empty pattern; Oniguruma's matches everywhere.
        if source.isEmpty { return "(?:)" }
        let characters = Array(source.contains("(?#") ? withoutComments(source) : source)
        var out = ""
        out.reserveCapacity(characters.count + 8)
        var i = 0
        var inClass = 0
        while i < characters.count {
            let c = characters[i]
            if c == "\\", i + 1 < characters.count {
                let next = characters[i + 1]
                // An escape with a braced argument -- \p{L}, \x{2028}, \N{NAME}
                // -- copied whole: its brace is not a stray one. Oniguruma's
                // \x{85 2028 2029}, a list of code points, as one each.
                if "pPxN".contains(next), i + 2 < characters.count, characters[i + 2] == "{",
                   let close = characters[(i + 3)...].firstIndex(of: "}") {
                    let inside = String(characters[(i + 3)..<close])
                    if next == "x", inside.contains(" ") {
                        out += inside.split(separator: " ").map { "\\x{\($0)}" }.joined()
                    } else {
                        out += "\\\(next){\(inside)}"
                    }
                    i = close + 1
                    continue
                }
                switch next {
                case "h": out += inClass > 0 ? "0-9A-Fa-f" : "[0-9A-Fa-f]"
                // Any character but a line break; to ICU, the start of \N{NAME}.
                case "N" where i + 2 >= characters.count || characters[i + 2] != "{":
                    out += inClass > 0 ? "\\x{0}-\\x{9}\\x{B}-\\x{10FFFF}" : "[^\\n]"
                // A line break, which ICU allows only outside a class.
                case "R" where inClass > 0: out += "\\n\\r"
                case "H": out += inClass > 0 ? "\\x{0}-/:-@G-`g-\\x{10FFFF}" : "[^0-9A-Fa-f]"
                case "z": out += "\\z"
                default: out.append(c); out.append(next)
                }
                i += 2
                continue
            }
            if c == "[" {
                // A POSIX class inside a class, [:alpha:], is not a nesting.
                if inClass > 0, i + 1 < characters.count, characters[i + 1] == ":",
                   let close = findPOSIXEnd(characters, from: i + 2) {
                    out += String(characters[i...close])
                    i = close + 1
                    continue
                }
                inClass += 1
                out.append(c)
                // A ] straight after [ or [^ is a literal.
                if i + 1 < characters.count, characters[i + 1] == "^" { out.append("^"); i += 1 }
                if i + 1 < characters.count, characters[i + 1] == "]" { out += "\\]"; i += 1 }
                i += 1
                continue
            }
            if c == "]", inClass > 0 {
                inClass -= 1
                out.append(c)
                i += 1
                continue
            }
            if c == "{", inClass == 0, !isInterval(characters, from: i) {
                out += "\\{"
                i += 1
                continue
            }
            // {,n} is "up to n" to Oniguruma; ICU wants the lower bound.
            if c == "{", inClass == 0, i + 1 < characters.count, characters[i + 1] == "," {
                out += "{0"
                i += 1
                continue
            }
            if c == "}", inClass == 0, !closesInterval(characters, at: i) {
                out += "\\}"
                i += 1
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// Oniguruma's inline comments, `(?# … )`, which ICU does not have.
    private static func withoutComments(_ source: String) -> String {
        var out = ""
        var rest = Substring(source)
        while let start = rest.range(of: "(?#") {
            // An escaped "\(?#" is no comment.
            if start.lowerBound > rest.startIndex, rest[rest.index(before: start.lowerBound)] == "\\" {
                out += rest[..<start.upperBound]
                rest = rest[start.upperBound...]
                continue
            }
            out += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].firstIndex(of: ")") else { return out }
            rest = rest[rest.index(after: end)...]
        }
        return out + rest
    }

    private static func findPOSIXEnd(_ characters: [Character], from start: Int) -> Int? {
        var j = start
        while j + 1 < characters.count, characters[j].isLetter { j += 1 }
        return j + 1 < characters.count && characters[j] == ":" && characters[j + 1] == "]" ? j + 1 : nil
    }

    /// `{n}`, `{n,}`, `{n,m}` -- and Oniguruma's `{,m}`.
    private static func isInterval(_ characters: [Character], from start: Int) -> Bool {
        var j = start + 1
        var digits = 0, comma = false
        while j < characters.count {
            let c = characters[j]
            if c.isASCII, c.isNumber { digits += 1 }
            else if c == ",", !comma { comma = true }
            else if c == "}" { return digits > 0 }
            else { return false }
            j += 1
        }
        return false
    }

    private static func closesInterval(_ characters: [Character], at index: Int) -> Bool {
        var j = index - 1
        while j >= 0, characters[j].isNumber || characters[j] == "," { j -= 1 }
        return j >= 0 && characters[j] == "{" && j < index - 1 && !(j > 0 && characters[j - 1] == "\\")
    }

    /// `\G` that never holds, outside a class.
    private static func replacingG(_ pattern: String) -> String {
        var out = ""
        let characters = Array(pattern)
        var i = 0
        while i < characters.count {
            if characters[i] == "\\", i + 1 < characters.count {
                if characters[i + 1] == "G" { out += "(?!)" } else { out.append(characters[i]); out.append(characters[i + 1]) }
                i += 2
            } else {
                out.append(characters[i])
                i += 1
            }
        }
        return out
    }

    /// `\1`… in an end or while pattern, replaced by what the begin pattern
    /// captured, escaped.
    static func resolvingBackReferences(_ source: String, captures: [String?]) -> String {
        guard source.contains("\\") else { return source }
        var out = ""
        let characters = Array(source)
        var i = 0
        while i < characters.count {
            if characters[i] == "\\", i + 1 < characters.count {
                let next = characters[i + 1]
                if let digit = next.wholeNumberValue, next.isASCII {
                    out += NSRegularExpression.escapedPattern(for: digit < captures.count ? captures[digit] ?? "" : "")
                } else {
                    out.append(characters[i])
                    out.append(next)
                }
                i += 2
            } else {
                out.append(characters[i])
                i += 1
            }
        }
        return out
    }

    static func hasBackReferences(_ source: String) -> Bool {
        source.range(of: #"\\[1-9]"#, options: .regularExpression) != nil
    }
}
