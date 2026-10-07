import Foundation
import Observation

/// Every name of one file: the other hard links to its inode -- its siblings,
/// as APFS calls them.
///
/// A file system keeps name -> inode only, so the names have to be searched
/// for. Not from the top, as `find / -inum` does, but outwards from the file:
/// its own folder and everything under it first, then the folder above
/// without the branch already read, and so on up to the top of the volume.
/// Hard links are usually made near each other, so they are usually found in
/// the first moments -- and the search stops as soon as it has as many names
/// as the inode says it has.
enum SiblingWalker {

    struct Target: Sendable, Equatable {
        let inode: UInt64
        let device: Int32
        let links: Int
    }

    enum Event: Sendable {
        case found(String)
        /// Where it has got to, now and then rather than per folder.
        case progress(folder: String, foldersRead: Int)
        /// A folder it was not allowed into; a name may be in there.
        case unreadable(String)
    }

    /// The item itself, not what a symbolic link points to.
    static func target(of url: URL) -> Target? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Target(inode: UInt64(info.st_ino), device: info.st_dev, links: Int(info.st_nlink))
    }

    /// Reads outwards from `url`'s folder until every name is found, the top
    /// of the volume is reached, or `cancelled` is set. Blocks; run it on a
    /// thread of its own. `report` is called on that thread.
    static func search(from url: URL, for target: Target, cancelled: CancellationFlag,
                       report: @escaping (Event) -> Void) {
        var walk = Walk(target: target, cancelled: cancelled, report: report)
        // The folder's real path, symbolic links on the way resolved -- not
        // `standardizedFileURL`, which turns /private/var back into /var. Up
        // from /var is /, and from there /private/var would be read again,
        // the names found twice under two paths.
        let folderPath = url.deletingLastPathComponent().path
        guard let resolved = realpath(folderPath, nil) else { return }
        let start = String(cString: resolved)
        free(resolved)

        // On the startup disk / is the same device as /Users, through the
        // firmlinks -- and /System/Volumes/Data is those same files again.
        // Read twice, every name would be found twice. Left in when the file
        // was reached through it.
        if !start.hasPrefix("/System/Volumes/") { walk.pruned.insert("/System/Volumes") }

        var folder = start
        var cameFrom: String?
        while true {
            walk.tree(folder, skipping: cameFrom)
            if walk.isOver { return }
            guard folder != "/" else { return }
            let parent = (folder as NSString).deletingLastPathComponent
            // The top of the volume: above it is another file system, where
            // this inode number means something else.
            var info = stat()
            guard lstat(parent, &info) == 0, info.st_dev == target.device else { return }
            cameFrom = folder
            folder = parent
        }
    }

    private struct Walk {
        let target: Target
        let cancelled: CancellationFlag
        let report: (Event) -> Void
        var pruned: Set<String> = []
        var found: Set<String> = []
        var foldersRead = 0
        var lastReport = Date.distantPast

        var isOver: Bool { found.count >= target.links || cancelled.isCancelled }

        /// `root` and everything under it but `skipping`, depth first.
        mutating func tree(_ root: String, skipping: String?) {
            var stack = [root]
            while let folder = stack.popLast() {
                if isOver { return }
                for sub in read(folder).reversed() where sub != skipping && !pruned.contains(sub) {
                    stack.append(sub)
                }
            }
        }

        /// One folder: any entry with the inode is checked and reported; the
        /// folders in it are returned, to be read next.
        mutating func read(_ folder: String) -> [String] {
            guard let directory = opendir(folder) else {
                if errno == EACCES || errno == EPERM { report(.unreadable(folder)) }
                return []
            }
            defer { closedir(directory) }

            // Another volume mounted here: not this file system.
            var info = stat()
            guard fstat(dirfd(directory), &info) == 0, info.st_dev == target.device else {
                return []
            }

            foldersRead += 1
            let now = Date()
            if now.timeIntervalSince(lastReport) > 0.1 {
                lastReport = now
                report(.progress(folder: folder, foldersRead: foldersRead))
            }

            let prefix = folder == "/" ? "/" : folder + "/"
            var folders: [String] = []
            while let entry = readdir(directory) {
                let name = Self.name(of: entry)
                if name == "." || name == ".." { continue }
                // The inode number is in the directory entry itself, so a
                // folder is read without a stat per file -- which is what makes
                // this quick. Only a match is looked at more closely.
                if UInt64(entry.pointee.d_ino) == target.inode {
                    let path = prefix + name
                    var candidate = stat()
                    if lstat(path, &candidate) == 0, UInt64(candidate.st_ino) == target.inode,
                       candidate.st_dev == target.device, found.insert(path).inserted {
                        report(.found(path))
                        if isOver { return [] }
                    }
                }
                // Only real folders: a symbolic link is not followed, so
                // nothing is read twice and no loop is gone round.
                if entry.pointee.d_type == DT_DIR { folders.append(prefix + name) }
            }
            return folders
        }

        private static func name(of entry: UnsafeMutablePointer<dirent>) -> String {
            let length = Int(entry.pointee.d_namlen)
            return withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: UInt8.self, capacity: length) {
                    String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
                }
            }
        }
    }
}

/// One search, for its window: what it has found so far, and where it is.
@MainActor
@Observable
final class SiblingSearch {

    let url: URL
    private(set) var target: SiblingWalker.Target?
    /// In the order found -- nearest first, as the search goes outwards.
    private(set) var found: [URL] = []
    private(set) var isSearching = false
    /// The folder being read, shown while it runs.
    private(set) var folder = ""
    private(set) var foldersRead = 0
    private(set) var unreadable: [String] = []
    private(set) var wasStopped = false
    let startedAt = Date()
    private(set) var endedAt: Date?

    @ObservationIgnored private let cancelled = CancellationFlag()

    init(url: URL) {
        self.url = url
        target = SiblingWalker.target(of: url)
        start()
    }

    var allFound: Bool { target.map { found.count >= $0.links } ?? false }

    func stop() {
        guard isSearching else { return }
        wasStopped = true
        cancelled.cancel()
    }

    /// The window has closed: nobody is waiting for the answer.
    func abandon() { cancelled.cancel() }

    private func start() {
        guard let target, target.links > 1 else { return }
        isSearching = true
        let url = url, cancelled = cancelled
        // A thread of its own: a search of a whole disk takes minutes, and
        // must not hold one of the threads the listings share.
        Thread.detachNewThread { [weak self] in
            SiblingWalker.search(from: url, for: target, cancelled: cancelled) { event in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(event) } }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish() } }
        }
    }

    private func receive(_ event: SiblingWalker.Event) {
        switch event {
        case .found(let path):
            found.append(URL(fileURLWithPath: path))
        case .progress(let folder, let count):
            self.folder = folder
            foldersRead = count
        case .unreadable(let path):
            unreadable.append(path)
        }
    }

    private func finish() {
        isSearching = false
        endedAt = Date()
        folder = ""
    }
}
