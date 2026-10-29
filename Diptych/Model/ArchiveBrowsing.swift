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
        var cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Diptych")
            .appendingPathComponent("Opened Archives")
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

    /// Where the pane is, as a person would say it: inside the archive --
    /// and inside the archive that one came out of, for a zip in a zip.
    /// Anything else as it is.
    static func shown(_ url: URL) -> URL {
        // A server's folder is shown by its sftp:// address, not as a path.
        if let remote = RemoteBrowsing.shown(url) { return remote }
        var url = url
        for _ in 0..<16 {
            guard let opened = opened(containing: url) else { break }
            let rest = String(resolved(url.path).dropFirst(resolved(opened.root.path).count))
            url = URL(fileURLWithPath: opened.archive.path + rest)
        }
        return url
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
        registry.lock.withLock {
            registry.opened.removeAll { $0.archive.standardizedFileURL == archive.standardizedFileURL }
            registry.opened.append(Opened(archive: archive, root: source.root, holder: holder,
                                          stamp: stamp))
        }
        return source.root
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
        if let mark = Archiving.quarantine(of: opened.archive) {
            Archiving.markQuarantined(target, with: mark)
        }
    }

    /// Everything unpacked, gone. Called when Diptych starts, for what a
    /// crash left, and when it quits.
    static func removeAll() {
        registry.lock.withLock { registry.opened.removeAll() }
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
