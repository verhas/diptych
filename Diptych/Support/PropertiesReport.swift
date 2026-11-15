import Foundation

/// A `.properties` file as a table: every key and the value Java reads for
/// it -- escapes decoded, continued lines joined -- with the comments where
/// they stand, and the keys set twice marked.
nonisolated enum PropertiesReport {

    typealias R = ExecutableReport

    static let shownRows = 20_000

    static func html(for properties: JavaProperties, url: URL, size: Int) -> String {
        let name = url.lastPathComponent
        let entries = properties.entries
        let keys = Set(entries.map(\.key)).count
        var body = "<h1>\(R.escape(name))</h1>"
        var lead = "Java properties, \(keys.formatted()) key\(keys == 1 ? "" : "s"), \(R.bytes(size))"
        if let locale = locale(of: url) { lead += "; strings for \(locale)" }
        body += "<p class=lead>\(R.escape(lead))</p><p class=meta>\(R.escape(url.deletingLastPathComponent().path))</p>"

        let overridden = entries.filter { $0.overriddenAt != nil }
        if !overridden.isEmpty {
            body += "<p class=warn>\(overridden.count == 1 ? "One key is" : "\(overridden.count) keys are") set more than once: "
                + "only the last value counts. The earlier ones are struck through.</p>"
        }
        if entries.contains(where: \.badEscape) {
            body += "<p class=warn>A <code>\\u</code> is not followed by four hex digits: Java refuses to load the whole file.</p>"
        }
        if properties.utf8 {
            body += "<p class=note>Read as UTF-8. Java 9 and later read resource bundles so; "
                + "<code>Properties.load</code> from a stream reads ISO 8859-1 and shows its accented letters wrong.</p>"
        } else if properties.hasNonASCII {
            body += "<p class=note>Read as ISO 8859-1, as <code>Properties.load</code> reads a stream: it is not valid UTF-8.</p>"
        }

        body += "<table class=\"summary props\"><tr><th>Line</th><th>Key</th><th>Value</th></tr>"
        var rows = 0, gap = false
        for line in properties.lines {
            guard rows < shownRows else { break }
            switch line {
            case .blank:
                gap = rows > 0
            case .comment(let text, let number):
                body += "<tr class=\"comment\(gap ? " gap" : "")\"><td class=n>\(number)</td><td colspan=2>\(R.escape(text))</td></tr>"
                rows += 1; gap = false
            case .entry(let entry):
                var classes: [String] = []
                if gap { classes.append("gap") }
                if entry.overriddenAt != nil { classes.append("old") }
                body += "<tr\(classes.isEmpty ? "" : " class=\"\(classes.joined(separator: " "))\"")><td class=n>\(entry.line)</td>"
                body += "<td><code>\(visible(entry.key))</code></td><td>"
                if entry.value.isEmpty {
                    body += "<span class=dim>empty</span>"
                } else {
                    body += "<code>\(visible(String(entry.value.prefix(20_000))))</code>"
                }
                var notes: [String] = []
                if let later = entry.overriddenAt { notes.append("set again on line \(later)") }
                if entry.lines > 1 { notes.append("on \(entry.lines) lines") }
                if entry.badEscape { notes.append("<span class=bad>a broken \\u escape</span>") }
                if !notes.isEmpty { body += "<br><span class=dim>\(notes.joined(separator: "; "))</span>" }
                body += "</td></tr>"
                rows += 1; gap = false
            }
        }
        body += "</table>"
        if rows >= shownRows { body += "<p class=dim>The first \(shownRows.formatted()) rows are shown.</p>" }
        return KeyStoreReport.page(title: name, body: R.style + style + body)
    }

    /// A value as it reads, with what cannot be seen made visible: line
    /// breaks and tabs that escapes put in, and blanks at either end.
    private static func visible(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\n": out += "<i class=mark>\\n</i><br>"
            case "\r": out += "<i class=mark>\\r</i>"
            case "\t": out += "<i class=mark>\\t</i>"
            case "\u{0C}": out += "<i class=mark>\\f</i>"
            default: out += R.escape(String(character))
            }
        }
        let trailing = text.reversed().prefix { $0 == " " }.count
        if trailing > 0, trailing < text.count {
            out = String(out.dropLast(trailing)) + String(repeating: "<i class=mark>\u{2423}</i>", count: trailing)
        }
        return out
    }

    /// `Messages_de_CH.properties` holds the strings for German in Switzerland.
    private static func locale(of url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let underscore = stem.firstIndex(of: "_") else { return nil }
        let identifier = String(stem[stem.index(after: underscore)...])
        guard identifier.range(of: #"^[a-z]{2,3}(_[A-Z]{2}|_[0-9]{3})?(_\w+)?$"#, options: .regularExpression) != nil,
              let name = Locale(identifier: "en").localizedString(forIdentifier: identifier),
              name != identifier else { return nil }
        return name
    }

    static let style = """
        <style>
        .props td { vertical-align: top; }
        .props .n { color: var(--dim); width: 3em; text-align: right; font-size: 11px; }
        .props tr.comment td:last-child { color: var(--dim); font-style: italic; }
        .props tr.gap td { border-top: 10px solid transparent; }
        .props tr.old code { text-decoration: line-through; color: var(--dim); }
        i.mark { font-style: normal; color: var(--soon); font-size: 10px; }
        </style>
        """
}
