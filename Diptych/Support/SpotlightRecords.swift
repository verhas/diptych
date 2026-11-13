import AppKit
import CoreSpotlight
import os
import SQLite3
import UniformTypeIdentifiers

/// Diptych's own records in Spotlight, each behind a switch of its own in
/// Settings, both off until switched on: Spotlight is read by anyone at the
/// Mac and by Siri, a different decision from a private file.
///
/// - **Files**: every file a pane shows, as a record carrying what Diptych
///   knows and Spotlight does not -- the town a picture was taken near, from
///   Diptych's own list of towns, with its region and country; the camera and
///   lens; when it was taken. So "Budapest" or "Fujifilm" in Spotlight finds
///   the pictures, as Diptych records, next to the files themselves. Opening
///   one shows the file in a Diptych pane.
/// - **The journal**: each entry, so "moved tax" finds what was done; opening
///   one opens the Journal on it. They expire when the journal would purge them.
///
/// Never a server's files, an archive's, or the Trash's. A file is indexed
/// again only when its date or size changes: what was indexed is kept in
/// `~/.diptych/spotlight.sqlite`.
@MainActor
final class SpotlightRecords {

    static let shared = SpotlightRecords()

    nonisolated static let filesDomain = "dev.verhas.Diptych.files"
    nonisolated static let journalDomain = "dev.verhas.Diptych.journal"
    nonisolated static let filePrefix = "file:"
    nonisolated static let journalPrefix = "journal:"
    /// Only what was done to files, and runs: what was looked at, shown,
    /// set or asked would flood Spotlight.
    nonisolated static let mirrored: Set<Journal.Category> = [.change, .run]

    /// What the journal's queue may read without the main actor.
    nonisolated private static let journalMirrored = OSAllocatedUnfairLock(initialState: false)
    nonisolated private static let journalDays = OSAllocatedUnfairLock(initialState: 90)

    nonisolated(unsafe) private let index: CSSearchableIndex
    private let queue = DispatchQueue(label: "Diptych.Spotlight", qos: .utility)
    nonisolated(unsafe) private let store: IndexedFiles
    /// Folders shown and not yet looked at, by path; looked at a moment
    /// later, so a folder refreshed five times in a second is read once.
    private var pending: [String: Shown] = [:]
    private var flushTask: Task<Void, Never>?
    private var started = false

    /// A listing, as a pane showed it.
    struct Shown: Sendable {
        var folder: URL
        /// The listing is the folder's whole content, so a record of a file
        /// no longer in it can go. Not for a flat view's or a filtered one.
        var complete: Bool
        var files: [Snapshot]
    }

    struct Snapshot: Sendable, Hashable {
        var url: URL
        var name: String
        var isDirectory: Bool
        var size: Int64
        var modified: Date
        var created: Date
        var tags: [String]
    }

    init(index: CSSearchableIndex = CSSearchableIndex(name: "Diptych"),
         store: IndexedFiles = IndexedFiles()) {
        self.index = index
        self.store = store
    }

    private var configuration: Configuration { ConfigStore.shared.configuration }

    // MARK: - Switches

    /// At launch: the journal's entries are passed on as they are written.
    func start() {
        guard !started else { return }
        started = true
        Journal.shared.onRecord = { [weak self] entry, _ in
            guard Self.journalMirrored.withLock({ $0 }),
                  Self.mirrored.contains(entry.category) else { return }
            let item = Self.item(for: entry, keptDays: Self.journalDays.withLock { $0 })
            self?.index.indexSearchableItems([item])
        }
        Journal.shared.onDelete = { [weak self] ids in
            guard let self else { return }
            if let ids {
                self.index.deleteSearchableItems(withIdentifiers: ids.map { Self.journalPrefix + String($0) })
            } else {
                self.index.deleteSearchableItems(withDomainIdentifiers: [Self.journalDomain])
            }
        }
        settingsChanged()
    }

    private var wasMirroringJournal = false
    private var wasRecordingFiles = false

    /// Called when Settings change: a switch turned off takes its records
    /// out of Spotlight; the journal's turned on puts what it already holds in.
    func settingsChanged() {
        let journal = configuration.journalInSpotlight && configuration.journalEnabled
        Self.journalMirrored.withLock { $0 = journal }
        let days = configuration.journalKeepDays
        Self.journalDays.withLock { $0 = days }
        if journal && !wasMirroringJournal {
            mirrorWholeJournal()
        } else if !journal && wasMirroringJournal {
            index.deleteSearchableItems(withDomainIdentifiers: [Self.journalDomain])
        }
        wasMirroringJournal = journal

        let files = configuration.spotlightFileRecords
        if !files && wasRecordingFiles { removeFileRecords() }
        wasRecordingFiles = files
    }

    /// Settings ▸ Remove from Spotlight: every file record, whatever the switch.
    func removeFileRecords() {
        pending.removeAll()
        index.deleteSearchableItems(withDomainIdentifiers: [Self.filesDomain])
        queue.async { [store] in store.removeAll() }
    }

    private func mirrorWholeJournal() {
        let days = configuration.journalKeepDays
        queue.async { [index] in
            var query = Journal.Query()
            query.limit = 100_000
            query.categories = Array(Self.mirrored)
            let entries = Journal.shared.search(query)
            for start in stride(from: 0, to: entries.count, by: 500) {
                let slice = entries[start..<min(start + 500, entries.count)]
                index.indexSearchableItems(slice.map { Self.item(for: $0, keptDays: days) })
            }
        }
    }

    // MARK: - Files

    /// A pane has listed a folder. Off, on a server, in an archive or in the
    /// Trash: nothing.
    func paneShowed(folder: URL, items: [FileItem], complete: Bool) {
        guard configuration.spotlightFileRecords, Self.isIndexable(folder) else { return }
        let files = items.filter { !$0.isParent && Self.isIndexable($0.url) }.map {
            Snapshot(url: $0.url, name: $0.name, isDirectory: $0.isDirectory && !$0.isPackage,
                     size: $0.byteSize, modified: $0.modified, created: $0.created, tags: $0.tags)
        }
        pending[folder.path] = Shown(folder: folder, complete: complete, files: files)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.flush()
        }
    }

    private func flush() {
        flushTask = nil
        let shown = Array(pending.values)
        pending.removeAll()
        guard configuration.spotlightFileRecords else { return }
        queue.async { [self] in
            for listing in shown { record(listing) }
        }
    }

    /// On the queue: what changed since it was last indexed goes to
    /// Spotlight; what is gone from a whole listing comes out. A flat view's
    /// files are in many folders, each compared with what it had.
    nonisolated private func record(_ shown: Shown) {
        let byFolder = Dictionary(grouping: shown.files) { $0.url.deletingLastPathComponent().path }
        var folders = Set(byFolder.keys)
        if shown.complete { folders.insert(shown.folder.path) }
        var changed: [Snapshot] = []
        for folder in folders {
            let files = byFolder[folder] ?? []
            let known = store.indexed(in: folder)
            for file in files {
                let was = known[file.url.path]
                if was?.modified != file.modified.timeIntervalSince1970 || was?.size != file.size {
                    changed.append(file)
                }
            }
            if shown.complete && folder == shown.folder.path {
                let present = Set(files.map(\.url.path))
                let gone = known.keys.filter { !present.contains($0) }
                if !gone.isEmpty {
                    index.deleteSearchableItems(withIdentifiers: gone.map { Self.filePrefix + $0 })
                    store.remove(gone)
                }
            }
        }
        for start in stride(from: 0, to: changed.count, by: 100) {
            let batch = Array(changed[start..<min(start + 100, changed.count)])
            index.indexSearchableItems(batch.map { Self.item(for: $0) })
            store.save(batch)
        }
    }

    /// Never a server's, an archive's, the Trash's, or Diptych's own.
    nonisolated static func isIndexable(_ url: URL) -> Bool {
        let path = url.path
        if RemoteBrowsing.isInside(url) || ArchiveBrowsing.isInside(url) { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for excluded in ["/.Trash", "/.diptych", "/Library/Caches"]
        where path.hasPrefix(home + excluded) {
            return false
        }
        return !path.contains("/.Trashes/")
    }

    // MARK: - Items

    nonisolated static func item(for file: Snapshot) -> CSSearchableItem {
        let type = file.isDirectory ? UTType.folder
            : UTType(filenameExtension: file.url.pathExtension) ?? .data
        let set = CSSearchableItemAttributeSet(contentType: type)
        set.title = file.name
        set.displayName = file.name
        set.contentURL = file.url
        set.contentModificationDate = file.modified
        set.contentCreationDate = file.created
        if !file.isDirectory { set.fileSize = NSNumber(value: file.size) }
        var keywords = file.tags
        var said: [String] = []

        if !file.isDirectory, MediaInfo.looksLikeMedia(file.url), let media = MediaReader.read(file.url) {
            describe(media, in: set, keywords: &keywords, said: &said)
            if media.kind == .image { set.thumbnailURL = file.url }
        }
        if !file.tags.isEmpty { said.append("Tagged " + file.tags.joined(separator: ", ")) }
        said.append("In " + (file.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        set.contentDescription = said.joined(separator: " \u{00B7} ")
        set.keywords = Array(Set(keywords.filter { !$0.isEmpty })).sorted()

        let item = CSSearchableItem(uniqueIdentifier: filePrefix + file.url.path,
                                    domainIdentifier: filesDomain, attributeSet: set)
        // Not the 30 days Spotlight gives by default: a record stays until
        // its file is gone from a listing or the switch is turned off.
        item.expirationDate = .distantFuture
        return item
    }

    /// What a picture or a video says about itself, as Spotlight's own
    /// attributes and as words: the town, the camera, when.
    nonisolated static func describe(_ media: MediaInfo, in set: CSSearchableItemAttributeSet,
                                     keywords: inout [String], said: inout [String]) {
        if let city = media.city {
            set.city = city
            set.stateOrProvince = media.state
            set.country = media.country
            set.namedLocation = [city, media.state, media.country].compactMap { $0 }.joined(separator: ", ")
            keywords += [city, media.state, media.country, media.countryCode].compactMap { $0 }
            let written = media.writtenCity != nil
            said.append((written ? "Taken in " : "Taken near ") + (set.namedLocation ?? city))
        }
        if let latitude = media.latitude, let longitude = media.longitude {
            set.latitude = NSNumber(value: latitude)
            set.longitude = NSNumber(value: longitude)
        }
        if let altitude = media.altitude { set.altitude = NSNumber(value: altitude) }
        if let camera = media.camera {
            set.acquisitionModel = camera
            keywords.append(camera)
            said.append(camera)
        }
        if let lens = media.lens {
            set.lensModel = lens
            keywords.append(lens)
        }
        if let taken = media.taken {
            set.contentCreationDate = taken
            said.append(taken.formatted(date: .long, time: .shortened))
        }
        if let iso = media.iso { set.isoSpeed = NSNumber(value: iso) }
        if let aperture = media.aperture { set.fNumber = NSNumber(value: aperture) }
        if let shutter = media.shutter { set.exposureTime = NSNumber(value: shutter) }
        if let focal = media.focal { set.focalLength = NSNumber(value: focal) }
        if let focal35 = media.focal35 { set.focalLength35mm = NSNumber(value: focal35) }
        if let width = media.width { set.pixelWidth = NSNumber(value: width) }
        if let height = media.height { set.pixelHeight = NSNumber(value: height) }
        if let duration = media.duration { set.duration = NSNumber(value: duration) }
        if let rating = media.rating { set.rating = NSNumber(value: rating) }
        if let artist = media.artist {
            set.authorNames = [artist]
            keywords.append(artist)
        }
        if let copyright = media.copyright { set.copyright = copyright }
        if let description = media.description {
            keywords.append(description)
            said.append(description)
        }
    }

    nonisolated static func item(for entry: Journal.Entry, keptDays: Int) -> CSSearchableItem {
        let set = CSSearchableItemAttributeSet(contentType: .text)
        set.title = "\(entry.kind) \u{2014} " + entry.time.formatted(date: .abbreviated, time: .shortened)
        set.displayName = set.title
        set.contentDescription = entry.told
        set.contentCreationDate = entry.time
        set.keywords = [entry.kind, entry.origin.title, "Diptych journal"]
            + (entry.folder.map { [($0 as NSString).lastPathComponent, ($0 as NSString).abbreviatingWithTildeInPath] } ?? [])
        let item = CSSearchableItem(uniqueIdentifier: journalPrefix + String(entry.id),
                                    domainIdentifier: journalDomain, attributeSet: set)
        item.expirationDate = keptDays > 0
            ? entry.time.addingTimeInterval(Double(keptDays) * 86_400) : .distantFuture
        return item
    }

    // MARK: - Opened from Spotlight

    /// A record chosen in Spotlight: a file is shown in a pane, a journal
    /// entry opens the Journal on it. False for an identifier not Diptych's.
    @discardableResult
    static func open(_ identifier: String) -> Bool {
        if identifier.hasPrefix(filePrefix) {
            let path = String(identifier.dropFirst(filePrefix.count))
            guard FileManager.default.fileExists(atPath: path) else {
                // Gone since: its record goes too.
                shared.index.deleteSearchableItems(withIdentifiers: [identifier])
                return true
            }
            FileViewer.shared.reveal([URL(fileURLWithPath: path)])
            return true
        }
        if identifier.hasPrefix(journalPrefix), let id = Int64(identifier.dropFirst(journalPrefix.count)) {
            JournalWindowModel.open(entry: id)
            return true
        }
        return false
    }
}

/// What has been put into Spotlight, and as which version of the file:
/// a file whose date and size are the same is not read again.
nonisolated final class IndexedFiles: @unchecked Sendable {

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".diptych/spotlight.sqlite")

    private var db: OpaquePointer?

    init(url: URL = IndexedFiles.url) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_exec(db, """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS files (
              path TEXT PRIMARY KEY, folder TEXT NOT NULL, modified REAL NOT NULL,
              size INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS files_folder ON files(folder);
            """, nil, nil, nil)
    }

    deinit { sqlite3_close(db) }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func indexed(in folder: String) -> [String: (modified: Double, size: Int64)] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT path, modified, size FROM files WHERE folder = ?",
                                 -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, folder, -1, Self.transient)
        var found: [String: (Double, Int64)] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) else { continue }
            found[path] = (sqlite3_column_double(statement, 1), sqlite3_column_int64(statement, 2))
        }
        return found
    }

    func save(_ files: [SpotlightRecords.Snapshot]) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO files VALUES (?, ?, ?, ?)",
                                 -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for file in files {
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, file.url.path, -1, Self.transient)
            sqlite3_bind_text(statement, 2, file.url.deletingLastPathComponent().path, -1, Self.transient)
            sqlite3_bind_double(statement, 3, file.modified.timeIntervalSince1970)
            sqlite3_bind_int64(statement, 4, file.size)
            sqlite3_step(statement)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    func remove(_ paths: [String]) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM files WHERE path = ?", -1, &statement, nil) == SQLITE_OK
        else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for path in paths {
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, path, -1, Self.transient)
            sqlite3_step(statement)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    func removeAll() {
        sqlite3_exec(db, "DELETE FROM files", nil, nil, nil)
    }
}
