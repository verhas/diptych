import Foundation

/// The ways a line can end, and what a file's lines end with.
enum LineEnding: String, CaseIterable, Identifiable, Codable, Sendable {
    case lf, crlf, cr, lfcr, nel, ls, ps

    var id: String { rawValue }

    var terminator: String {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        case .cr: "\r"
        case .lfcr: "\n\r"
        case .nel: "\u{85}"
        case .ls: "\u{2028}"
        case .ps: "\u{2029}"
        }
    }

    /// For the list of files: short.
    var short: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        case .lfcr: "LF CR"
        case .nel: "NEL"
        case .ls: "LS"
        case .ps: "PS"
        }
    }

    /// For the choice of target: what it is and who uses it.
    var title: String {
        switch self {
        case .lf: "LF \u{2014} macOS, Unix, Linux"
        case .crlf: "CRLF \u{2014} Windows"
        case .cr: "CR \u{2014} classic Mac OS"
        case .lfcr: "LF CR \u{2014} Acorn, RISC OS"
        case .nel: "NEL \u{2014} Unicode next line (U+0085)"
        case .ls: "LS \u{2014} Unicode line separator (U+2028)"
        case .ps: "PS \u{2014} Unicode paragraph separator (U+2029)"
        }
    }

    /// LS and PS separate lines rather than end them: a file of them has
    /// none after its last line. Every other kind does.
    var separates: Bool { self == .ls || self == .ps }
}

/// What a file's text has for line endings.
struct LineEndingReport: Equatable, Sendable {
    /// How many of each kind there are.
    var counts: [LineEnding: Int] = [:]
    /// Whether the text ends with one: its last line is ended, not just
    /// separated.
    var endsWithOne = false
    /// An empty file: no lines to end.
    var isEmpty = false

    /// The one kind it uses, when it uses one.
    var single: LineEnding? { counts.count == 1 ? counts.keys.first : nil }
    var isMixed: Bool { counts.count > 1 }
    var hasNone: Bool { counts.isEmpty }

    /// "CRLF", "mixed (LF 3, CRLF 9)", "none (one line)".
    var description: String {
        if isEmpty { return "empty" }
        if let single { return single.short }
        if hasNone { return "none (one line)" }
        let parts = LineEnding.allCases.compactMap { kind in
            counts[kind].map { "\(kind.short) \($0)" }
        }
        return "mixed (\(parts.joined(separator: ", ")))"
    }

    /// The last line being ended -- or not -- is what is usual for the file's
    /// kind: missing after anything but LS or PS is worth a warning, and
    /// present after LS or PS.
    var finalIsUnusual: Bool {
        guard !isEmpty else { return false }
        if let single, single.separates { return endsWithOne }
        return !endsWithOne
    }
}

enum LineEndings {

    /// The text cut into lines and the ending after each: the last line's is
    /// nil when it has none.
    ///
    /// LF followed by CR is one Acorn ending or the end of one line and the
    /// start of a classic Mac one; CR followed by LF is one Windows ending or
    /// the other way about. Which pairs up is decided for the whole text, by
    /// which pair it has more of: "a\n\r\n\rb" is two Acorn endings, not LF,
    /// CRLF and CR.
    static func split(_ text: String) -> [(line: String, ending: LineEnding?)] {
        let scalars = Array(text.unicodeScalars)
        let acorn = prefersAcorn(scalars)
        var result: [(String, LineEnding?)] = []
        var line = String.UnicodeScalarView()
        var index = 0
        func end(_ kind: LineEnding, width: Int) {
            result.append((String(line), kind))
            line = String.UnicodeScalarView()
            index += width
        }
        while index < scalars.count {
            let scalar = scalars[index]
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            switch scalar {
            case "\n":
                if acorn, next == "\r" { end(.lfcr, width: 2) } else { end(.lf, width: 1) }
            case "\r":
                if !acorn, next == "\n" { end(.crlf, width: 2) } else { end(.cr, width: 1) }
            case "\u{85}": end(.nel, width: 1)
            case "\u{2028}": end(.ls, width: 1)
            case "\u{2029}": end(.ps, width: 1)
            default:
                line.append(scalar)
                index += 1
            }
        }
        if !line.isEmpty || result.isEmpty { result.append((String(line), nil)) }
        return result
    }

    private static func prefersAcorn(_ scalars: [Unicode.Scalar]) -> Bool {
        var lfcr = 0
        var crlf = 0
        var index = 0
        while index + 1 < scalars.count {
            if scalars[index] == "\n", scalars[index + 1] == "\r" { lfcr += 1 }
            if scalars[index] == "\r", scalars[index + 1] == "\n" { crlf += 1 }
            index += 1
        }
        return lfcr > crlf
    }

    static func report(of text: String) -> LineEndingReport {
        var report = LineEndingReport()
        guard !text.isEmpty else {
            report.isEmpty = true
            return report
        }
        let lines = split(text)
        for (_, ending) in lines {
            if let ending { report.counts[ending, default: 0] += 1 }
        }
        report.endsWithOne = lines.last?.ending != nil
        return report
    }

    /// Every line ending in `text` made `target`, and after the last line one
    /// or none as `finalEnding` says. An empty text stays empty.
    static func convert(_ text: String, to target: LineEnding, finalEnding: Bool) -> String {
        guard !text.isEmpty else { return text }
        // A text that ends in an ending has no empty line after it here.
        var joined = split(text).map(\.line).joined(separator: target.terminator)
        if finalEnding { joined += target.terminator }
        return joined
    }
}
