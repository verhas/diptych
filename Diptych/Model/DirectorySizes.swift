import Foundation
import Observation

/// How much is in a folder, everything under it counted, worked out when
/// asked -- Calculate Directory Sizes -- and kept in memory for as long as
/// Diptych runs, never on disk.
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

        /// Said beside it where there is room: the Info window.
        var note: String {
            switch self {
            case .waiting:  "being worked out"
            case .updating: "an estimate, being worked out"
            case .done:     "everything in it"
            }
        }

        var text: String {
            switch self {
            case .waiting: "??"
            case .updating(let size), .done(let size):
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
    }

    /// The folder's total as it stands, nil when it was never asked for.
    func shown(for url: URL) -> Shown? {
        _ = revision
        return store.shown(url.path)
    }

    /// Works out the size of each of these folders, after whatever is being
    /// worked out on their volume already.
    func calculate(_ folders: [URL]) {
        store.calculate(folders.map(\.path))
    }

    /// Every total forgotten and every calculation stopped: folders show
    /// `--` again.
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
            /// How many readings at or under it are still to come.
            var pending = 0
            let device: dev_t
            /// The folders in it when it was last read.
            var folders: [String] = []
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

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        private var workers: [dev_t: Worker] = [:]
        private var publishing = false
        /// Moved on by Clear: a folder read before it is not recorded.
        private var generation = 0
        /// Told when totals have changed; not more than ten times a second.
        var changed: (@Sendable () -> Void)?

        func shown(_ path: String) -> Shown? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[Self.key(path)] else { return nil }
            switch (entry.size, entry.pending) {
            case (nil, 0):            return nil
            case (nil, _):            return .waiting
            case (let size?, 0):      return .done(size)
            case (let size?, _):      return .updating(size)
            }
        }

        /// The total as it stands, waiting or not.
        func size(_ path: String) -> Int64? {
            lock.lock()
            defer { lock.unlock() }
            return entries[Self.key(path)]?.size
        }

        /// The total of each of these folders known now, for sorting by it.
        func sizes(_ paths: [String]) -> [String: Int64] {
            lock.lock()
            defer { lock.unlock() }
            var sizes: [String: Int64] = [:]
            for path in paths {
                if let size = entries[Self.key(path)]?.size { sizes[path] = size }
            }
            return sizes
        }

        var isEmpty: Bool {
            lock.lock()
            defer { lock.unlock() }
            return entries.isEmpty
        }

        func clear() {
            lock.lock()
            entries = [:]
            for worker in workers.values { worker.jobs = [] }
            generation += 1
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
            entries[path, default: Entry(device: device)].pending += 1
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
                entries[path]?.size = new
                entries[path]?.folders = found.folders
                carry(new - old, above: path, device: device)
            } else {
                // Gone: what it added to the folders above goes with it.
                carry(-old, above: path, device: device)
                for folder in entries[path]?.folders ?? [] { forget(folder) }
                entries[path]?.size = nil
                entries[path]?.folders = []
            }
            entries[path]?.pending -= 1
            for folder in reading.above where entries[folder] != nil {
                entries[folder]!.pending = max(0, entries[folder]!.pending - 1)
            }
            if let entry = entries[path], entry.size == nil, entry.pending == 0 {
                entries[path] = nil
            }
        }

        /// Locked. A folder no longer there, and everything known under it.
        private func forget(_ path: String) {
            guard let entry = entries.removeValue(forKey: path) else { return }
            for folder in entry.folders { forget(folder) }
        }

        /// Locked. Every folder above with a total has the change in it too.
        private func carry(_ difference: Int64, above path: String, device: dev_t) {
            guard difference != 0 else { return }
            for folder in Self.ancestors(of: path) {
                guard let entry = entries[folder], entry.device == device,
                      let size = entry.size else { continue }
                entries[folder]!.size = size + difference
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
