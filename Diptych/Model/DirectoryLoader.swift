import Foundation

/// Reads directories off the main thread.
///
/// Deliberately *not* an actor any more. An actor serialises its work, so one
/// listing of a USB disk that takes four seconds to spin up held up every other
/// listing behind it -- the other pane, and this pane's next directory, both
/// waiting on a disk neither of them cares about. Listings have no shared state
/// to protect, so there is nothing for the serialisation to buy.
///
/// Each call now runs on its own thread and carries a cancellation flag that is
/// polled as the entries are walked. The syscall already in flight cannot be
/// interrupted; everything after it can be abandoned.
enum DirectoryLoader {

    /// `deferMedia`: without what pictures and videos say about themselves,
    /// which is read from each file -- on a server, too slow to wait for
    /// before showing anything. The pane reads it after.
    /// `counted` hears how many entries have been read so far, a few times
    /// a second, while a slow folder is being read.
    static func load(directory: URL, showHidden: Bool, columns: [FileColumn],
                     deferMedia: Bool = false,
                     counted: (@Sendable (Int) -> Void)? = nil) async throws -> [FileItem] {
        let cancelled = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await BlockingWork.run {
                try list(directory: directory, showHidden: showHidden,
                         columns: columns, deferMedia: deferMedia, cancelled: cancelled,
                         counted: counted)
            }
        } onCancel: {
            cancelled.cancel()
        }
    }

    /// Exposed for the tests, which is also the only way to check that an
    /// abandoned listing actually stops.
    static func list(directory: URL, showHidden: Bool, columns: [FileColumn],
                     deferMedia: Bool = false,
                     cancelled: CancellationFlag = CancellationFlag(),
                     counted: ((Int) -> Void)? = nil) throws -> [FileItem] {
        // The single most important performance decision in this whole app.
        //
        // Passing `includingPropertiesForKeys:` makes Foundation batch-prefetch
        // this metadata while it walks the directory. Omit it and every
        // `resourceValues(forKeys:)` below turns into its own stat(2) syscall --
        // four per row, thousands per directory. Same lesson as reading all of a
        // file's attributes in one shot instead of calling isDirectory(),
        // length() and lastModified() separately.
        // Always what is needed to classify and draw a row at all -- a tag
        // colours the whole row, so tags too -- plus whatever the enabled
        // columns ask for, and nothing else.
        var keys = Self.keys(for: columns)
        if deferMedia { keys.remove(mediaKey) }

        // A private FileManager instance rather than `.default`: instances are
        // cheap, and a local one is unambiguously ours, which keeps the
        // concurrency checker quiet.
        let fm = FileManager()

        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHidden { options.insert(.skipsHiddenFiles) }

        let urls = Self.withoutAppleDouble(
            try entries(of: directory, keys: Self.fileSystemKeys(keys), options: options,
                        fm: fm, cancelled: cancelled, counted: counted))

        try Self.stop(if: cancelled)

        let keySet = keys
        var items: [FileItem] = []
        items.reserveCapacity(urls.count + 1)

        for (index, url) in urls.enumerated() {
            // Polled rather than tested every time: the check is a lock, and a
            // directory of a hundred thousand entries would pay for it once per
            // row for no benefit.
            if index % 256 == 0 { try Self.stop(if: cancelled) }

            items.append(Self.item(at: url, keys: keySet, fm: fm))
        }

        try Self.stop(if: cancelled)

        // Cheap way to know we are not at "/" without string-comparing paths.
        if directory.pathComponents.count > 1 {
            items.insert(FileItem.parent(of: directory), at: 0)
        }
        return items
    }

    /// What `contentsOfDirectory` answers -- the same entries, the same
    /// errors -- but read as they come, so a folder on a server can say how
    /// many it has read while it is still reading, and stop when abandoned.
    private static func entries(of directory: URL, keys: [URLResourceKey],
                                options: FileManager.DirectoryEnumerationOptions,
                                fm: FileManager, cancelled: CancellationFlag,
                                counted: ((Int) -> Void)?) throws -> [URL] {
        var failure: Error?
        guard let enumerator = fm.enumerator(
            at: directory, includingPropertiesForKeys: keys,
            options: options.union(.skipsSubdirectoryDescendants),
            errorHandler: { url, error in
                // The folder itself cannot be read: that is the answer. One
                // entry that cannot be is left for its row to show.
                guard url.standardizedFileURL.path == directory.standardizedFileURL.path else {
                    return true
                }
                failure = error
                return false
            }) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: directory])
        }
        var urls: [URL] = []
        var lastCount = Date()
        while let url = enumerator.nextObject() as? URL {
            urls.append(url)
            if urls.count % 64 == 0 {
                try Self.stop(if: cancelled)
                if let counted, Date().timeIntervalSince(lastCount) > 0.2 {
                    counted(urls.count)
                    lastCount = Date()
                }
            }
        }
        if let failure { throw failure }
        return urls
    }

    /// `._photo.jpg` beside `photo.jpg`: where macOS keeps a file's extended
    /// attributes and tags on a disk or server that cannot hold them. Part of
    /// the file, not a file of its own, so it is not listed -- as Finder does
    /// not, even with hidden files shown. One with nothing beside it stays.
    static func withoutAppleDouble(_ urls: [URL]) -> [URL] {
        let names = Set(urls.map(\.lastPathComponent))
        return urls.filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("._"), name.count > 2 else { return true }
            return !names.contains(String(name.dropFirst(2)))
        }
    }

    /// Not a key the file system knows: a column that shows what a
    /// picture or video says about itself, which is read from the file.
    static let mediaKey = URLResourceKey("dev.verhas.Diptych.media")

    /// The keys to ask the file system for: all but `mediaKey`.
    static func fileSystemKeys(_ keys: Set<URLResourceKey>) -> [URLResourceKey] {
        Array(keys.subtracting([mediaKey]))
    }

    /// The keys `list` asks for with these columns on.
    static func keys(for columns: [FileColumn]) -> Set<URLResourceKey> {
        var keys: Set<URLResourceKey> = [
            .nameKey, .localizedNameKey, .isDirectoryKey, .isPackageKey,
            .isSymbolicLinkKey, .isExecutableKey, .fileSizeKey,
            .contentModificationDateKey, .tagNamesKey,
        ]
        for column in columns { keys.formUnion(column.resourceKeys) }
        return keys
    }

    /// One row, for an entry of a listing -- or for one file on its own, as
    /// the flat view re-reads its rows.
    static func item(at url: URL, keys keySet: Set<URLResourceKey>,
                     fm: FileManager = FileManager()) -> FileItem {
        // `try?` yields an Optional instead of throwing: one unreadable
        // entry (a dangling symlink, a permission hole) must not abort the
        // whole listing.
        let v = try? url.resourceValues(forKeys: Set(Self.fileSystemKeys(keySet)))
        let isSymlink = v?.isSymbolicLink ?? false

        // `.isDirectoryKey` describes the link itself, not its target, so a
        // symlink to a folder reports false. Resolve it with fileExists,
        // which follows the link. Only done for actual symlinks -- it is an
        // extra stat, and there are usually a handful per directory.
        var isDirectory = v?.isDirectory ?? false
        // The same for "executable": a link's own permissions are always
        // rwxr-xr-x on macOS and mean nothing, so a link to a PDF was
        // badged executable. The target's say, read through the link; a
        // dangling link is not executable.
        var isExecutable = v?.isExecutable ?? false
        if isSymlink {
            var target: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &target) {
                isDirectory = target.boolValue
                isExecutable = fm.isExecutableFile(atPath: url.path)
            } else {
                isExecutable = false
            }
        }
        var item = FileItem(
            isParent: false,
            url: url,
            // The name as listed, not `.nameKey`: that is looked up by
            // inode, and for a hard link it can answer with another of the
            // file's names -- "hardx5" was listed as a second "x5".
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            isPackage: v?.isPackage ?? false,
            isSymlink: isSymlink,
            isExecutable: !isDirectory && isExecutable,
            byteSize: Int64(v?.fileSize ?? 0),
            modified: v?.contentModificationDate ?? .distantPast)

        if isSymlink {
            item.linkTarget = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            item.linkChain = LinkChain.follow(url)
        }
        // The name itself, not through a link: a link's own count is what
        // says how many names the link has.
        if !(v?.isDirectory ?? false) {
            var info = stat()
            if lstat(url.path, &info) == 0 { item.hardLinkCount = Int(info.st_nlink) }
        }
        item.created = v?.creationDate ?? .distantPast
        item.added = v?.addedToDirectoryDate ?? .distantPast
        item.kind = v?.localizedTypeDescription ?? ""
        item.tags = v?.tagNames ?? []
        // A symlink carries its own mode (usually 0755) while chmod, and
        // FileManager.setAttributes with it, follow the link and change the
        // target. Showing the link's own bits would mean displaying one
        // thing and editing another, so read through the link.
        var security = v?.fileSecurity
        if isSymlink {
            security = try? url.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.fileSecurityKey]).fileSecurity
        }

        if let security {
            let decoded = Self.decode(security, isDirectory: isDirectory)
            item.permissions = decoded.permissions
            item.mode = decoded.mode
            item.owner = decoded.owner
            item.group = decoded.group
        }
        // A picture's or video's own facts, when a column shows them: read
        // from the file, once while it stays as it is.
        if keySet.contains(mediaKey), !isDirectory {
            item.media = MediaCache.shared.info(for: url)
        }

        return item
    }

    private static func stop(if cancelled: CancellationFlag) throws {
        if cancelled.isCancelled { throw CancellationError() }
    }

    /// POSIX mode and owner out of the one prefetched NSFileSecurity, rather
    /// than a separate stat per row.
    private static func decode(_ security: NSFileSecurity,
                               isDirectory: Bool) -> (permissions: String, mode: mode_t,
                                                      owner: String, group: String) {
        let cf = security as CFFileSecurity

        var permissions = ""
        var mode: mode_t = 0
        if CFFileSecurityGetMode(cf, &mode) {
            permissions = (isDirectory ? "d" : "-") + FileOperations.rwxString(mode)
        }

        var owner = ""
        var uid: uid_t = 0
        if CFFileSecurityGetOwner(cf, &uid), let pw = getpwuid(uid) {
            owner = String(cString: pw.pointee.pw_name)
        }

        var group = ""
        var gid: gid_t = 0
        if CFFileSecurityGetGroup(cf, &gid), let gr = getgrgid(gid) {
            group = String(cString: gr.pointee.gr_name)
        }

        return (permissions, mode, owner, group)
    }
}
