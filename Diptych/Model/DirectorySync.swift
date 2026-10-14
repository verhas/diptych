import Foundation

/// Makes one folder of a comparison the same as the other.
///
/// The result is what deleting the target and copying the source over it
/// would leave -- content, permissions, extended attributes, access control
/// lists and dates -- but only what differs is touched: a file the comparison
/// found the same is not copied again, a file that differs only in its
/// permissions gets new permissions rather than a new copy, and a file the
/// comparison matched by content under another name is renamed rather than
/// copied a second time.
///
/// Planned first, from the comparison's own pairs, so the plan can be shown
/// before anything is changed; carried out second.
enum DirectorySync {

    enum Direction: Sendable, Equatable {
        case leftToRight, rightToLeft
        /// Each change goes whichever way it was made -- see `twoWay`.
        case both
    }

    /// One thing done to the target folder.
    struct Step: Identifiable, Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            /// Copied over, from scratch -- missing from the target, or a file
            /// there that is a folder here, or a link that differs.
            case copy
            /// The target's content replaced by the source's, in one go: a
            /// copy beside it, renamed over it.
            case replace
            /// Same content, different permissions, attributes, ACL or dates.
            case metadata
            /// Already in the target under another name: renamed there.
            case move
            /// Not in the source: removed from the target.
            case delete
        }

        let kind: Kind
        /// Where it comes from in the source folder. Nil for a delete, and
        /// for a move that only makes room under another name.
        let source: URL?
        /// The item in the target folder this step changes: where a copy
        /// lands, what a delete removes, where a move starts.
        let target: URL
        /// Where a move ends. Nil for everything else.
        let destination: URL?
        /// What the list shows, relative to the folder it belongs to -- the
        /// target's for a delete, the source's for the rest.
        let relativePath: String
        let isDirectory: Bool

        var id: String { "\(kind)|\(target.path)" }
    }

    struct Plan: Identifiable, Sendable, Equatable {
        let id = UUID()
        let direction: Direction
        let left: URL
        let right: URL
        /// In the order they run: moves before deletes, so nothing renamed out
        /// of a folder is removed with it; deletes before copies, so a file
        /// can make way for a folder of the same name.
        let steps: [Step]

        var isEmpty: Bool { steps.isEmpty }

        /// For one way only: the folder copied from, and the one changed.
        var sourceRoot: URL { direction == .rightToLeft ? right : left }
        var targetRoot: URL { direction == .rightToLeft ? left : right }

        func count(_ kind: Step.Kind) -> Int {
            steps.filter { $0.kind == kind }.count
        }

        /// "3 copied, 1 replaced, 2 deleted" -- what the plan does, in the
        /// order a reader cares about.
        var summary: String {
            let parts: [(Step.Kind, String)] = [
                (.copy, "copied"), (.replace, "replaced"), (.move, "renamed"),
                (.metadata, "with new attributes"), (.delete, "deleted"),
            ]
            let said = parts.compactMap { kind, word -> String? in
                let n = count(kind)
                return n == 0 ? nil : "\(n) \(word)"
            }
            return said.isEmpty ? "Nothing to change" : said.joined(separator: ", ")
        }
    }

    // MARK: - Planning

    /// The steps that make the target the same as the source, as far as the
    /// comparison that produced `pairs` looked.
    ///
    /// A folder copied or deleted whole takes everything under it along, so
    /// nothing under it gets a step of its own.
    static func mirror(_ pairs: [DirectoryComparison.Pair], direction: Direction,
                       left: URL, right: URL) -> Plan {
        let targetRoot = direction == .leftToRight ? right : left
        func source(_ pair: DirectoryComparison.Pair) -> DirectoryComparison.Entry? {
            direction == .leftToRight ? pair.left : pair.right
        }
        func target(_ pair: DirectoryComparison.Pair) -> DirectoryComparison.Entry? {
            direction == .leftToRight ? pair.right : pair.left
        }

        var copies: [DirectoryComparison.Entry] = []
        var deletes: [DirectoryComparison.Entry] = []
        var replaces: [(DirectoryComparison.Entry, DirectoryComparison.Entry)] = []
        var metadata: [(DirectoryComparison.Entry, DirectoryComparison.Entry)] = []
        var moves: [(from: DirectoryComparison.Entry, to: DirectoryComparison.Entry)] = []

        for pair in pairs where pair.status != .same {
            switch (source(pair), target(pair)) {
            case let (s?, nil):
                copies.append(s)
            case let (nil, t?):
                deletes.append(t)
            case let (s?, t?):
                if pair.isRename {
                    moves.append((from: t, to: s))
                } else if pair.differences.contains(.kind) || s.isSymlink || t.isSymlink {
                    // A link is cheaper made again than corrected, and a file
                    // cannot be turned into a folder in place.
                    deletes.append(t)
                    copies.append(s)
                } else if !s.isDirectory,
                          !pair.differences.isDisjoint(with: [.content, .size]) {
                    replaces.append((s, t))
                } else if !pair.differences.isEmpty {
                    metadata.append((s, t))
                }
            case (nil, nil):
                continue
            }
        }

        let copiedFolders = Set(copies.filter(\.isDirectory).map(\.relativePath))

        // A rename into a folder that is copied whole would land in a folder
        // that is not there yet; the copy brings that file along anyway, so
        // the old one only has to go.
        var keptMoves: [(from: DirectoryComparison.Entry, to: DirectoryComparison.Entry)] = []
        for move in moves {
            if hasAncestor(move.to.relativePath, in: copiedFolders) {
                deletes.append(move.from)
            } else {
                keptMoves.append(move)
            }
        }

        let deletedFolders = Set(deletes.filter(\.isDirectory).map(\.relativePath))
        let byPath: (DirectoryComparison.Entry, DirectoryComparison.Entry) -> Bool = {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }

        var steps: [Step] = []
        for move in keptMoves.sorted(by: { byPath($0.to, $1.to) }) {
            steps.append(Step(kind: .move, source: move.to.url, target: move.from.url,
                              destination: targetRoot.appendingPathComponent(move.to.relativePath),
                              relativePath: move.to.relativePath, isDirectory: false))
        }
        for entry in deletes.sorted(by: byPath)
        where !hasAncestor(entry.relativePath, in: deletedFolders) {
            steps.append(Step(kind: .delete, source: nil, target: entry.url, destination: nil,
                              relativePath: entry.relativePath, isDirectory: entry.isDirectory))
        }
        for entry in copies.sorted(by: byPath)
        where !hasAncestor(entry.relativePath, in: copiedFolders) {
            steps.append(Step(kind: .copy, source: entry.url,
                              target: targetRoot.appendingPathComponent(entry.relativePath),
                              destination: nil, relativePath: entry.relativePath,
                              isDirectory: entry.isDirectory))
        }
        for (s, t) in replaces.sorted(by: { byPath($0.0, $1.0) }) {
            steps.append(Step(kind: .replace, source: s.url, target: t.url, destination: nil,
                              relativePath: s.relativePath, isDirectory: false))
        }
        for (s, t) in metadata.sorted(by: { byPath($0.0, $1.0) }) {
            steps.append(Step(kind: .metadata, source: s.url, target: t.url, destination: nil,
                              relativePath: s.relativePath, isDirectory: s.isDirectory))
        }
        return Plan(direction: direction, left: left, right: right, steps: steps)
    }

    /// Whether a folder above `path` -- not `path` itself -- is in `folders`.
    static func hasAncestor(_ path: String, in folders: Set<String>) -> Bool {
        guard !folders.isEmpty else { return false }
        var parent = (path as NSString).deletingLastPathComponent
        while !parent.isEmpty {
            if folders.contains(parent) { return true }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return false
    }

    // MARK: - Carrying it out

    struct Failure: Sendable, Equatable {
        let relativePath: String
        let message: String
    }

    struct Outcome: Sendable {
        var done = 0
        var failures: [Failure] = []
        var cancelled = false
    }

    /// Runs the plan, step by step, carrying on past a step that fails.
    ///
    /// `progress` hears the number of the step about to run and its path.
    /// Deletions go to the Trash unless `deleteOutright` says otherwise -- a
    /// server's volume often has no Trash to go to.
    static func run(_ plan: Plan, deleteOutright: Bool, monitor: TransferMonitor,
                    progress: @escaping @Sendable (Int, String) -> Void) async -> Outcome {
        var outcome = Outcome()
        // Which folders had something copied in or taken out, by side.
        var touched: Set<SideFolder> = []

        for (index, step) in plan.steps.enumerated() {
            if monitor.isCancelled { outcome.cancelled = true; break }
            progress(index, step.relativePath)

            let problem: String?
            switch step.kind {
            case .delete:
                problem = await remove(step.target, outright: deleteOutright)
            case .replace:
                problem = await replace(step, outright: deleteOutright, monitor: monitor)
            default:
                problem = await BlockingWork.run { perform(step, monitor: monitor) }
            }

            if monitor.isCancelled, problem != nil { outcome.cancelled = true; break }
            if let problem {
                outcome.failures.append(Failure(relativePath: step.relativePath, message: problem))
            } else {
                outcome.done += 1
            }
            for url in [step.target, step.destination].compactMap({ $0 }) {
                let folder = url.deletingLastPathComponent()
                if let path = relative(folder, to: plan.left) {
                    touched.insert(SideFolder(onLeft: true, path: path))
                } else if let path = relative(folder, to: plan.right) {
                    touched.insert(SideFolder(onLeft: false, path: path))
                }
            }
        }

        // Copying into a folder, or removing from it, makes the folder itself
        // look modified just now. The other side's date goes on, as a copy
        // made from scratch would have it -- unless that side's folder was
        // changed too, and has no older date left to give.
        let (left, right, folders) = (plan.left, plan.right, touched)
        await BlockingWork.run {
            for folder in folders
            where !folders.contains(SideFolder(onLeft: !folder.onLeft, path: folder.path)) {
                restoreFolderDate(folder.path,
                                  from: folder.onLeft ? right : left,
                                  to: folder.onLeft ? left : right)
            }
        }
        return outcome
    }

    /// The path of `url` inside `root`, "" for the root itself; nil when it
    /// is not inside at all.
    private static func relative(_ url: URL, to root: URL) -> String? {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == base { return "" }
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }

    private struct SideFolder: Hashable, Sendable {
        let onLeft: Bool
        let path: String
    }

    private static func restoreFolderDate(_ path: String, from sourceRoot: URL, to targetRoot: URL) {
        let source = path.isEmpty ? sourceRoot : sourceRoot.appendingPathComponent(path)
        let target = path.isEmpty ? targetRoot : targetRoot.appendingPathComponent(path)
        guard FileManager.isFolder(source), FileManager.isFolder(target) else { return }
        copyDates(from: source.path, to: target.path, modification: true)
    }

    /// To the Trash, or gone for good.
    private static func remove(_ url: URL, outright: Bool) async -> String? {
        let result = outright
            ? await FileOperations.shared.deleteOutright([url])
            : await FileOperations.shared.trash([url])
        return result.failures.first?.message
    }

    /// The new content is copied beside the old one first, so the old file
    /// stays whole until the new one is -- which matters most on a server
    /// that can drop the connection half way. Then the old one goes, to the
    /// Trash like any delete, and the copy takes its name.
    private static func replace(_ step: Step, outright: Bool,
                                monitor: TransferMonitor) async -> String? {
        guard let source = step.source else { return nil }
        let spare = step.target.deletingLastPathComponent().appendingPathComponent(
            ".\(step.target.lastPathComponent).diptych-\(UUID().uuidString.prefix(8))")
        let copied: String? = await BlockingWork.run {
            switch FileOperations.copyWithProgress(source, to: spare, monitor: monitor) {
            case .done: return nil
            case .cancelled: return "Stopped."
            case .failed(let message): return message
            }
        }
        let discardSpare = { await BlockingWork.run { try? FileManager().removeItem(at: spare) } }
        if let copied {
            await discardSpare()
            return copied
        }
        if let problem = await remove(step.target, outright: outright) {
            await discardSpare()
            return problem
        }
        return await BlockingWork.run { () -> String? in
            guard Darwin.rename(spare.path, step.target.path) != 0 else { return nil }
            return String(cString: strerror(errno))
                + ". The new copy is beside it, as \u{201C}\(spare.lastPathComponent)\u{201D}."
        }
    }

    /// One step that is not a delete or a replace. Nil when it worked, what went wrong
    /// when it did not.
    nonisolated static func perform(_ step: Step, monitor: TransferMonitor) -> String? {
        if step.kind == .move, let destination = step.destination {
            guard !FileOperations.exists(destination) else {
                return "\u{201C}\(destination.lastPathComponent)\u{201D} is already there."
            }
            guard Darwin.rename(step.target.path, destination.path) == 0 else {
                return String(cString: strerror(errno))
            }
            return step.source.flatMap { copyMetadata(from: $0, to: destination) }
        }
        guard let source = step.source else { return nil }
        let fm = FileManager()
        switch step.kind {
        case .delete:
            return nil

        case .copy:
            switch FileOperations.copyWithProgress(source, to: step.target, monitor: monitor) {
            case .done:
                return nil
            case .cancelled:
                try? fm.removeItem(at: step.target)
                return "Stopped."
            case .failed(let message):
                return message
            }

        case .replace:
            return nil

        case .metadata:
            return copyMetadata(from: source, to: step.target)

        case .move:
            return nil
        }
    }

    /// Permissions, owner and group where allowed, dates, extended attributes
    /// and the access control list -- everything but the bytes. Attributes
    /// the target has and the source does not are removed.
    nonisolated static func copyMetadata(from source: URL, to target: URL) -> String? {
        let flags = copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_XATTR | COPYFILE_STAT
                                     | COPYFILE_NOFOLLOW)
        guard copyfile(source.path, target.path, nil, flags) == 0 else {
            return String(cString: strerror(errno))
        }
        copyCreationDates(from: source, to: target)
        return nil
    }

    /// `copyfile` keeps the modification date but not the creation date: the
    /// copy is born when it is made, and comes out with its modification date
    /// as its creation date. Set from the source's, for the item and, for a
    /// folder, for everything in it.
    nonisolated static func copyCreationDates(from source: URL, to target: URL) {
        copyDates(from: source.path, to: target.path, modification: false)
        guard FileManager.isFolder(source),
              let walker = FileManager().enumerator(atPath: source.path) else { return }
        while let path = walker.nextObject() as? String {
            copyDates(from: source.appendingPathComponent(path).path,
                      to: target.appendingPathComponent(path).path, modification: false)
        }
    }

    /// The creation date, and the modification date too when asked, copied
    /// to the nanosecond -- through `Date`, a `Double`, the last digits get
    /// lost, and the comparison then finds the two a hair apart. A link's
    /// own dates, never its target's.
    @discardableResult
    nonisolated static func copyDates(from source: String, to target: String,
                                      modification: Bool) -> Bool {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_CRTIME) | attrgroup_t(ATTR_CMN_MODTIME)
        let size = MemoryLayout<timespec>.size
        // A length, then the two dates in the order of their bits, packed
        // four-byte aligned -- not a Swift struct, which would pad.
        var buffer = [UInt8](repeating: 0, count: 4 + 2 * size)
        guard getattrlist(source, &list, &buffer, buffer.count,
                          UInt32(FSOPT_NOFOLLOW)) == 0 else { return false }
        if !modification {
            list.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        }
        let dates = Array(buffer[4..<(4 + (modification ? 2 : 1) * size)])
        return dates.withUnsafeBytes {
            setattrlist(target, &list, UnsafeMutableRawPointer(mutating: $0.baseAddress),
                        $0.count, UInt32(FSOPT_NOFOLLOW)) == 0
        }
    }
}

private extension FileManager {
    /// A real folder, not a link to one.
    static func isFolder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }
}
