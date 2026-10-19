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
        let entries = try Archiving.entries(of: archive, kind: kind, password: password, job: job)
        let manager = FileManager()
        let holder = cacheRoot.appendingPathComponent(UUID().uuidString)
        let root = holder.appendingPathComponent(archive.lastPathComponent)
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        let needed = entries.compactMap(\.size).reduce(0, +)
        if let free = (try? holder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage, needed > free {
            remove(holder)
            throw Failure(message: "It holds \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)), "
                          + "more than the disk has free.")
        }
        do throws(Failure) {
            try Archiving.unpack(archive, kind: kind, into: root, password: password,
                                 entries: entries, job: job)
        } catch {
            remove(holder)
            throw error
        }
        guard !job.isCancelled else {
            remove(holder)
            throw Failure(message: "Stopped.")
        }
        // Folded into the files by ditto; tar leaves it as it is.
        let macOSX = root.appendingPathComponent("__MACOSX")
        if manager.fileExists(atPath: macOSX.path) { remove(macOSX) }
        if let mark = Archiving.quarantine(of: archive) { Archiving.markQuarantined(root, with: mark) }
        registry.lock.withLock {
            registry.opened.removeAll { $0.archive.standardizedFileURL == archive.standardizedFileURL }
            registry.opened.append(Opened(archive: archive, root: root, stamp: stamp))
        }
        return root
    }

    // MARK: - Tidying

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
