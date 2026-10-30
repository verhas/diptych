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
        // Files changed here and not yet sent: kept as they are, whatever the
        // server lists, so that an edit is never lost to a listing.
        let editedHere = previous.filter {
            Self.locallyChanged($0, at: folder.appendingPathComponent($0.name))
        }
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
            if let edited = editedHere.first(where: { $0.name == entry.name }) {
                nodes.append(edited)
                continue
            }
            let node = try place(entry, at: child, previously: before)
            nodes.append(node)
        }

        for edited in editedHere where !nodes.contains(where: { $0.name == edited.name }) {
            nodes.append(edited)
        }
        // What the server listed before and no longer does goes, bytes and all.
        // Nothing else is touched: an editor saving here writes a file of its
        // own beside the one it saves, and takes it away itself.
        let listed = Set(nodes.map(\.name))
        for name in previous.map(\.name) where !listed.contains(name) {
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
        if !Self.needsFetch(node, at: file) { return file }

        let staging = root.appendingPathComponent(".downloading-\(UUID().uuidString)")
        RemoteBrowsing.arriving(file, at: staging)
        defer { RemoteBrowsing.arriving(file, at: nil) }
        try await remote.download(path, to: staging)
        let checksum = try FileChecksum.sha256(of: staging)
        // The placeholder is read-only, so it is unlocked for the replacement.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: staging)
        // Writable here when the server lets its owner write: a save is sent back.
        let serverMode = node.attribute(BrowserManifest.Attribute.mode)?.intValue.map { UInt32($0) }
        try FileManager.default.setAttributes([.posixPermissions: Self.localMode(for: serverMode)],
                                              ofItemAtPath: file.path)

        node.backing = .file(file.lastPathComponent)
        node.attributes[BrowserManifest.Attribute.checksum] = .string(checksum)
        node.attributes[BrowserManifest.Attribute.serverChanged] = nil
        if let made = Self.localModified(file) {
            node.attributes[BrowserManifest.Attribute.localModified] = .date(made)
        }
        var manifest = located.manifest
        manifest.nodes = manifest.nodes.map { $0.name == node.name ? node : $0 }
        try BrowserManifestStore.write(manifest, named: located.fileName, in: folder)
        return file
    }

    // MARK: - Writing back

    /// The mode the copy here of a fetched file gets: writable when the server
    /// lets its owner write, read-only otherwise.
    static func localMode(for serverMode: UInt32?) -> Int {
        (serverMode ?? 0) & 0o200 != 0 ? 0o600 : 0o400
    }

    static func localModified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    /// Whether a file's bytes have to be fetched before it is opened: never
    /// fetched, or changed on the server since, with no change here. A file
    /// changed in both places keeps the change here: sending it shows the conflict.
    static func needsFetch(_ node: BrowserManifest.Node?, at url: URL) -> Bool {
        guard let node else { return true }
        if node.backing == .none { return true }
        guard node.attribute(BrowserManifest.Attribute.serverChanged)?.boolValue == true,
              !locallyChanged(node, at: url) else { return false }
        // The bytes as well as the time: an edit is never fetched over. Read
        // only for a file the server changed, which is seldom.
        let recorded = node.attribute(BrowserManifest.Attribute.checksum)?.stringValue
        guard let recorded, (try? FileChecksum.sha256(of: url)) == recorded else { return false }
        // Nor while a Diptych editor holds changes to it not saved yet.
        return !EditedHere.holdsUnsaved(url)
    }

    /// Whether a fetched file was changed here since it was fetched or last sent.
    static func locallyChanged(_ node: BrowserManifest.Node?, at url: URL) -> Bool {
        guard let node, case .file = node.backing,
              let recorded = node.attribute(BrowserManifest.Attribute.localModified)?.dateValue,
              let now = localModified(url) else { return false }
        // Within a millisecond: the date goes through a number on its way to the
        // manifest, which may round it.
        return abs(now.timeIntervalSince(recorded)) > 0.001
    }

    /// Sends a file changed here to the server, when the server's copy is still the
    /// one fetched. Otherwise says so, with what the server has now.
    func writeBack(_ path: String) async throws -> WriteBack {
        let file = localURL(for: path)
        // Decided by the bytes, not the time: a time can be taken for the
        // fetched one by mistake, the checksum cannot.
        guard let node = node(at: file), case .file = node.backing else { return .unchanged }
        let mine = try FileChecksum.sha256(of: file)
        let recorded = node.attribute(BrowserManifest.Attribute.checksum)?.stringValue
        if mine == recorded {
            // Saved with nothing changed: only the time is new.
            try updateNode(at: file) {
                if let made = Self.localModified(file) {
                    $0.attributes[BrowserManifest.Attribute.localModified] = .date(made)
                }
            }
            return .unchanged
        }
        let current = root.appendingPathComponent(".downloading-\(UUID().uuidString)")
        try await remote.download(path, to: current)
        let theirs = try FileChecksum.sha256(of: current)
        guard theirs == recorded else {
            return .conflict(serverCopy: current, serverChecksum: theirs,
                             isText: TextSniff.looksLikeText(file) && TextSniff.looksLikeText(current))
        }
        try? FileManager.default.removeItem(at: current)
        try await remote.upload(file, to: path)
        try await recordSent(path, checksum: mine)
        return .sent
    }

    /// Takes the server's version as the one the file here is now compared with:
    /// after a merge of the two is saved, it is sent.
    func adoptBaseline(_ path: String, checksum: String) throws {
        try updateNode(at: localURL(for: path)) {
            $0.attributes[BrowserManifest.Attribute.checksum] = .string(checksum)
            $0.attributes[BrowserManifest.Attribute.serverChanged] = nil
        }
    }

    /// Makes the file here the server's version again, from `copy` of it.
    func keepServersVersion(_ path: String, from copy: URL, checksum: String) async throws {
        let file = localURL(for: path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: copy)
        try await recordSent(path, checksum: checksum)
    }

    /// Sends the file here as `path`'s neighbour under a free name -- `name-1.ext`,
    /// `name-2.ext` -- and returns the name.
    func sendAsNew(_ path: String) async throws -> String {
        let file = localURL(for: path)
        let folder = "/" + path.split(separator: "/").dropLast().joined(separator: "/")
        let taken = Set(try await remote.entries(in: folder).map(\.name))
        let name = Self.freeName(for: file.lastPathComponent, among: taken)
        try await remote.upload(file, to: folder == "/" ? "/" + name : folder + "/" + name)
        return name
    }

    /// `name-1.ext`, `name-2.ext`, ...: the first not in `taken`.
    static func freeName(for name: String, among taken: Set<String>) -> String {
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var number = 1
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(number)" : "\(base)-\(number).\(ext)"
            if !taken.contains(candidate) { return candidate }
            number += 1
        }
    }

    /// After a file was sent, or made the server's again: the server's facts for
    /// it, the checksum of what it now holds, and when the copy here was settled.
    private func recordSent(_ path: String, checksum: String) async throws {
        let file = localURL(for: path)
        let folder = "/" + path.split(separator: "/").dropLast().joined(separator: "/")
        let entry = try await remote.entries(in: folder).first { $0.name == file.lastPathComponent }
        try FileManager.default.setAttributes([.posixPermissions: Self.localMode(for: entry?.mode)],
                                              ofItemAtPath: file.path)
        try updateNode(at: file) { node in
            if let entry {
                if let size = entry.size { node.attributes[BrowserManifest.Attribute.size] = .size(Int64(size)) }
                if let mode = entry.mode { node.attributes[BrowserManifest.Attribute.mode] = .mode(UInt16(mode)) }
                if let modified = entry.modified {
                    node.attributes[BrowserManifest.Attribute.modified] = .date(modified)
                }
            }
            node.backing = .file(file.lastPathComponent)
            node.attributes[BrowserManifest.Attribute.checksum] = .string(checksum)
            node.attributes[BrowserManifest.Attribute.serverChanged] = nil
            if let made = Self.localModified(file) {
                node.attributes[BrowserManifest.Attribute.localModified] = .date(made)
            }
        }
    }

    private func node(at file: URL) -> BrowserManifest.Node? {
        BrowserManifestStore.read(in: file.deletingLastPathComponent())?.nodes
            .first { $0.name == file.lastPathComponent }
    }

    private func updateNode(at file: URL, _ change: (inout BrowserManifest.Node) -> Void) throws {
        let folder = file.deletingLastPathComponent()
        guard let located = BrowserManifestStore.located(in: folder) else { return }
        var manifest = located.manifest
        manifest.nodes = manifest.nodes.map { node in
            guard node.name == file.lastPathComponent else { return node }
            var changed = node
            change(&changed)
            return changed
        }
        try Self.writeIfChanged(manifest, named: located.fileName, in: folder)
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

    func setPermissions(_ path: String, mode: UInt32) async throws {
        try await remote.setPermissions(path, mode: mode)
    }

    func setOwnership(_ path: String, uid: UInt32, gid: UInt32) async throws {
        try await remote.setOwnership(path, uid: uid, gid: gid)
    }

    func setTimes(_ path: String, modified: Date) async throws {
        try await remote.setTimes(path, modified: modified)
    }

    func runAsRoot(_ arguments: [String], password: String?) async throws -> SudoOutcome {
        try await remote.runAsRoot(arguments, password: password)
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

    /// Creates the folder or placeholder for one entry, and its node. A fetched
    /// file keeps its bytes; when the server no longer reports the size and date
    /// it had when they were fetched, it is marked as changed there.
    private func place(_ entry: SFTPEntry, at child: URL,
                       previously: BrowserManifest.Node?) throws -> BrowserManifest.Node {
        var attributes: [String: AttributeValue] = [:]
        if let mode = entry.mode { attributes[BrowserManifest.Attribute.mode] = .mode(UInt16(mode)) }
        if let uid = entry.uid { attributes[BrowserManifest.Attribute.uid] = .user(uid) }
        if let gid = entry.gid { attributes[BrowserManifest.Attribute.gid] = .user(gid) }
        if let owner = entry.ownerName { attributes[BrowserManifest.Attribute.ownerName] = .string(owner) }
        if let group = entry.groupName { attributes[BrowserManifest.Attribute.groupName] = .string(group) }
        if let modified = entry.modified { attributes[BrowserManifest.Attribute.modified] = .date(modified) }

        let fileManager = FileManager.default
        if entry.kind == .directory {
            try fileManager.createDirectory(at: child, withIntermediateDirectories: true)
            return BrowserManifest.Node(id: entry.name, kind: .directory, name: entry.name,
                                        attributes: attributes)
        }

        // Only a size the server gave is written: an unknown one is left out, and
        // shown as unknown rather than as zero.
        if let size = entry.size { attributes[BrowserManifest.Attribute.size] = .size(Int64(size)) }
        // Fetched bytes are never emptied by a listing, even when the server has
        // changed the file since: an editor may have the file open, and emptied
        // under it, it would refuse to save -- or save over what the server now
        // has without the conflict ever being seen. The file is marked instead,
        // and fetched again the next time it is opened.
        var kept = false
        if case .file? = previously?.backing { kept = fileManager.fileExists(atPath: child.path) }
        let changedThere = kept && (!bytesStillCurrent(previously, for: entry)
            || previously?.attribute(BrowserManifest.Attribute.serverChanged)?.boolValue == true)
        if !kept {
            try? fileManager.removeItem(at: child)
            fileManager.createFile(atPath: child.path, contents: nil)
        }
        // Set only when it is wrong: a change to a file in the folder is a
        // change to the folder, and the pane reloads on that. A placeholder is
        // locked; a fetched file is writable when the server lets its owner write.
        let wanted = kept ? Self.localMode(for: entry.mode) : 0o400
        let mode = (try? fileManager.attributesOfItem(atPath: child.path)[.posixPermissions]) as? Int
        if mode != wanted {
            try fileManager.setAttributes([.posixPermissions: wanted], ofItemAtPath: child.path)
        }
        if kept, let previously {
            // Carried over as they were. The time is never taken from the file
            // now: an editor may have saved it while the server was listing, and
            // taking that time would make the save look like no change at all --
            // never sent, and lost to the next fetch. Setting the mode does not
            // change the time anyway.
            for key in [BrowserManifest.Attribute.checksum, BrowserManifest.Attribute.localModified] {
                if let value = previously.attribute(key) { attributes[key] = value }
            }
            if changedThere { attributes[BrowserManifest.Attribute.serverChanged] = .bool(true) }
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
        return node.attribute(BrowserManifest.Attribute.size)?.intValue == entry.size.map { Int64($0) }
            && node.attribute(BrowserManifest.Attribute.modified)?.dateValue == entry.modified
    }
}

enum SFTPMirrorError: Error, Equatable {
    /// The server did not list the file, or the mirror has not been populated
    /// for its folder.
    case notListed(String)
}
