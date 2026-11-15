import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Right-click ▸ Edit on a SQLite database: its tables and views in a
/// sidebar, the rows of the one chosen fetched as they are scrolled to,
/// sorted by a column, filtered, a row's whole values below -- and queries of
/// your own. Read-only: what is opened is a private snapshot, and nothing is
/// ever written, to it or to the file.
struct DatabaseView: View {

    @State private var model: DatabaseModel
    @State private var sortOrder: [ColumnOrder] = []
    @State private var showsSchema = false

    init(url: URL) {
        _model = State(initialValue: DatabaseModel(url: url))
    }

    var body: some View {
        Group {
            if model.isOpening {
                ProgressView("Opening \(model.url.lastPathComponent)\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure = model.failure {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
                    Text(failure).multilineTextAlignment(.center).frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 160, ideal: 210)
                } detail: {
                    detail
                }
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .navigationTitle(model.url.lastPathComponent)
        .background(WindowAccessor { window in
            guard let window else { return }
            AppWindows.shared.register(window)
            WindowSubjects.shared.register(window, kind: "database", description: model.url.path)
        })
        .task { await model.open() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $model.source) {
            if !model.tables.isEmpty {
                Section("Tables") {
                    ForEach(model.tables) { table in
                        Label(table.name, systemImage: "tablecells").tag(DatabaseModel.Source.object(table.name))
                    }
                }
            }
            if !model.views.isEmpty {
                Section("Views") {
                    ForEach(model.views) { view in
                        Label(view.name, systemImage: "eye").tag(DatabaseModel.Source.object(view.name))
                    }
                }
            }
            if !model.internalTables.isEmpty {
                Section("SQLite\u{2019}s own") {
                    ForEach(model.internalTables) { table in
                        Label(table.name, systemImage: "gearshape").tag(DatabaseModel.Source.object(table.name))
                    }
                }
            }
            Section {
                Label("Query", systemImage: "text.magnifyingglass").tag(DatabaseModel.Source.query)
            }
        }
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            VSplitView {
                grid
                    .frame(minHeight: 160)
                inspector
                    .frame(minHeight: 90, idealHeight: 160)
            }
            Divider()
            footer
                .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var header: some View {
        if model.source == .query {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $model.queryText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    Text("Only queries that read run here: SELECT, WITH, VALUES, PRAGMA, EXPLAIN.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Run") { sortOrder = []; model.runQuery() }
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        } else {
            HStack(spacing: 8) {
                TextField("Find in any column", text: $model.filter.text)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit { model.applyFilter() }
                TextField("WHERE \u{2026}", text: $model.filter.condition)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { model.applyFilter() }
                    .help("A condition in SQL, as after WHERE: price > 10 AND name LIKE 'A%'")
                Button("Filter") { model.applyFilter() }
                if model.schema != nil {
                    Button { showsSchema.toggle() } label: { Image(systemName: "curlybraces") }
                        .help("The statements that made it")
                        .popover(isPresented: $showsSchema) {
                            ScrollView {
                                Text(model.schema ?? "")
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(width: 520, height: 280)
                        }
                }
            }
        }
    }

    private var grid: some View {
        let columns = model.columns.enumerated().map { GridColumn(id: $0.offset, name: $0.element) }
        return Table(of: DatabaseModel.Row.self, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumnForEach(columns) { column in
                TableColumn(column.name, sortUsing: ColumnOrder(column: column.id)) { row in
                    cell(row, column.id)
                }
                .width(min: 40, ideal: 140)
            }
        } rows: {
            ForEach(model.rows) { row in TableRow(row) }
        }
        .id(model.gridIdentity)
        .font(.system(size: 12))
        .onChange(of: sortOrder) { _, order in
            guard let first = order.first, model.columns.indices.contains(first.column) else {
                model.sort(by: nil, ascending: true)
                return
            }
            model.sort(by: model.columns[first.column], ascending: first.order == .forward)
        }
        .onCopyCommand {
            model.copySelection()
            return []
        }
        .overlay {
            if let problem = model.problem {
                Text(problem).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding().frame(maxWidth: 460)
            } else if model.rows.isEmpty, !model.isLoading, model.reachedEnd {
                Text("No rows.").foregroundStyle(.secondary)
            }
        }
    }

    private func cell(_ row: DatabaseModel.Row, _ column: Int) -> some View {
        let value = row.values.indices.contains(column) ? row.values[column] : .null
        return Text(value.shortText())
            .foregroundStyle(value.isNull ? .secondary : .primary)
            .lineLimit(1)
            .onAppear { if column == 0 { model.appeared(row) } }
    }

    /// The chosen row's every value, whole.
    @ViewBuilder
    private var inspector: some View {
        if model.selection.count == 1, let id = model.selection.first,
           let row = model.rows.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(zip(model.columns, row.values).enumerated()), id: \.offset) { _, pair in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pair.0).font(.caption).foregroundStyle(.secondary)
                            ValueView(value: pair.1)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(model.selection.isEmpty ? "Choose a row to see its values whole." : "\(model.selection.count) rows chosen; ⌘C copies them.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(status).font(.caption).foregroundStyle(.secondary)
            if model.isLoading { ProgressView().controlSize(.small) }
            Spacer()
            if let note = model.database?.note {
                Image(systemName: "info.circle").foregroundStyle(.secondary).help(note)
            }
            Button("Export CSV\u{2026}") { export() }
                .disabled(model.columns.isEmpty)
        }
    }

    private var status: String {
        var parts: [String] = []
        if let total = model.total {
            parts.append("\(total.count.formatted())\(total.capped ? "+" : "") row\(total.count == 1 && !total.capped ? "" : "s")")
        }
        if !model.rows.isEmpty {
            parts.append("\(model.rows.count.formatted()) fetched" + (model.reachedEnd ? "" : ", more as you scroll"))
        }
        parts.append("read-only snapshot")
        return parts.joined(separator: " \u{2022} ")
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let base = switch model.source {
        case .object(let name)?: name
        default: "query"
        }
        panel.nameFieldStringValue = base + ".csv"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        Task {
            if let problem = await model.export(to: target) {
                let alert = NSAlert()
                alert.messageText = "The rows could not be exported."
                alert.informativeText = problem
                alert.runModal()
            }
        }
    }
}

private struct GridColumn: Identifiable {
    let id: Int
    let name: String
}

/// Sorting is done by SQLite, not by the table: this only carries which
/// column was clicked and which way.
struct ColumnOrder: SortComparator, Hashable {
    var column: Int
    var order: SortOrder = .forward
    func compare(_ lhs: DatabaseModel.Row, _ rhs: DatabaseModel.Row) -> ComparisonResult { .orderedSame }
}

/// One value, whole: text (JSON laid out), a picture, or a blob's bytes.
private struct ValueView: View {
    let value: SQLiteDatabase.Value

    var body: some View {
        switch value {
        case .null:
            Text("NULL").foregroundStyle(.secondary)
        case .integer, .real:
            Text(value.plainText).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        case .text(let text):
            Text(Self.formattedJSON(text) ?? text)
                .font(.system(size: 12, design: Self.formattedJSON(text) != nil || text.contains("\n") ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .blob(let data):
            VStack(alignment: .leading, spacing: 4) {
                Text(value.shortText()).font(.caption).foregroundStyle(.secondary)
                if let image = NSImage(data: data), image.isValid {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 320, maxHeight: 240, alignment: .leading)
                } else {
                    Text(Self.hex(data)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
    }

    /// JSON laid out, when the text is an object or an array.
    static func formattedJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[", trimmed.count < 1_000_000,
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The first bytes, sixteen to a line, with their characters.
    static func hex(_ data: Data, most: Int = 1024) -> String {
        let bytes = [UInt8](data.prefix(most))
        var lines: [String] = []
        for start in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = bytes[start..<min(start + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let text = String(chunk.map { (0x20..<0x7F).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%06x  ", start) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + "  " + text)
        }
        if data.count > most { lines.append("\u{2026} \(data.count - most) more bytes") }
        return lines.joined(separator: "\n")
    }
}
