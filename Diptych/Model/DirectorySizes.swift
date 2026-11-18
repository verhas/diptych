import Foundation
import Observation

/// How much is in a folder, everything under it counted, worked out when
/// asked -- Calculate Directory Sizes -- and kept: in memory while Diptych
/// runs, and in the `folder_size` table of `LocalDatabase.cache`, each total
/// with when it was measured and whether it was still growing then.
///
/// A total kept from before is shown again -- in a later session, or for a
/// folder not asked about in this one -- fading as it ages, since it was
/// true when measured and not necessarily now. After Settings ▸ Behaviour ▸
/// Folder Sizes' days it is no longer shown, and is purged. Asking again
/// measures the folder again, starting from what was kept.
///
/// An estimate, given early and made better. A folder is read for its own
/// files and the folders in it; a folder in it already known counts at what
/// it was, one not yet known at nothing, and each is read in its turn after.
/// Whenever a folder's total changes, every folder above it that has one
/// changes by the same amount. So a folder shows a number as soon as its own
/// files are counted, and the number grows -- or settles -- as what is under
/// it is read, and asking again for a folder already counted shows the old
/// total until the new one has replaced it.
///
/// One reader per volume, so that two calculations never compete for one
/// disk; a calculation asked for while another is under way on the same
/// volume waits for it. A folder on another volume -- something mounted
/// inside -- is not counted.
@MainActor
@Observable
final class DirectorySizes {

    static let shared = DirectorySizes()

    /// What a folder's Size cell shows.
    enum Shown: Equatable {
        /// Being worked out, nothing known yet: `??`.
        case waiting
        /// A total that is about to change: from before, or still growing.
        case updating(Int64)
        /// Worked out, and nothing under it is waiting.
        case done(Int64)
        /// Not known, and not knowable without downloading everything in it:
        /// a folder on a server. Shown as `???`, never as a zero.
        case unknown
        /// Measured before, not in this session: everything in it when
        /// `complete`, an estimate caught part way otherwise.
        case remembered(Int64, complete: Bool)

        /// Said beside it where there is room: the Info window.
        var note: String {
            switch self {
            case .waiting:  "being worked out"
            case .updating: "an estimate, being worked out"
            case .done:     "everything in it"
            case .unknown:  "not known: finding out would mean downloading everything in it"
            case .remembered(_, let complete):
                complete ? "everything in it, when it was measured" : "an estimate, measured part way"
            }
        }

        var text: String {
            switch self {
            case .waiting: "??"
            case .unknown: "???"
            case .updating(let size), .done(let size), .remembered(let size, _):
                ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            }
        }
    }

    /// Bumped whenever the totals have changed, at most a few times a
    /// second: what makes a cell that showed one ask again.
    private(set) var revision = 0

    @ObservationIgnored nonisolated let store = Store()

    private init() {
        store.changed = {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { DirectorySizes.shared.revision += 1 }
            }
        }
        // Fading goes on with nothing else changing: the cells look again
        // every few minutes.
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            MainActor.assumeIsolated { DirectorySizes.shared.revision += 1 }
        }
    }

    /// How long a total is shown, from the setting.
    static var keepSeconds: TimeInterval {
        TimeInterval(max(1, ConfigStore.shared.configuration.directorySizeKeepDays)) * 86_400
    }

    /// The folder's total as it stands; nil when it was never asked for, or
    /// was measured longer ago than the setting keeps it.
    func shown(for url: URL) -> Shown? {
        _ = revision
        guard let shown = store.shown(url.path) else { return nil }
        if let measured = store.measured(url.path), Date().timeIntervalSince(measured) > Self.keepSeconds {
            return nil
        }
        return shown
    }

    /// How fresh the folder's total is: 1 when just measured, down to 0.3 at
    /// the end of the time the setting keeps it -- how strongly it is drawn.
    func freshness(for url: URL) -> Double {
        _ = revision
        guard let measured = store.measured(url.path) else { return 1 }
        let age = max(0, Date().timeIntervalSince(measured)) / Self.keepSeconds
        return max(0.3, 1 - 0.7 * min(1, age))
    }

    /// When the folder's total was measured, if there is one.
    func measured(for url: URL) -> Date? {
        _ = revision
        return store.measured(url.path)
    }

    /// The kept totals older than the setting allows, deleted.
    static func purgeExpired() {
        let before = Date().addingTimeInterval(-keepSeconds)
        let store = shared.store
        DispatchQueue.global(qos: .utility).async { store.purge(measuredBefore: before) }
    }

    /// The folders whose size is not known, as opposed to not yet worked out.
    func markUnknown(_ folders: [URL]) {
        store.markUnknown(folders.map(\.path))
    }

    /// Works out the size of each of these folders, after whatever is being
    /// worked out on their volume already.
    func calculate(_ folders: [URL]) {
        store.calculate(folders.map(\.path))
    }

    /// Every total forgotten -- kept ones too -- and every calculation
    /// stopped: folders show `--` again.
    func clear() {
        store.clear()
    }

    /// True when there is a total, or one being worked out, to forget.
    var isEmpty: Bool {
        _ = revision
        return store.isEmpty
    }

    /// The folders of a pane's rows, whose sizes Calculate Directory Sizes
    /// works out.
    static func folders(in rows: [FileItem]) -> [URL] {
        rows.filter { $0.isDirectory && !$0.isParent && !$0.isSymlink }.map(\.url)
    }

    // MARK: - The work

    nonisolated final class Store: @unchecked Sendable {

        struct Entry {
            /// Everything under it, as far as known; nil before it is read.
            var size: Int64?
            /// When `size` was last set.
            var measured = Date.distantPast
            /// How many readings at or under it are still to come.
            var pending = 0
            let device: dev_t
            /// The folders in it when it was last read.
            var folders: [String] = []
            /// Not knowable here: shown as unknown, whatever is or is not read.
            var unknown = false
        }

        /// One folder to read, and the folders above it whose `pending`
        /// counted it.
        private struct Reading {
            let path: String
            let above: [String]
        }

        /// What one request asked for, and what reading it led to, in the
        /// order it is read: breadth first, so that every folder asked for
        /// shows a number soon.
        private final class Job: @unchecked Sendable {
            var readings: [Reading] = []
            var next = 0
            var queued: Set<String> = []
            var isEmpty: Bool { next >= readings.count }
        }

        /// A volume's reader and what it has to do.
        private final class Worker: @unchecked Sendable {
            let queue: DispatchQueue
            var jobs: [Job] = []
            var running = false
            init(device: dev_t) {
                queue = DispatchQueue(label: "Diptych.DirectorySizes.\(device)", qos: .utility)
            }
        }

        /// A total kept from before.
        struct Remembered {
            let size: Int64
            let measured: Date
            let complete: Bool
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        /// Where totals are kept; nil keeps them in memory only.
        private let database: LocalDatabase?
        /// Kept totals read so far, by folder, and the folders whose
        /// children have been read: one query for a folder's children.
        private var remembered: [String: Remembered] = [:]
        /// The folders whose children have been read, and those children.
        private var keptChildren: [String: [String]] = [:]
        /// Whether anything at all is kept.
        private var anythingKept = false
        /// Folders whose total changed since it was last written.
        private var dirty: Set<String> = []
        private var workers: [dev_t: Worker] = [:]
        private var publishing = false
        /// Moved on by Clear: a folder read before it is not recorded.
        private var generation = 0
        /// Told when totals have changed; not more than ten times a second.
        var changed: (@Sendable () -> Void)?

        init(database: LocalDatabase? = .cache) {
            self.database = database
            anythingKept = database?.access { connection in
                connection.rows("SELECT EXISTS (SELECT 1 FROM folder_size)") { $0.int(0) == 1 }.first
            } ?? false
        }

        /// Locked. The kept total of a folder, its parent's kept children
        /// read first if they were not.
        private func rememberedTotal(_ path: String) -> Remembered? {
            guard database != nil, anythingKept else { return nil }
            loadChildren(of: (path as NSString).deletingLastPathComponent)
            return remembered[path]
        }

        /// Locked. The kept totals of the folders in `parent`, read once.
        @discardableResult
        private func loadChildren(of parent: String) -> [String] {
            guard let database, anythingKept else { return [] }
            if let known = keptChildren[parent] { return known }
            let rows = database.access { connection in
                connection.rows("SELECT path, size, measured_at, complete FROM folder_size WHERE parent = ?",
                                .text(parent)) { row in
                    (row.text(0) ?? "", Remembered(size: row.int(1) ?? 0,
                                                   measured: Date(timeIntervalSince1970: row.real(2) ?? 0),
                                                   complete: row.int(3) == 1))
                }
            }
            for (folder, kept) in rows { remembered[folder] = kept }
            keptChildren[parent] = rows.map(\.0)
            return rows.map(\.0)
        }

        /// When the folder's total was measured: this session's, or a kept one.
        func measured(_ path: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            let key = Self.key(path)
            if let entry = entries[key], entry.size != nil { return entry.measured }
            if entries[key]?.unknown == true { return nil }
            return rememberedTotal(key)?.measured
        }

        /// Kept totals measured before `date`, deleted.
        func purge(measuredBefore date: Date) {
            database?.access {
                $0.run("DELETE FROM folder_size WHERE measured_at < ?", .real(date.timeIntervalSince1970))
            }
            lock.lock()
            remembered = remembered.filter { $0.value.measured >= date }
            keptChildren = [:]
            lock.unlock()
            publish()
        }

        /// What changed since the last time, written. Off the lock while it
        /// writes; called after each publication.
        private func flush() {
            guard let database else { return }
            lock.lock()
            let rows: [[LocalDatabase.Value]] = dirty.compactMap { path in
                guard let entry = entries[path], let size = entry.size, !entry.unknown else { return nil }
                return [.text(path), .text((path as NSString).deletingLastPathComponent), .int(size),
                        .real(entry.measured.timeIntervalSince1970), .int(entry.pending == 0 ? 1 : 0)]
            }
            dirty = []
            if !rows.isEmpty { anythingKept = true }
            lock.unlock()
            guard !rows.isEmpty else { return }
            _ = try? database.transaction { connection in
                connection.runEach("""
                    INSERT OR REPLACE INTO folder_size (path, parent, size, measured_at, complete)
                    VALUES (?, ?, ?, ?, ?)
                    """, rows)
            }
        }

        func shown(_ path: String) -> Shown? {
            lock.lock()
            defer { lock.unlock() }
            let key = Self.key(path)
            if let entry = entries[key] {
                if entry.unknown { return .unknown }
                switch (entry.size, entry.pending) {
                case (nil, 0):            break
                case (nil, _):            return .waiting
                case (let size?, 0):      return .done(size)
                case (let size?, _):      return .updating(size)
                }
            }
            return rememberedTotal(key).map { .remembered($0.size, complete: $0.complete) }
        }

        /// The total as it stands, waiting or not.
        func size(_ path: String) -> Int64? {
            lock.lock()
            defer { lock.unlock() }
            let key = Self.key(path)
            return entries[key]?.size ?? rememberedTotal(key)?.size
        }

        /// The total of each of these folders known now, for sorting by it:
        /// kept ones too, when measured after `since`.
        func sizes(_ paths: [String], since: Date = .distantPast) -> [String: Int64] {
            lock.lock()
            defer { lock.unlock() }
            var sizes: [String: Int64] = [:]
            for path in paths {
                let key = Self.key(path)
                if let entry = entries[key], let size = entry.size {
                    if entry.measured >= since { sizes[path] = size }
                } else if let kept = rememberedTotal(key), kept.measured >= since {
                    sizes[path] = kept.size
                }
            }
            return sizes
        }

        /// Nothing worked out, being worked out, or kept.
        var isEmpty: Bool {
            lock.lock()
            defer { lock.unlock() }
            return entries.isEmpty && !anythingKept
        }

        func markUnknown(_ paths: [String]) {
            lock.lock()
            for path in paths {
                entries[Self.key(path)] = Entry(size: nil, pending: 0, device: 0, folders: [], unknown: true)
            }
            lock.unlock()
            publish()
        }

        func clear() {
            lock.lock()
            entries = [:]
            remembered = [:]
            keptChildren = [:]
            dirty = []
            anythingKept = false
            for worker in workers.values { worker.jobs = [] }
            generation += 1
            database?.access { $0.run("DELETE FROM folder_size") }
            lock.unlock()
            publish()
        }

        /// True while anything is still to be read.
        var isWorking: Bool {
            lock.lock()
            defer { lock.unlock() }
            return workers.values.contains { $0.running }
        }

        func calculate(_ paths: [String]) {
            var byDevice: [(dev_t, [String])] = []
            for path in paths.map(Self.key) {
                var status = stat()
                guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { continue }
                if let at = byDevice.firstIndex(where: { $0.0 == status.st_dev }) {
                    byDevice[at].1.append(path)
                } else {
                    byDevice.append((status.st_dev, [path]))
                }
            }
            lock.lock()
            for (device, paths) in byDevice {
                let worker = workers[device] ?? Worker(device: device)
                workers[device] = worker
                let job = Job()
                for path in paths { schedule(path, device: device, in: job) }
                worker.jobs.append(job)
                if !worker.running {
                    worker.running = true
                    worker.queue.async { [self] in drain(worker, device: device) }
                }
            }
            lock.unlock()
            publish()
        }

        /// Locked. To be read in this job, unless it already is to be.
        private func schedule(_ path: String, device: dev_t, in job: Job) {
            guard job.queued.insert(path).inserted else { return }
            var above: [String] = []
            for folder in Self.ancestors(of: path) where entries[folder]?.device == device {
                entries[folder]!.pending += 1
                above.append(folder)
            }
            if entries[path] == nil {
                // Measured before: shown as it was until it is read again, and
                // counted at that in the folders above meanwhile.
                var entry = Entry(device: device)
                if let kept = rememberedTotal(path) {
                    entry.size = kept.size
                    entry.measured = kept.measured
                }
                entries[path] = entry
            }
            entries[path]!.pending += 1
            job.readings.append(Reading(path: path, above: above))
        }

        private func drain(_ worker: Worker, device: dev_t) {
            while true {
                lock.lock()
                while let job = worker.jobs.first, job.isEmpty { worker.jobs.removeFirst() }
                guard let job = worker.jobs.first else {
                    worker.running = false
                    lock.unlock()
                    publish()
                    return
                }
                let reading = job.readings[job.next]
                job.next += 1
                let started = generation
                lock.unlock()

                let found = Self.read(reading.path, device: device)

                lock.lock()
                if generation == started { record(found, of: reading, device: device, in: job) }
                lock.unlock()
                publish()
            }
        }

        /// Locked. What a folder was found to hold: its total set, the
        /// difference carried up, and the folders in it to be read next.
        private func record(_ found: (own: Int64, folders: [String])?, of reading: Reading,
                            device: dev_t, in job: Job) {
            let path = reading.path
            let old = entries[path]?.size ?? 0
            if let found {
                for folder in found.folders { schedule(folder, device: device, in: job) }
                let new = found.own + found.folders.reduce(0) { $0 + (entries[$1]?.size ?? 0) }
                let still = Set(found.folders)
                for gone in entries[path]?.folders ?? [] where !still.contains(gone) {
                    forget(gone)
                }
                // Kept from an earlier session, which this one never read.
                for gone in loadChildren(of: path) where !still.contains(gone) {
                    forget(gone)
                }
                entries[path]?.size = new
                entries[path]?.measured = Date()
                entries[path]?.folders = found.folders
                dirty.insert(path)
                carry(new - old, above: path, device: device)
            } else {
                // Gone: what it added to the folders above goes with it.
                carry(-old, above: path, device: device)
                for folder in entries[path]?.folders ?? [] { drop(folder) }
                entries[path]?.size = nil
                entries[path]?.folders = []
                unkeep(path)
            }
            entries[path]?.pending -= 1
            for folder in reading.above where entries[folder] != nil {
                entries[folder]!.pending = max(0, entries[folder]!.pending - 1)
                // Its total may be complete now: written again with that.
                dirty.insert(folder)
            }
            if let entry = entries[path], entry.size == nil, entry.pending == 0 {
                entries[path] = nil
            }
        }

        /// Locked. A folder no longer there, and everything known under it.
        private func forget(_ path: String) {
            drop(path)
            unkeep(path)
        }

        /// Locked. The folder and everything under it, out of this session's totals.
        private func drop(_ path: String) {
            guard let entry = entries.removeValue(forKey: path) else { return }
            for folder in entry.folders { drop(folder) }
        }

        /// Locked. Gone from the disk, so from what is kept, with all under it.
        private func unkeep(_ path: String) {
            let prefix = path == "/" ? "/" : path + "/"
            remembered = remembered.filter { $0.key != path && !$0.key.hasPrefix(prefix) }
            keptChildren = keptChildren.filter { $0.key != path && !$0.key.hasPrefix(prefix) }
            let parent = (path as NSString).deletingLastPathComponent
            keptChildren[parent]?.removeAll { $0 == path }
            dirty.remove(path)
            database?.access {
                $0.run("DELETE FROM folder_size WHERE path = ? OR substr(path, 1, ?) = ?",
                       // SQLite counts code points, not what Swift calls characters.
                       .text(path), .int(Int64(prefix.unicodeScalars.count)), .text(prefix))
            }
        }

        /// Locked. Every folder above with a total has the change in it too.
        private func carry(_ difference: Int64, above path: String, device: dev_t) {
            guard difference != 0 else { return }
            for folder in Self.ancestors(of: path) {
                guard let entry = entries[folder], entry.device == device,
                      let size = entry.size else { continue }
                entries[folder]!.size = size + difference
                entries[folder]!.measured = Date()
                dirty.insert(folder)
            }
        }

        private func publish() {
            lock.lock()
            let first = !publishing
            publishing = true
            lock.unlock()
            guard first else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
                lock.lock()
                publishing = false
                lock.unlock()
                flush()
                changed?()
            }
        }

        // MARK: - Reading a folder

        /// The bytes of the files directly in it, and the folders in it on
        /// the same volume. Nil when it is not there any more; nothing in it
        /// when it cannot be read.
        static func read(_ path: String, device: dev_t) -> (own: Int64, folders: [String])? {
            guard let folder = opendir(path) else {
                return errno == ENOENT || errno == ENOTDIR ? nil : (0, [])
            }
            defer { closedir(folder) }
            let descriptor = dirfd(folder)
            let prefix = path == "/" ? "/" : path + "/"
            var own: Int64 = 0
            var folders: [String] = []
            while let entry = readdir(folder) {
                var name = entry.pointee.d_name
                let length = Int(entry.pointee.d_namlen)
                let found: (Int64, String?)? = withUnsafePointer(to: &name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: length + 1) { name in
                        if length == 1, name[0] == 46 { return nil }
                        if length == 2, name[0] == 46, name[1] == 46 { return nil }
                        var status = stat()
                        guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0
                        else { return nil }
                        switch status.st_mode & S_IFMT {
                        case S_IFREG:
                            return (Int64(status.st_size), nil)
                        case S_IFDIR where status.st_dev == device:
                            return (0, prefix + String(cString: name))
                        default:
                            return nil
                        }
                    }
                }
                guard let (bytes, inner) = found else { continue }
                own += bytes
                if let inner { folders.append(inner) }
            }
            return (own, folders)
        }

        /// A folder as the cache knows it: no trailing slash.
        static func key(_ path: String) -> String {
            path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }

        static func ancestors(of path: String) -> [String] {
            var folders: [String] = []
            var current = path
            while current != "/" {
                current = (current as NSString).deletingLastPathComponent
                if current.isEmpty { break }
                folders.append(current)
            }
            return folders
        }
    }
}
