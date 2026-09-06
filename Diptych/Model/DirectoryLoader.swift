import Foundation

/// Reads directories off the main thread.
///
/// Swing analogy: an `actor` is roughly a single-threaded executor that owns its
/// own state. Every `func` on it is implicitly async from the outside, and the
/// compiler *proves* nobody touches its innards concurrently. Calling
/// `await DirectoryLoader.shared.load(...)` from `@MainActor` code is the
/// equivalent of handing work to a SwingWorker -- except the hop is a language
/// feature rather than a library call, and forgetting it is a compile error.
actor DirectoryLoader {

    static let shared = DirectoryLoader()

    func load(directory: URL, showHidden: Bool, columns: [FileColumn]) throws -> [FileItem] {
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

        let keySet = keys
        var items: [FileItem] = []
        items.reserveCapacity(urls.count + 1)

        for url in urls {
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
            if let security = v?.fileSecurity {
                let decoded = Self.decode(security, isDirectory: isDirectory)
                item.permissions = decoded.permissions
                item.owner = decoded.owner
                item.group = decoded.group
            }

            items.append(item)
        }

        // Cheap way to know we are not at "/" without string-comparing paths.
        if directory.pathComponents.count > 1 {
            items.insert(FileItem.parent(of: directory), at: 0)
        }
        return items
    }

    /// POSIX mode and owner out of the one prefetched NSFileSecurity, rather
    /// than a separate stat per row.
    private static func decode(_ security: NSFileSecurity,
                               isDirectory: Bool) -> (permissions: String, owner: String, group: String) {
        let cf = security as CFFileSecurity

        var permissions = ""
        var mode: mode_t = 0
        if CFFileSecurityGetMode(cf, &mode) {
            permissions.append(isDirectory ? "d" : "-")
            for shift: mode_t in [6, 3, 0] {
                let bits = (mode >> shift) & 7
                permissions.append(bits & 4 != 0 ? "r" : "-")
                permissions.append(bits & 2 != 0 ? "w" : "-")
                permissions.append(bits & 1 != 0 ? "x" : "-")
            }
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

        return (permissions, owner, group)
    }
}
