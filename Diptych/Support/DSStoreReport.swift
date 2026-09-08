import Foundation

/// Renders a decoded `.DS_Store` as a page Quick Look can show.
///
/// HTML rather than text because the interesting parts are not lines: the
/// records are a table, the embedded property lists are trees, and icon
/// positions are the one genuinely spatial thing in the file -- worth drawing
/// rather than listing as pairs of numbers.
enum DSStoreReport {

    /// What each four-character key is for. Anything missing is shown by its
    /// code alone: there are dozens of these, third-party tools invent more,
    /// and a key we cannot name is still worth showing.
    private static let meanings: [String: String] = [
        "Iloc": "Icon position",
        "dilc": "Desktop icon position",
        "bwsp": "Window settings",
        "icvp": "Icon view settings",
        "icvo": "Icon view options",
        "lsvp": "List view settings",
        "lsvP": "List view settings",
        "lsvC": "List view columns",
        "lsvo": "List view options",
        "clvp": "Column view settings",
        "glvp": "Gallery view settings",
        "vSrn": "View settings version",
        "vstl": "View style",
        "fwi0": "Window frame and view",
        "fwsw": "Sidebar width",
        "fwvh": "Window height",
        "dscl": "Folder was open in list view",
        "fdsc": "Folder was open in list view",
        "cmmt": "Spotlight comment",
        "extn": "Extension",
        "logS": "Logical size",
        "lg1S": "Logical size",
        "ph1S": "Physical size",
        "phyS": "Physical size",
        "modD": "Modified",
        "moDD": "Modified",
        "BKGD": "Window background",
        "pict": "Background picture",
        "info": "Finder info",
        "bRsV": "Browser reserved",
        "ptbL": "Path bar location",
        "ptbN": "Path bar name",
    ]

    static func html(for store: DSStore, name: String, path: String) -> String {
        let entries = store.byEntry
        var body = ""

        body += "<h1>\(escape(name))</h1>"
        body += "<p class=lead>\(store.records.count) record"
            + (store.records.count == 1 ? "" : "s")
            + " describing \(entries.count) item\(entries.count == 1 ? "" : "s") "
            + "in \(escape(path))</p>"
        body += "<p class=meta>B-tree: \(store.nodes) node\(store.nodes == 1 ? "" : "s"), "
            + "\(store.levels) level\(store.levels == 1 ? "" : "s"), "
            + "\(store.pageSize)-byte pages, \(store.declaredRecords) records declared</p>"

        if let map = iconMap(entries) { body += map }

        for (entry, records) in entries {
            body += "<h2>\(escape(entry))</h2><table>"
            for record in records {
                let meaning = meanings[record.key].map { escape($0) } ?? "<i>unknown</i>"
                body += "<tr><td class=key><code>\(escape(record.key))</code></td>"
                     +  "<td class=what>\(meaning)</td>"
                     +  "<td class=val>\(render(record))</td></tr>"
            }
            body += "</table>"
        }

        if entries.isEmpty {
            body += "<p class=empty>The tree is empty. Finder writes this when it has "
                  + "forgotten everything it knew about a folder but has not removed the file.</p>"
        }

        body += "<p class=footnote>A <code>.DS_Store</code> remembers the names of items that "
              + "were in the folder, including ones since deleted -- which is why finding one on "
              + "a web server counts as a disclosure.</p>"

        return page(title: name, body: body)
    }

    // MARK: - Values

    private static func render(_ record: DSStore.Record) -> String {
        switch record.value {
        case .flag(let on):
            return on ? "yes" : "no"

        case .integer(let value):
            return "\(value)"

        case .long(let value):
            // comp is used for sizes far more often than for anything else, so
            // show both readings rather than making the reader do the division.
            return "\(value) <span class=aside>(\(bytes(Int64(value))))</span>"

        case .code(let code):
            return "<code>\(escape(code))</code>"

        case .text(let text):
            return escape(text)

        case .blob(let data):
            return blob(data, key: record.key)
        }
    }

    private static func blob(_ data: Data, key: String) -> String {
        if key == "Iloc" || key == "dilc", let point = iconPosition(data) {
            return "x \(point.x), y \(point.y)"
        }
        if key.hasSuffix("odD") || key == "moDD", let date = timestamp(data) {
            return escape(date.formatted(date: .abbreviated, time: .shortened))
        }
        if data.starts(with: Array("bplist00".utf8)),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            return "<div class=plist>\(tree(plist))</div>"
        }
        return "<code class=hex>\(hex(data))</code>"
    }

    /// Icon coordinates: two big-endian 32-bit numbers, then padding Finder
    /// fills with 0xFF.
    static func iconPosition(_ data: Data) -> (x: UInt32, y: UInt32)? {
        guard data.count >= 8 else { return nil }
        let values = [UInt8](data.prefix(8))
        let x = values[0...3].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let y = values[4...7].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        // Finder writes 0xFFFFFFFF for "no position of its own".
        guard x != .max, y != .max else { return nil }
        return (x, y)
    }

    /// The one little-endian number in a big-endian format: an IEEE double of
    /// seconds since 2001, the Mac epoch, where everything else here is a
    /// big-endian integer.
    static func timestamp(_ data: Data) -> Date? {
        guard data.count >= 8 else { return nil }
        let raw = [UInt8](data.prefix(8)).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let seconds = Double(bitPattern: raw)
        guard seconds.isFinite, abs(seconds) < 4e10 else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    // MARK: - Pieces

    /// Where the icons sat, drawn to scale. Coordinates are the icon centres in
    /// the window's own space, so this is a real picture of the folder as it was
    /// last arranged -- the only part of the file that is genuinely a shape.
    private static func iconMap(_ entries: [(entry: String, records: [DSStore.Record])]) -> String? {
        var points: [(String, UInt32, UInt32)] = []
        for (entry, records) in entries {
            for record in records where record.key == "Iloc" || record.key == "dilc" {
                if case .blob(let data) = record.value, let point = iconPosition(data) {
                    points.append((entry, point.x, point.y))
                }
            }
        }
        guard points.count > 1 else { return nil }

        let width = Double(points.map(\.1).max() ?? 1) + 40
        let height = Double(points.map(\.2).max() ?? 1) + 40
        var svg = "<h2>Icon positions</h2><div class=map>"
            + "<svg viewBox='0 0 \(Int(width)) \(Int(height))' preserveAspectRatio='xMinYMin meet'>"
        for (name, x, y) in points {
            svg += "<circle cx='\(x)' cy='\(y)' r='7'/>"
            svg += "<text x='\(x)' y='\(Int(y) + 20)'>\(escape(name))</text>"
        }
        return svg + "</svg></div>"
    }

    /// Property lists nest, so the rendering does too.
    private static func tree(_ value: Any) -> String {
        switch value {
        case let dictionary as [String: Any]:
            // `dictionary[key] as Any` wraps the miss in an Optional that then
            // prints as "Optional(...)"; the keys came from the dictionary, so
            // there is no miss to report.
            return "<ul>" + dictionary.keys.sorted().map {
                "<li><b>\(escape($0))</b>: \(tree(dictionary[$0] ?? ""))</li>"
            }.joined() + "</ul>"
        case let array as [Any]:
            return "<ul>" + array.map { "<li>\(tree($0))</li>" }.joined() + "</ul>"
        case let data as Data:
            return "<code class=hex>\(hex(data))</code>"
        case let date as Date:
            return escape(date.formatted(date: .abbreviated, time: .shortened))
        case let flag as Bool:
            return flag ? "yes" : "no"
        case let text as String:
            return rectangle(text) ?? escape(text)
        default:
            return escape("\(value)")
        }
    }

    /// Finder stores window frames as the string `{{x, y}, {w, h}}`, which is
    /// four numbers in an order nobody remembers. Say which is which.
    static func rectangle(_ text: String) -> String? {
        let numbers = text.split(whereSeparator: { !"-0123456789".contains($0) })
            .compactMap { Int($0) }
        guard numbers.count == 4, text.hasPrefix("{{") else { return nil }
        return "\(numbers[2]) \u{00D7} \(numbers[3]) at (\(numbers[0]), \(numbers[1]))"
    }

    private static func hex(_ data: Data) -> String {
        let shown = data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
        return data.count > 32 ? "\(shown) ... (\(data.count) bytes)" : shown
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Failure gets a page too. Quick Look's own "no preview" panel says
    /// nothing, and "this file is not what it claims to be" is worth knowing.
    static func html(failure: Error, name: String) -> String {
        let explanation: String
        switch failure {
        case DSStore.Failure.notADSStore:
            explanation = "This is named <code>.DS_Store</code> but does not start with the "
                        + "<code>Bud1</code> magic. Something else wrote it."
        case DSStore.Failure.truncated:
            explanation = "The file ends in the middle of a structure. It is truncated or corrupt."
        case DSStore.Failure.tooLarge:
            explanation = "The file is larger than any real <code>.DS_Store</code>, so it has "
                        + "not been parsed."
        case DSStore.Failure.malformed(let detail):
            explanation = "The file does not decode: \(escape(detail))."
        default:
            explanation = escape("\(failure)")
        }
        return page(title: name,
                    body: "<h1>\(escape(name))</h1><p class=lead>\(explanation)</p>")
    }

    private static func page(title: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title><style>
        :root { color-scheme: light dark;
                --ink: #1c1c1e; --dim: #6c6c70; --rule: #d8d8dc; --bg: #fff; --panel: #f6f6f8; }
        @media (prefers-color-scheme: dark) {
          :root { --ink: #ececf0; --dim: #9a9aa0; --rule: #3a3a3e; --bg: #1c1c1e; --panel: #262629; }
        }
        body { font: 13px -apple-system, system-ui, sans-serif; color: var(--ink);
               background: var(--bg); margin: 0; padding: 18px 22px; }
        h1 { font-size: 17px; margin: 0 0 2px; }
        h2 { font-size: 13px; margin: 20px 0 5px; padding-bottom: 3px;
             border-bottom: 1px solid var(--rule); font-weight: 600; }
        .lead { margin: 0 0 2px; color: var(--dim); }
        .meta, .footnote { color: var(--dim); font-size: 11px; margin: 0 0 4px; }
        .footnote { margin-top: 22px; border-top: 1px solid var(--rule); padding-top: 8px; }
        table { border-collapse: collapse; width: 100%; }
        td { padding: 3px 8px 3px 0; vertical-align: top; border-bottom: 1px solid var(--rule); }
        .key { width: 52px; } .what { width: 170px; color: var(--dim); }
        code { font: 11px ui-monospace, Menlo, monospace; }
        .hex { color: var(--dim); word-break: break-all; }
        .aside { color: var(--dim); }
        .plist ul { margin: 0; padding-left: 15px; list-style: none; }
        .plist li { padding: 1px 0; }
        .map { background: var(--panel); border-radius: 6px; padding: 8px; }
        .map svg { width: 100%; height: auto; max-height: 320px; }
        .map circle { fill: #4a90d9; }
        .map text { font: 9px -apple-system, sans-serif; fill: var(--dim); text-anchor: middle; }
        .empty { color: var(--dim); font-style: italic; }
        </style></head><body>\(body)</body></html>
        """
    }
}
