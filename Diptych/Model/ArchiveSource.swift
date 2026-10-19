import Foundation
import Darwin

/// A browsable source made from an archive: it unpacks the archive once into
/// an opaque indexed backing store, records every entry's own metadata in
/// per-directory manifests, and answers listings from those -- never from the
/// backing files, whose on-disk permissions are locked and whose names are
/// just numbers.
///
/// This is the manifest-based replacement for the direct extraction in
/// `ArchiveBrowsing`. It is built and tested on its own first; the pane is
/// pointed at it in a later step. See `object-browser-design.md`.
final class ArchiveSource: BrowserSource, @unchecked Sendable {

    typealias Failure = Archiving.Failure

    let archive: URL
    /// Everything for this opened archive: `tree/` (directory skeleton with
    /// manifests) and `store/` (indexed backing files).
    let holder: URL
    /// What the pane navigates: `holder/tree`, the archive's root.
    let root: URL

    let capabilities = BrowserManifest.Capabilities(writable: false)

    private init(archive: URL, holder: URL) {
        self.archive = archive
        self.holder = holder
        self.root = holder.appendingPathComponent("tree")
    }

    // MARK: - Building

    /// Unpacks `archive` under `holder` and writes its manifests. `holder`
    /// must not exist yet; it is made here.
    static func build(archive: URL, kind: Archiving.Kind, into holder: URL,
                      password: Archiving.PasswordFile? = nil,
                      job: Archiving.Job = Archiving.Job()) throws(Failure) -> ArchiveSource {
        let source = ArchiveSource(archive: archive, holder: holder)
        do throws(Failure) {
            try source.assemble(kind: kind, password: password, job: job)
        } catch {
            remove(holder)
            throw error
        }
        return source
    }

    private func assemble(kind: Archiving.Kind, password: Archiving.PasswordFile?,
                          job: Archiving.Job) throws(Failure) {
        let manager = FileManager()
        let work = holder.appendingPathComponent("work")
        let store = holder.appendingPathComponent("store")
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            try manager.createDirectory(at: work, withIntermediateDirectories: true)
            try manager.createDirectory(at: store, withIntermediateDirectories: true)
        } catch { throw Failure(message: error.localizedDescription) }

        let entries = try Archiving.entries(of: archive, kind: kind, password: password, job: job)
        let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        try Archiving.unpack(archive, kind: kind, into: work, password: password,
                             entries: entries, job: job)
        guard !job.isCancelled else { throw Failure(message: "Stopped.") }

        // Each directory's children, built as the extracted tree is walked.
        var children: [String: [BrowserManifest.Node]] = ["": []]
        var index = 0
        guard let walker = manager.enumerator(atPath: work.path) else {
            throw Failure(message: "The archive\u{2019}s contents could not be read.")
        }
        while let relative = walker.nextObject() as? String {
            if relative == "__MACOSX" || relative.hasPrefix("__MACOSX/") { continue }
            let onDisk = work.appendingPathComponent(relative)
            var info = stat()
            guard lstat(onDisk.path, &info) == 0 else { continue }
            let entry = byPath[Archiving.normalized(relative)]
            let parent = (relative as NSString).deletingLastPathComponent
            let leaf = (relative as NSString).lastPathComponent
            var node = BrowserManifest.Node(id: Archiving.normalized(relative),
                                            kind: .other, name: leaf)
            node.attributes[BrowserManifest.Attribute.mode] =
                .mode(entry?.mode ?? (info.st_mode & 0o7777))
            node.attributes[BrowserManifest.Attribute.uid] = .user(entry?.uid ?? info.st_uid)
            node.attributes[BrowserManifest.Attribute.gid] = .user(entry?.gid ?? info.st_gid)
            node.attributes[BrowserManifest.Attribute.modified] =
                .date(Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)

            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                node.kind = .directory
                // A bucket of its own, so a manifest is written even when it
                // is empty.
                if children[relative] == nil { children[relative] = [] }
                do { try manager.createDirectory(at: root.appendingPathComponent(relative),
                                                 withIntermediateDirectories: true) }
                catch { throw Failure(message: error.localizedDescription) }
            case S_IFLNK:
                node.kind = .symlink
                node.linkTarget = (try? manager.destinationOfSymbolicLink(atPath: onDisk.path))
            case S_IFREG:
                node.kind = .file
                node.attributes[BrowserManifest.Attribute.size] = .size(entry?.size ?? Int64(info.st_size))
                index += 1
                let slot = store.appendingPathComponent(String(index))
                do {
                    try manager.createDirectory(at: slot, withIntermediateDirectories: false)
                    try manager.moveItem(at: onDisk, to: slot.appendingPathComponent(leaf))
                } catch { throw Failure(message: error.localizedDescription) }
                node.backing = .file("store/\(index)/\(leaf)")
            default:
                node.kind = .other
            }
            children[parent, default: []].append(node)
        }

        let sha = Archiving.sha256(of: archive) ?? ""
        try writeManifests(children, sha: sha)
        try? manager.removeItem(at: work)
        lock()
    }

    /// One manifest per directory, its name chosen so it never clashes with a
    /// real subdirectory of the same name.
    private func writeManifests(_ children: [String: [BrowserManifest.Node]],
                                sha: String) throws(Failure) {
        for (directory, nodes) in children {
            let folder = directory.isEmpty ? root : root.appendingPathComponent(directory)
            let subdirectories = Set(nodes.filter { $0.kind == .directory }.map(\.name))
            let fileName = BrowserManifestStore.chooseName(avoiding: subdirectories)
            var manifest = BrowserManifest(source: "archive",
                                           nodes: nodes.sorted { $0.name < $1.name })
            manifest.origin = ["path": archive.path, "sha256": sha, "holder": holder.path]
            do { try BrowserManifestStore.write(manifest, named: fileName, in: folder) }
            catch { throw Failure(message: error.localizedDescription) }
        }
    }

    // MARK: - Reading

    func listing(of directory: String) -> [BrowserManifest.Node] {
        let folder = directory.isEmpty ? root : root.appendingPathComponent(directory)
        return BrowserManifestStore.read(in: folder)?.nodes ?? []
    }

    func localFile(for node: BrowserManifest.Node) -> URL? {
        guard case .file(let path) = node.backing else { return nil }
        return holder.appendingPathComponent(path)
    }

    // MARK: - Locking and removal

    /// The backing bytes read-only and the skeleton traversable but not
    /// writable, so even an external app cannot quietly save over them.
    private func lock() {
        let manager = FileManager()
        for place in [root, holder.appendingPathComponent("store")] {
            guard let walker = manager.enumerator(atPath: place.path) else { continue }
            while let relative = walker.nextObject() as? String {
                let path = place.appendingPathComponent(relative).path
                var info = stat()
                guard lstat(path, &info) == 0 else { continue }
                chmod(path, info.st_mode & S_IFMT == S_IFDIR ? 0o500 : 0o400)
            }
            chmod(place.path, 0o500)
        }
    }

    /// Removes a holder, giving write permission back first so the locked
    /// directories can be emptied.
    static func remove(_ holder: URL) {
        let manager = FileManager()
        guard manager.fileExists(atPath: holder.path) else { return }
        chmod(holder.path, 0o700)
        if let walker = manager.enumerator(atPath: holder.path) {
            while let relative = walker.nextObject() as? String {
                let path = holder.appendingPathComponent(relative).path
                var info = stat()
                if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
                    chmod(path, (info.st_mode & 0o7777) | 0o700)
                }
            }
        }
        try? manager.removeItem(at: holder)
    }
}
