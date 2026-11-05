import Citadel
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

// SFTP: a file server reached over SSH and browsed without mounting it.
//
// macOS cannot mount SFTP by itself, so Diptych talks to the server through
// Citadel. The panes do not use this yet; it is the connection they will be
// given.

// MARK: - Host keys

/// The host keys Diptych trusts, one line each: the host as it is filed,
/// a space, then the key in OpenSSH's form. Kept apart from ~/.ssh/known_hosts,
/// which belongs to OpenSSH and is not Diptych's to write.
nonisolated struct SFTPHostKeys: Sendable {

    let file: URL

    static let standard = SFTPHostKeys(
        file: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".diptych/sftp_known_hosts"))

    /// How a host is filed: `nas`, or `[nas]:2222` off the default port.
    static func filing(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    /// The key kept for `filing`, if there is one.
    func key(for filing: String) -> NIOSSHPublicKey? {
        for line in lines() {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0] == filing else { continue }
            return try? NIOSSHPublicKey(openSSHPublicKey: String(parts[1]))
        }
        return nil
    }

    /// Keeps `key` for `filing`, in place of any key kept for it before.
    func trust(_ key: NIOSSHPublicKey, for filing: String) throws {
        var kept = lines().filter { !$0.isEmpty && !$0.hasPrefix("\(filing) ") }
        kept.append("\(filing) \(String(openSSHPublicKey: key))")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (kept.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// The lines kept for `filing`, numbered as an editor numbers them, and
    /// each one shortened so that it can be read in a dialog.
    func entries(for filing: String) -> [(line: Int, text: String)] {
        lines().enumerated()
            .filter { $0.element.hasPrefix("\(filing) ") }
            .map { (line: $0.offset + 1, text: Self.abstract($0.element)) }
    }

    /// The first and last few characters of a line: enough to recognise it.
    static func abstract(_ line: String) -> String {
        guard line.count > 60 else { return line }
        return String(line.prefix(40)) + "\u{2026}" + String(line.suffix(12))
    }

    /// Every line, blank ones included, so that the numbers are the editor's.
    private func lines() -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n")
    }
}

/// The server presented a host key Diptych does not trust for that host.
nonisolated enum SFTPHostKeyProblem: Error, Equatable, Sendable {
    /// Nothing is kept for the host yet. `presented` is its key, to confirm.
    case unknown(filing: String, presented: String)
    /// A different key is kept. A changed key is also what an impostor
    /// presents, so it is refused, not offered.
    case changed(filing: String, presented: String)
}

/// Accepts only the key already kept for the host, and records what it was
/// shown so the caller can say why the connection was refused.
///
/// A key Diptych has never seen is refused rather than trusted: whether to
/// trust a new host is the person's decision, and it is made in the UI.
final class SFTPHostKeyCheck: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private let filing: String
    private let keys: SFTPHostKeys
    private var refusal: SFTPHostKeyProblem?

    init(filing: String, keys: SFTPHostKeys) {
        self.filing = filing
        self.keys = keys
    }

    /// Why the last connection was refused, when it was refused for its key.
    var problem: SFTPHostKeyProblem? {
        lock.lock(); defer { lock.unlock() }
        return refusal
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if let kept = keys.key(for: filing), kept == hostKey {
            validationCompletePromise.succeed(())
            return
        }
        let presented = String(openSSHPublicKey: hostKey)
        let kept = keys.key(for: filing) != nil
        let problem: SFTPHostKeyProblem = kept
            ? .changed(filing: filing, presented: presented)
            : .unknown(filing: filing, presented: presented)
        lock.lock()
        refusal = problem
        lock.unlock()
        validationCompletePromise.fail(problem)
    }
}

// MARK: - Listings

/// One item in a remote folder, as the server describes it.
nonisolated struct SFTPEntry: Equatable, Sendable {

    enum Kind: Equatable, Sendable {
        case file, directory, symlink, other
    }

    let name: String
    let kind: Kind
    /// Nil when the server did not say: that is not the same as empty.
    let size: UInt64?
    /// The permission bits, without the type. Nil when the server did not say.
    let mode: UInt32?
    let modified: Date?
    /// The owner and group the server reports, as numbers.
    let uid: UInt32?
    let gid: UInt32?
    /// The owner and group as the server's own listing names them, when it names them.
    let ownerName: String?
    let groupName: String?

    init(name: String, kind: Kind, size: UInt64? = nil, mode: UInt32? = nil,
         modified: Date? = nil, uid: UInt32? = nil, gid: UInt32? = nil,
         ownerName: String? = nil, groupName: String? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.mode = mode
        self.modified = modified
        self.uid = uid
        self.gid = gid
        self.ownerName = ownerName
        self.groupName = groupName
    }

    init(_ component: SFTPPathComponent) {
        let attributes = component.attributes
        name = component.filename
        size = attributes.size
        mode = attributes.permissions.map { $0 & 0o7777 }
        modified = attributes.accessModificationTime?.modificationTime
        uid = attributes.uidgid?.userId
        gid = attributes.uidgid?.groupId
        kind = Self.kind(ofPermissions: attributes.permissions)
        // `ls -l` puts the owner and the group after the link count.
        let fields = component.longname.split(separator: " ", omittingEmptySubsequences: true)
        if fields.count >= 9, fields[0].count == 10 {
            ownerName = String(fields[2])
            groupName = String(fields[3])
        } else {
            ownerName = nil
            groupName = nil
        }
    }

    /// The file-type bits of a Unix mode (`S_IFMT`).
    static func kind(ofPermissions permissions: UInt32?) -> Kind {
        switch (permissions ?? 0) & 0o170000 {
        case 0o040000: .directory
        case 0o100000: .file
        case 0o120000: .symlink
        default: .other
        }
    }
}

// MARK: - Session

/// How Diptych proves who the person is to a server.
nonisolated enum SFTPLogin: Sendable {
    case password(String)
    /// An OpenSSH private key file. Encrypted keys are refused: there is no
    /// passphrase prompt yet, so they are skipped like a missing key.
    case keyFile(URL)
    /// The keys an ssh-agent holds. The agent signs; no private key is read here.
    case agent(SSHAgent)

    /// The keys in `~/.ssh` that can be tried, in the order OpenSSH tries them.
    static var keyFilesInSSHFolder: [URL] {
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        return ["id_ed25519", "id_rsa"]
            .map { ssh.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func method(username: String) throws -> SSHAuthenticationMethod {
        switch self {
        case .password(let password):
            return .passwordBased(username: username, password: password)
        case .agent(let agent):
            let login = SSHAgentLogin(username: username, identities: try agent.identities(), agent: agent)
            guard login.count > 0 else { throw SFTPLoginError.noUsableAgentKeys }
            return .custom(login)
        case .keyFile(let file):
            let text = try String(contentsOf: file, encoding: .utf8)
            switch try SSHKeyDetection.detectPrivateKeyType(from: text) {
            case .ed25519:
                return .ed25519(username: username,
                                privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: text))
            case .rsa:
                return .rsa(username: username,
                            privateKey: try Insecure.RSA.PrivateKey(sshRsa: text))
            default:
                throw SFTPLoginError.unsupportedKey(file.lastPathComponent)
            }
        }
    }
}

/// A file that did not arrive whole, either way.
nonisolated enum SFTPTransferError: LocalizedError, Equatable, Sendable {
    case incomplete(path: String, expected: UInt64, got: UInt64)

    var errorDescription: String? {
        switch self {
        case let .incomplete(path, expected, got):
            let name = (path as NSString).lastPathComponent
            return "\u{201C}\(name)\u{201D} did not arrive whole: \(got) of \(expected) bytes."
        }
    }
}

nonisolated enum SFTPLoginError: Error, Equatable, Sendable {
    case unsupportedKey(String)
    /// The agent holds no key Diptych can sign with.
    case noUsableAgentKeys
    /// The sign-in was forgotten, when the connection was closed: it cannot be
    /// made again.
    case signInForgotten
}

/// What a session's requests share: whether it is closed, how many are under
/// way, and when bytes last moved.
///
/// A request begun on a closed connection, or a connection's thread shut down
/// under a request still running, leaves that request waiting for ever -- and a
/// debug build stops on the abandoned promise. So nothing starts once the
/// session is closed, and its thread is shut down only when the last request
/// under way has ended.
final class SFTPSessionGate: @unchecked Sendable {

    private let lock = NSLock()
    private var closed = false
    private var closingDone = false
    private var underWay = 0
    private var shutDown = false
    private var lastMoved: ContinuousClock.Instant?

    /// Whether a request may start; counted as under way when it may.
    func enter() -> Bool {
        lock.withLock {
            guard !closed else { return false }
            underWay += 1
            return true
        }
    }

    /// A request ended. True when the thread is to be shut down now.
    func leave() -> Bool {
        lock.withLock {
            underWay -= 1
            return takeShutDown()
        }
    }

    /// No more requests start.
    func close() {
        lock.withLock { closed = true }
    }

    /// The connection is closed. True when the thread is to be shut down now.
    func closingFinished() -> Bool {
        lock.withLock {
            closingDone = true
            return takeShutDown()
        }
    }

    private func takeShutDown() -> Bool {
        guard closingDone, underWay == 0, !shutDown else { return false }
        shutDown = true
        return true
    }

    /// Bytes went one way or the other just now.
    func moved() {
        lock.withLock { lastMoved = .now }
    }

    /// Whether bytes moved within `span`: a transfer under way, which is proof the
    /// connection is there however slow the server is to answer anything else.
    func moved(within span: Duration) -> Bool {
        lock.withLock { lastMoved.map { ContinuousClock.now - $0 < span } ?? false }
    }
}

/// A connected SFTP session, shared by whatever asks for a listing.
///
/// Every request goes through `SFTPClient`, which is `Sendable`. The
/// `SSHClient` is not, and is held only to keep the connection open and to
/// close it, so the session is marked `@unchecked Sendable` on that basis.
final class SFTPSession: @unchecked Sendable {

    private let ssh: SSHClient
    private let sftp: SFTPClient
    /// The thread the connection runs on. Its own, so that a signature the
    /// agent is slow to make stalls only this connection.
    private let group: MultiThreadedEventLoopGroup
    let gate = SFTPSessionGate()

    private init(ssh: SSHClient, sftp: SFTPClient, group: MultiThreadedEventLoopGroup) {
        self.ssh = ssh
        self.sftp = sftp
        self.group = group
    }

    /// Connects and signs in as `username`, and checks the host key against
    /// `keys` first.
    ///
    /// When the host key is refused, the error is `SFTPHostKeyProblem`, which
    /// says whether the host is new or its key has changed.
    static func connect(host: String, port: Int = 22, username: String, login: SFTPLogin,
                        keys: SFTPHostKeys = .standard) async throws -> SFTPSession {
        let check = SFTPHostKeyCheck(
            filing: SFTPHostKeys.filing(host: host, port: port), keys: keys)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let ssh: SSHClient
        do {
            ssh = try await SSHClient.connect(
                host: host, port: port,
                authenticationMethod: try login.method(username: username),
                hostKeyValidator: .custom(check),
                reconnect: .never,
                group: group)
        } catch {
            try? await group.shutdownGracefully()
            if let problem = check.problem { throw problem }
            throw error
        }
        do {
            return SFTPSession(ssh: ssh, sftp: try await ssh.openSFTP(), group: group)
        } catch {
            try? await ssh.close()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    /// The folder the server starts a session in, as an absolute path.
    func homeDirectory() async throws -> String {
        try await using { try await sftp.getRealPath(atPath: ".") }
    }

    /// What is in `path`, without `.` and `..`.
    func list(_ path: String) async throws -> [SFTPEntry] {
        try await using { try await sftp.listDirectory(atPath: path) }
            .flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .map(SFTPEntry.init)
    }

    /// Runs one request, unless the session is closed: see `SFTPSessionGate`.
    func using<T>(_ request: () async throws -> T) async throws -> T {
        guard gate.enter() else { throw SFTPError.connectionClosed }
        defer {
            if gate.leave() {
                let group = group
                Task.detached { try? await group.shutdownGracefully() }
            }
        }
        return try await request()
    }

    /// Closing fails the requests under way; the thread goes once they have ended.
    func close() async {
        gate.close()
        try? await sftp.close()
        try? await ssh.close()
        if gate.closingFinished() { try? await group.shutdownGracefully() }
    }
}

/// An open file on the server, handed to the requests that run at once on it.
/// Citadel's handle is a class that does not say it is `Sendable`; it is only
/// read by those requests -- a request carries its own offset -- and closed
/// once they have all ended.
nonisolated struct SharedFile: @unchecked Sendable {
    let handle: SFTPFile
    init(_ handle: SFTPFile) { self.handle = handle }
}

/// Many requests on their way at once, as OpenSSH's `sftp` sends them.
///
/// SFTP numbers every request and its answer, so a client need not wait for one
/// answer before sending the next. Sent one at a time, every 32 KB cost a round
/// trip to the server and back, and a large file crawled over Wi-Fi however fast
/// the network was. The pieces stay small -- every server must take 32 KB, and
/// a bigger write leaves some waiting for good -- but up to `window` of them are
/// under way together.
nonisolated enum SFTPPipeline {

    /// Bytes in one write: one request each, as Citadel cuts them anyway.
    static let writePiece = 32_000
    /// Bytes asked for in one read: what every server must answer in full.
    static let readPiece: UInt32 = 32_768
    /// Requests under way at once: OpenSSH's own default.
    static let window = 64

    /// Sends what `next` gives, piece by piece, until it gives nothing, with up
    /// to `window` writes under way. Returns how many bytes were sent. The first
    /// failure ends it; the writes still under way are left to end.
    static func send(next: () throws -> Data?,
                     write: @escaping @Sendable (Data, UInt64) async throws -> Void,
                     window: Int = window) async throws -> UInt64 {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var offset: UInt64 = 0
            var underWay = 0
            while let piece = try next(), !piece.isEmpty {
                if underWay >= window {
                    try await group.next()
                    underWay -= 1
                }
                let at = offset
                group.addTask { try await write(piece, at) }
                underWay += 1
                offset += UInt64(piece.count)
            }
            try await group.waitForAll()
            return offset
        }
    }

    /// Reads a file of `expected` bytes with up to `window` reads under way, and
    /// hands each piece to `write` with its offset, in whatever order they come.
    /// A read answered short is asked again for the rest; an empty one is the
    /// end. Past `expected` -- or with no size known -- the rest is read one piece
    /// at a time to the end. Returns where the file ended.
    static func receive(expected: UInt64?,
                        read: @escaping @Sendable (UInt64, UInt32) async throws -> Data,
                        write: (Data, UInt64) throws -> Void,
                        piece: UInt32 = readPiece, window: Int = window) async throws -> UInt64 {
        var end: UInt64?
        if let expected, expected > 0 {
            end = try await withThrowingTaskGroup(of: (UInt64, UInt32, Data).self) { group in
                var next: UInt64 = 0
                var gaps: [(UInt64, UInt32)] = []
                var underWay = 0
                var end: UInt64?
                func ask() {
                    while underWay < window {
                        let request: (UInt64, UInt32)
                        if let gap = gaps.popLast() {
                            request = gap
                        } else if next < expected {
                            request = (next, UInt32(min(UInt64(piece), expected - next)))
                            next += UInt64(request.1)
                        } else {
                            return
                        }
                        if let end, request.0 >= end { continue }
                        group.addTask { (request.0, request.1, try await read(request.0, request.1)) }
                        underWay += 1
                    }
                }
                ask()
                while let (offset, asked, data) = try await group.next() {
                    underWay -= 1
                    if data.isEmpty {
                        end = min(end ?? offset, offset)
                    } else {
                        try write(data, offset)
                        if data.count < Int(asked) {
                            gaps.append((offset + UInt64(data.count), asked - UInt32(data.count)))
                        }
                    }
                    ask()
                }
                return end
            }
        }
        // To the end, one piece at a time: a file with no size given, or one that
        // grew after it was opened.
        guard end == nil else { return end! }
        var offset = expected ?? 0
        while true {
            let data = try await read(offset, piece)
            guard !data.isEmpty else { return offset }
            try write(data, offset)
            offset += UInt64(data.count)
        }
    }
}

/// A command a server may have that prints a file's SHA-256: GNU coreutils'
/// `sha256sum` on Linux, Perl's `shasum` on macOS and the BSDs.
nonisolated enum SFTPHashCommand: String, CaseIterable, Sendable {
    case sha256sum, shasum

    /// The command line for `path`, quoted for the shell.
    func line(for path: String) -> String {
        switch self {
        case .sha256sum: "sha256sum -- " + shellQuoted(path)
        case .shasum: "shasum -a 256 -- " + shellQuoted(path)
        }
    }

    /// The checksum both print first, as 64 hexadecimal digits.
    static func digest(in output: String) -> String? {
        guard let word = output.split(whereSeparator: \.isWhitespace).first else { return nil }
        let digest = word.lowercased()
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { return nil }
        return digest
    }
}

/// What asking a server for a checksum came to.
nonisolated enum SFTPHashOutcome: Equatable, Sendable {
    case digest(String)
    /// The server has no such command, or it printed no checksum.
    case commandMissing
    /// The command is there, but failed on this file -- unreadable, gone.
    case failed
}

/// Whether a server can be asked for checksums, and with which command.
nonisolated enum SFTPHashSupport: Equatable, Sendable {
    case untried
    case works(SFTPHashCommand)
    case none

    /// As kept with a saved server: nil when untried, "none", or the command.
    init(stored: String?) {
        switch stored {
        case nil: self = .untried
        case "none": self = .none
        case let name?: self = SFTPHashCommand(rawValue: name).map { .works($0) } ?? .untried
        }
    }

    var stored: String? {
        switch self {
        case .untried: nil
        case .works(let command): command.rawValue
        case .none: "none"
        }
    }
}

/// The server, as the mirror needs it: a folder's entries and a file's bytes.
/// `SFTPSession` is the real one; tests put a fake in its place.
nonisolated protocol RemoteListing: Sendable {
    func entries(in path: String) async throws -> [SFTPEntry]
    /// Writes the file's bytes to `destination`, which it creates.
    func download(_ path: String, to destination: URL) async throws
    func makeDirectory(_ path: String) async throws
    /// Removes a file or a link.
    func removeFile(_ path: String) async throws
    /// Removes an empty folder.
    func removeDirectory(_ path: String) async throws
    func rename(_ from: String, to: String) async throws
    /// Writes a local file's bytes to `path` on the server, replacing what is there.
    func upload(_ local: URL, to path: String) async throws
    /// Sets the permission bits of `path` on the server: setuid, setgid and sticky too.
    func setPermissions(_ path: String, mode: UInt32) async throws
    /// Sets the owner and group of `path` on the server, by number.
    func setOwnership(_ path: String, uid: UInt32, gid: UInt32) async throws
    /// Sets the modification time of `path` on the server.
    func setTimes(_ path: String, modified: Date) async throws
    /// Runs one command as root through sudo, over the same connection: with no
    /// password (`sudo -n`), or with the one given, sent on its input.
    func runAsRoot(_ arguments: [String], password: String?) async throws -> SudoOutcome
    /// The SHA-256 of `path`, worked out on the server by `command`.
    func sha256(of path: String, using command: SFTPHashCommand) async throws -> SFTPHashOutcome
}

extension RemoteListing {
    /// A server that runs no commands has none to work out a checksum with.
    func sha256(of path: String, using command: SFTPHashCommand) async throws -> SFTPHashOutcome {
        .commandMissing
    }
}

extension SFTPSession: RemoteListing {

    func entries(in path: String) async throws -> [SFTPEntry] {
        try await list(path)
    }

    /// Streams the file to `destination` a piece at a time, so a large one is
    /// never held in memory whole.
    func makeDirectory(_ path: String) async throws {
        try await using { try await sftp.createDirectory(atPath: path) }
    }

    func removeFile(_ path: String) async throws {
        try await using { try await sftp.remove(at: path) }
    }

    func removeDirectory(_ path: String) async throws {
        try await using { try await sftp.rmdir(at: path) }
    }

    func rename(_ from: String, to: String) async throws {
        try await using { try await sftp.rename(at: from, to: to) }
    }

    func setPermissions(_ path: String, mode: UInt32) async throws {
        var attributes = SFTPFileAttributes()
        attributes.permissions = mode
        try await using { try await sftp.setAttributes(at: path, to: attributes) }
    }

    func setOwnership(_ path: String, uid: UInt32, gid: UInt32) async throws {
        var attributes = SFTPFileAttributes()
        attributes.uidgid = SFTPFileAttributes.UserGroupId(userId: uid, groupId: gid)
        try await using { try await sftp.setAttributes(at: path, to: attributes) }
    }

    func runAsRoot(_ arguments: [String], password: String?) async throws -> SudoOutcome {
        let words = arguments.map(shellQuoted).joined(separator: " ")
        // With a password, a shell on the server reads one line -- the password,
        // sent on the input -- and hands sudo only that line. It never appears on
        // a command line, and a wrong one fails at once rather than waiting for
        // sudo's next try.
        let command = password == nil
            ? "sudo -n -- " + words
            : "sh -c " + shellQuoted("IFS= read -r p; printf '%s\\n' \"$p\" | sudo -S -p '' -- \"$@\"")
                + " sh " + words
        var errors = ""
        var failed = false
        guard gate.enter() else { throw SFTPError.connectionClosed }
        defer {
            if gate.leave() {
                let group = group
                Task.detached { try? await group.shutdownGracefully() }
            }
        }
        do {
            try await ssh.withExec(command) { inbound, outbound in
                if let password {
                    try await outbound.write(ByteBuffer(string: password + "\n"))
                }
                // The outcome is read here: closing the channel afterwards can fail
                // in its own right and hide whether the command did.
                do {
                    for try await output in inbound {
                        if case .stderr(let buffer) = output { errors += String(buffer: buffer) }
                    }
                } catch is SSHClient.CommandFailed {
                    failed = true
                }
            }
        } catch let error as ChannelError where error == .alreadyClosed {
            // The command ended and the server closed the channel first: nothing lost.
        }
        return failed ? SudoOutcome.reading(errors) : .done
    }

    func sha256(of path: String, using command: SFTPHashCommand) async throws -> SFTPHashOutcome {
        guard gate.enter() else { throw SFTPError.connectionClosed }
        defer {
            if gate.leave() {
                let group = group
                Task.detached { try? await group.shutdownGracefully() }
            }
        }
        var output = ""
        do {
            try await ssh.withExec(command.line(for: path)) { inbound, _ in
                for try await piece in inbound {
                    if case .stdout(let buffer) = piece { output += String(buffer: buffer) }
                }
            }
        } catch let failure as SSHClient.CommandFailed {
            // 127 is the shell's "command not found".
            return failure.exitCode == 127 ? .commandMissing : .failed
        } catch let error as ChannelError where error == .alreadyClosed {
            // Ended, and the server closed the channel first: the output is all here.
        }
        return SFTPHashCommand.digest(in: output).map { .digest($0) } ?? .commandMissing
    }

    func setTimes(_ path: String, modified: Date) async throws {
        var attributes = SFTPFileAttributes()
        attributes.accessModificationTime = SFTPFileAttributes.AccessModificationTime(
            accessTime: modified, modificationTime: modified)
        try await using { try await sftp.setAttributes(at: path, to: attributes) }
    }

    /// Streams a local file to the server a piece at a time.
    func upload(_ local: URL, to path: String) async throws {
        try await using { try await send(local, to: path) }
    }

    func download(_ path: String, to destination: URL) async throws {
        try await using { try await receive(path, to: destination) }
    }

    private func send(_ local: URL, to path: String) async throws {
        let file = SharedFile(try await sftp.openFile(filePath: path, flags: [.write, .create, .truncate]))
        let input = try FileHandle(forReadingFrom: local)
        defer { try? input.close() }
        let gate = gate
        let sent: UInt64
        do {
            sent = try await SFTPPipeline.send(
                next: { try input.read(upToCount: SFTPPipeline.writePiece) },
                write: { piece, offset in
                    try await file.handle.write(ByteBuffer(bytes: piece), at: offset)
                    gate.moved()
                })
        } catch {
            try? await file.handle.close()
            throw error
        }
        try await file.handle.close()
        // What the server holds now, against what was read here: a file that
        // arrived short is a failure said, not a copy taken as made.
        // Counted as it was read, not looked up again: the file here may have
        // changed by now, and that is no fault of the transfer.
        if let held = try await sftp.getAttributes(at: path).size, held != sent {
            throw SFTPTransferError.incomplete(path: path, expected: sent, got: held)
        }
    }

    private func receive(_ path: String, to destination: URL) async throws {
        let file = SharedFile(try await sftp.openFile(filePath: path, flags: .read))
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let gate = gate
        let expected: UInt64?
        let got: UInt64
        do {
            expected = try? await file.handle.readAttributes().size
            got = try await SFTPPipeline.receive(
                expected: expected,
                read: { offset, length in
                    let piece = try await file.handle.read(from: offset, length: length)
                    gate.moved()
                    return Data(piece.readableBytesView)
                },
                write: { piece, offset in
                    try output.seek(toOffset: offset)
                    try output.write(contentsOf: piece)
                })
        } catch {
            try? await file.handle.close()
            throw error
        }
        try await file.handle.close()
        // Short of the size the server gave when it was opened: not the file.
        // (Longer is a file still growing there, and is what it has now.)
        if let expected, got < expected {
            throw SFTPTransferError.incomplete(path: path, expected: expected, got: got)
        }
    }
}
