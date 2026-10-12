import Foundation

/// Walks a folder's tree for the flat view: every folder the query says to
/// walk into, every item it says to list.
///
/// On a thread of its own -- a big tree takes a while -- reporting what it
/// has found in batches, so the rows arrive as they are found and the count
/// goes up while it works. Stopped by cancelling the task reading it.
enum FlatScanner {

    /// How far the walk has got: the folders read, the items looked at in
    /// them, and the folder being read now.
    struct Progress: Sendable, Equatable {
        var folders = 0
        var seen = 0
        var current: URL
    }

    enum Event: Sendable {
        /// Rows found since the last batch -- none, when nothing has passed
        /// for a while -- and how far the walk has got.
        case found([FileItem], Progress)
        /// Done: the folders that could not be read.
        case finished(unreadable: [URL])
    }

    /// The columns the query may need, whatever the pane shows: owner,
    /// group and mode for `owner`, `group` and `access`, and the dates.
    static let columns: [FileColumn] = [.permissions, .owner, .group, .created, .modified]

    static func scan(root: URL, query: FlatQuery, showHidden: Bool,
                     columns shown: [FileColumn]) -> AsyncStream<Event> {
        let cancelled = CancellationFlag()
        let keys = DirectoryLoader.keys(for: shown + columns)
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            continuation.onTermination = { _ in cancelled.cancel() }
            Thread.detachNewThread {
                let unreadable = walk(root: root, query: query, showHidden: showHidden,
                                      keys: keys, cancelled: cancelled) { batch, progress in
                    continuation.yield(.found(batch, progress))
                }
                if !cancelled.isCancelled {
                    continuation.yield(.finished(unreadable: unreadable))
                }
                continuation.finish()
            }
        }
    }

    /// The walk itself, on the caller's thread: what the tests drive.
    /// `report` gets the rows in batches, a few times a second -- with
    /// none, while nothing passes, so the counts still move: a tree on a
    /// server can be read for minutes without a single match.
    @discardableResult
    static func walk(root: URL, query: FlatQuery, showHidden: Bool,
                     keys: Set<URLResourceKey> = DirectoryLoader.keys(for: columns),
                     cancelled: CancellationFlag = CancellationFlag(),
                     report: ([FileItem], Progress) -> Void) -> [URL] {
        let fm = FileManager()
        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHidden { options.insert(.skipsHiddenFiles) }

        var pending: [(url: URL, prefix: String)] = [(root, "")]
        var unreadable: [URL] = []
        var batch: [FileItem] = []
        var progress = Progress(current: root)
        var lastReport = Date()

        while let (folder, prefix) = pending.popLast() {
            if cancelled.isCancelled { return unreadable }
            // Said before the folder is read: it is the slow part on a server.
            progress.current = folder
            if Date().timeIntervalSince(lastReport) > 0.2 {
                report(batch, progress)
                batch = []
                lastReport = Date()
            }
            progress.folders += 1
            guard let urls = (try? fm.contentsOfDirectory(at: folder,
                                                          includingPropertiesForKeys: DirectoryLoader.fileSystemKeys(keys),
                                                          options: options))
                .map(DirectoryLoader.withoutAppleDouble) else {
                unreadable.append(folder)
                continue
            }
            progress.seen += urls.count
            var below: [(URL, String)] = []
            for (index, url) in urls.enumerated() {
                if index % 256 == 0, cancelled.isCancelled { return unreadable }
                var item = DirectoryLoader.item(at: url, keys: keys, fm: fm)
                item.folderPrefix = prefix
                let decision = query.decide(FlatSubject(item))
                if decision.list { batch.append(item) }
                // Not through a link: one pointing above itself would go
                // round for ever, and the place it leads is somewhere else.
                if decision.traverse, item.isDirectory, !item.isPackage, !item.isSymlink {
                    below.append((url, prefix + item.name + "/"))
                }
            }
            // In listing order, the first folder walked first.
            pending.append(contentsOf: below.reversed())
        }
        progress.current = root
        if !batch.isEmpty || progress.folders > 0 { report(batch, progress) }
        return unreadable
    }

    /// One row again, as it is now -- nil when it is gone -- for refreshing
    /// a flat view without walking the tree again.
    static func reread(_ item: FileItem, columns shown: [FileColumn]) -> FileItem? {
        var isDirectory: ObjCBool = false
        // The link itself, not what it points to: a broken link is still a row.
        guard FileManager.default.fileExists(atPath: item.url.path, isDirectory: &isDirectory)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: item.url.path))
                    != nil else { return nil }
        // A URL keeps what it was told about the file: the mode set a
        // moment ago would not show without asking again.
        var url = item.url
        url.removeAllCachedResourceValues()
        var fresh = DirectoryLoader.item(at: url,
                                         keys: DirectoryLoader.keys(for: shown + columns))
        fresh.folderPrefix = item.folderPrefix
        return fresh
    }

    /// An item under `root` -- one just renamed, or made there -- as a row,
    /// whether or not the expression would list it; nil outside `root`.
    static func row(for url: URL, under root: URL, columns shown: [FileColumn]) -> FileItem? {
        let rootPath = canonicalPath(root)
        let folder = (canonicalPath(url) as NSString).deletingLastPathComponent
        var info = stat()
        guard folder == rootPath || folder.hasPrefix(rootPath == "/" ? "/" : rootPath + "/"),
              lstat(url.path, &info) == 0 else { return nil }
        var item = DirectoryLoader.item(at: url, keys: DirectoryLoader.keys(for: shown + columns))
        let relative = folder.dropFirst(rootPath.count).drop { $0 == "/" }
        item.folderPrefix = relative.isEmpty ? "" : relative + "/"
        return item
    }

    /// A path to compare by: `/private/var` is `/var`, as the system's
    /// own links have it, whichever way a URL was made -- worked out from
    /// the text alone, so it holds for a path that was just renamed away.
    nonisolated static func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        for linked in ["/var", "/tmp", "/etc"] where path == "/private" + linked
            || path.hasPrefix("/private" + linked + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }
}
