import Foundation

/// The shadow of one SFTP server: a real directory tree, one folder for each
/// remote folder that has been listed, each holding a manifest of what the
/// server listed there.
///
/// It is laid out as `ArchiveSource` lays out an opened archive, so the
/// directory loader's manifest overlay shows the server's permissions, owner
/// and dates, and the panes work on real folders. A file is a placeholder
/// until its bytes are fetched: the manifest says so with a `.none` backing,
/// and `materialize` fetches them. Nothing is written back yet, so the shadow
/// is read-only, as an archive is.
actor SFTPMirror {

    let root: URL
    private let remote: RemoteListing
    private let host: String

    init(root: URL, remote: RemoteListing, host: String) {
        self.root = root
        self.remote = remote
        self.host = host
    }

    /// The local folder for a remote path such as `/home/peter/photos`.
    func localURL(for path: String) -> URL {
        path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    /// Lists `path` into its local folder. Subfolders become folders, files
    /// become placeholders, entries the server no longer lists are removed, and
    /// the manifest records what is there. Returns the names it could not
    /// mirror, which differ only in case from one already mirrored: a
    /// case-insensitive disk cannot hold both.
    @discardableResult
    func populate(_ path: String) async throws -> [String] {
        let entries = try await remote.entries(in: path)
        let folder = localURL(for: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let previous = BrowserManifestStore.read(in: folder)?.nodes ?? []
        var seen = Set<String>()
        var skipped: [String] = []
        var nodes: [BrowserManifest.Node] = []

        for entry in entries {
            guard seen.insert(entry.name.lowercased()).inserted else {
                skipped.append(entry.name)
                continue
            }
            let child = folder.appendingPathComponent(entry.name)
            let before = previous.first { $0.name == entry.name }
            let node = try place(entry, at: child, previously: before)
            nodes.append(node)
        }

        // Anything no longer listed by the server goes, bytes and all.
        let listed = Set(nodes.map(\.name))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where !listed.contains(name) && BrowserManifestStore.number(of: name) == nil {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }

        let manifest = BrowserManifest(
            source: "sftp",
            origin: ["host": host, "path": path],
            capabilities: BrowserManifest.Capabilities(),
            nodes: nodes)
        let fileName = BrowserManifestStore.chooseName(avoiding: Set(listed))
        if let old = BrowserManifestStore.located(in: folder), old.fileName != fileName {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old.fileName))
        }
        try Self.writeIfChanged(manifest, named: fileName, in: folder)
        return skipped
    }

    /// Writes the manifest only when its content differs. The pane watches its
    /// folder and reloads on any change, and each reload lists the folder again:
    /// a manifest rewritten with the same content would start that loop over,
    /// and the pane would blink and jump back to the top all the time.
    private static func writeIfChanged(_ manifest: BrowserManifest, named fileName: String,
                                       in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        let url = folder.appendingPathComponent(fileName)
        if (try? Data(contentsOf: url)) == data { return }
        try data.write(to: url)
    }

    /// Makes sure the bytes of the file at `path` are local, fetching them if
    /// they are not, and returns the local file.
    func materialize(_ path: String) async throws -> URL {
        let file = localURL(for: path)
        let folder = file.deletingLastPathComponent()
        guard let located = BrowserManifestStore.located(in: folder),
              var node = located.manifest.nodes.first(where: { $0.name == file.lastPathComponent })
        else { throw SFTPMirrorError.notListed(path) }
        if node.backing != .none { return file }

        let staging = root.appendingPathComponent(".downloading-\(UUID().uuidString)")
        try await remote.download(path, to: staging)
        // The placeholder is read-only, so it is unlocked for the replacement.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: staging)

        node.backing = .file(file.lastPathComponent)
        var manifest = located.manifest
        manifest.nodes = manifest.nodes.map { $0.name == node.name ? node : $0 }
        try BrowserManifestStore.write(manifest, named: located.fileName, in: folder)
        return file
    }

    /// What the server lists in `path`, now.
    func listing(_ path: String) async throws -> [SFTPEntry] {
        try await remote.entries(in: path)
    }

    func makeFolder(_ path: String) async throws {
        try await remote.makeDirectory(path)
    }

    func rename(_ from: String, to: String) async throws {
        try await remote.rename(from, to: to)
    }

    /// Removes `path` from the server, and everything in it when it is a folder.
    func remove(_ path: String, isDirectory: Bool) async throws {
        guard isDirectory else {
            try await remote.removeFile(path)
            return
        }
        for entry in try await remote.entries(in: path) {
            let child = path == "/" ? "/" + entry.name : path + "/" + entry.name
            try await remove(child, isDirectory: entry.kind == .directory)
        }
        try await remote.removeDirectory(path)
    }

    /// Copies a local file, or a local folder with everything in it, to `path`
    /// on the server. The manifest a shadow folder carries is not copied.
    func upload(_ local: URL, to path: String, isDirectory: Bool) async throws {
        guard isDirectory else {
            try await remote.upload(local, to: path)
            return
        }
        try await remote.makeDirectory(path)
        let names = try FileManager.default.contentsOfDirectory(atPath: local.path)
            .filter { BrowserManifestStore.number(of: $0) == nil }
        for name in names.sorted() {
            let child = local.appendingPathComponent(name)
            let target = path == "/" ? "/" + name : path + "/" + name
            try await upload(child, to: target, isDirectory: Self.isDirectory(child))
        }
    }

    /// Whether a local path is a folder, following nothing.
    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Creates the folder or placeholder for one entry, and its node. A file
    /// keeps its bytes only while the server still reports the size and date
    /// it had when they were fetched; otherwise the placeholder is emptied.
    private func place(_ entry: SFTPEntry, at child: URL,
                       previously: BrowserManifest.Node?) throws -> BrowserManifest.Node {
        var attributes: [String: AttributeValue] = [:]
        if let mode = entry.mode { attributes[BrowserManifest.Attribute.mode] = .mode(UInt16(mode)) }
        if let uid = entry.uid { attributes[BrowserManifest.Attribute.uid] = .user(uid) }
        if let gid = entry.gid { attributes[BrowserManifest.Attribute.gid] = .user(gid) }
        if let modified = entry.modified { attributes[BrowserManifest.Attribute.modified] = .date(modified) }

        let fileManager = FileManager.default
        if entry.kind == .directory {
            try fileManager.createDirectory(at: child, withIntermediateDirectories: true)
            attributes[BrowserManifest.Attribute.size] = .size(Int64(entry.size))
            return BrowserManifest.Node(id: entry.name, kind: .directory, name: entry.name,
                                        attributes: attributes)
        }

        attributes[BrowserManifest.Attribute.size] = .size(Int64(entry.size))
        let kept = bytesStillCurrent(previously, for: entry)
        if !kept || !fileManager.fileExists(atPath: child.path) {
            try? fileManager.removeItem(at: child)
            fileManager.createFile(atPath: child.path, contents: nil)
        }
        // Set only when it is wrong: a change to a file in the folder is a
        // change to the folder, and the pane reloads on that.
        let mode = (try? fileManager.attributesOfItem(atPath: child.path)[.posixPermissions]) as? Int
        if mode != 0o400 {
            try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: child.path)
        }

        let kind: BrowserManifest.Kind = {
            switch entry.kind {
            case .symlink: .symlink
            case .other: .other
            default: .file
            }
        }()
        return BrowserManifest.Node(
            id: entry.name, kind: kind, name: entry.name, attributes: attributes,
            backing: kept ? previously?.backing ?? .none : .none)
    }

    /// Whether the bytes fetched for `node` are still those the server has:
    /// the same size and date, and fetched at all.
    private func bytesStillCurrent(_ node: BrowserManifest.Node?, for entry: SFTPEntry) -> Bool {
        guard let node, case .file = node.backing else { return false }
        return node.attribute(BrowserManifest.Attribute.size)?.intValue == Int64(entry.size)
            && node.attribute(BrowserManifest.Attribute.modified)?.dateValue == entry.modified
    }
}

enum SFTPMirrorError: Error, Equatable {
    /// The server did not list the file, or the mirror has not been populated
    /// for its folder.
    case notListed(String)
}
