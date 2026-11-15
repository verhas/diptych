import Foundation

/// A SQLite database for Quick Look: its tables and views, how many rows
/// each holds, a few of them, and the schema -- a summary only. Looking
/// through it, more rows, sorted and filtered, is the Database window's.
nonisolated enum SQLiteReport {

    typealias R = ExecutableReport

    static let sampleRows = 5
    static let sampleColumns = 12
    static let mostTables = 60

    static func html(for url: URL, size: Int64?) -> String {
        let name = url.lastPathComponent
        var body = "<h1>\(R.escape(name))</h1>"
        let database: SQLiteDatabase
        do {
            database = try SQLiteDatabase(url: url)
        } catch {
            body += "<p class=lead>SQLite database\(size.map { ", " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")</p>"
            body += "<p class=meta>\(R.escape(url.path))</p><p class=warn>\(R.escape(error.description))</p>"
            return KeyStoreReport.page(title: name, body: R.style + style + body)
        }
        let objects = database.objects()
        let tables = objects.filter { $0.kind == .table && !$0.isInternal }
        let views = objects.filter { $0.kind == .view }
        var lead = "SQLite database, \(tables.count) table\(tables.count == 1 ? "" : "s")"
        if !views.isEmpty { lead += ", \(views.count) view\(views.count == 1 ? "" : "s")" }
        if let size { lead += ", " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
        body += "<p class=lead>\(R.escape(lead))</p><p class=meta>\(R.escape(url.path))</p>"
        if let note = database.note { body += "<p class=note>\(R.escape(note))</p>" }
        body += "<p class=note>Right-click ▸ Edit opens it in the Database window: every row, sorted, filtered, "
            + "and queries of your own. Nothing is ever written to it.</p>"

        if tables.isEmpty && views.isEmpty { body += "<p class=dim>It holds no tables.</p>" }
        for table in (tables + views).prefix(mostTables) {
            body += card(table, in: database, objects: objects)
        }
        if tables.count + views.count > mostTables {
            body += "<p class=dim>And \(tables.count + views.count - mostTables) more, in the Database window.</p>"
        }
        let ownTables = objects.filter { $0.kind == .table && $0.isInternal }
        if !ownTables.isEmpty {
            body += "<p class=dim>SQLite's own: \(ownTables.map { "<code>\(R.escape($0.name))</code>" }.joined(separator: ", ")).</p>"
        }
        return KeyStoreReport.page(title: name, body: R.style + style + body)
    }

    private static func card(_ table: SQLiteDatabase.Object, in database: SQLiteDatabase,
                             objects: [SQLiteDatabase.Object]) -> String {
        let columns = database.columns(of: table.name)
        var head = "<b>\(R.escape(table.name))</b>"
        if table.kind == .view { head += " <span class=kind>view</span>" }
        if let counted = try? database.count(of: table.name) {
            head += " <span class=count>\(counted.count.formatted())\(counted.capped ? "+" : "") row\(counted.count == 1 && !counted.capped ? "" : "s")</span>"
        }
        var html = "<div class=card><div class=head>\(head)</div>"
        let attached = objects.filter { ($0.kind == .index || $0.kind == .trigger) && $0.table == table.name && $0.sql != nil }
        html += "<p class=\"cols inset\">" + columns.map { column in
            var text = "<code>\(R.escape(column.name))</code>"
            if !column.type.isEmpty { text += " <span class=dim>\(R.escape(column.type.lowercased()))</span>" }
            if column.primaryKey { text += " <span class=kind>key</span>" }
            return text
        }.joined(separator: " · ") + "</p>"

        if let page = try? database.browse(table.name, limit: sampleRows, offset: 0), !page.rows.isEmpty {
            let shown = page.columns.prefix(sampleColumns)
            html += "<div class=scroll><table class=summary><tr>" + shown.map { "<th>\(R.escape($0))</th>" }.joined() + "</tr>"
            for row in page.rows {
                html += "<tr>" + row.prefix(sampleColumns).map { value in
                    value.isNull ? "<td class=dim>NULL</td>" : "<td>\(R.escape(value.shortText(80)))</td>"
                }.joined() + "</tr>"
            }
            html += "</table></div>"
            if page.columns.count > sampleColumns {
                html += "<p class=\"dim inset\">And \(page.columns.count - sampleColumns) more columns.</p>"
            }
        }
        if let sql = table.sql {
            html += "<details class=inset><summary>Schema\(attached.isEmpty ? "" : ", with \(attached.count) index\(attached.count == 1 ? "" : "es") and triggers")</summary>"
                + "<pre class=sql>\(R.escape(([sql] + attached.compactMap(\.sql)).joined(separator: ";\n\n")));</pre></details>"
        }
        return html + "</div>"
    }

    static let style = """
        <style>
        .inset { margin: 4px 10px; }
        .count { color: var(--dim); font-size: 11px; margin-left: 6px; }
        .cols { font-size: 12px; line-height: 1.6; }
        .scroll { overflow-x: auto; margin: 0 10px; }
        .scroll table.summary { width: auto; min-width: 100%; margin: 4px 0 8px; }
        .scroll td { white-space: nowrap; max-width: 320px; overflow: hidden; text-overflow: ellipsis; font-size: 12px; }
        pre.sql { font: 11px ui-monospace, Menlo, monospace; background: var(--panel); border-radius: 6px;
                  padding: 8px 10px; white-space: pre-wrap; margin: 6px 0; }
        summary { color: var(--dim); font-size: 11px; cursor: default; }
        </style>
        """
}
