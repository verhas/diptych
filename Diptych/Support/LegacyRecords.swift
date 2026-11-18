import Foundation

/// Brings what Diptych 1.x kept in JSON files in `~/.diptych` into
/// `LocalDatabase.records`, and deletes each file once it is in.
///
/// Run when the records are first opened, at every start, so that an upgrade
/// from any 1.x to any later version carries on where it left off -- and a
/// file 1.x writes again, run after a later version, is brought in the next
/// time too, its entries winning over older ones.
///
/// A file that cannot be read is left where it is, untouched: deleting it
/// would lose what it holds, and it is tried again at the next start.
/// `config.json` is not one of these: it is read once, at start, and is meant
/// to be edited by hand.
///
/// What each file was, and when, is in `DIPTYCH_STORAGE.md`.
nonisolated enum LegacyRecords {

    /// The files, by the name 1.x gave them.
    static let trashOrigins = "trash-origins.json"
    static let servers = "servers.json"
    static let scriptTimings = "script-timings.json"
    static let scriptApprovals = "scripts-approved.json"
    static let state = "state.json"

    /// The earliest versions wrote the window state as the file `~/.diptych`
    /// itself. Made a folder, with the state in it as `state.json`, which the
    /// import then brings in like any other.
    static func liftPlainFile(at home: URL) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: home.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return }
        let legacy = try? Data(contentsOf: home)
        try? fm.removeItem(at: home)
        try? fm.createDirectory(at: home, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        if let legacy { try? legacy.write(to: home.appendingPathComponent(state)) }
    }

    /// What was brought in, by file name: how many entries each held.
    @discardableResult
    static func importFiles(in folder: URL, into database: LocalDatabase) -> [String: Int] {
        var imported: [String: Int] = [:]
        /// One file: read, stored in one transaction, then deleted.
        func bringStoring(_ name: String, _ store: (Data, LocalDatabase.Connection) throws -> Int) {
            let file = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file) else { return }
            guard let count = try? database.transaction({ try store(data, $0) }) else {
                NSLog("Diptych: \(name) could not be read or stored, and is left as it is")
                return
            }
            try? FileManager.default.removeItem(at: file)
            imported[name] = count
        }
        func bring(_ name: String, _ rows: (Data) throws -> (sql: String, rows: [[LocalDatabase.Value]])) {
            bringStoring(name) { data, connection in
                let (sql, values) = try rows(data)
                guard connection.runEach(sql, values) else {
                    throw LocalDatabase.Failure(description: "\(name) could not be stored")
                }
                return values.count
            }
        }

        bring(trashOrigins) { data in
            let origins = try JSONDecoder().decode([String: String].self, from: data)
            let now = Date().timeIntervalSince1970
            // Only those whose trashed file is still in the Trash.
            let rows = origins.filter { FileManager.default.fileExists(atPath: $0.key) }
                .map { [LocalDatabase.Value.text($0.key), .text($0.value), .real(now)] }
            return (TrashOriginals.insert, rows)
        }
        bring(servers) { data in
            let list = try ServerStore.decoder.decode([KnownServer].self, from: data)
            return (ServerStore.insert, list.map(ServerStore.values))
        }
        bring(scriptTimings) { data in
            let entries = try JSONDecoder().decode([String: ScriptTimings.Entry].self, from: data)
            return (ScriptTimings.upsert, entries.map { ScriptTimings.values($0.key, $0.value) })
        }
        bring(scriptApprovals) { data in
            let list = try JSONDecoder().decode([String].self, from: data)
            let now = Date().timeIntervalSince1970
            return (ScriptCatalogue.approveSQL, list.map { [.text($0), .real(now)] })
        }
        bringStoring(state) { data, connection in
            let state = try JSONDecoder().decode(DiptychState.self, from: data)
            StateStore.write(state, in: connection)
            return state.windows.count
        }
        return imported
    }
}
