import Foundation

/// Two folders, entry by entry.
///
/// Two directories are the same when they hold the same files: the same
/// relative path, the same permissions, the same extended attributes, the
/// same size, the same content byte for byte, and the same access control
/// list. A file moved without being touched -- the shape a rename takes when
/// a folder is copied -- is still matched, by content rather than by path. A
/// folder itself is compared the same way minus the two things only a file
/// has: size and content.
enum DirectoryComparison {

    /// What one run of the comparison actually looks at.
    ///
    /// Content has no setting of its own and is always on by default -- it is
    /// the one thing "these two folders are the same" cannot mean without --
    /// but a window may still switch it off for a single run, which is why it
    /// lives here rather than being hard-coded `true`.
    struct Options: Sendable, Equatable {
        var compareContent = true
        var comparePermissions = true
        var compareAttributes = true
        var compareACL = true
        /// Off by default: a fresh copy commonly gets a new creation date and
        /// sometimes a new modification date depending on how it was made, so
        /// these are noise more often than they are signal.
        var compareModificationDate = false
        var compareCreationDate = false
        /// One switch for both, not two: an owner is meaningless without its
        /// group, and nothing here has ever asked about one without the other.
        var compareOwnership = false
        /// Off: a hidden folder (its name starts with a dot, such as `.git`)
        /// still appears in the list, but its contents are not walked.
        var recurseHiddenDirectories = false
    }

    /// One file, folder or symlink found under a root, keyed by its path
    /// relative to that root.
    struct Entry: Sendable {
        var url: URL
        var relativePath: String
        var name: String
        var isDirectory: Bool
        var isSymlink: Bool
        var byteSize: Int64
        var mode: mode_t
        var owner: String
        var group: String
        var modified: Date
        var created: Date
        /// Where a symlink points, exactly as stored. Empty for everything
        /// else.
        var linkTarget: String
        var attributes: AttributeSnapshot
        /// Nil when the file carries no access control list at all.
        var acl: String?

        var permissions: String {
            (isDirectory ? "d" : "-") + FileOperations.rwxString(mode)
        }
    }

    /// Every extended attribute a file carries, split into the ones that could
    /// be read and the ones macOS refused -- some attributes live in a private
    /// namespace no process may read, root included, and dropping them from
    /// the comparison would call two files the same when one of them carries
    /// something the other does not.
    struct AttributeSnapshot: Sendable, Equatable {
        var readable: [String: Data] = [:]
        var unreadableNames: Set<String> = []

        static func read(at path: String) -> AttributeSnapshot {
            var snapshot = AttributeSnapshot()
            for name in ExtendedAttributes.names(of: path) {
                if let data = ExtendedAttributes.data(of: path, name: name) {
                    snapshot.readable[name] = data
                } else {
                    snapshot.unreadableNames.insert(name)
                }
            }
            return snapshot
        }

        /// The link's own attributes, not the target's.
        ///
        /// `listxattr`/`getxattr` follow a symlink by default, the same as any
        /// other path-based call -- fine for Get Info, which shows a symlink's
        /// target deliberately, wrong here: a link is never followed anywhere
        /// else in this comparison, and reading through it would blame two
        /// links for whatever their unrelated targets happen to carry, or fail
        /// outright when one target does not exist.
        static func readNoFollow(at path: String) -> AttributeSnapshot {
            var snapshot = AttributeSnapshot()
            let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return snapshot }
            var buffer = [CChar](repeating: 0, count: size)
            guard listxattr(path, &buffer, size, XATTR_NOFOLLOW) > 0 else { return snapshot }

            for name in buffer.split(separator: 0).map({
                String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }) {
                let dataSize = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
                guard dataSize >= 0 else { snapshot.unreadableNames.insert(name); continue }
                var data = Data(count: dataSize)
                let read = data.withUnsafeMutableBytes {
                    getxattr(path, name, $0.baseAddress, dataSize, 0, XATTR_NOFOLLOW)
                }
                if read >= 0 { snapshot.readable[name] = data }
                else { snapshot.unreadableNames.insert(name) }
            }
            return snapshot
        }
    }

    /// The link's own access control list -- `acl_get_link_np`, not
    /// `acl_get_file`, for the reason `readNoFollow` does not use plain
    /// `getxattr`.
    private static func acl(at path: String, isSymlink: Bool) -> String? {
        guard isSymlink else { return AccessControl.text(of: path) }
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length: ssize_t = 0
        guard let raw = acl_to_text(acl, &length) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(raw)) }
        return String(cString: raw)
    }

    /// What sets two matched entries apart. A pair can carry more than one.
    struct Difference: OptionSet, Sendable {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }

        /// One side is a folder, the other a file, at the same relative path.
        /// Reported alone: once this is true, nothing else about the two is
        /// worth comparing.
        static let kind = Difference(rawValue: 1 << 0)
        /// Matched by content rather than by path -- the pair's name, or its
        /// place in the tree, is not the same on both sides.
        static let name = Difference(rawValue: 1 << 1)
        static let size = Difference(rawValue: 1 << 2)
        static let content = Difference(rawValue: 1 << 3)
        static let permissions = Difference(rawValue: 1 << 4)
        static let attributes = Difference(rawValue: 1 << 5)
        static let acl = Difference(rawValue: 1 << 6)
        static let modified = Difference(rawValue: 1 << 7)
        static let created = Difference(rawValue: 1 << 8)
        /// Owner and group together -- see `Options.compareOwnership`.
        static let ownership = Difference(rawValue: 1 << 9)

        var summary: String {
            if contains(.kind) { return "one is a file, the other a folder" }
            var parts: [String] = []
            if contains(.name) { parts.append("name") }
            if contains(.size) { parts.append("size") }
            if contains(.content) { parts.append("content") }
            if contains(.permissions) { parts.append("permissions") }
            if contains(.attributes) { parts.append("extended attributes") }
            if contains(.acl) { parts.append("access control list") }
            if contains(.modified) { parts.append("modification date") }
            if contains(.created) { parts.append("creation date") }
            if contains(.ownership) { parts.append("owner or group") }
            return parts.joined(separator: ", ")
        }
    }

    enum Status: Sendable, Hashable {
        case same, differs, onlyLeft, onlyRight
    }

    /// One row of the comparison: a pair matched by name or by content, or an
    /// entry that exists on only one side.
    struct Pair: Identifiable, Sendable {
        let id: String
        var left: Entry?
        var right: Entry?
        var status: Status
        var differences: Difference
        /// Matched by content rather than by relative path -- a rename.
        var isRename: Bool
        /// Other files, either side, holding exactly the same bytes as this
        /// side's -- not this pair's own partner, which is already shown
        /// beside it. Relative paths, sorted; empty when there are none.
        var leftContentSiblings: [String] = []
        var rightContentSiblings: [String] = []

        var isDirectory: Bool { (left ?? right)?.isDirectory ?? false }

        /// A double-click or Cmd-D can open this pair for a closer look: both
        /// sides are still there, neither is a symlink, and they agree on
        /// being a file or being a folder. Two files open in the existing
        /// file-comparison window; two folders open a comparison of their own,
        /// narrowed to just the two of them.
        var canOpenComparison: Bool {
            guard let left, let right else { return false }
            return !left.isSymlink && !right.isSymlink && left.isDirectory == right.isDirectory
        }

        enum NewerSide: Sendable, Equatable { case left, right }

        /// Which side has the later date, when a date is among what differs.
        /// Modification takes precedence over creation when both do -- it is
        /// the date that answers "which one was actually touched last", and
        /// the more useful of the two to lead with.
        var newerSide: NewerSide? {
            guard let left, let right else { return nil }
            if differences.contains(.modified), left.modified != right.modified {
                return left.modified > right.modified ? .left : .right
            }
            if differences.contains(.created), left.created != right.created {
                return left.created > right.created ? .left : .right
            }
            return nil
        }
    }

    // MARK: - Comparing

    static func compare(left leftRoot: URL, right rightRoot: URL,
                        options: Options = Options()) throws -> [Pair] {
        try Task.checkCancellation()
        var leftOnly = walk(leftRoot, options: options)
        var rightOnly = walk(rightRoot, options: options)
        try Task.checkCancellation()

        var pairs: [Pair] = []
        for path in Set(leftOnly.keys).intersection(rightOnly.keys) {
            guard let left = leftOnly.removeValue(forKey: path),
                  let right = rightOnly.removeValue(forKey: path) else { continue }
            let diff = comparePair(left, right, options: options)
            pairs.append(Pair(id: path, left: left, right: right,
                              status: diff.isEmpty ? .same : .differs,
                              differences: diff, isRename: false))
        }

        try Task.checkCancellation()
        pairs.append(contentsOf: matchRenames(&leftOnly, &rightOnly, options: options))

        for entry in leftOnly.values {
            pairs.append(Pair(id: "L:" + entry.relativePath, left: entry, right: nil,
                              status: .onlyLeft, differences: [], isRename: false))
        }
        for entry in rightOnly.values {
            pairs.append(Pair(id: "R:" + entry.relativePath, left: nil, right: entry,
                              status: .onlyRight, differences: [], isRename: false))
        }

        pairs.sort {
            sortKey($0).localizedStandardCompare(sortKey($1)) == .orderedAscending
        }

        try Task.checkCancellation()
        return withContentSiblings(pairs)
    }

    /// Fills in `leftContentSiblings`/`rightContentSiblings`: for every file
    /// in the comparison, every *other* file, on either side, that holds
    /// exactly the same bytes.
    ///
    /// A rename match only ever accounts for one such duplicate. Building a
    /// copy of a folder often leaves more than one -- a template re-saved
    /// under a new name, an empty scaffold reused for several files -- and
    /// without this the second one just looks like an ordinary, unrelated
    /// pair, or an ordinary, unrelated single, with nothing to say they are
    /// the same file in every way that matters.
    private static func withContentSiblings(_ pairs: [Pair]) -> [Pair] {
        let bySlot = contentSiblingSlots(of: pairs)
        guard !bySlot.isEmpty else { return pairs }

        return pairs.map { pair in
            var pair = pair
            if let left = pair.left {
                let partner = pair.right.map { "R:" + $0.relativePath }
                pair.leftContentSiblings = (bySlot["L:" + left.relativePath] ?? [])
                    .filter { $0.key != partner }
                    .map(\.relativePath).sorted()
            }
            if let right = pair.right {
                let partner = pair.left.map { "L:" + $0.relativePath }
                pair.rightContentSiblings = (bySlot["R:" + right.relativePath] ?? [])
                    .filter { $0.key != partner }
                    .map(\.relativePath).sorted()
            }
            return pair
        }
    }

    /// One file, wherever it sits in either tree, worth naming in a "same
    /// content" hint -- keyed the same way `Pair.id` keys a single, so a
    /// pair's own partner can be excluded from its own list by the same key.
    private struct ContentSlot {
        let key: String
        let relativePath: String
        let entry: Entry
    }

    /// Groups every non-empty, non-folder, non-symlink file across both
    /// trees by identical content, by size first -- cheap, and it keeps the
    /// byte comparisons that follow down to files that could actually match
    /// -- then by bytes within a size. Empty files are left out entirely:
    /// every empty file matches every other one, and a hint that says so
    /// would say nothing.
    private static func contentSiblingSlots(of pairs: [Pair]) -> [String: [ContentSlot]] {
        var slots: [ContentSlot] = []
        for pair in pairs {
            if let left = pair.left, !left.isDirectory, !left.isSymlink, left.byteSize > 0 {
                slots.append(ContentSlot(key: "L:" + left.relativePath,
                                        relativePath: left.relativePath, entry: left))
            }
            if let right = pair.right, !right.isDirectory, !right.isSymlink, right.byteSize > 0 {
                slots.append(ContentSlot(key: "R:" + right.relativePath,
                                        relativePath: right.relativePath, entry: right))
            }
        }

        var bySize: [Int64: [ContentSlot]] = [:]
        for slot in slots { bySize[slot.entry.byteSize, default: []].append(slot) }

        var result: [String: [ContentSlot]] = [:]
        for group in bySize.values where group.count > 1 {
            var clusters: [[ContentSlot]] = []
            for slot in group {
                if let index = clusters.firstIndex(where: { cluster in
                    guard let first = cluster.first else { return false }
                    return (try? BinaryComparison.compare(first.entry.url, slot.entry.url)
                        .isIdentical) == true
                }) {
                    clusters[index].append(slot)
                } else {
                    clusters.append([slot])
                }
            }
            for cluster in clusters where cluster.count > 1 {
                for slot in cluster {
                    result[slot.key] = cluster.filter { $0.key != slot.key }
                }
            }
        }
        return result
    }

    private static func sortKey(_ pair: Pair) -> String {
        pair.left?.relativePath ?? pair.right?.relativePath ?? ""
    }

    /// Files left unmatched by name, paired up when one side is byte-for-byte
    /// the other -- the common shape of a rename in a copied folder.
    ///
    /// Grouped by size first, which is cheap and keeps the byte comparisons
    /// that follow down to files that could actually match. Folders and
    /// symlinks are never matched this way: a folder carries no bytes of its
    /// own, and a symlink already stands for its target rather than for bytes
    /// on disk. Nothing is matched this way at all when content is not being
    /// compared -- a rename *is* a content match, and there is no other way
    /// to tell one from an unrelated file of the same size.
    private static func matchRenames(_ leftOnly: inout [String: Entry],
                                     _ rightOnly: inout [String: Entry],
                                     options: Options) -> [Pair] {
        guard options.compareContent else { return [] }

        let leftFiles = leftOnly.values
            .filter { !$0.isDirectory && !$0.isSymlink }
            .sorted { $0.relativePath < $1.relativePath }
        guard !leftFiles.isEmpty else { return [] }

        var rightBySize: [Int64: [Entry]] = [:]
        for entry in rightOnly.values where !entry.isDirectory && !entry.isSymlink {
            rightBySize[entry.byteSize, default: []].append(entry)
        }

        var pairs: [Pair] = []
        for left in leftFiles {
            guard let candidates = rightBySize[left.byteSize], !candidates.isEmpty else { continue }
            guard let match = candidates.first(where: {
                (try? BinaryComparison.compare(left.url, $0.url).isIdentical) ?? false
            }) else { continue }

            leftOnly.removeValue(forKey: left.relativePath)
            rightOnly.removeValue(forKey: match.relativePath)
            rightBySize[left.byteSize]?.removeAll { $0.relativePath == match.relativePath }

            // Always at least `.name`: matching by content rather than by
            // path is exactly what makes this a rename instead of a plain
            // match, and it is worth a badge of its own for the same reason
            // the other differences are.
            let diff = comparePair(left, match, options: options).union(.name)
            pairs.append(Pair(id: "rename:\(left.relativePath)\u{2194}\(match.relativePath)",
                              left: left, right: match, status: .differs,
                              differences: diff, isRename: true))
        }
        return pairs
    }

    private static func comparePair(_ left: Entry, _ right: Entry, options: Options) -> Difference {
        guard left.isDirectory == right.isDirectory else { return .kind }

        var diff: Difference = []
        if options.comparePermissions, left.mode != right.mode { diff.insert(.permissions) }
        // Empty on both sides whenever the matching option is off, since
        // `walk` never read them in that case -- so this stays silent rather
        // than needing its own guard.
        if left.attributes != right.attributes { diff.insert(.attributes) }
        if (left.acl ?? "") != (right.acl ?? "") { diff.insert(.acl) }
        if options.compareModificationDate, left.modified != right.modified {
            diff.insert(.modified)
        }
        if options.compareCreationDate, left.created != right.created { diff.insert(.created) }
        if options.compareOwnership, left.owner != right.owner || left.group != right.group {
            diff.insert(.ownership)
        }

        if left.isSymlink || right.isSymlink {
            if options.compareContent, left.linkTarget != right.linkTarget { diff.insert(.content) }
            return diff
        }
        guard !left.isDirectory else { return diff }

        // Size is treated as part of content rather than checked on its own:
        // a size that came from a byte comparison nobody asked for would be
        // exactly that comparison in a smaller disguise, and somebody who
        // switched content off to ignore two files that differ would still
        // see them flagged as different.
        guard options.compareContent else { return diff }

        if left.byteSize != right.byteSize {
            diff.insert(.size)
            diff.insert(.content)
            return diff
        }
        // Sizes agree, so the bytes are worth reading. A file that could not
        // be opened counts as differing rather than as silently the same.
        let identical = (try? BinaryComparison.compare(left.url, right.url).isIdentical) ?? false
        if !identical { diff.insert(.content) }
        return diff
    }

    // MARK: - Walking a tree

    private static func walk(_ root: URL, options: Options) -> [String: Entry] {
        let fm = FileManager()
        var result: [String: Entry] = [:]
        let keys: Set<URLResourceKey> = [
            .nameKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .fileSecurityKey,
            .contentModificationDateKey, .creationDateKey,
        ]
        // The path-based enumerator, not the URL-based one: it hands back each
        // entry's path already relative to `root`, sidestepping `/var` versus
        // `/private/var` -- macOS resolves that inconsistently between a URL
        // and the absolute paths an enumerator builds from it, which turned a
        // child's path into neither a prefix match nor a resolvable one.
        guard let walker = fm.enumerator(atPath: root.path) else { return result }

        while let relative = walker.nextObject() as? String {
            let url = root.appendingPathComponent(relative)
            let v = try? url.resourceValues(forKeys: keys)
            let isSymlink = v?.isSymbolicLink ?? false
            var isDirectory = v?.isDirectory ?? false
            let name = v?.name ?? url.lastPathComponent
            if isSymlink {
                // Not followed: `.isDirectoryKey` already says false for the
                // link itself, and descending into it risks a cycle.
                walker.skipDescendants()
                var target: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &target) {
                    isDirectory = target.boolValue
                }
            } else if isDirectory, !options.recurseHiddenDirectories, name.hasPrefix(".") {
                // The folder itself still shows up in the list -- only what
                // is inside it is left unexamined.
                walker.skipDescendants()
            }

            var mode: mode_t = 0
            var owner = ""
            var group = ""
            if let security = v?.fileSecurity {
                let cf = security as CFFileSecurity
                _ = CFFileSecurityGetMode(cf, &mode)
                var uid: uid_t = 0
                if CFFileSecurityGetOwner(cf, &uid), let pw = getpwuid(uid) {
                    owner = String(cString: pw.pointee.pw_name)
                }
                var gid: gid_t = 0
                if CFFileSecurityGetGroup(cf, &gid), let gr = getgrgid(gid) {
                    group = String(cString: gr.pointee.gr_name)
                }
            }

            let linkTarget = isSymlink
                ? ((try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? "") : ""

            result[relative] = Entry(
                url: url,
                relativePath: relative,
                name: name,
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                byteSize: Int64(v?.fileSize ?? 0),
                mode: mode,
                owner: owner,
                group: group,
                modified: v?.contentModificationDate ?? .distantPast,
                created: v?.creationDate ?? .distantPast,
                linkTarget: linkTarget,
                attributes: options.compareAttributes
                    ? (isSymlink ? .readNoFollow(at: url.path) : .read(at: url.path))
                    : AttributeSnapshot(),
                acl: options.compareACL ? acl(at: url.path, isSymlink: isSymlink) : nil)
        }
        return result
    }
}

/// What a directory-comparison window is opened for.
struct DirectoryDiffPair: Hashable, Codable, Sendable {
    var left: URL
    var right: URL

    /// What the window is called. Two folders of the same name are told apart
    /// by the part of their paths that differs, for the same reason a diff
    /// window does it for two files of the same name.
    var title: String {
        let mine = left.lastPathComponent
        let theirs = right.lastPathComponent
        guard mine == theirs else { return "\(mine) \u{2194} \(theirs)" }
        return "\(distinguishing(left)) \u{2194} \(distinguishing(right))"
    }

    private func distinguishing(_ url: URL) -> String {
        let leftParts = left.pathComponents
        let rightParts = right.pathComponents
        var common = 0
        while common < leftParts.count, common < rightParts.count,
              leftParts[common] == rightParts[common] { common += 1 }
        let parts = url.pathComponents
        guard common < parts.count else { return url.lastPathComponent }
        return "\u{2026}/" + parts[common...].joined(separator: "/")
    }
}
