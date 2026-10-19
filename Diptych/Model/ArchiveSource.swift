import Foundation
import Darwin

/// A browsable source made from an archive.
///
/// The archive is unpacked once, as the user, into a real directory tree under
/// the caches -- so everything that works on files (Quick Look, Compare, copy
/// and drag out, the flat view, Find Duplicates) works inside it -- and that
/// tree is locked read-only so nothing, not even an external app, can quietly
/// write over the copy. Beside the files, each directory carries a manifest
/// recording the archive's own metadata: the directory loader lists the real
/// folder for names and bytes and overlays the manifest for the permissions,
/// owner and group the locked copy cannot show.
///
/// This is the manifest-based replacement for the metadata-blind extraction in
/// `ArchiveBrowsing`. The opaque indexed backing store in the design document
/// is a later step, bundled with copy-out as extract-a-subset so that copying
/// a whole folder out stays correct. See `object-browser-design.md`.
final class ArchiveSource: BrowserSource, @unchecked Sendable {

    typealias Failure = Archiving.Failure

    let archive: URL
    /// Everything for this opened archive lives under here, removed when
    /// Diptych quits.
    let holder: URL
    /// What the pane navigates: the unpacked tree, named after the archive.
    let root: URL

    let capabilities = BrowserManifest.Capabilities(writable: false)

    private init(archive: URL, holder: URL) {
        self.archive = archive
        self.holder = holder
        self.root = holder.appendingPathComponent(archive.lastPathComponent)
    }

    // MARK: - Building

    /// Unpacks `archive` under `holder`, writes its manifests and locks it.
    /// `holder` must not exist yet.
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
        do { try manager.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { throw Failure(message: error.localizedDescription) }

        let entries = try Archiving.entries(of: archive, kind: kind, password: password, job: job)
        let needed = entries.compactMap(\.size).reduce(0, +)
        if let free = (try? holder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage, needed > free {
            throw Failure(message: "It holds "
                          + "\(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)), "
                          + "more than the disk has free.")
        }
        try Archiving.unpack(archive, kind: kind, into: root, password: password,
                             entries: entries, job: job)
        guard !job.isCancelled else { throw Failure(message: "Stopped.") }

        // Folded into the files by ditto; left as a folder by tar.
        let macOSX = root.appendingPathComponent("__MACOSX")
        if manager.fileExists(atPath: macOSX.path) { ArchiveSource.remove(macOSX) }
        // A downloaded archive's contents are downloaded too.
        if let mark = Archiving.quarantine(of: archive) { Archiving.markQuarantined(root, with: mark) }

        try writeManifests(entries: entries)
        lock()
    }

    /// One manifest per directory, from the archive's recorded metadata, with
    /// a name that never overwrites a real entry of that directory.
    private func writeManifests(entries: [Archiving.Entry]) throws(Failure) {
        let manager = FileManager()
        let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let sha = Archiving.sha256(of: archive) ?? ""

        // Every directory under the root, and the children in each.
        var children: [String: [BrowserManifest.Node]] = ["": []]
        guard let walker = manager.enumerator(atPath: root.path) else {
            throw Failure(message: "The archive\u{2019}s contents could not be read.")
        }
        while let relative = walker.nextObject() as? String {
            let onDisk = root.appendingPathComponent(relative)
            var info = stat()
            guard lstat(onDisk.path, &info) == 0 else { continue }
            let entry = byPath[Archiving.normalized(relative)]
            let parent = (relative as NSString).deletingLastPathComponent
            var node = BrowserManifest.Node(id: Archiving.normalized(relative),
                                            kind: .file, name: (relative as NSString).lastPathComponent)
            node.attributes[BrowserManifest.Attribute.mode] = .mode(entry?.mode ?? (info.st_mode & 0o7777))
            node.attributes[BrowserManifest.Attribute.uid] = .user(entry?.uid ?? info.st_uid)
            node.attributes[BrowserManifest.Attribute.gid] = .user(entry?.gid ?? info.st_gid)
            node.attributes[BrowserManifest.Attribute.modified] =
                .date(Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                node.kind = .directory
                if children[relative] == nil { children[relative] = [] }
            case S_IFLNK:
                node.kind = .symlink
                node.linkTarget = try? manager.destinationOfSymbolicLink(atPath: onDisk.path)
                node.backing = .file(Archiving.normalized(relative))
            case S_IFREG:
                node.kind = .file
                node.attributes[BrowserManifest.Attribute.size] = .size(entry?.size ?? Int64(info.st_size))
                node.backing = .file(Archiving.normalized(relative))
            default:
                node.kind = .other
            }
            children[parent, default: []].append(node)
        }

        for (directory, nodes) in children {
            let folder = directory.isEmpty ? root : root.appendingPathComponent(directory)
            let taken = Set((try? manager.contentsOfDirectory(atPath: folder.path)) ?? [])
            let fileName = BrowserManifestStore.chooseName(avoiding: taken)
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
        return root.appendingPathComponent(path)
    }

    // MARK: - Locking and removal

    /// The tree traversable but not writable and the files read-only, so even
    /// an external app cannot save over the copy. Display metadata comes from
    /// the manifest, so the stripped on-disk permissions are never shown.
    private func lock() {
        let manager = FileManager()
        guard let walker = manager.enumerator(atPath: root.path) else { return }
        while let relative = walker.nextObject() as? String {
            let path = root.appendingPathComponent(relative).path
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFLNK { continue }
            chmod(path, info.st_mode & S_IFMT == S_IFDIR
                  ? 0o500 : (info.st_mode & 0o100 != 0 ? 0o500 : 0o400))
        }
        chmod(root.path, 0o500)
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
