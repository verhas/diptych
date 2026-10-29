import Foundation

/// Why a change to a server was not made.
nonisolated enum RemoteWriteError: LocalizedError, Equatable, Sendable {
    /// Something of that name is already there, and is not written over.
    case exists(String)
    /// The item is not on a server.
    case notOnServer

    var errorDescription: String? {
        switch self {
        case .exists(let name):
            "\u{201C}\(name)\u{201D} is already there on the server, and is not written over."
        case .notOnServer:
            "That is not a place on a server."
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
            guard let manifest = BrowserManifestStore.read(in: url.deletingLastPathComponent()),
                  let node = manifest.nodes.first(where: { $0.name == url.lastPathComponent })
            else { return true }
            return node.backing == .none
        }
        guard let manifest = BrowserManifestStore.read(in: url) else { return true }
        return manifest.nodes.contains { node in
            node.kind == .directory
                ? pending(url.appendingPathComponent(node.name))
                : node.backing == .none
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
                _ = try await server.mirror.materialize(path)
            }
        }
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

    /// The file at a shadow path, with its bytes fetched.
    static func materialize(_ url: URL) async throws {
        guard let (server, path) = remotePath(url) else { return }
        _ = try await server.mirror.materialize(path)
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
