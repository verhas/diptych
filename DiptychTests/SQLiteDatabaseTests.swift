import XCTest
import SQLite3
@testable import Diptych

/// SQLite databases, opened to be looked at: the snapshot that leaves the file
/// alone, the schema, browsing, queries, the Quick Look summary and the
/// Database window's paging.
final class SQLiteDatabaseTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SQLiteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A database made with SQLite itself; the connection is handed back
    /// open when asked, as an app using it would keep it.
    @discardableResult
    private func make(name: String = "shop.sqlite", wal: Bool = false, keepOpen: Bool = false,
                      _ sql: String) throws -> (url: URL, db: OpaquePointer?) {
        let url = folder.appendingPathComponent(name)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        if wal {
            sqlite3_exec(db, "PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;", nil, nil, nil)
        }
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &error)
        if status != SQLITE_OK { XCTFail(error.map { String(cString: $0) } ?? "sqlite") }
        if keepOpen { return (url, db) }
        sqlite3_close(db)
        return (url, nil)
    }

    private static let shop = """
        CREATE TABLE product (id INTEGER PRIMARY KEY, name TEXT NOT NULL, price REAL, picture BLOB);
        CREATE INDEX product_name ON product(name);
        CREATE VIEW cheap AS SELECT name FROM product WHERE price < 5;
        INSERT INTO product (name, price, picture) VALUES
          ('apple', 1.5, NULL), ('bread', 3.25, NULL), ('cheese', 12.0, x'89504E470D0A1A0A'),
          ('50% off', 9.99, NULL), ('a_b', 2.0, NULL);
        """

    func testTheSchemaAndRows() throws {
        let (url, _) = try make(Self.shop)
        let database = try SQLiteDatabase(url: url)
        let objects = database.objects()
        XCTAssertEqual(Set(objects.map(\.id)), ["table:product", "index:product_name", "view:cheap"])
        XCTAssertEqual(objects.first { $0.name == "product_name" }?.table, "product")
        let columns = database.columns(of: "product")
        XCTAssertEqual(columns.map(\.name), ["id", "name", "price", "picture"])
        XCTAssertEqual(columns.first?.primaryKey, true)
        XCTAssertEqual(columns[1].notNull, true)
        XCTAssertEqual(try database.count(of: "product").count, 5)
        XCTAssertEqual(try database.count(of: "cheap").count, 3)

        let page = try database.browse("product", order: .init(column: "price", ascending: false), limit: 2, offset: 0)
        XCTAssertEqual(page.columns, ["id", "name", "price", "picture"])
        XCTAssertEqual(page.rows.map { $0[1] }, [.text("cheese"), .text("50% off")])
        XCTAssertEqual(page.rows.first?[3].shortText(), "8 bytes PNG blob")
    }

    func testFilteringFindsTextLiterallyAndTakesAConditiion() throws {
        let (url, _) = try make(Self.shop)
        let database = try SQLiteDatabase(url: url)
        // % and _ are what they look like, not wildcards.
        let percent = try database.browse("product", filter: .init(text: "50%"), limit: 10, offset: 0)
        XCTAssertEqual(percent.rows.map { $0[1] }, [.text("50% off")])
        let underscore = try database.browse("product", filter: .init(text: "a_"), limit: 10, offset: 0)
        XCTAssertEqual(underscore.rows.map { $0[1] }, [.text("a_b")])
        XCTAssertEqual(try database.count(of: "product", filter: .init(text: "e")).count, 3, "apple, bread, cheese")

        let condition = try database.browse("product", filter: .init(condition: "price > 3 AND price < 10"),
                                            order: .init(column: "price", ascending: true), limit: 10, offset: 0)
        XCTAssertEqual(condition.rows.map { $0[1] }, [.text("bread"), .text("50% off")])
        XCTAssertThrowsError(try database.browse("product", filter: .init(condition: "1; DROP TABLE product"), limit: 1, offset: 0))
    }

    func testOnlyQueriesThatReadRun() throws {
        let (url, _) = try make(Self.shop)
        let database = try SQLiteDatabase(url: url)
        let page = try database.run("SELECT name, price * 2 AS twice FROM product WHERE price < 2;", limit: 10, offset: 0)
        XCTAssertEqual(page.columns, ["name", "twice"])
        XCTAssertEqual(page.rows.first?[1], .real(3.0))
        XCTAssertEqual(try database.run("PRAGMA table_info(product)", limit: 10, offset: 0).rows.count, 4)
        XCTAssertThrowsError(try database.run("DELETE FROM product", limit: 1, offset: 0))
        XCTAssertThrowsError(try database.run("WITH x AS (SELECT 1) DELETE FROM product", limit: 1, offset: 0))
        // And the file still holds all of it.
        XCTAssertEqual(try SQLiteDatabase(url: url).count(of: "product").count, 5)
    }

    func testWhatIsStillInTheLogIsSeenAndTheFileIsLeftAlone() throws {
        // An app has the database open in WAL mode, its last rows not yet
        // folded into the file.
        let (url, db) = try make(wal: true, keepOpen: true, Self.shop + "INSERT INTO product (name) VALUES ('late');")
        defer { sqlite3_close(db) }
        let wal = URL(fileURLWithPath: url.path + "-wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wal.path))
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let walBefore = try Data(contentsOf: wal)
        let listing = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()

        do {
            let database = try SQLiteDatabase(url: url)
            XCTAssertEqual(try database.count(of: "product").count, 6, "the row still in the log")
            XCTAssertNil(database.note)
        }

        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(after[.modificationDate] as? Date, before[.modificationDate] as? Date)
        XCTAssertEqual(after[.size] as? Int, before[.size] as? Int)
        XCTAssertEqual(try Data(contentsOf: wal), walBefore, "the log untouched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), listing,
                       "nothing made beside it")
    }

    func testWhatIsNotADatabaseSaysSo() throws {
        let text = folder.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        XCTAssertThrowsError(try SQLiteDatabase(url: text)) { error in
            guard case SQLiteDatabase.Failure.notADatabase = error else { return XCTFail("\(error)") }
        }
        let scrambled = folder.appendingPathComponent("secret.db")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: scrambled)
        XCTAssertThrowsError(try SQLiteDatabase(url: scrambled)) { error in
            guard case SQLiteDatabase.Failure.encrypted = error else { return XCTFail("\(error)") }
        }
        // A real header over damaged pages.
        let damaged = folder.appendingPathComponent("damaged.sqlite")
        try (SQLiteDatabase.header + Data(repeating: 0xEE, count: 8192)).write(to: damaged)
        XCTAssertThrowsError(try SQLiteDatabase(url: damaged))
        XCTAssertTrue(SQLiteReport.html(for: damaged, size: 8208).contains("SQLite cannot read it"))
    }

    func testTheSummaryPage() throws {
        let (url, _) = try make(Self.shop)
        let html = SQLiteReport.html(for: url, size: 8192)
        for expected in ["SQLite database, 1 table, 1 view", "product", "5 rows", "cheese", "8 bytes PNG blob",
                         "CREATE INDEX product_name", "Database window"] {
            XCTAssertTrue(html.contains(expected), expected)
        }
    }

    func testCSVFieldsAreQuotedWhenTheyMustBe() {
        XCTAssertEqual(DatabaseModel.csvField("plain"), "plain")
        XCTAssertEqual(DatabaseModel.csvField("a,b"), "\"a,b\"")
        XCTAssertEqual(DatabaseModel.csvField("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(DatabaseModel.csvField("two\nlines"), "\"two\nlines\"")
    }

    @MainActor
    func testTheWindowFetchesRowsAPageAtATime() async throws {
        let (url, _) = try make(name: "many.sqlite", """
            CREATE TABLE n (i INTEGER);
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1200) INSERT INTO n SELECT x FROM c;
            """)
        let model = DatabaseModel(url: url)
        await model.open()
        XCTAssertEqual(model.source, .object("n"))
        try await waitUntil { !model.isLoading && !model.rows.isEmpty }
        XCTAssertEqual(model.rows.count, DatabaseModel.pageSize)
        try await waitUntil { model.total != nil }
        XCTAssertEqual(model.total?.count, 1200)

        model.appeared(model.rows.last!)
        try await waitUntil { model.rows.count == 1000 }
        model.appeared(model.rows.last!)
        try await waitUntil { model.reachedEnd }
        XCTAssertEqual(model.rows.count, 1200)

        model.sort(by: "i", ascending: false)
        try await waitUntil { model.rows.first?.values.first == .integer(1200) }
        model.filter.condition = "i % 100 = 0"
        model.applyFilter()
        try await waitUntil { model.reachedEnd && model.rows.count == 12 }
        XCTAssertEqual(model.rows.first?.values.first, .integer(1200), "the order kept")

        let csv = folder.appendingPathComponent("out.csv")
        let problem = await model.export(to: csv)
        XCTAssertNil(problem)
        let lines = try String(contentsOf: csv, encoding: .utf8).split(separator: "\r\n")
        XCTAssertEqual(lines.first, "i")
        XCTAssertEqual(lines.count, 13, "the header and every row, not only those fetched")
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
