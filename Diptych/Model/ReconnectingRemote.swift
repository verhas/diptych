import Foundation

/// The sign-in a connection made, kept only for as long as the connection is
/// open: so that it can be made again when the connection is lost, and gone
/// when the connection is closed. Nothing else keeps it, so once it is
/// forgotten the password is no longer held by Diptych.
final class SFTPCredential: @unchecked Sendable {

    private let lock = NSLock()
    private var stored: SFTPLogin?

    init(_ login: SFTPLogin) {
        stored = login
    }

    /// The sign-in, until it is forgotten.
    var login: SFTPLogin? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// Forgets the sign-in: the connection can no longer be made again.
    func forget() {
        lock.lock()
        stored = nil
        lock.unlock()
    }
}

/// The connection a server's shadow reads and writes through. It keeps the
/// connection alive, and makes a new one when the old one has died.
///
/// A network device between here and a server ends a connection it sees
/// idle, and nothing says so: the next request just fails. So every minute the
/// connection is asked a question, and one that does not answer is dropped. A
/// request that fails on a connection that does not answer is made again, once,
/// on a new one. A read is made again whatever the failure, since reading twice
/// changes nothing; a change is made again only when the connection is found to
/// be dead, so that it is not made twice.
actor ReconnectingRemote: RemoteListing {

    /// One connection: what it reads through, whether it still answers, and how
    /// it is closed.
    struct Link: Sendable {
        /// Which connection this is, so that a dead one is not mistaken for a new one.
        let id = UUID()
        let remote: RemoteListing
        let answers: @Sendable () async -> Bool
        let close: @Sendable () async -> Void

        init(remote: RemoteListing, answers: @escaping @Sendable () async -> Bool,
             close: @escaping @Sendable () async -> Void) {
            self.remote = remote
            self.answers = answers
            self.close = close
        }
    }

    private var link: Link?
    private let open: @Sendable () async throws -> Link
    private var keepAlive: Task<Void, Never>?
    /// How often the connection is asked whether it is there; nil for never.
    private var interval: Duration?

    /// The interval the ssh configuration uses when it says nothing.
    static let defaultInterval: Duration = .seconds(60)
    /// How long an answer may take before the connection is given up on.
    static let patience: Duration = .seconds(15)

    init(link: Link, open: @escaping @Sendable () async throws -> Link,
         interval: Duration? = ReconnectingRemote.defaultInterval) {
        self.link = link
        self.open = open
        self.interval = interval
    }

    /// Starts asking the connection, every interval, whether it is there.
    func startKeepingAlive() {
        keepAlive?.cancel()
        keepAlive = nil
        guard let interval else { return }
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.checkAlive()
            }
        }
    }

    /// Changes how often the connection is asked, from now on; nil stops it.
    func setKeepAlive(_ interval: Duration?) {
        self.interval = interval
        startKeepingAlive()
    }

    /// Closes the connection, and stops keeping it alive.
    func close() async {
        keepAlive?.cancel()
        keepAlive = nil
        let old = link
        link = nil
        await old?.close()
    }

    /// Asks the connection whether it is there. One that is not is dropped, so
    /// that the next request makes a new one.
    func checkAlive() async {
        guard let link else { return }
        if await !Self.answers(link) {
            self.link = nil
            await link.close()
        }
    }

    // MARK: - Requests

    private func current() async throws -> Link {
        if let link { return link }
        let fresh = try await open()
        link = fresh
        return fresh
    }

    /// Runs one request on the current connection. A failure on a connection
    /// that does not answer is followed by one more try on a new connection; a
    /// read is tried again whatever the failure, a change only when the
    /// connection is dead.
    private func perform<T: Sendable>(idempotent: Bool,
                                      _ request: @escaping @Sendable (RemoteListing) async throws -> T) async throws -> T {
        let used = try await current()
        do {
            return try await request(used.remote)
        } catch {
            if !idempotent, await Self.answers(used) { throw error }
            await drop(used)
            return try await request(try await current().remote)
        }
    }

    /// Forgets `used` if it is still the current connection, and closes it.
    private func drop(_ used: Link) async {
        if link?.id == used.id { link = nil }
        await used.close()
    }

    /// Whether `link` answers within the patience, a stalled one counting as dead.
    private static func answers(_ link: Link) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await link.answers() }
            group.addTask {
                try? await Task.sleep(for: patience)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: - RemoteListing

    func entries(in path: String) async throws -> [SFTPEntry] {
        try await perform(idempotent: true) { try await $0.entries(in: path) }
    }

    func download(_ path: String, to destination: URL) async throws {
        try await perform(idempotent: true) { try await $0.download(path, to: destination) }
    }

    func makeDirectory(_ path: String) async throws {
        try await perform(idempotent: false) { try await $0.makeDirectory(path) }
    }

    func removeFile(_ path: String) async throws {
        try await perform(idempotent: false) { try await $0.removeFile(path) }
    }

    func removeDirectory(_ path: String) async throws {
        try await perform(idempotent: false) { try await $0.removeDirectory(path) }
    }

    func rename(_ from: String, to: String) async throws {
        try await perform(idempotent: false) { try await $0.rename(from, to: to) }
    }

    func upload(_ local: URL, to path: String) async throws {
        try await perform(idempotent: false) { try await $0.upload(local, to: path) }
    }

    func setPermissions(_ path: String, mode: UInt32) async throws {
        // Setting a mode twice leaves it as it was set: safe to make again.
        try await perform(idempotent: true) { try await $0.setPermissions(path, mode: mode) }
    }

    func setOwnership(_ path: String, uid: UInt32, gid: UInt32) async throws {
        try await perform(idempotent: true) { try await $0.setOwnership(path, uid: uid, gid: gid) }
    }

    func setTimes(_ path: String, modified: Date) async throws {
        try await perform(idempotent: true) { try await $0.setTimes(path, modified: modified) }
    }
}

/// How often a connection is checked: Diptych's own setting for the server,
/// else `ServerAliveInterval` from `~/.ssh/config` for the host, else a minute.
/// Zero, from either, turns the checks off.
enum SFTPKeepAlive {

    static func interval(host: String, override: Int?) -> Duration? {
        let seconds = override ?? SSHConfig.serverAliveInterval(for: host)
            ?? Int(ReconnectingRemote.defaultInterval.components.seconds)
        return seconds > 0 ? .seconds(seconds) : nil
    }
}

extension ReconnectingRemote.Link {

    /// A link over an SFTP session: it answers by reporting the home folder.
    static func over(_ session: SFTPSession) -> ReconnectingRemote.Link {
        ReconnectingRemote.Link(
            remote: session,
            answers: { (try? await session.homeDirectory()) != nil },
            close: { await session.close() })
    }
}
