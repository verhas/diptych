import CryptoKit
import Foundation

/// How two folders stood the last time they were synced: for every path that
/// was the same on both sides then, what each side looked like.
///
/// What makes a sync both ways possible. A file on one side only was either
/// made there since, or deleted on the other side -- the two folders alone
/// cannot tell which, and the answers are opposite: copy it across, or delete
/// it too. Against the last sync they can.
struct SyncBaseline: Codable, Sendable, Equatable {

    /// One side of one path, as much of it as tells whether it has changed:
    /// size and modification date for the bytes -- what rsync and Unison look
    /// at too, without reading every file again -- and a digest of the rest.
    struct State: Codable, Sendable, Equatable {
        var isDirectory: Bool
        var isSymlink: Bool
        var size: Int64
        var modified: Date
        var mode: UInt16
        /// Extended attributes, ACL, owner, group and a link's target.
        var digest: String

        init(_ entry: DirectoryComparison.Entry) {
            isDirectory = entry.isDirectory
            isSymlink = entry.isSymlink
            size = entry.byteSize
            modified = entry.modified
            mode = UInt16(entry.mode)
            var hash = SHA256()
            for (name, data) in entry.attributes.readable.sorted(by: { $0.key < $1.key }) {
                hash.update(data: Data(name.utf8))
                hash.update(data: data)
            }
            for name in entry.attributes.unreadableNames.sorted() {
                hash.update(data: Data(("?" + name).utf8))
            }
            for text in [entry.acl ?? "", entry.owner, entry.group, entry.linkTarget] {
                hash.update(data: Data(("\u{0}" + text).utf8))
            }
            digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }

        /// Whether `now` is the same item as this, unchanged. A folder's own
        /// dates and size move whenever something inside it does, so only
        /// what a folder itself carries counts for one.
        func isUnchanged(_ now: State) -> Bool {
            guard isDirectory == now.isDirectory, isSymlink == now.isSymlink,
                  mode == now.mode, digest == now.digest else { return false }
            return isDirectory || (size == now.size && modified == now.modified)
        }
    }

    struct Sides: Codable, Sendable, Equatable {
        var left: State
        var right: State
    }

    /// Canonical paths, so the same two folders are found again however they
    /// were reached.
    var left: String
    var right: String
    var synced: Date
    var entries: [String: Sides]

    /// The same record, the two sides the other way round -- for the same
    /// two folders compared with the panes swapped.
    var swapped: SyncBaseline {
        SyncBaseline(left: right, right: left, synced: synced,
                     entries: entries.mapValues { Sides(left: $0.right, right: $0.left) })
    }

    /// The record after a sync, from the comparison made right after it.
    ///
    /// A path the same on both sides now is recorded as it is now. One that
    /// still differs -- a step failed, or a choice was skipped -- keeps what
    /// was recorded before, so it comes up the same way next time: a delete
    /// that failed is tried again rather than taken back.
    static func after(_ pairs: [DirectoryComparison.Pair], left: URL, right: URL,
                      previous: SyncBaseline?) -> SyncBaseline {
        var entries: [String: Sides] = [:]
        var present: Set<String> = []
        for pair in pairs {
            if let l = pair.left { present.insert(l.relativePath) }
            if let r = pair.right { present.insert(r.relativePath) }
            guard let l = pair.left, let r = pair.right, !pair.isRename,
                  pair.status == .same || isSameFolder(pair) else { continue }
            entries[l.relativePath] = Sides(left: State(l), right: State(r))
        }
        for (path, sides) in previous?.entries ?? [:]
        where entries[path] == nil && present.contains(path) {
            entries[path] = sides
        }
        return SyncBaseline(left: FileOperations.canonicalPath(left),
                            right: FileOperations.canonicalPath(right),
                            synced: Date(), entries: entries)
    }

    /// Two folders that differ only in their dates are the same folder:
    /// their dates follow whatever happens inside them.
    private static func isSameFolder(_ pair: DirectoryComparison.Pair) -> Bool {
        pair.isDirectory && pair.differences.isSubset(of: [.modified, .created])
    }
}

/// Where the records are kept: one JSON file per pair of folders, in
/// `~/.diptych/sync`, named by a digest of the two paths.
nonisolated final class SyncBaselineStore: @unchecked Sendable {

    static let shared = SyncBaselineStore(directory: FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent(".diptych/sync"))

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The record for these two folders, whichever side each was on then.
    func baseline(left: URL, right: URL) -> SyncBaseline? {
        let l = FileOperations.canonicalPath(left)
        let r = FileOperations.canonicalPath(right)
        if let found = read(l, r), found.left == l { return found }
        if let found = read(r, l), found.left == r { return found.swapped }
        return nil
    }

    func save(_ baseline: SyncBaseline) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        try encoder.encode(baseline).write(to: file(baseline.left, baseline.right),
                                           options: .atomic)
    }

    /// Forgets these two folders were ever synced: the next sync both ways
    /// starts again as the first.
    func forget(left: URL, right: URL) {
        let l = FileOperations.canonicalPath(left)
        let r = FileOperations.canonicalPath(right)
        try? FileManager.default.removeItem(at: file(l, r))
        try? FileManager.default.removeItem(at: file(r, l))
    }

    private func read(_ left: String, _ right: String) -> SyncBaseline? {
        guard let data = try? Data(contentsOf: file(left, right)) else { return nil }
        return try? JSONDecoder().decode(SyncBaseline.self, from: data)
    }

    private func file(_ left: String, _ right: String) -> URL {
        let digest = SHA256.hash(data: Data((left + "\u{0}" + right).utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }
}
