import Foundation

/// Renders Markdown as a page Quick Look can show.
///
/// The parsing is Foundation's: `AttributedString(markdown:)` is a real
/// CommonMark parser with the GitHub extensions, so headings, nested lists,
/// block quotes, fenced code blocks with a language hint, and tables with
/// per-column alignment all arrive already identified. Nothing is vendored and
/// nothing is hand-parsed.
///
/// What is left is shape. The parser hands back a *flat* run of text carrying
/// `presentationIntent` attributes, and HTML is a tree -- so the work here is
/// turning one into the other: compare each run's intent with the previous
/// run's, close the tags that ended, open the ones that began.
enum MarkdownReport {

    /// A ceiling, as everywhere else that reads a file it did not write. A
    /// Markdown file is prose; anything past this is a log someone renamed.
    static let maximumSize = 4 << 20

    static func html(for markdown: String, name: String, baseURL: URL) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            // A malformed table or an unclosed fence should cost that block,
            // not the document.
            failurePolicy: .returnPartiallyParsedIfPossible)

        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return page(title: name, body: "<p class=note>This file could not be parsed as "
                                         + "Markdown.</p>")
        }

        var body = ""
        // Outermost first, which is the order tags have to be opened in.
        var open: [PresentationIntent.IntentType] = []
        // Alignment belongs to the table, not to the cell, so it has to be
        // remembered when the table opens and applied when each cell does.
        var columns: [PresentationIntent.TableColumn] = []
        var inHeaderRow = false

        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            let wanted = (run.presentationIntent?.components ?? []).reversed().map { $0 }

            // How much of the open nesting this run still shares. Identity is
            // the parser's own block id, so two list items with the same kind
            // are still told apart.
            var shared = 0
            while shared < open.count, shared < wanted.count,
                  open[shared].identity == wanted[shared].identity {
                shared += 1
            }
            for intent in open[shared...].reversed() {
                if case .tableHeaderRow = intent.kind { inHeaderRow = false }
                body += close(intent, inHeaderRow: inHeaderRow)
            }
            for intent in wanted[shared...] {
                if case .table(let declared) = intent.kind { columns = declared }
                if case .tableHeaderRow = intent.kind { inHeaderRow = true }
                body += start(intent, columns: columns, inHeaderRow: inHeaderRow)
            }
            open = wanted

            body += inline(text, run: run, in: parsed, baseURL: baseURL,
                           insideCode: wanted.contains { if case .codeBlock = $0.kind { return true }
                                                         else { return false } })
        }
        for intent in open.reversed() { body += close(intent, inHeaderRow: inHeaderRow) }

        return page(title: name, body: body.isEmpty ? "<p class=note>This file is empty.</p>" : body)
    }

    // MARK: - Blocks

    private static func start(_ intent: PresentationIntent.IntentType,
                              columns: [PresentationIntent.TableColumn],
                              inHeaderRow: Bool) -> String {
        switch intent.kind {
        case .paragraph:            return "<p>"
        case .header(let level):    return "<h\(min(max(level, 1), 6))>"
        case .orderedList:          return "<ol>"
        case .unorderedList:        return "<ul>"
        case .listItem:             return "<li>"
        case .blockQuote:           return "<blockquote>"
        case .thematicBreak:        return "<hr>"
        case .codeBlock(let language):
            let hint = language.map { " data-language=\"\(escape($0))\"" } ?? ""
            return "<pre\(hint)><code>"
        case .table:                return "<table>"
        case .tableHeaderRow:       return "<thead><tr>"
        case .tableRow:             return "<tr>"
        case .tableCell(let column):
            let tag = inHeaderRow ? "th" : "td"
            guard columns.indices.contains(Int(column)) else { return "<\(tag)>" }
            switch columns[Int(column)].alignment {
            case .left:   return "<\(tag)>"
            case .center: return "<\(tag) style=\"text-align:center\">"
            case .right:  return "<\(tag) style=\"text-align:right\">"
            @unknown default: return "<\(tag)>"
            }
        default:                    return ""
        }
    }

    private static func close(_ intent: PresentationIntent.IntentType,
                              inHeaderRow: Bool) -> String {
        switch intent.kind {
        case .paragraph:            return "</p>"
        case .header(let level):    return "</h\(min(max(level, 1), 6))>"
        case .orderedList:          return "</ol>"
        case .unorderedList:        return "</ul>"
        case .listItem:             return "</li>"
        case .blockQuote:           return "</blockquote>"
        case .thematicBreak:        return ""
        case .codeBlock:            return "</code></pre>"
        case .table:                return "</table>"
        case .tableHeaderRow:       return "</tr></thead>"
        case .tableRow:             return "</tr>"
        case .tableCell:            return inHeaderRow ? "</th>" : "</td>"
        default:                    return ""
        }
    }

    // MARK: - Inline

    private static func inline(_ text: String, run: AttributedString.Runs.Run,
                               in parsed: AttributedString, baseURL: URL,
                               insideCode: Bool) -> String {
        // Inside a fence, everything is literal -- including the characters
        // that would otherwise be markup.
        guard !insideCode else { return escape(text) }

        // An image carries its alt text as the run's characters, so the URL is
        // resolved against the document rather than the temporary file the
        // preview is written to -- otherwise every relative path breaks.
        if let image = run.imageURL {
            let resolved = URL(string: image.absoluteString, relativeTo: baseURL)?.absoluteString
                ?? image.absoluteString
            return "<img src=\"\(escape(resolved))\" alt=\"\(escape(text))\">"
        }

        var html = escape(text)
        if let inlineIntent = run.inlinePresentationIntent {
            if inlineIntent.contains(.code) { html = "<code>\(html)</code>" }
            if inlineIntent.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
            if inlineIntent.contains(.emphasized) { html = "<em>\(html)</em>" }
            if inlineIntent.contains(.strikethrough) { html = "<del>\(html)</del>" }
            if inlineIntent.contains(.lineBreak) { html += "<br>" }
        }
        if let link = run.link {
            html = "<a href=\"\(escape(link.absoluteString))\">\(html)</a>"
        }
        return html
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func page(title: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title><style>
        :root { color-scheme: light dark;
                --ink: #1c1c1e; --dim: #6c6c70; --rule: #d8d8dc; --bg: #fff; --panel: #f6f6f8; }
        @media (prefers-color-scheme: dark) {
          :root { --ink: #ececf0; --dim: #9a9aa0; --rule: #3a3a3e; --bg: #1c1c1e; --panel: #262629; }
        }
        body { font: 14px/1.6 -apple-system, system-ui, sans-serif; color: var(--ink);
               background: var(--bg); margin: 0 auto; padding: 26px 32px; max-width: 46em; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 .5em; }
        h1 { font-size: 1.8em; } h2 { font-size: 1.4em; padding-bottom: .2em;
             border-bottom: 1px solid var(--rule); } h3 { font-size: 1.15em; }
        p { margin: .7em 0; }
        a { color: #2f6fb5; } @media (prefers-color-scheme: dark) { a { color: #6ea8e6; } }
        code { font: 12px ui-monospace, Menlo, monospace;
               background: var(--panel); padding: .1em .3em; border-radius: 3px; }
        pre { background: var(--panel); padding: 11px 13px; border-radius: 6px;
              overflow-x: auto; }
        pre code { background: none; padding: 0; font-size: 12px; line-height: 1.45; }
        blockquote { margin: .8em 0; padding: .1em 0 .1em 14px; color: var(--dim);
                     border-left: 3px solid var(--rule); }
        ul, ol { padding-left: 1.5em; } li { margin: .25em 0; }
        li > p { margin: 0; }
        hr { border: 0; border-top: 1px solid var(--rule); margin: 1.6em 0; }
        table { border-collapse: collapse; margin: 1em 0; display: block;
                overflow-x: auto; max-width: 100%; }
        td, th { border: 1px solid var(--rule); padding: 5px 10px; text-align: left; }
        th { background: var(--panel); font-weight: 600; }
        img { max-width: 100%; }
        .note { color: var(--dim); font-style: italic; }
        </style></head><body>\(body)</body></html>
        """
    }
}
