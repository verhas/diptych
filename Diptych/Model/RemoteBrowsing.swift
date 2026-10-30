import Foundation
import Observation

/// Why a change to a server was not made.
nonisolated enum RemoteWriteError: LocalizedError, Equatable, Sendable {
    /// Something of that name is already there, and is not written over.
    case exists(String)
    /// The item is not on a server.
    case notOnServer
    /// An owner or group name that the server's listings do not show, and that is
    /// not a number.
    case unknownAccount(String)
    /// The person did not give the sudo password.
    case sudoCancelled
    /// sudo will not let the user do it, or the password was refused too often.
    case sudoRefused(String)
    /// sudo ran the change, and the change failed.
    case sudoFailed(String)

    var errorDescription: String? {
        switch self {
        case .exists(let name):
            "\u{201C}\(name)\u{201D} is already there on the server, and is not written over."
        case .notOnServer:
            "That is not a place on a server."
        case .sudoCancelled:
            "The server needs the sudo password for this, and none was given."
        case .sudoRefused(let said):
            "The server would not let this be done with sudo: \(said)"
        case .sudoFailed(let said):
            "It was run with sudo, and failed: \(said)"
        case .unknownAccount(let name):
            "\u{201C}\(name)\u{201D} is not a user or group the server\u{2019}s listings show. "
                + "Give its number, or show a folder with files it owns in a pane first."
        }
    }
}

/// The SFTP servers the panes show. A folder on a server is shown by its
/// `sftp://` address, and its files are kept in a shadow folder under the
/// caches, as an opened archive's are. The pane itself browses the shadow, so
/// it needs no change for a server: the mapping is made where a shown address
/// and a real path meet, as `ArchiveBrowsing` makes it.
///
/// Each server has one shadow, whose root is the server's `/`. A remote path
/// and its shadow folder correspond one to one.
nonisolated enum RemoteBrowsing {

    /// A connected server: who it is, where its shadow is, and what reads it.
    struct Server: Sendable {
        let user: String
        let host: String
        let port: Int
        /// The shadow of the server's `/`.
        let root: URL
        let mirror: SFTPMirror
        /// Closes the connection, forgetting its sign-in.
        let close: @Sendable () async -> Void
        /// Changes how often the connection is checked: nil stops checking it.
        var setKeepAlive: @Sendable (Duration?) async -> Void = { _ in }

        var key: String { Self.key(user: user, host: host, port: port) }

        static func key(user: String, host: String, port: Int) -> String {
            "\(user)@\(SFTPHostKeys.filing(host: host, port: port))"
        }
    }

    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var servers: [Server] = []
        var cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Diptych")
            .appendingPathComponent("Opened Servers")
    }

    private static let registry = Registry()

    /// Where the shadows are kept. The tests put them somewhere of their own.
    static var cacheRoot: URL {
        get { registry.lock.withLock { registry.cacheRoot } }
        set { registry.lock.withLock { registry.cacheRoot = newValue } }
    }

    // MARK: - Servers

    /// Adds a server, or replaces the one with the same user, host and port.
    /// A server that was connected before keeps its shadow.
    static func add(_ server: Server) {
        let replaced = registry.lock.withLock { () -> [Server] in
            let old = registry.servers.filter { $0.key == server.key }
            registry.servers.removeAll { $0.key == server.key }
            registry.servers.append(server)
            return old
        }
        // The connection it replaces is no longer used.
        for old in replaced {
            Task.detached { await old.close() }
        }
    }

    /// The shadow folder for a server that is connected, or a new one for it.
    static func shadowRoot(user: String, host: String, port: Int) -> URL {
        let key = Server.key(user: user, host: host, port: port)
        if let existing = registry.lock.withLock({ registry.servers.first { $0.key == key } }) {
            return existing.root
        }
        return cacheRoot.appendingPathComponent(UUID().uuidString)
    }

    /// Each connected server as a sidebar volume: named after its host, and
    /// ejectable, which disconnects it. In the order they connected.
    static func sidebarEntries() -> [SidebarEntry] {
        registry.lock.withLock { registry.servers }.map { server in
            SidebarEntry(kind: .volume, url: server.root, name: server.host,
                         isEjectable: true, isNetwork: true, isReadOnly: true)
        }
    }

    /// The connected server a shadow path belongs to.
    static func server(of url: URL) -> Server? {
        owning(url)?.server
    }

    /// The connected server whose shadow is `root`.
    static func server(root: URL) -> Server? {
        let path = resolved(root.path)
        return registry.lock.withLock { registry.servers.first { resolved($0.root.path) == path } }
    }

    /// Disconnects the server whose shadow is `root`: its connection closes,
    /// and its shadow goes. Its panes must have been moved off it first.
    /// False when no connected server has that root.
    @discardableResult
    static func disconnect(root: URL) -> Bool {
        let path = resolved(root.path)
        let server = registry.lock.withLock { () -> Server? in
            guard let index = registry.servers.firstIndex(where: { resolved($0.root.path) == path })
            else { return nil }
            return registry.servers.remove(at: index)
        }
        guard let server else { return false }
        SudoPasswords.shared.forget(server.key)
        Task.detached { await server.close() }
        try? FileManager.default.removeItem(at: server.root)
        return true
    }

    /// Closes every connection and removes every shadow, at quit. Also run at
    /// launch, for what a crash left behind: nothing is connected then.
    static func removeAll() {
        let servers = registry.lock.withLock {
            let servers = registry.servers
            registry.servers = []
            return servers
        }
        for server in servers {
            Task.detached { await server.close() }
        }
        SudoPasswords.shared.forgetAll()
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    // MARK: - Where things are

    /// The server a shadow path belongs to, and the path inside the server
    /// it stands for, as components of `/`.
    private static func owning(_ url: URL) -> (server: Server, components: [String])? {
        let path = resolved(url.path)
        return registry.lock.withLock { () -> (server: Server, components: [String])? in
            for server in registry.servers {
                let root = resolved(server.root.path)
                if path == root {
                    return (server, [])
                }
                if path.hasPrefix(root + "/") {
                    let inside = path.dropFirst(root.count + 1)
                    return (server, inside.split(separator: "/").map(String.init))
                }
            }
            return nil
        }
    }

    /// Whether `url` is a folder or file on a server's shadow.
    static func isInside(_ url: URL) -> Bool {
        owning(url) != nil
    }

    /// Whether `url` is a server's `/`, the top of its shadow: nothing lies
    /// above it that the pane should go to.
    static func isServerRoot(_ url: URL) -> Bool {
        owning(url)?.components.isEmpty == true
    }

    /// A shadow folder as the address the pane shows it by:
    /// `sftp://peter@nas/home/peter`.
    static func shown(_ url: URL) -> URL? {
        guard let (server, components) = owning(url) else { return nil }
        var parts = URLComponents()
        parts.scheme = "sftp"
        parts.user = server.user
        parts.host = server.host
        parts.port = server.port == 22 ? nil : server.port
        parts.path = "/" + components.joined(separator: "/")
        return parts.url
    }

    /// The sftp:// address of a connected server, without its path.
    static func address(of server: Server) -> URL {
        var parts = URLComponents()
        parts.scheme = "sftp"
        parts.user = server.user
        parts.host = server.host
        parts.port = server.port == 22 ? nil : server.port
        parts.path = "/"
        return parts.url ?? URL(fileURLWithPath: "/")
    }

    /// The shadow folder an `sftp://` address stands for, when that server is
    /// connected and the address is on it.
    static func actual(_ shown: URL) -> URL? {
        guard shown.scheme == "sftp", let host = shown.host, let user = shown.user else { return nil }
        let port = shown.port ?? 22
        let key = Server.key(user: user, host: host, port: port)
        return registry.lock.withLock {
            registry.servers.first { $0.key == key }
        }.map { localURL(on: $0, remote: shown.path) }
    }

    /// The shadow an `sftp://` address written as text stands for: escaped, or
    /// as `reportedPath` and a drag give it, with spaces and all as they are.
    static func actual(text: String) -> URL? {
        guard text.lowercased().hasPrefix("sftp://") else { return nil }
        if let url = URL(string: text), let local = actual(url) { return local }
        var allowed = CharacterSet.urlPathAllowed
        allowed.insert(charactersIn: ":@")
        guard let escaped = text.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: escaped) else { return nil }
        return actual(url)
    }

    /// A file on a server whose bytes are not here: its size as the server
    /// listed it, nil when it listed none.
    struct Placeholder: Equatable, Sendable {
        let size: Int64?
    }

    /// The size the server gave a file whose bytes are not here yet. Nil for
    /// anything else, and for a file the server gave no size for.
    static func placeholder(_ url: URL) -> Placeholder? {
        guard isInside(url), !SFTPMirror.isDirectory(url),
              let manifest = BrowserManifestStore.read(in: url.deletingLastPathComponent()),
              let node = manifest.nodes.first(where: { $0.name == url.lastPathComponent }),
              node.backing == .none else { return nil }
        return Placeholder(size: node.attribute(BrowserManifest.Attribute.size)?.intValue)
    }

    /// A path as the MCP tools report it: a folder on a server by its sftp://
    /// address, which is where it is; anything else by its path, as before.
    static func reportedPath(_ url: URL) -> String {
        let display = ArchiveBrowsing.shown(url)
        guard display.scheme == "sftp" else { return url.path }
        return display.absoluteString.removingPercentEncoding ?? display.absoluteString
    }

    /// The copies, on the shadows of the connected servers, of a path that is
    /// absolute on the server: a folder listed in a pane. Empty when there are none.
    static func shadows(ofRemotePath path: String) -> [URL] {
        let servers = registry.lock.withLock { registry.servers }
        return servers.map { localURL(on: $0, remote: path) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The shadow folder for a path on a server.
    static func localURL(on server: Server, remote: String) -> URL {
        remote.split(separator: "/").reduce(server.root) { $0.appendingPathComponent(String($1)) }
    }

    /// The path on the server that a shadow path stands for, `/home/peter`.
    private static func remotePath(_ url: URL) -> (Server, String)? {
        guard let (server, components) = owning(url) else { return nil }
        return (server, "/" + components.joined(separator: "/"))
    }

    /// The volume facts of a folder on a server: a network volume, read-only,
    /// named after the host.
    static func volumeFacts(of url: URL) -> VolumeFacts? {
        guard let (server, _) = owning(url) else { return nil }
        return VolumeFacts(isNetwork: true, isReadOnly: true, typeName: "sftp", name: server.host)
    }

    // MARK: - Listing and fetching

    /// Lists a folder from the server into its shadow, so that the pane shows
    /// what is there now.
    static func refresh(_ url: URL) async throws {
        guard let (server, path) = remotePath(url) else { return }
        try await server.mirror.populate(path)
    }

    /// Whether any file under `urls` still lacks its bytes, or any folder has
    /// not been listed. Read from the manifests, so nothing is fetched to ask.
    static func hasPending(_ urls: [URL]) -> Bool {
        urls.contains { url in
            guard isInside(url) else { return false }
            return pending(url)
        }
    }

    private static func pending(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return true }
        guard isDirectory.boolValue else {
            let node = BrowserManifestStore.read(in: url.deletingLastPathComponent())?.nodes
                .first { $0.name == url.lastPathComponent }
            return SFTPMirror.needsFetch(node, at: url)
        }
        guard let manifest = BrowserManifestStore.read(in: url) else { return true }
        return manifest.nodes.contains { node in
            node.kind == .directory
                ? pending(url.appendingPathComponent(node.name))
                : SFTPMirror.needsFetch(node, at: url.appendingPathComponent(node.name))
        }
    }

    /// Lists every folder under `urls` and fetches every file, so that they
    /// can be copied or previewed as real files.
    static func fetch(_ urls: [URL]) async throws {
        for url in urls {
            guard let (server, path) = remotePath(url) else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                _ = try await server.mirror.populate(path)
                let children = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                try await fetch(children
                    .filter { BrowserManifestStore.number(of: $0) == nil }
                    .map { url.appendingPathComponent($0) })
            } else {
                try Task.checkCancellation()
                try await download(url)
            }
        }
    }

    // MARK: - Downloads

    private final class Downloads: @unchecked Sendable {
        let lock = NSLock()
        /// One download per file, shared by everyone who asks for it meanwhile.
        var tasks: [String: Task<Void, Error>] = [:]
        /// Where a file's bytes are arriving, while they arrive.
        var arriving: [String: URL] = [:]
    }

    private static let downloads = Downloads()

    /// Posted on the main actor when a file's bytes have arrived; the object is
    /// its shadow URL.
    static let fetched = Notification.Name("RemoteBrowsing.fetched")

    private static func downloadKey(_ url: URL) -> String { url.standardizedFileURL.path }

    /// Fetches a file's bytes when they are not here or are of an older version,
    /// once however many ask at the same time. Not cancelled when one who asked
    /// stops waiting: someone else may still want it.
    static func download(_ url: URL) async throws {
        let key = downloadKey(url)
        let task = downloads.lock.withLock { () -> Task<Void, Error> in
            if let running = downloads.tasks[key] { return running }
            let task = Task<Void, Error> {
                await MainActor.run { ServerDownloads.shared.started(key) }
                defer {
                    _ = downloads.lock.withLock { downloads.tasks.removeValue(forKey: key) }
                    Task { @MainActor in ServerDownloads.shared.finished(key) }
                }
                try await materialize(url)
                await MainActor.run { NotificationCenter.default.post(name: fetched, object: url) }
            }
            downloads.tasks[key] = task
            return task
        }
        try await task.value
    }

    /// Starts fetching, without waiting: what a right-click does for a file up to
    /// the size the settings allow.
    static func prefetch(_ urls: [URL], upTo limit: Int64) {
        for url in urls where isInside(url) && !SFTPMirror.isDirectory(url) && !isDownloading(url) {
            guard hasPending([url]) else { continue }
            let size = listedNode(of: url)?.attribute(BrowserManifest.Attribute.size)?.intValue
            // A file the server gave no size for is not fetched unasked: it may be
            // anything.
            guard let size, size <= limit else { continue }
            Task.detached(priority: .utility) { try? await download(url) }
        }
    }

    static func isDownloading(_ url: URL) -> Bool {
        let key = downloadKey(url)
        return downloads.lock.withLock { downloads.tasks[key] != nil || downloads.arriving[key] != nil }
    }

    /// How much of a file has arrived, while it is being fetched; nil otherwise.
    static func received(_ url: URL) -> Int64? {
        let key = downloadKey(url)
        guard let staging = downloads.lock.withLock({ downloads.arriving[key] }) else {
            return isDownloading(url) ? 0 : nil
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: staging.path))?[.size]
        return (size as? NSNumber)?.int64Value ?? 0
    }

    /// Told by the mirror where a file's bytes are arriving, and when they have.
    static func arriving(_ file: URL, at staging: URL?) {
        let key = downloadKey(file)
        downloads.lock.withLock { downloads.arriving[key] = staging }
    }

    // MARK: - Changing the server

    /// Makes a folder named `name` in `parent`, on the server, and lists it.
    static func makeFolder(named name: String, in parent: URL) async throws -> URL {
        guard let (server, folder) = remotePath(parent) else { throw RemoteWriteError.notOnServer }
        try await requireAbsent(name, in: folder, server)
        let path = join(folder, name)
        try await server.mirror.makeFolder(path)
        try await refresh(parent)
        return localURL(on: server, remote: path)
    }

    /// Makes a file named `name` in `parent`, on the server, holding `contents`
    /// (empty by default), and lists it.
    static func createFile(named name: String, in parent: URL, contents: Data = Data()) async throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("new-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let file = staging.appendingPathComponent(name)
        try contents.write(to: file)
        try await upload([file], into: parent)
        guard let (server, folder) = remotePath(parent) else { throw RemoteWriteError.notOnServer }
        return localURL(on: server, remote: join(folder, name))
    }

    /// Whether a user or group, by name or number, is one the server's listings
    /// show: a number always is, as the server takes it.
    static func knowsAccount(_ text: String, group: Bool, for url: URL) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if UInt32(trimmed) != nil { return true }
        guard let (server, _) = remotePath(url) else { return false }
        let known = accounts(of: server)
        return (group ? known.groups : known.users)[trimmed] != nil
    }

    /// Sets the owner and group of the items at `urls`, each given by the name the
    /// server's listings show or by its number; nil leaves that half as it is.
    static func setOwnership(owner: String?, group: String?, for urls: [URL]) async throws {
        var folders = Set<URL>()
        for url in urls {
            guard let (server, path) = remotePath(url) else { continue }
            let known = accounts(of: server)
            let current = ownership(of: url)
            let uid = try owner.map { try identifier($0, among: known.users) } ?? current?.uid
            let gid = try group.map { try identifier($0, among: known.groups) } ?? current?.gid
            guard let uid, let gid else { throw RemoteWriteError.notOnServer }
            do {
                try await server.mirror.setOwnership(path, uid: uid, gid: gid)
            } catch {
                // Refused to the user who signed in, as giving a file away usually
                // is: the one command is run as root, through sudo.
                try await chownAsRoot(path, uid: uid, gid: gid, on: server)
            }
            folders.insert(url.deletingLastPathComponent())
        }
        for folder in folders {
            try await refresh(folder)
        }
    }

    /// Who asks the person for a sudo password. The tests put their own here.
    nonisolated(unsafe) static var askForSudo: @Sendable (_ host: String, _ user: String,
                                                         _ wasWrong: Bool) async -> SudoAnswer? = {
        host, user, wasWrong in await SudoPrompter.ask(host: host, user: user, wasWrong: wasWrong)
    }

    /// `chown` as root, through sudo: with no password when sudo needs none, with
    /// a kept one when there is one, and otherwise with one the person gives.
    private static func chownAsRoot(_ path: String, uid: UInt32, gid: UInt32,
                                    on server: Server) async throws {
        let command = ["chown", "\(uid):\(gid)", "--", path]
        var password = SudoPasswords.shared.password(for: server.key)
        var wasWrong = false
        for _ in 0..<4 {
            let outcome = try await server.mirror.runAsRoot(command, password: password)
            switch outcome {
            case .done:
                return
            case .needsPassword, .wrongPassword:
                if outcome == .wrongPassword {
                    SudoPasswords.shared.forget(server.key)
                    wasWrong = true
                }
                guard let answer = await askForSudo(server.host, server.user, wasWrong) else {
                    throw RemoteWriteError.sudoCancelled
                }
                password = answer.password
                SudoPasswords.shared.keep(answer.password, for: server.key, answer.keep)
            case .notAllowed(let said):
                throw RemoteWriteError.sudoRefused(said)
            case .failed(let said):
                throw RemoteWriteError.sudoFailed(said)
            }
        }
        SudoPasswords.shared.forget(server.key)
        throw RemoteWriteError.sudoRefused("the password was not accepted.")
    }

    /// Sets the modification time of the items at `urls` on their servers.
    static func setTimes(modified: Date, for urls: [URL]) async throws {
        var folders = Set<URL>()
        for url in urls {
            guard let (server, path) = remotePath(url) else { continue }
            try await server.mirror.setTimes(path, modified: modified)
            folders.insert(url.deletingLastPathComponent())
        }
        for folder in folders {
            try await refresh(folder)
        }
    }

    /// The users and groups the server's listings name, with their numbers.
    static func accounts(of server: Server) -> (users: [String: UInt32], groups: [String: UInt32]) {
        var users: [String: UInt32] = [:]
        var groups: [String: UInt32] = [:]
        var folders = [server.root]
        let enumerator = FileManager.default.enumerator(at: server.root, includingPropertiesForKeys: nil)
        while let next = enumerator?.nextObject() as? URL {
            if SFTPMirror.isDirectory(next) { folders.append(next) }
        }
        for folder in folders {
            for node in BrowserManifestStore.read(in: folder)?.nodes ?? [] {
                if let name = node.attribute(BrowserManifest.Attribute.ownerName)?.stringValue,
                   let id = node.attribute(BrowserManifest.Attribute.uid)?.intValue {
                    users[name] = UInt32(truncatingIfNeeded: id)
                }
                if let name = node.attribute(BrowserManifest.Attribute.groupName)?.stringValue,
                   let id = node.attribute(BrowserManifest.Attribute.gid)?.intValue {
                    groups[name] = UInt32(truncatingIfNeeded: id)
                }
            }
        }
        return (users, groups)
    }

    /// A user or group as a number: a number as it is, a name the listings show as
    /// the number they show it with.
    private static func identifier(_ text: String, among known: [String: UInt32]) throws -> UInt32 {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let number = UInt32(trimmed) { return number }
        guard let number = known[trimmed] else { throw RemoteWriteError.unknownAccount(trimmed) }
        return number
    }

    /// The owner and group numbers an item has, as its listing recorded them.
    private static func ownership(of url: URL) -> (uid: UInt32, gid: UInt32)? {
        guard let node = BrowserManifestStore.read(in: url.deletingLastPathComponent())?.nodes
                .first(where: { $0.name == url.lastPathComponent }),
              let uid = node.attribute(BrowserManifest.Attribute.uid)?.intValue,
              let gid = node.attribute(BrowserManifest.Attribute.gid)?.intValue else { return nil }
        return (UInt32(truncatingIfNeeded: uid), UInt32(truncatingIfNeeded: gid))
    }

    /// Renames the item at `url` on the server, in the same folder.
    static func rename(_ url: URL, to name: String) async throws -> URL {
        guard let (server, path) = remotePath(url) else { throw RemoteWriteError.notOnServer }
        let folder = parentOf(path)
        try await requireAbsent(name, in: folder, server)
        let target = join(folder, name)
        try await server.mirror.rename(path, to: target)
        try await refresh(url.deletingLastPathComponent())
        return localURL(on: server, remote: target)
    }

    /// Sets the permission bits of the items at `urls` on their servers, and
    /// lists the folders they are in so that the new bits are shown.
    static func setPermissions(_ mode: UInt32, for urls: [URL]) async throws {
        var folders = Set<URL>()
        for url in urls {
            guard let (server, path) = remotePath(url) else { continue }
            try await server.mirror.setPermissions(path, mode: mode)
            folders.insert(url.deletingLastPathComponent())
        }
        for folder in folders {
            try await refresh(folder)
        }
    }

    /// Removes the items at `urls` from their servers, folders with everything
    /// in them, and lists the folders they were in.
    static func remove(_ urls: [URL]) async throws {
        var folders = Set<URL>()
        for url in urls {
            guard let (server, path) = remotePath(url) else { continue }
            try await server.mirror.remove(path, isDirectory: SFTPMirror.isDirectory(url))
            folders.insert(url.deletingLastPathComponent())
        }
        for folder in folders {
            try await refresh(folder)
        }
    }

    /// Copies local files and folders, or the local copies of a server's
    /// items, into the server folder `destination`. A name already there is
    /// not written over.
    static func upload(_ sources: [URL], into destination: URL) async throws {
        guard let (server, folder) = remotePath(destination) else { throw RemoteWriteError.notOnServer }
        for source in sources {
            let name = source.lastPathComponent
            try await requireAbsent(name, in: folder, server)
            try await server.mirror.upload(source, to: join(folder, name),
                                           isDirectory: SFTPMirror.isDirectory(source))
        }
        try await refresh(destination)
    }

    /// Copies a local file or folder, or the local copy of a server's item, to the
    /// server under the path `target`: its folder, and the name it is to have
    /// there. A name already there is not written over.
    static func upload(_ source: URL, as target: URL) async throws {
        let parent = target.deletingLastPathComponent()
        guard let (server, folder) = remotePath(parent) else { throw RemoteWriteError.notOnServer }
        let name = target.lastPathComponent
        try await requireAbsent(name, in: folder, server)
        try await server.mirror.upload(source, to: join(folder, name),
                                       isDirectory: SFTPMirror.isDirectory(source))
        try await refresh(parent)
    }

    /// Sends files written here, in a server's folders, that the server does not
    /// have yet; then lists their folders.
    static func publish(_ urls: [URL]) async throws {
        var folders = Set<URL>()
        for url in urls {
            guard let (server, path) = remotePath(url) else { continue }
            try await server.mirror.upload(url, to: path, isDirectory: false)
            folders.insert(url.deletingLastPathComponent())
        }
        for folder in folders {
            try await refresh(folder)
        }
    }

    /// The permission bits a server item had when it was listed.
    static func listedMode(of url: URL) -> mode_t? {
        listedNode(of: url)?.attribute(BrowserManifest.Attribute.mode)?.intValue
            .map { mode_t(truncatingIfNeeded: $0) }
    }

    /// A server item as its listing recorded it: the server's facts about it.
    static func listedNode(of url: URL) -> BrowserManifest.Node? {
        guard isInside(url) else { return nil }
        return BrowserManifestStore.read(in: url.deletingLastPathComponent())?.nodes
            .first { $0.name == url.lastPathComponent }
    }

    /// The names the server's listings show for its users and groups, for the
    /// server a shadow path is on; empty elsewhere.
    static func accountNames(for url: URL) -> (users: [String], groups: [String]) {
        guard let server = server(of: url) else { return ([], []) }
        let known = accounts(of: server)
        return (known.users.keys.sorted(), known.groups.keys.sorted())
    }

    private static func requireAbsent(_ name: String, in folder: String, _ server: Server) async throws {
        let names = try await server.mirror.listing(folder).map(\.name)
        guard !names.contains(name) else { throw RemoteWriteError.exists(name) }
    }

    /// `/home/peter` and `notes.txt` make `/home/peter/notes.txt`.
    private static func join(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/" + name : folder + "/" + name
    }

    /// The folder a remote path is in: `/home` for `/home/peter`.
    private static func parentOf(_ path: String) -> String {
        "/" + path.split(separator: "/").dropLast().joined(separator: "/")
    }

    // MARK: - Writing back

    /// Sends a file saved here back to its server, unless the server's copy changed.
    static func writeBack(_ url: URL) async throws -> WriteBack {
        guard let (server, path) = remotePath(url) else { return .unchanged }
        return try await server.mirror.writeBack(path)
    }

    /// The server's version, `checksum`, becomes what the file here is compared with.
    static func adoptBaseline(_ url: URL, checksum: String) async throws {
        guard let (server, path) = remotePath(url) else { return }
        try await server.mirror.adoptBaseline(path, checksum: checksum)
    }

    /// The file here is made the server's version again, from `copy` of it.
    static func keepServersVersion(_ url: URL, from copy: URL, checksum: String) async throws {
        guard let (server, path) = remotePath(url) else { return }
        try await server.mirror.keepServersVersion(path, from: copy, checksum: checksum)
        try await refresh(url.deletingLastPathComponent())
    }

    /// The file here is sent under a free name beside it; returns the name.
    static func sendAsNew(_ url: URL) async throws -> String {
        guard let (server, path) = remotePath(url) else { throw RemoteWriteError.notOnServer }
        let name = try await server.mirror.sendAsNew(path)
        try await refresh(url.deletingLastPathComponent())
        return name
    }

    /// Files changed here and not yet on their server: on one server's shadow, or
    /// on all of them.
    static func unsentEdits(under root: URL? = nil) -> [URL] {
        let servers = registry.lock.withLock { registry.servers }
            .filter { root == nil || resolved($0.root.path) == resolved(root!.path) }
        var edits: [URL] = []
        for server in servers {
            var folders = [server.root]
            let enumerator = FileManager.default.enumerator(at: server.root, includingPropertiesForKeys: nil)
            while let next = enumerator?.nextObject() as? URL {
                if SFTPMirror.isDirectory(next) { folders.append(next) }
            }
            for folder in folders {
                for node in BrowserManifestStore.read(in: folder)?.nodes ?? [] {
                    let file = folder.appendingPathComponent(node.name)
                    if SFTPMirror.locallyChanged(node, at: file) { edits.append(file) }
                }
            }
        }
        return edits
    }

    /// The file at a shadow path, with its bytes fetched.
    static func materialize(_ url: URL) async throws {
        guard let (server, path) = remotePath(url) else { return }
        _ = try await server.mirror.materialize(path)
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// The server files being fetched right now, for the views: a row shows its
/// bar, an editor or the Info window its wait, and each follows when it ends.
@MainActor
@Observable
final class ServerDownloads {

    static let shared = ServerDownloads()

    private(set) var active: Set<String> = []

    func started(_ key: String) { active.insert(key) }
    func finished(_ key: String) { active.remove(key) }

    func isDownloading(_ url: URL) -> Bool { active.contains(url.standardizedFileURL.path) }
}
