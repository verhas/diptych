import Foundation

/// Source text for Quick Look, coloured by its language's TextMate grammar:
/// the colours Text Edit uses, line numbers, light and dark. What Quick Look
/// shows by itself is the plain text.
nonisolated enum SourceReport {

    /// Read at most this much of a file; colour for at most this long.
    static let mostBytes = 768 * 1024
    static let budget: TimeInterval = 2
    static let mostLines = 20_000

    /// The language a file is coloured as: by name, extension or first line.
    static func language(for url: URL, firstLine: String?) -> TextMateRegistry.Language? {
        TextMateRegistry.shared.language(for: url, firstLine: firstLine)
    }

    /// The page. `coloured` false gives the plain page shown while the
    /// coloured one is made.
    static func html(text: String, url: URL, language: TextMateRegistry.Language, size: Int,
                     truncated: Bool, coloured: Bool = true) -> String {
        let ns = text as NSString
        var spans: [SyntaxColouring.Span] = []
        var complete = true
        if coloured, let colourer = SourceColourer(language: language) {
            (spans, complete) = colourer.colour(text, budget: budget)
        }
        var lines: [String] = []
        var current = ""
        var spanIndex = 0
        var at = 0
        // The text in pieces, each in its colour, cut at line ends.
        func append(_ range: NSRange, _ role: SyntaxColouring.Role?) {
            let piece = ns.substring(with: range)
            var first = true
            for part in piece.split(separator: "\n", omittingEmptySubsequences: false) {
                if !first {
                    lines.append(current)
                    current = ""
                }
                first = false
                let escaped = escape(String(part).replacingOccurrences(of: "\r", with: ""))
                guard !escaped.isEmpty else { continue }
                current += role.map { "<span class=\($0.cssClass)>\(escaped)</span>" } ?? escaped
            }
        }
        while at < ns.length, lines.count < mostLines {
            if spanIndex < spans.count, spans[spanIndex].range.location <= at {
                let span = spans[spanIndex]
                spanIndex += 1
                let start = max(at, span.range.location)
                guard NSMaxRange(span.range) > start else { continue }
                append(NSRange(location: start, length: NSMaxRange(span.range) - start), span.role)
                at = NSMaxRange(span.range)
            } else {
                let next = spanIndex < spans.count ? spans[spanIndex].range.location : ns.length
                append(NSRange(location: at, length: next - at), nil)
                at = next
            }
        }
        if !current.isEmpty || lines.isEmpty { lines.append(current) }
        let cut = lines.count >= mostLines

        let name = url.lastPathComponent
        var body = "<h1>\(escape(name))</h1>"
        body += "<p class=lead>\(escape(language.name)), \(lines.count.formatted()) line\(lines.count == 1 ? "" : "s"), "
            + "\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))</p>"
        if truncated || cut {
            body += "<p class=note>The first \(cut ? "\(mostLines.formatted()) lines" : ByteCountFormatter.string(fromByteCount: Int64(mostBytes), countStyle: .file)) are shown.</p>"
        }
        if coloured, !complete {
            body += "<p class=note>Coloured as far as there was time for; the rest is plain. Text Edit colours it all.</p>"
        }
        body += "<table class=code>"
        for (number, line) in lines.enumerated() {
            body += "<tr><td class=n>\(number + 1)</td><td>\(line.isEmpty ? " " : line)</td></tr>"
        }
        body += "</table>"
        return page(title: name, body: body)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The same colours as Text Edit's: the system colours, light and dark.
    static func page(title: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title><style>
        :root { color-scheme: light dark; --ink: #1c1c1e; --dim: #6c6c70; --bg: #fff; --panel: #f6f6f8;
          --key: #AF52DE; --string: #E0281E; --number: #007AFF; --keyword: #E5245A; --comment: #8a8a8e;
          --tag: #007AFF; --attribute: #D87A00; --instruction: #A2845E; --entity: #2A9BB0;
          --function: #5856D6; --type: #248A3D; }
        @media (prefers-color-scheme: dark) {
          :root { --ink: #ececf0; --dim: #9a9aa0; --bg: #1c1c1e; --panel: #262629;
            --key: #BF5AF2; --string: #FF6961; --number: #409CFF; --keyword: #FF6482; --comment: #8e8e93;
            --tag: #409CFF; --attribute: #FFB340; --instruction: #C4A584; --entity: #5DD8FF;
            --function: #7D7AFF; --type: #30D158; }
        }
        body { font: 13px -apple-system, system-ui, sans-serif; color: var(--ink); background: var(--bg);
               margin: 0; padding: 18px 22px; }
        h1 { font-size: 17px; margin: 0 0 2px; word-break: break-all; }
        .lead { margin: 0 0 10px; color: var(--dim); }
        .note { margin: 0 0 10px; padding: 8px 10px; border-radius: 6px; background: var(--panel); }
        table.code { border-collapse: collapse; font: 12px ui-monospace, Menlo, monospace; }
        table.code td { padding: 0 0 0 12px; white-space: pre; vertical-align: top; }
        table.code td.n { color: var(--dim); text-align: right; padding: 0 4px 0 0; user-select: none;
                          border-right: 1px solid var(--panel); min-width: 3em; }
        .key { color: var(--key); } .string { color: var(--string); } .number { color: var(--number); }
        .keyword { color: var(--keyword); } .comment { color: var(--comment); font-style: italic; }
        .tag { color: var(--tag); } .attribute { color: var(--attribute); } .instruction { color: var(--instruction); }
        .entity { color: var(--entity); } .function { color: var(--function); } .type { color: var(--type); }
        </style></head><body>\(body)</body></html>
        """
    }
}

extension SyntaxColouring.Role {
    /// The page's class for it.
    nonisolated var cssClass: String {
        switch self {
        case .key: "key"
        case .string: "string"
        case .number: "number"
        case .keyword: "keyword"
        case .comment: "comment"
        case .tag: "tag"
        case .attribute: "attribute"
        case .instruction: "instruction"
        case .entity: "entity"
        case .function: "function"
        case .type: "type"
        }
    }
}
