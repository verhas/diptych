import Foundation

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
        /// Closes the connection, when the server is forgotten.
        let close: @Sendable () async -> Void

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
                _ = try await server.mirror.materialize(path)
            }
        }
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
