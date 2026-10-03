import Foundation
import Observation
import SQLite3

/// `com.apple.provenance`, in words.
///
/// macOS writes it on a file when a process it tracks makes or changes the
/// file -- tracked meaning the app responsible for the process was once
/// checked by Gatekeeper. The value is undocumented: three header bytes, then
/// 8 bytes that are, read as a little-endian signed 64-bit number, the `pk` of
/// a row in the `provenance_tracking` table of
/// `/var/db/SystemPolicyConfiguration/ExecPolicy` -- verified against that
/// table, where the same number is the `link_pk` of everything the app ran.
/// That row names the app: its path, bundle id, team and signing identity.
/// Only root can read the database, so the lookup is a deliberate request
/// that asks for the administrator password; what it finds is kept in
/// `~/.diptych/provenance.sqlite`, so each ID is asked about once, ever.
///
/// Without root, the ID can still be matched against the apps installed:
/// every app bundle carries a provenance tag too. It is not a lookup -- an
/// app's bundle carries the tag of whatever installed it as often as its own,
/// so a terminal and every app installed from it share one -- but the list of
/// apps sharing an ID nearly always makes plain where a file came from, and
/// it is said as "the same tag as", never as "made by".
enum Provenance {

    static let xattrName = "com.apple.provenance"

    /// The 8-byte ID, as hex, from an attribute value laid out as described
    /// above. Nil for anything shorter, rather than a guess.
    static func id(of data: Data) -> String? {
        guard data.count >= 11 else { return nil }
        return data.suffix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The table key the ID is.
    static func key(of data: Data) -> Int64? {
        guard data.count >= 11 else { return nil }
        let bytes = Array(data.suffix(8))
        let raw = bytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
        return Int64(bitPattern: raw)
    }

    /// The app, once looked up; otherwise the ID and the installed apps that
    /// carry the same tag.
    @MainActor
    static func describe(_ data: Data) -> String? {
        if let key = key(of: data), case .found(let record)? = Lookup.shared.answers[key] {
            return record.summary
        }
        guard let id = id(of: data) else { return nil }
        let apps = AppIndex.shared.apps(withID: id)
        guard !apps.isEmpty else {
            return "provenance ID \(id) \u{2014} no installed app carries the same tag"
        }
        return "provenance ID \(id) \u{2014} the same tag as "
            + apps.joined(separator: ", ")
    }

    /// What the provenance database says about one app.
    struct Record: Equatable, Sendable {
        let path: String
        let bundleID: String?
        let team: String?
        let signingID: String?
        let since: Date?

        /// "Ghostty (com.mitchellh.ghostty, team 24VZTF6M5V) -- /Applications/
        /// Ghostty.app, tracked since 24 Sep 2026".
        var summary: String {
            // An app's row ends its path with a slash: "/Applications/Ghostty.app/".
            let path = self.path.count > 1 && self.path.hasSuffix("/")
                ? String(self.path.dropLast()) : self.path
            let name = path.hasSuffix(".app")
                ? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                : (path as NSString).lastPathComponent
            var identity: [String] = []
            if let id = bundleID ?? signingID { identity.append(id) }
            if let team { identity.append("team \(team)") }
            var text = "made or last changed by \(name)"
            if !identity.isEmpty { text += " (\(identity.joined(separator: ", ")))" }
            text += " \u{2014} \(NamingTemplate.tilde(path))"
            // A saved answer can outlive the app it names.
            if !FileManager.default.fileExists(atPath: path) { text += " (no longer there)" }
            if let since {
                text += ", tracked since " + since.formatted(date: .abbreviated, time: .omitted)
            }
            return text
        }
    }

    /// Lookups in the provenance database. What was found is saved, and read
    /// back at the next launch; "not found" is kept for the session only, since
    /// a row can appear in the database later.
    @MainActor
    @Observable
    final class Lookup {
        static let shared = Lookup()

        enum Answer: Equatable { case found(Record), notFound }
        private(set) var answers: [Int64: Answer] = [:]

        @ObservationIgnored private let store = SavedLookups()

        private init() {
            for (key, record) in store.all() { answers[key] = .found(record) }
        }

        /// Reads the rows for every key not already known, in one command and
        /// so behind one administrator prompt. Read-only: the database is
        /// opened with `-readonly`, and the keys are numbers, never text.
        func identify(_ keys: [Int64]) -> Privileged.Result {
            let wanted = Array(Set(keys.filter { answers[$0] == nil }))
            guard !wanted.isEmpty else { return .succeeded }
            // The key as text: it is a 19-digit number, and a JSON number that
            // large can come back rounded through a Double -- a different row.
            let query = "select cast(pk as text) as pk, url, bundle_id, team_identifier, "
                + "signing_identifier, "
                + "timestamp from provenance_tracking where pk in ("
                + wanted.map(String.init).joined(separator: ",") + ")"
            let command = "/usr/bin/sqlite3 -readonly -json "
                + "/var/db/SystemPolicyConfiguration/ExecPolicy " + Shell.quoted(query)
            let (result, output) = Privileged.runCapturingOutput(command)
            guard result == .succeeded else { return result }

            let found = Self.records(fromJSON: output ?? "")
            for key in wanted {
                answers[key] = found[key].map(Answer.found) ?? .notFound
            }
            for (key, record) in found { store.save(record, for: key) }
            return .succeeded
        }

        /// The rows `sqlite3 -json` printed. Nothing printed is no rows.
        nonisolated static func records(fromJSON output: String) -> [Int64: Record] {
            var found: [Int64: Record] = [:]
            let rows = (try? JSONSerialization.jsonObject(with: Data(output.utf8)))
                as? [[String: Any]] ?? []
            for row in rows {
                guard let pk = (row["pk"] as? String).flatMap({ Int64($0) }),
                      let path = row["url"] as? String else { continue }
                func text(_ key: String) -> String? {
                    guard let value = row[key] as? String, !value.isEmpty,
                          value != "NOT_A_BUNDLE" else { return nil }
                    return value
                }
                let seconds = (row["timestamp"] as? NSNumber)?.doubleValue
                found[pk] = Record(path: path, bundleID: text("bundle_id"),
                                   team: text("team_identifier"),
                                   signingID: text("signing_identifier"),
                                   since: seconds.map(Date.init(timeIntervalSince1970:)))
            }
            return found
        }
    }

    /// Installed apps by the provenance ID their bundle carries. Read once,
    /// and again when it is more than a minute old: a few hundred `getxattr`
    /// calls, too many to make on every redraw, too few to keep longer.
    @MainActor
    final class AppIndex {
        static let shared = AppIndex()
        private var byID: [String: [String]] = [:]
        private var readAt: Date?

        func apps(withID id: String) -> [String] {
            if readAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true { read() }
            return byID[id] ?? []
        }

        private func read() {
            var found: [String: [String]] = [:]
            let home = FileManager.default.homeDirectoryForCurrentUser
            let folders = [URL(fileURLWithPath: "/Applications"),
                           URL(fileURLWithPath: "/Applications/Utilities"),
                           home.appendingPathComponent("Applications")]
            for folder in folders {
                let entries = (try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: nil)) ?? []
                for app in entries where app.pathExtension == "app" {
                    guard let data = ExtendedAttributes.data(of: app.path, name: xattrName),
                          let id = Provenance.id(of: data) else { continue }
                    found[id, default: []].append(app.deletingPathExtension().lastPathComponent)
                }
            }
            byID = found.mapValues { $0.sorted() }
            readAt = Date()
        }
    }

    /// `~/.diptych/provenance.sqlite`: the answers looked up so far, nothing
    /// else. A database rather than JSON so that adding one answer is one
    /// row, not a rewrite of the file. Anything going wrong with it costs only
    /// a password prompt the next time, so failures are not reported.
    @MainActor
    final class SavedLookups {
        static let url = StateStore.directory.appendingPathComponent("provenance.sqlite")
        private var db: OpaquePointer?

        init(url: URL = SavedLookups.url) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard sqlite3_open(url.path, &db) == SQLITE_OK else {
                sqlite3_close(db)
                db = nil
                return
            }
            sqlite3_exec(db, """
                CREATE TABLE IF NOT EXISTS lookups (
                  pk INTEGER PRIMARY KEY, path TEXT NOT NULL, bundle_id TEXT,
                  team_identifier TEXT, signing_identifier TEXT, since REAL,
                  looked_up REAL NOT NULL)
                """, nil, nil, nil)
        }

        func all() -> [Int64: Record] {
            guard let db else { return [:] }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT pk, path, bundle_id, team_identifier, "
                                     + "signing_identifier, since FROM lookups",
                                     -1, &statement, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(statement) }
            func text(_ column: Int32) -> String? {
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            }
            var found: [Int64: Record] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let path = text(1) else { continue }
                let since = sqlite3_column_type(statement, 5) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                found[sqlite3_column_int64(statement, 0)] = Record(
                    path: path, bundleID: text(2), team: text(3), signingID: text(4), since: since)
            }
            return found
        }

        func save(_ record: Record, for key: Int64) {
            guard let db else { return }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO lookups VALUES (?, ?, ?, ?, ?, ?, ?)",
                                     -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            // SQLITE_TRANSIENT: SQLite copies the text before the Swift string
            // it came from goes away.
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            func bind(_ index: Int32, _ value: String?) {
                if let value { sqlite3_bind_text(statement, index, value, -1, transient) }
                else { sqlite3_bind_null(statement, index) }
            }
            sqlite3_bind_int64(statement, 1, key)
            bind(2, record.path)
            bind(3, record.bundleID)
            bind(4, record.team)
            bind(5, record.signingID)
            if let since = record.since {
                sqlite3_bind_double(statement, 6, since.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 6)
            }
            sqlite3_bind_double(statement, 7, Date().timeIntervalSince1970)
            sqlite3_step(statement)
        }
    }
}
