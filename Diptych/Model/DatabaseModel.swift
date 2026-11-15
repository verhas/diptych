import AppKit
import Foundation
import Observation

/// The Database window's state: a SQLite database opened as a private
/// snapshot (`SQLiteDatabase`), one table, view or query shown, its rows
/// fetched a page at a time as they are scrolled to.
@MainActor
@Observable
final class DatabaseModel {

    enum Source: Hashable {
        case object(String)
        case query
    }

    struct Row: Identifiable, Sendable {
        let id: Int
        let values: [SQLiteDatabase.Value]
    }

    let url: URL
    private(set) var database: SQLiteDatabase?
    private(set) var failure: String?
    private(set) var objects: [SQLiteDatabase.Object] = []
    private(set) var isOpening = true

    var source: Source? {
        didSet { if source != oldValue { reset() } }
    }

    private(set) var columns: [String] = []
    private(set) var rows: [Row] = []
    private(set) var total: (count: Int, capped: Bool)?
    private(set) var reachedEnd = false
    private(set) var isLoading = false
    private(set) var problem: String?
    /// Bumped whenever what is shown starts over, so a page still on its way
    /// for the last one is dropped, and the grid is made anew.
    private(set) var generation = 0

    var filter = SQLiteDatabase.Filter()
    private(set) var order: SQLiteDatabase.Order?
    var queryText = ""
    var selection: Set<Int> = []

    nonisolated static let pageSize = 500

    init(url: URL) {
        self.url = url
    }

    // MARK: - Opening

    func open() async {
        let url = url
        let result = await BlockingWork.run { () -> Result<(SQLiteDatabase, [SQLiteDatabase.Object]), SQLiteDatabase.Failure> in
            do throws(SQLiteDatabase.Failure) {
                let database = try SQLiteDatabase(url: url)
                return .success((database, database.objects()))
            } catch {
                return .failure(error)
            }
        }
        isOpening = false
        switch result {
        case .success(let (database, objects)):
            self.database = database
            self.objects = objects
            let first = tables.first ?? views.first
            queryText = first.map { "SELECT * FROM \(SQLiteDatabase.quoted($0.name))" } ?? "SELECT * FROM sqlite_master"
            source = first.map { .object($0.name) } ?? .query
        case .failure(let error):
            failure = error.description
        }
    }

    var tables: [SQLiteDatabase.Object] { objects.filter { $0.kind == .table && !$0.isInternal } }
    var views: [SQLiteDatabase.Object] { objects.filter { $0.kind == .view } }
    var internalTables: [SQLiteDatabase.Object] { objects.filter { $0.kind == .table && $0.isInternal } }

    /// The statements that make the object shown: itself, its indexes and triggers.
    var schema: String? {
        guard case .object(let name)? = source else { return nil }
        let parts = objects.filter { $0.name == name || (($0.kind == .index || $0.kind == .trigger) && $0.table == name) }
            .compactMap(\.sql)
        return parts.isEmpty ? nil : parts.joined(separator: ";\n\n") + ";"
    }

    // MARK: - Rows

    /// What the grid is made for: the same while only the rows change -- a
    /// sort, a filter -- so it keeps its scroll and column widths; new for
    /// another table or query.
    var gridIdentity: String {
        let shown = switch source {
        case .object(let name)?: "table:" + name
        case .query?: "query"
        case nil: ""
        }
        return shown + "|" + columns.joined(separator: "\u{1F}")
    }

    private func reset(keepingColumns: Bool = false) {
        generation += 1
        if !keepingColumns { columns = [] }
        rows = []
        total = nil
        reachedEnd = false
        problem = nil
        selection = []
        isLoading = false
        loadMore()
        countRows()
    }

    func applyFilter() {
        reset(keepingColumns: true)
    }

    func sort(by column: String?, ascending: Bool) {
        let next = column.map { SQLiteDatabase.Order(column: $0, ascending: ascending) }
        guard next != order else { return }
        order = next
        reset(keepingColumns: true)
    }

    func runQuery() {
        source = .query
        order = nil
        reset()
    }

    /// The next page, once the last rows are close to being shown.
    func appeared(_ row: Row) {
        if row.id >= rows.count - 100 { loadMore() }
    }

    func loadMore() {
        guard let database, let source, !isLoading, !reachedEnd else { return }
        isLoading = true
        let offset = rows.count
        let generation = generation
        let filter = filter, order = order, query = queryText
        Task {
            let result = await BlockingWork.run { () -> Result<SQLiteDatabase.Page, SQLiteDatabase.Failure> in
                do throws(SQLiteDatabase.Failure) {
                    switch source {
                    case .object(let name):
                        return .success(try database.browse(name, filter: filter, order: order,
                                                            limit: Self.pageSize, offset: offset))
                    case .query:
                        return .success(try database.run(query, order: order, limit: Self.pageSize, offset: offset))
                    }
                } catch {
                    return .failure(error)
                }
            }
            guard generation == self.generation else { return }
            isLoading = false
            switch result {
            case .success(let page):
                if columns.isEmpty || offset == 0 { columns = page.columns }
                rows += page.rows.enumerated().map { Row(id: offset + $0.offset, values: $0.element) }
                reachedEnd = page.rows.count < Self.pageSize
            case .failure(let error):
                problem = error.description
                reachedEnd = true
            }
        }
    }

    private func countRows() {
        guard let database, case .object(let name)? = source else { return }
        let generation = generation
        let filter = filter
        Task {
            let counted = await BlockingWork.run { try? database.count(of: name, filter: filter) }
            guard generation == self.generation, let counted else { return }
            total = counted
        }
    }

    // MARK: - Copying out

    /// The rows chosen, tab-separated, with the column names first.
    func copySelection() {
        let chosen = rows.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let lines = [columns.joined(separator: "\t")]
            + chosen.map { $0.values.map { $0.plainText.replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(lines.joined(separator: "\n") + "\n", forType: .string)
    }

    /// Everything the table, view or query shows -- all its rows, not only
    /// those fetched -- as CSV.
    func export(to target: URL) async -> String? {
        guard let database, let source else { return "Nothing is shown." }
        let filter = filter, order = order, query = queryText
        return await BlockingWork.run { () -> String? in
            FileManager.default.createFile(atPath: target.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: target) else { return "It could not be written there." }
            defer { try? handle.close() }
            var offset = 0
            var wroteHeader = false
            while true {
                let page: SQLiteDatabase.Page
                do throws(SQLiteDatabase.Failure) {
                    switch source {
                    case .object(let name): page = try database.browse(name, filter: filter, order: order, limit: 5000, offset: offset)
                    case .query: page = try database.run(query, order: order, limit: 5000, offset: offset)
                    }
                } catch {
                    return error.description
                }
                var text = ""
                if !wroteHeader {
                    text += page.columns.map(Self.csvField).joined(separator: ",") + "\r\n"
                    wroteHeader = true
                }
                for row in page.rows { text += row.map { Self.csvField($0.plainText) }.joined(separator: ",") + "\r\n" }
                handle.write(Data(text.utf8))
                offset += page.rows.count
                if page.rows.count < 5000 { return nil }
            }
        }
    }

    nonisolated static func csvField(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
