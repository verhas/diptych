import Foundation
import NetFS
import Observation

// MARK: - Addresses

/// What can be typed into Connect to Server, and what it means.
///
/// Everything here is about the text of an address, never the network, so
/// it is all testable without a server.
nonisolated enum ServerAddress {

    enum Kind: String, Sendable {
        case smb, nfs, webdav, ftp, afp

        var label: String {
            switch self {
            case .smb: "SMB"
            case .nfs: "NFS"
            case .webdav: "WebDAV"
            case .ftp: "FTP"
            case .afp: "AFP"
            }
        }

        /// A share is the first part of the path: `smb://nas/photos/2024` is
        /// the share `photos`, and `2024` a folder inside it.
        var hasShares: Bool { self == .smb || self == .afp }
    }

    /// The URL to mount, or the sentence to show. A bare name is an SMB
    /// server, as in Finder: `nas.local` is `smb://nas.local`.
    static func parse(_ text: String) -> Result<URL, ServerProblem> {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .failure(ServerProblem("Type the server\u{2019}s address: smb://server/share"))
        }
        if !text.contains("://") { text = "smb://" + text }

        guard let colon = text.range(of: "://") else {
            return .failure(ServerProblem("\u{201C}\(text)\u{201D} is not an address"))
        }
        let scheme = text[..<colon.lowerBound].lowercased()
        let rest = text[colon.upperBound...]
        let mapped: String
        switch scheme {
        case "smb", "cifs": mapped = "smb"
        case "nfs", "afp", "ftp", "http", "https": mapped = scheme
        case "webdav", "dav": mapped = "http"
        case "webdavs", "davs": mapped = "https"
        case "sftp", "ssh":
            return .failure(ServerProblem("macOS cannot mount SFTP by itself. A mounter such as "
                + "Mountain Duck, or sshfs on macFUSE, makes it a folder Diptych can open."))
        case "s3", "gs":
            return .failure(ServerProblem("An object store is not a file server macOS can mount. "
                + "rclone mount, or an app such as Mountain Duck, makes it a folder."))
        case "ftps":
            return .failure(ServerProblem("macOS mounts plain FTP only, and read-only."))
        default:
            return .failure(ServerProblem("\u{201C}\(scheme)://\u{201D} is not something macOS "
                + "can mount: use smb://, nfs://, https:// (WebDAV), ftp:// or afp://"))
        }

        // Spaces and the like typed as they are, `smb://nas/My Photos`, are
        // what people write; the URL needs them escaped.
        let escaped = String(rest).addingPercentEncoding(withAllowedCharacters: Self.allowed)
            ?? String(rest)
        guard let url = URL(string: "\(mapped)://\(escaped)"), let host = url.host(),
              !host.isEmpty else {
            return .failure(ServerProblem("The address needs a server: \(mapped)://server/\u{2026}"))
        }
        return .success(url)
    }

    /// What may stay as typed: everything a URL allows, and `%` for what is
    /// already escaped.
    private static let allowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.insert(charactersIn: ":@[]%")
        return set
    }()

    static func kind(of url: URL) -> Kind? {
        switch url.scheme?.lowercased() {
        case "smb", "cifs": .smb
        case "nfs": .nfs
        case "http", "https", "webdav", "webdavs": .webdav
        case "ftp": .ftp
        case "afp": .afp
        default: nil
        }
    }

    /// The address without a password in it: what is kept on disk and shown.
    static func withoutPassword(_ url: URL) -> URL {
        guard url.password(percentEncoded: true) != nil,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.password = nil
        return parts.url ?? url
    }

    /// The path's parts, unescaped, without empty ones.
    static func components(of url: URL) -> [String] {
        url.path(percentEncoded: false).split(separator: "/").map(String.init)
    }

    /// The share an SMB or AFP address names, if it names one.
    static func share(of url: URL) -> String? {
        guard kind(of: url)?.hasShares == true else { return nil }
        return components(of: url).first
    }

    /// What lies beyond what is mounted: `2024` in `smb://nas/photos/2024`.
    /// Mounted is the share, for SMB and AFP; the whole path for the rest.
    static func inside(_ url: URL) -> [String] {
        guard kind(of: url)?.hasShares == true else { return [] }
        return Array(components(of: url).dropFirst())
    }

    /// "photos on nas", "nas" -- how a server is named in a list.
    static func title(of url: URL) -> String {
        let host = displayHost(url.host(percentEncoded: false) ?? "")
        let parts = components(of: url)
        if let last = parts.last { return "\(last) on \(host)" }
        return host
    }

    /// `NAS._smb._tcp.local` -- a name found on the network -- reads as `NAS`.
    static func displayHost(_ host: String) -> String {
        var host = host
        if let range = host.range(of: "._"), host.hasSuffix(".local") {
            host = String(host[..<range.lowerBound])
        }
        return host
    }

    /// A host as it can be compared: `NAS.local.`, `nas` and
    /// `NAS._smb._tcp.local` are one machine.
    static func comparableHost(_ host: String) -> String {
        var host = displayHost(host.lowercased())
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasSuffix(".local") { host.removeLast(".local".count) }
        return host
    }

    /// Whether a mounted volume, by the address macOS would mount it again
    /// with, is what `wanted` asks for: the same kind, the same machine and
    /// the same share or path. The user in either is left out of it.
    static func isSameMount(_ mounted: URL, as wanted: URL) -> Bool {
        guard let a = kind(of: mounted), let b = kind(of: wanted), a == b else { return false }
        guard comparableHost(mounted.host(percentEncoded: false) ?? "")
                == comparableHost(wanted.host(percentEncoded: false) ?? "") else { return false }
        if a.hasShares {
            guard let share = share(of: wanted) else { return false }
            return share.caseInsensitiveCompare(Self.share(of: mounted) ?? "") == .orderedSame
        }
        return components(of: mounted) == components(of: wanted)
    }
}

/// Why an address cannot be used, or why connecting failed.
nonisolated struct ServerProblem: Error, Equatable, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Mounting

/// NetFS: the system's own mounting, the same that Finder's Connect to Server
/// uses. With its interface allowed, macOS asks for the name and password
/// itself -- keeping them in the Keychain if the user says so -- and for the
/// shares to mount when an SMB address names none. Diptych never sees a
/// password.
nonisolated enum ServerMounter {

    /// One mount under way, to cancel.
    final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var id: AsyncRequestID?
        private var cancelled = false

        fileprivate func started(_ id: AsyncRequestID?) {
            lock.lock(); defer { lock.unlock() }
            self.id = id
            if cancelled, let id { NetFSMountURLCancel(id) }
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if let id { NetFSMountURLCancel(id) }
        }

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
    }

    enum Outcome: Sendable, Equatable {
        /// Where it was mounted: one place for each share chosen.
        case mounted([URL])
        case cancelled
        case failed(ServerProblem)
    }

    static func mount(_ url: URL, request: Request) async -> Outcome {
        await withCheckedContinuation { continuation in
            let options = NSMutableDictionary()
            // "UIOption" / "AllowUI": kNAUIOptionKey and kNAUIOptionAllowUI,
            // which are macros Swift does not see.
            options["UIOption"] = "AllowUI"
            var id: AsyncRequestID?
            let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, options, nil, &id,
                                            DispatchQueue.global(qos: .userInitiated)) {
                status, _, mountPoints in
                if request.isCancelled || Self.isCancel(status) {
                    continuation.resume(returning: .cancelled)
                } else if status == 0 {
                    let paths = (mountPoints as? [String]) ?? []
                    continuation.resume(returning: .mounted(paths.map {
                        URL(fileURLWithPath: $0, isDirectory: true)
                    }))
                } else {
                    continuation.resume(returning: .failed(problem(status, url)))
                }
            }
            if status != 0 {
                // Refused before it began; the block is not called.
                continuation.resume(returning: Self.isCancel(status)
                                    ? .cancelled : .failed(problem(status, url)))
                return
            }
            request.started(id)
        }
    }

    static func isCancel(_ status: Int32) -> Bool {
        status == ECANCELED || status == -128 /* userCanceledErr */
    }

    /// The failure in words the user can act on.
    static func problem(_ status: Int32, _ url: URL) -> ServerProblem {
        let host = ServerAddress.displayHost(url.host(percentEncoded: false) ?? "the server")
        switch status {
        case EAUTH, EACCES, EPERM:
            return ServerProblem("\(host) did not accept the name and password, or does not "
                                 + "let this user in.")
        case ENOENT:
            if let share = ServerAddress.share(of: url) {
                return ServerProblem("\(host) has no share called \u{201C}\(share)\u{201D}.")
            }
            // NFS says this for a server it cannot find, too.
            return ServerProblem("\(host) cannot be found, or exports nothing at "
                                 + "\(url.path(percentEncoded: false)).")
        case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ETIMEDOUT, ECONNREFUSED:
            return ServerProblem("\(host) cannot be reached: "
                                 + String(cString: strerror(status)).lowercased()
                                 + ". Is it switched on, and on this network or the VPN?")
        case EIO where ServerAddress.kind(of: url) == .webdav:
            // What WebDAV says for anything from a wrong name to a server
            // that is not WebDAV at all.
            return ServerProblem("\(host) did not answer as a WebDAV server. Check the "
                                 + "address, including its path, and that the server is up.")
        case EEXIST:
            return ServerProblem("\(ServerAddress.title(of: url)) is already connected.")
        case let code where code > 0:
            return ServerProblem("Could not connect to \(host): "
                                 + String(cString: strerror(code)).lowercased() + ".")
        default:
            return ServerProblem("Could not connect to \(host) (error \(status)).")
        }
    }
}

// MARK: - Saved and recent servers

/// A server connected to once, kept in `~/.diptych/servers.json`. Never with
/// a password: that is the Keychain's, and only if the user asked macOS to
/// keep it there.
struct KnownServer: Codable, Identifiable, Equatable, Sendable {
    /// As it was connected to, without a password.
    var address: String
    /// Starred: kept, and shown in the sidebar, rather than only recent.
    var saved = false
    /// Mounted when Diptych starts.
    var openAtLogin = false
    var lastUsed = Date()
    /// Where it was last mounted, so a pane left there can bring it back.
    var mountPoint: String?

    var id: String { address.lowercased() }
    var url: URL? { URL(string: address) }
    var title: String { url.map(ServerAddress.title(of:)) ?? address }

    init(address: String, saved: Bool = false, openAtLogin: Bool = false,
         lastUsed: Date = Date(), mountPoint: String? = nil) {
        self.address = address
        self.saved = saved
        self.openAtLogin = openAtLogin
        self.lastUsed = lastUsed
        self.mountPoint = mountPoint
    }

    /// Tolerant: a field added later must not discard the whole list.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = try c.decode(String.self, forKey: .address)
        saved = try c.decodeIfPresent(Bool.self, forKey: .saved) ?? false
        openAtLogin = try c.decodeIfPresent(Bool.self, forKey: .openAtLogin) ?? false
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed) ?? Date()
        mountPoint = try c.decodeIfPresent(String.self, forKey: .mountPoint)
    }
}

@MainActor
@Observable
final class ServerStore {

    static let shared = ServerStore()

    /// Saved first, then the most recently used.
    private(set) var servers: [KnownServer] = []

    /// How many unsaved ones are remembered.
    static let recentLimit = 10

    @ObservationIgnored private let file: URL

    init(file: URL = StateStore.directory.appendingPathComponent("servers.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let list = try? Self.decoder.decode([KnownServer].self, from: data) {
            servers = Self.ordered(list)
        }
    }

    var saved: [KnownServer] { servers.filter(\.saved) }
    var recent: [KnownServer] { servers.filter { !$0.saved } }

    func server(for url: URL) -> KnownServer? {
        let id = ServerAddress.withoutPassword(url).absoluteString.lowercased()
        return servers.first { $0.id == id }
    }

    /// Connected: to the top of the recent ones, with where it went.
    func used(_ url: URL, mountPoint: URL?) {
        let address = ServerAddress.withoutPassword(url).absoluteString
        var entry = servers.first { $0.id == address.lowercased() } ?? KnownServer(address: address)
        entry.lastUsed = Date()
        if let mountPoint { entry.mountPoint = mountPoint.path }
        servers.removeAll { $0.id == entry.id }
        servers.append(entry)
        commit()
    }

    /// A server macOS mounted some other way -- Finder, a script -- learnt
    /// from the volume, so that a pane left on it can bring it back too.
    /// Not moved up the recent list: it was not connected to from here.
    func noticed(_ url: URL, mountPoint: URL) {
        let address = ServerAddress.withoutPassword(url).absoluteString
        if let index = servers.firstIndex(where: { $0.id == address.lowercased() }) {
            guard servers[index].mountPoint != mountPoint.path else { return }
            servers[index].mountPoint = mountPoint.path
        } else {
            servers.append(KnownServer(address: address, lastUsed: .distantPast,
                                       mountPoint: mountPoint.path))
        }
        commit()
    }

    func setSaved(_ server: KnownServer, _ saved: Bool) {
        update(server) {
            $0.saved = saved
            if !saved { $0.openAtLogin = false }
        }
    }

    func setOpenAtLogin(_ server: KnownServer, _ on: Bool) {
        update(server) {
            $0.openAtLogin = on
            if on { $0.saved = true }
        }
    }

    func forget(_ server: KnownServer) {
        servers.removeAll { $0.id == server.id }
        commit()
    }

    /// The server last mounted at `path` or above it, and the mount point.
    func server(mountedAbove path: String) -> (KnownServer, String)? {
        for server in servers {
            guard let point = server.mountPoint else { continue }
            if path == point || path.hasPrefix(point + "/") { return (server, point) }
        }
        return nil
    }

    private func update(_ server: KnownServer, _ change: (inout KnownServer) -> Void) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        change(&servers[index])
        commit()
    }

    private func commit() {
        servers = Self.ordered(servers)
        let unsaved = servers.filter { !$0.saved }
        // The oldest recent ones go; those only noticed, never connected to
        // from here, are the oldest of all.
        if unsaved.count > Self.recentLimit {
            let dropped = Set(unsaved.dropFirst(Self.recentLimit).map(\.id))
            servers.removeAll { dropped.contains($0.id) }
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(servers) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func ordered(_ list: [KnownServer]) -> [KnownServer] {
        list.sorted {
            if $0.saved != $1.saved { return $0.saved }
            if $0.saved { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.lastUsed > $1.lastUsed
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - What is mounted

/// The network volumes mounted now, whoever mounted them, and the address
/// macOS would mount each again with. Stats every volume: off the main actor.
nonisolated enum ServerVolumes {

    struct Mounted: Sendable, Equatable {
        let remount: URL
        let mountPoint: URL
    }

    static func mounted() -> [Mounted] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeURLForRemountingKey]
        let urls = FileManager().mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                   options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal == false,
                  let remount = values.volumeURLForRemounting,
                  ServerAddress.kind(of: remount) != nil else { return nil }
            return Mounted(remount: remount, mountPoint: url)
        }
    }

    /// Where `url`'s share or path is mounted already, if it is.
    static func mountPoint(of url: URL, among mounted: [Mounted] = mounted()) -> URL? {
        mounted.first { ServerAddress.isSameMount($0.remount, as: url) }?.mountPoint
    }
}

// MARK: - What a folder is on

/// The few facts about a folder's volume that change how Diptych treats it.
nonisolated struct VolumeFacts: Equatable, Sendable {
    /// On a server rather than this Mac's own disks.
    var isNetwork = false
    /// Nothing can be written: FTP, or a share mounted read-only.
    var isReadOnly = false
    /// `smbfs`, `nfs`, `webdav`, `ftp`, `apfs`…
    var typeName: String?
    /// The volume's name, as the sidebar shows it.
    var name: String?

    static let local = VolumeFacts()

    /// Stats the volume: off the main actor. Inside an archive opened as a
    /// folder, the archive is the volume, and read-only.
    static func of(_ url: URL) -> VolumeFacts {
        if let facts = ArchiveBrowsing.volumeFacts(of: url) { return facts }
        guard let values = try? url.resourceValues(forKeys: [
            .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeTypeNameKey,
            .volumeLocalizedNameKey]) else { return .local }
        return VolumeFacts(isNetwork: values.volumeIsLocal == false,
                           isReadOnly: values.volumeIsReadOnly == true,
                           typeName: values.volumeTypeName?.lowercased(),
                           name: values.volumeLocalizedName)
    }
}
