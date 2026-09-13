import Foundation

/// The page Quick Look shows for a folder or an archive.
///
/// Quick Look gives a folder a large blue icon and a size, and an archive
/// little more -- which answers none of the question anybody presses Space to
/// ask, namely *what is in it*.
enum ListingReport {

    static func html(for result: Listing.Result, name: String, path: String,
                     kind: Kind, stillReading: Bool = false) -> String {
        var body = "<h1>\(escape(name))</h1>"
        body += "<p class=lead>\(summary(result, kind: kind, stillReading: stillReading))</p>"
        body += "<p class=meta>\(escape(path))</p>"

        if let trouble = result.trouble {
            body += "<p class=trouble>\(escape(trouble))</p>"
        }

        if stillReading {
            body += "<p class=empty>Reading\u{2026}</p>"
        } else if result.entries.isEmpty && result.trouble == nil {
            body += "<p class=empty>It is empty.</p>"
        }

        if !result.entries.isEmpty {
            body += "<table>"
            for entry in result.entries {
                body += "<tr><td class=icon>\(entry.isDirectory ? "\u{1F4C1}" : "\u{1F4C4}")</td>"
                body += "<td class=name>\(escape(entry.name))</td>"
                body += "<td class=size>\(entry.size.map(bytes) ?? "")</td>"
                body += "<td class=when>\(entry.modified.map(when) ?? "")</td></tr>"
            }
            body += "</table>"
        }

        if result.omitted > 0 {
            body += "<p class=footnote>\(result.omitted) more "
                  + "item\(result.omitted == 1 ? "" : "s") not listed. "
                  + "A preview shows the first \(Listing.mostEntries).</p>"
        }
        return page(title: name, body: body)
    }

    enum Kind {
        case folder, archive
    }

    private static func summary(_ result: Listing.Result, kind: Kind,
                                stillReading: Bool) -> String {
        guard !stillReading else {
            return kind == .folder ? "Looking inside the folder" : "Looking inside the archive"
        }
        let shown = result.entries.count
        let total = shown + result.omitted
        let folders = result.entries.count { $0.isDirectory }
        let files = shown - folders

        guard total > 0 else { return kind == .folder ? "Folder" : "Archive" }
        var parts: [String] = []
        if files > 0 { parts.append("\(files) file\(files == 1 ? "" : "s")") }
        if folders > 0 { parts.append("\(folders) folder\(folders == 1 ? "" : "s")") }
        let what = parts.isEmpty ? "\(total) items" : parts.joined(separator: ", ")
        return result.omitted > 0 ? "\(what), and more" : what
    }

    // MARK: - Bits and pieces

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// Built per call rather than shared: a DateFormatter is not Sendable, and
    /// a listing is written once.
    static func when(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The same look as the other previews, so that pressing Space on one thing
    /// and then another does not feel like two applications.
    private static func page(title: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title><style>
        :root { color-scheme: light dark;
                --ink: #1c1c1e; --dim: #6c6c70; --rule: #d8d8dc; --bg: #fff; --warn: #b35309; }
        @media (prefers-color-scheme: dark) {
          :root { --ink: #ececf0; --dim: #9a9aa0; --rule: #3a3a3e; --bg: #1c1c1e; --warn: #f0a05a; }
        }
        body { font: 13px -apple-system, system-ui, sans-serif; color: var(--ink);
               background: var(--bg); margin: 0; padding: 18px 22px; }
        h1 { font-size: 17px; margin: 0 0 2px; word-break: break-all; }
        .lead { margin: 0 0 2px; color: var(--dim); }
        .meta, .footnote { color: var(--dim); font-size: 11px; margin: 0 0 4px;
                           word-break: break-all; }
        .footnote { margin-top: 22px; border-top: 1px solid var(--rule); padding-top: 8px; }
        .trouble { color: var(--warn); margin: 8px 0; }
        .empty { color: var(--dim); font-style: italic; }
        table { border-collapse: collapse; width: 100%; margin-top: 10px; }
        td { padding: 3px 8px 3px 0; vertical-align: top; border-bottom: 1px solid var(--rule); }
        .icon { width: 18px; }
        .name { word-break: break-all; }
        .size { width: 80px; text-align: right; color: var(--dim);
                font: 11px ui-monospace, Menlo, monospace; white-space: nowrap; }
        .when { width: 150px; color: var(--dim); font-size: 11px; white-space: nowrap; }
        </style></head><body>\(body)</body></html>
        """
    }
}
