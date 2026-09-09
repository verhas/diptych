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

    static func load(directory: URL, showHidden: Bool,
                     columns: [FileColumn]) async throws -> [FileItem] {
        let cancelled = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await BlockingWork.run {
                try list(directory: directory, showHidden: showHidden,
                         columns: columns, cancelled: cancelled)
            }
        } onCancel: {
            cancelled.cancel()
        }
    }

    /// Exposed for the tests, which is also the only way to check that an
    /// abandoned listing actually stops.
    static func list(directory: URL, showHidden: Bool, columns: [FileColumn],
                     cancelled: CancellationFlag = CancellationFlag()) throws -> [FileItem] {
        // The single most important performance decision in this whole app.
        //
        // Passing `includingPropertiesForKeys:` makes Foundation batch-prefetch
        // this metadata while it walks the directory. Omit it and every
        // `resourceValues(forKeys:)` below turns into its own stat(2) syscall --
        // four per row, thousands per directory. Same lesson as reading all of a
        // file's attributes in one shot instead of calling isDirectory(),
        // length() and lastModified() separately.
        // Always needed to classify and draw a row at all...
        var keys: Set<URLResourceKey> = [
            .nameKey, .localizedNameKey, .isDirectoryKey, .isPackageKey,
            .isSymbolicLinkKey, .isExecutableKey, .fileSizeKey,
            .contentModificationDateKey,
            // Always, not only when the Tags column is on: a tag colours the
            // whole row, so it is needed to draw the list at all.
            .tagNamesKey,
        ]
        // ...plus whatever the enabled columns ask for, and nothing else.
        for column in columns {
            keys.formUnion(column.resourceKeys)
        }

        // A private FileManager instance rather than `.default`: instances are
        // cheap, and a local one is unambiguously ours, which keeps the
        // concurrency checker quiet.
        let fm = FileManager()

        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHidden { options.insert(.skipsHiddenFiles) }

        let urls = try fm.contentsOfDirectory(at: directory,
                                              includingPropertiesForKeys: Array(keys),
                                              options: options)

        try Self.stop(if: cancelled)

        let keySet = keys
        var items: [FileItem] = []
        items.reserveCapacity(urls.count + 1)

        for (index, url) in urls.enumerated() {
            // Polled rather than tested every time: the check is a lock, and a
            // directory of a hundred thousand entries would pay for it once per
            // row for no benefit.
            if index % 256 == 0 { try Self.stop(if: cancelled) }

            // `try?` yields an Optional instead of throwing: one unreadable
            // entry (a dangling symlink, a permission hole) must not abort the
            // whole listing.
            let v = try? url.resourceValues(forKeys: keySet)
            let isSymlink = v?.isSymbolicLink ?? false

            // `.isDirectoryKey` describes the link itself, not its target, so a
            // symlink to a folder reports false. Resolve it with fileExists,
            // which follows the link. Only done for actual symlinks -- it is an
            // extra stat, and there are usually a handful per directory.
            var isDirectory = v?.isDirectory ?? false
            if isSymlink {
                var target: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &target) {
                    isDirectory = target.boolValue
                }
            }

            var item = FileItem(
                isParent: false,
                url: url,
                name: v?.name ?? url.lastPathComponent,
                isDirectory: isDirectory,
                isPackage: v?.isPackage ?? false,
                isSymlink: isSymlink,
                isExecutable: !isDirectory && (v?.isExecutable ?? false),
                byteSize: Int64(v?.fileSize ?? 0),
                modified: v?.contentModificationDate ?? .distantPast)

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

            items.append(item)
        }

        try Self.stop(if: cancelled)

        // Cheap way to know we are not at "/" without string-comparing paths.
        if directory.pathComponents.count > 1 {
            items.insert(FileItem.parent(of: directory), at: 0)
        }
        return items
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
