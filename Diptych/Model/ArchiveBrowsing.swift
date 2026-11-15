import Foundation
import Darwin

/// An archive opened in a pane as if it were a folder.
///
/// It is unpacked once, as the user, into a folder of Diptych's caches named
/// after the archive -- `photos.zip` -- and the pane shows that folder. So
/// everything that works on files works inside it: Quick Look, Compare,
/// copying out, the flat view, Find Duplicates. The folder counts as a
/// read-only volume, so nothing can be renamed, moved, trashed or dropped in
/// it; the path bar shows it where the archive is, `~/Downloads/photos.zip/
/// 2024`, and going up from its top lands next to the archive with the
/// archive selected.
///
/// Opened again while it has not changed, it is shown at once. The folders
/// go when Diptych quits, and any left by a crash when it starts.
nonisolated enum ArchiveBrowsing {

    typealias Failure = Archiving.Failure

    struct Opened: Equatable, Sendable {
        let archive: URL
        /// The archive's name, holding what was in it.
        let root: URL
        /// Everything for this opened archive; removed when it is forgotten.
        let holder: URL
        let stamp: Stamp
    }

    /// Enough to tell the archive has changed since it was unpacked.
    struct Stamp: Equatable, Sendable {
        let size: Int64
        let modified: timespec
        let inode: UInt64

        init?(_ url: URL) {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return nil }
            size = Int64(info.st_size)
            modified = info.st_mtimespec
            inode = UInt64(info.st_ino)
        }

        static func == (a: Stamp, b: Stamp) -> Bool {
            a.size == b.size && a.inode == b.inode
                && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }

    /// What is opened, and where. Read from any thread: a volume's facts are
    /// worked out off the main actor.
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var opened: [Opened] = []
        /// Archives whose unpacked copy was thrown away because the archive
        /// went or changed. Kept only to say where a pane that was inside one
        /// stood, so that it can step out to where the archive was rather than
        /// into the caches.
        var retired: [Opened] = []
        /// One watch on each opened archive, by its holder's path.
        var watches: [String: DispatchSourceFileSystemObject] = [:]
        var cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Diptych")
            .appendingPathComponent("Opened Archives")
        /// Clean copies handed to a drag, by the path of what they were
        /// copied from.
        var handedOut: [String: HandedOut] = [:]
    }

    struct HandedOut {
        let original: URL
        let copy: URL
        let made: Date
    }

    private static let registry = Registry()

    /// Where the archives are unpacked. The tests put it somewhere of their own.
    static var cacheRoot: URL {
        get { registry.lock.withLock { registry.cacheRoot } }
        set { registry.lock.withLock { registry.cacheRoot = newValue } }
    }

    // MARK: - Where things are

    /// Anything under the caches folder, opened in this run or left over.
    static func isInside(_ url: URL) -> Bool {
        let root = resolved(cacheRoot.path)
        let path = resolved(url.path)
        return path == root || path.hasPrefix(root + "/")
    }

    /// The opened archive whose top `url` is -- exactly its root, not a folder
    /// within it. Used to leave an archive upward and land beside it. Compares
    /// symlink-resolved paths, so it holds however the path is spelled (a
    /// trailing slash from `deletingLastPathComponent()`, a `/private` prefix).
    static func openedRoot(at url: URL) -> Opened? {
        let path = resolved(url.path)
        return registry.lock.withLock {
            registry.opened.first { resolved($0.root.path) == path }
        }
    }

    /// The opened archive `url` is in.
    static func opened(containing url: URL) -> Opened? {
        let path = resolved(url.path)
        return registry.lock.withLock {
            registry.opened.first { opened in
                let root = resolved(opened.root.path)
                return path == root || path.hasPrefix(root + "/")
            }
        }
    }

    /// The thrown-away archive `url` was in, for saying where it stood.
    private static func retired(containing url: URL) -> Opened? {
        let path = resolved(url.path)
        return registry.lock.withLock {
            registry.retired.last { opened in
                let root = resolved(opened.root.path)
                return path == root || path.hasPrefix(root + "/")
            }
        }
    }

    /// Where the pane is, as a person would say it: inside the archive --
    /// and inside the archive that one came out of, for a zip in a zip.
    /// Anything else as it is.
    static func shown(_ url: URL) -> URL {
        // A server's folder is shown by its sftp:// address, not as a path.
        if let remote = RemoteBrowsing.shown(url) { return remote }
        var url = url
        for _ in 0..<16 {
            guard let opened = opened(containing: url) ?? retired(containing: url) else { break }
            let rest = String(resolved(url.path).dropFirst(resolved(opened.root.path).count))
            url = URL(fileURLWithPath: opened.archive.path + rest)
        }
        return url
    }

    /// A path as text for the person to copy or read: a server's folder as its
    /// sftp:// address, a folder inside an archive as inside the archive, and
    /// anything else as its path.
    static func shownText(_ url: URL) -> String {
        let display = shown(url)
        guard display.scheme == "sftp" else { return display.path }
        return display.absoluteString.removingPercentEncoding ?? display.absoluteString
    }

    /// A path through an opened archive -- `…/photos.zip/2024` -- as the
    /// folder it was unpacked to; nil for one that is not.
    static func actual(_ shown: URL) -> URL? {
        if shown.scheme == "sftp" { return RemoteBrowsing.actual(shown) }
        var path = shown.standardizedFileURL.path
        var mapped = false
        // The outer archive first, then any opened from inside it.
        for _ in 0..<16 {
            let next: String? = registry.lock.withLock {
                for opened in registry.opened {
                    let archive = opened.archive.standardizedFileURL.path
                    if path == archive { return opened.root.path }
                    if path.hasPrefix(archive + "/") {
                        return opened.root.path + String(path.dropFirst(archive.count))
                    }
                }
                return nil
            }
            guard let next else { break }
            path = next
            mapped = true
        }
        return mapped ? URL(fileURLWithPath: path) : nil
    }

    /// The folder `archive` was unpacked to, when it has not changed since.
    static func existing(for archive: URL) -> URL? {
        let stamp = Stamp(archive)
        return registry.lock.withLock {
            registry.opened.first {
                $0.archive.standardizedFileURL == archive.standardizedFileURL && $0.stamp == stamp
                    && FileManager.default.fileExists(atPath: $0.root.path)
            }?.root
        }
    }

    /// The facts of a folder inside an opened archive: read-only, named
    /// after the archive.
    static func volumeFacts(of url: URL) -> VolumeFacts? {
        guard isInside(url) else { return nil }
        let name = opened(containing: url)?.archive.lastPathComponent
            ?? resolved(url.path).dropFirst(resolved(cacheRoot.path).count + 1)
                .split(separator: "/").dropFirst().first.map(String.init)
        return VolumeFacts(isNetwork: false, isReadOnly: true, typeName: "archive", name: name)
    }

    // MARK: - Opening

    /// Unpacked into a new folder of the caches, and remembered. The room it
    /// needs is checked first, from what the archive lists.
    static func open(_ archive: URL, kind: Archiving.Kind, password: Archiving.PasswordFile?,
                     job: Archiving.Job) throws(Failure) -> URL {
        if let root = existing(for: archive) { return root }
        guard let stamp = Stamp(archive) else {
            throw Failure(message: "The archive could not be read.")
        }
        job.set(.counting)
        let holder = cacheRoot.appendingPathComponent(UUID().uuidString)
        let source = try ArchiveSource.build(archive: archive, kind: kind, into: holder,
                                             password: password, job: job)
        // An earlier copy of this archive, from before it changed, goes:
        // a pane still showing it is showing what the archive no longer holds.
        let earlier = registry.lock.withLock {
            registry.opened.filter { $0.archive.standardizedFileURL == archive.standardizedFileURL }
        }
        for opened in earlier { retire(opened) }
        let opened = Opened(archive: archive, root: source.root, holder: holder, stamp: stamp)
        registry.lock.withLock { registry.opened.append(opened) }
        watch(opened)
        return source.root
    }

    // MARK: - When the archive goes

    /// Whether the archive `url` is in -- and the one that came out of, for a
    /// zip in a zip -- is still where it was and unchanged. True of anything
    /// not inside an archive.
    static func isCurrent(_ url: URL) -> Bool {
        var url = url
        for _ in 0..<16 {
            guard isInside(url) else { return true }
            guard let opened = opened(containing: url), Stamp(opened.archive) == opened.stamp
            else { return false }
            url = opened.archive
        }
        return true
    }

    /// Throws away the unpacked copy of every archive that has been deleted,
    /// moved, renamed or changed since it was opened. Panes inside one see
    /// their folder go, as they would a real folder's, and step out of it.
    /// Cheap -- a `stat` per opened archive -- so it is asked on every
    /// navigation too, for disks whose changes the kernel does not report.
    /// True when anything was thrown away.
    @discardableResult
    static func retireStale() -> Bool {
        var any = false
        // Outer archives first: an inner one's archive is in the outer's copy,
        // so it goes with it and is caught on the next turn of the loop.
        for _ in 0..<16 {
            let stale = registry.lock.withLock { registry.opened }
                .filter { !isCurrent($0.root) }
            guard !stale.isEmpty else { return any }
            for opened in stale { retire(opened) }
            any = true
        }
        return any
    }

    private static func retire(_ opened: Opened) {
        let watch = registry.lock.withLock { () -> DispatchSourceFileSystemObject? in
            registry.opened.removeAll { $0.holder == opened.holder }
            registry.retired.removeAll { $0.holder == opened.holder }
            registry.retired.append(opened)
            if registry.retired.count > 64 { registry.retired.removeFirst() }
            return registry.watches.removeValue(forKey: opened.holder.path)
        }
        watch?.cancel()
        remove(opened.holder)
    }

    private static let watchQueue = DispatchQueue(label: "Diptych.ArchiveBrowsing.watch")

    /// The kernel says when the archive file itself is deleted, renamed --
    /// moved to the Trash is a rename -- or written. Nothing has to be looking
    /// at the folder it is in for that to be noticed.
    private static func watch(_ opened: Opened) {
        let descriptor = Darwin.open(opened.archive.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.delete, .rename, .write, .extend, .attrib, .revoke],
            queue: watchQueue)
        source.setEventHandler { retireStale() }
        source.setCancelHandler { Darwin.close(descriptor) }
        let replaced = registry.lock.withLock {
            let old = registry.watches[opened.holder.path]
            registry.watches[opened.holder.path] = source
            return old
        }
        replaced?.cancel()
        source.resume()
    }

    /// Where a pane inside a thrown-away archive goes: the nearest folder that
    /// is there, counted from where the archive was -- not up through the
    /// caches. Nil for a path that is not inside an archive.
    static func landing(for url: URL) -> URL? {
        guard isInside(url) else { return nil }
        let shown = shown(url)
        // Not known at all: a leftover from a crash. Home, as for any folder
        // with nothing left above it.
        guard !isInside(shown) else { return FileManager.default.homeDirectoryForCurrentUser }
        var candidate = shown.deletingLastPathComponent()
        while candidate.pathComponents.count > 1 {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue, !isInside(candidate) {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: - Tidying

    /// Gives a copy taken out of an opened archive the archive's own
    /// permissions, rather than the read-only lock the extracted copy carries.
    ///
    /// Browsing an archive unpacks it and locks every file so the cache cannot
    /// be written over. A copy of one of those files would inherit the lock
    /// and come out read-only, which is not what the archive held. So after a
    /// copy out, each item is set to the mode the manifest records -- write
    /// bits, setuid and all -- and the archive's quarantine is put on it, the
    /// same as Extract does. The owner stays the user's, as an extract as the
    /// user gives.
    nonisolated static func unlockCopy(at target: URL, from source: URL) {
        guard let opened = opened(containing: source) else { return }
        applyListedModes(at: target, from: source)
        if let mark = Archiving.quarantine(of: opened.archive) {
            Archiving.markQuarantined(target, with: mark)
        }
    }

    /// Gives a copy taken out of any manifest-backed source -- an opened archive,
    /// a server's shadow -- the modes its manifests record, item by item, rather
    /// than the read-only lock the copy it came from carries.
    nonisolated static func applyListedModes(at target: URL, from source: URL) {
        let manager = FileManager()
        // Every item copied, paired with where it came from.
        var pairs = [(target: target, source: source)]
        if let walker = manager.enumerator(atPath: target.path) {
            while let relative = walker.nextObject() as? String {
                pairs.append((target.appendingPathComponent(relative),
                              source.appendingPathComponent(relative)))
            }
        }
        // One manifest read per source directory, not per item.
        var modes: [String: [String: mode_t]] = [:]
        func mode(of item: URL) -> mode_t? {
            let directory = item.deletingLastPathComponent().path
            if modes[directory] == nil {
                var byName: [String: mode_t] = [:]
                for node in BrowserManifestStore.read(in: item.deletingLastPathComponent())?.nodes ?? [] {
                    if let value = node.attribute(BrowserManifest.Attribute.mode)?.intValue {
                        byName[node.name] = mode_t(truncatingIfNeeded: value)
                    }
                }
                modes[directory] = byName
            }
            return modes[directory]?[item.lastPathComponent]
        }
        for (target, source) in pairs {
            if let mode = mode(of: source) {
                chmod(target.path, mode)
            } else {
                var info = stat()
                if lstat(target.path, &info) == 0 { chmod(target.path, (info.st_mode & 0o7777) | 0o600) }
            }
        }
    }

    // MARK: - Dragged out

    /// Where the copies handed to drags are made: beside the unpacked
    /// archives, on the same volume, so that a copy is a clone.
    nonisolated static var handOutRoot: URL {
        cacheRoot.deletingLastPathComponent().appendingPathComponent("Dragged Out")
    }

    /// What to give a drag for `url`: for an item of an opened archive, a
    /// copy of it as Extract would give it -- the archive's own permissions,
    /// not the cache's lock, and its quarantine. A drag hands over a path and
    /// the receiver copies what is there: Finder, given the cache's own
    /// files, copied their lock, and a folder of the copy could then not even
    /// be deleted. Anything else is given as it is.
    ///
    /// Cloned, so a folder of any size costs next to nothing; asked for again
    /// within a minute -- the same drag, read once more -- the same copy is
    /// given. The copies are not removed when the drag ends: the receiver may
    /// go on reading them long after. They go when they are a day old, and
    /// when Diptych starts.
    nonisolated static func handOut(_ url: URL) -> URL {
        guard isInside(url), url.standardizedFileURL != cacheRoot.standardizedFileURL else { return url }
        let key = url.standardizedFileURL.path
        if let earlier = registry.lock.withLock({ registry.handedOut[key] }),
           Date().timeIntervalSince(earlier.made) < 60,
           FileManager.default.fileExists(atPath: earlier.copy.path) {
            return earlier.copy
        }
        removeHandedOut(olderThan: 24 * 3600)
        let holder = handOutRoot.appendingPathComponent(UUID().uuidString)
        let copy = holder.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager().createDirectory(at: holder, withIntermediateDirectories: true)
            // clonefile takes a whole tree at once, links and locked folders
            // included; another volume, should the caches be on one, copies.
            if clonefile(url.path, copy.path, UInt32(CLONE_NOFOLLOW)) != 0 {
                try FileManager().copyItem(at: url, to: copy)
            }
        } catch {
            remove(holder)
            return url
        }
        unlockCopy(at: copy, from: url)
        registry.lock.withLock {
            registry.handedOut[key] = HandedOut(original: url, copy: copy, made: Date())
        }
        return copy
    }

    /// The archive item a copy handed to a drag was made from, so that a
    /// drop back into Diptych works on the item itself -- inside the archive,
    /// and always a copy. Anything else as it is.
    nonisolated static func original(of url: URL) -> URL {
        let path = url.standardizedFileURL.path
        return registry.lock.withLock {
            registry.handedOut.values.first { $0.copy.standardizedFileURL.path == path }?.original
        } ?? url
    }

    /// The handed-out copies older than `age`, or all of them.
    nonisolated static func removeHandedOut(olderThan age: TimeInterval? = nil) {
        let manager = FileManager()
        let holders = (try? manager.contentsOfDirectory(at: handOutRoot,
                                                        includingPropertiesForKeys: [.creationDateKey])) ?? []
        for holder in holders {
            if let age {
                let made = (try? holder.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                guard let made, Date().timeIntervalSince(made) > age else { continue }
            }
            remove(holder)
        }
        let kept = Set(((try? manager.contentsOfDirectory(atPath: handOutRoot.path)) ?? []))
        registry.lock.withLock {
            registry.handedOut = registry.handedOut.filter {
                kept.contains($0.value.copy.deletingLastPathComponent().lastPathComponent)
            }
        }
    }

    /// Everything unpacked, gone. Called when Diptych starts, for what a
    /// crash left, and when it quits.
    static func removeAll() {
        let watches = registry.lock.withLock { () -> [DispatchSourceFileSystemObject] in
            registry.opened.removeAll()
            registry.retired.removeAll()
            defer { registry.watches.removeAll() }
            return Array(registry.watches.values)
        }
        for watch in watches { watch.cancel() }
        remove(cacheRoot)
    }

    /// Removed even where the archive made a folder read-only: write
    /// permission is given back first, top down.
    static func remove(_ url: URL) {
        let manager = FileManager()
        guard manager.fileExists(atPath: url.path) else { return }
        chmod(url.path, 0o700)
        if let walker = manager.enumerator(atPath: url.path) {
            while let relative = walker.nextObject() as? String {
                let path = url.appendingPathComponent(relative).path
                var info = stat()
                if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
                    chmod(path, (info.st_mode & 0o7777) | 0o700)
                }
            }
        }
        try? manager.removeItem(at: url)
        BrowserManifestStore.forget(under: url)
    }

    /// `/var` and `/tmp` as the kernel has them, so either spelling matches
    /// -- for a path that is not there too, such as one through an archive's
    /// own name: its longest part that is, resolved, and the rest as it is.
    private static func resolved(_ path: String) -> String {
        var head = URL(fileURLWithPath: path).standardizedFileURL.path
        var tail = ""
        while head.count > 1 {
            if let real = realpath(head, nil) {
                defer { free(real) }
                return String(cString: real) + tail
            }
            tail = "/" + (head as NSString).lastPathComponent + tail
            head = (head as NSString).deletingLastPathComponent
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
