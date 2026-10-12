import Foundation

/// A property list for Quick Look, laid out the way Text Edit's tree shows it:
/// one row per key, with its type and its value, nested dictionaries and
/// arrays indented under the key that holds them and folding like the tree.
///
/// Quick Look's own preview of an XML plist is the source text, and of a
/// binary one a name and a size. Both are read here -- binary and OpenStep
/// lists by way of their XML form -- so every `.plist` previews the same way.
nonisolated enum PlistReport {

    /// Far beyond any settings file; a bigger "plist" is a data dump nobody
    /// reads in a preview panel.
    static let maximumSize = 8 * 1024 * 1024

    /// Rows drawn before the page says where it stopped: a preview that takes
    /// seconds to lay out is worse than one that says "and 40,000 more".
    static let maximumRows = 5000

    enum Format: String { case xml = "XML", binary = "binary", openStep = "OpenStep" }

    /// The tree, in the file's own key order when the file is XML. A binary
    /// list keeps no order a reader could see, so it comes out in the order
    /// its XML form writes -- sorted by key.
    static func tree(of data: Data) -> (root: StructureNode, format: Format)? {
        var raw = PropertyListSerialization.PropertyListFormat.xml
        guard let value = try? PropertyListSerialization.propertyList(from: data, format: &raw) else {
            return nil
        }
        let format: Format = switch raw {
        case .binary: .binary
        case .openStep: .openStep
        default: .xml
        }
        if format == .xml, let text = String(data: data, encoding: .utf8),
           let node = PlistTree(text as NSString).parse()?.children.first {
            return (node, format)
        }
        guard let xml = try? PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0),
              let text = String(data: xml, encoding: .utf8),
              let node = PlistTree(text as NSString).parse()?.children.first else { return nil }
        return (node, format)
    }

    static func html(for data: Data, name: String, path: String) -> String {
        guard let (root, format) = tree(of: data) else {
            return page(title: name, body: "<h1>\(escape(name))</h1><p class=lead>This is named like a "
                        + "property list but does not read as one -- not XML, binary or OpenStep.</p>")
        }
        var rows = 0
        var body = "<h1>\(escape(name))</h1>"
        body += "<p class=lead>\(format.rawValue) property list, \(summary(of: root)), "
            + "\(escape(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))</p>"
        body += "<p class=meta>\(escape(path))</p>"
        body += "<div class=tree><div class='row head'><span>Key</span><span>Type</span><span>Value</span></div>"
        body += render(root, depth: 0, label: "Root", rows: &rows)
        body += "</div>"
        if rows > maximumRows {
            body += "<p class=footnote>Only the first \(maximumRows) rows are shown. "
                + "Text Edit opens all of it, as a tree or as text.</p>"
        }
        return page(title: name, body: body)
    }

    private static func render(_ node: StructureNode, depth: Int, label: String, rows: inout Int) -> String {
        rows += 1
        guard rows <= maximumRows else { return "" }
        let cells = "<span class=k style='padding-left:\(depth * 16 + 4)px'>\(label)</span>"
            + "<span class=t>\(node.kind.title)</span><span class='v \(node.kind.rawValue)'>\(value(of: node))</span>"
        guard node.kind == .dictionary || node.kind == .array else {
            return "<div class=row><span class=leaf></span>\(cells)</div>"
        }
        var inside = ""
        for (index, child) in node.children.enumerated() {
            let name = node.kind == .array
                ? "<i>Item \(index)</i>" : "<b>\(escape(child.key ?? ""))</b>"
            inside += render(child, depth: depth + 1, label: name, rows: &rows)
            if rows > maximumRows { break }
        }
        // <details> folds with no script, which Quick Look would not run. Only
        // the top two levels open, as the tree first shows them: a long list
        // of dictionaries reads as its list before its contents.
        let open = depth < 2 ? " open" : ""
        return "<details\(open)><summary class=row>\(cells)</summary>\(inside)</details>"
    }

    private static func value(of node: StructureNode) -> String {
        switch node.kind {
        case .dictionary, .array: return "<span class=dim>\(summary(of: node))</span>"
        case .boolean: return node.value == "true" ? "YES" : "NO"
        case .data:
            let bytes = Data(base64Encoded: node.value ?? "", options: .ignoreUnknownCharacters) ?? Data()
            let hex = bytes.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes.count), countStyle: .file)
            return "<code>\(hex)\(bytes.count > 24 ? " \u{2026}" : "")</code> <span class=dim>\(size)</span>"
        case .date:
            let text = node.value ?? ""
            guard let date = ISO8601DateFormatter().date(from: text) else { return escape(text) }
            return escape(date.formatted(date: .abbreviated, time: .standard))
                + " <span class=dim>\(escape(text))</span>"
        default: return escape(node.value ?? "")
        }
    }

    private static func summary(of node: StructureNode) -> String {
        let count = node.children.count
        switch node.kind {
        case .dictionary: return "\(count) key\(count == 1 ? "" : "s")"
        case .array: return "\(count) item\(count == 1 ? "" : "s")"
        default: return "one \(node.kind.title.lowercased())"
        }
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
                --ink: #1c1c1e; --dim: #6c6c70; --rule: #e4e4e8; --bg: #fff; --panel: #f6f6f8;
                --str: #c41a16; --num: #1c00cf; --key: #1c1c1e; }
        @media (prefers-color-scheme: dark) {
          :root { --ink: #ececf0; --dim: #9a9aa0; --rule: #333336; --bg: #1c1c1e; --panel: #262629;
                  --str: #fc6a5d; --num: #d0bf69; --key: #ececf0; }
        }
        body { font: 13px -apple-system, system-ui, sans-serif; color: var(--ink);
               background: var(--bg); margin: 0; padding: 18px 22px; }
        h1 { font-size: 17px; margin: 0 0 2px; }
        .lead { margin: 0 0 2px; color: var(--dim); }
        .meta, .footnote { color: var(--dim); font-size: 11px; margin: 0 0 12px; }
        .footnote { margin-top: 14px; }
        .tree { border: 1px solid var(--rule); border-radius: 6px; overflow: hidden; }
        .row { display: grid; grid-template-columns: 14px minmax(160px, 36%) 84px 1fr;
               align-items: baseline; padding: 2px 8px 2px 4px; border-bottom: 1px solid var(--rule); }
        .row > span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .head { grid-template-columns: 14px minmax(160px, 36%) 84px 1fr; background: var(--panel);
                color: var(--dim); font-size: 11px; font-weight: 600; }
        .head span:first-child { grid-column: 2; }
        summary { list-style: none; cursor: default; }
        summary::-webkit-details-marker { display: none; }
        summary::before { content: "\\25B8"; color: var(--dim); font-size: 10px; }
        details[open] > summary::before { content: "\\25BE"; }
        .k b { font-weight: 500; color: var(--key); } .k i { color: var(--dim); font-style: normal; }
        .t { color: var(--dim); font-size: 11px; }
        .v.string { color: var(--str); white-space: pre-wrap; overflow-wrap: anywhere; }
        .v.integer, .v.real, .v.boolean { color: var(--num); font-variant-numeric: tabular-nums; }
        .dim { color: var(--dim); }
        code { font: 11px ui-monospace, Menlo, monospace; color: var(--dim); }
        </style></head><body>\(body)</body></html>
        """
    }
}
