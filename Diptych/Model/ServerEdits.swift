import CoreServices
import CryptoKit
import Foundation

// Editing a server's files in place. A file fetched from a server is written
// back when it is saved here, unless the server's copy changed meanwhile: the
// checksum of what was fetched is kept, and compared with what the server has
// before anything is sent.

/// The SHA-256 of a file, read a piece at a time.
nonisolated enum FileChecksum {

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Whether a file reads as text: no NUL in its first part, and that part UTF-8.
nonisolated enum TextSniff {

    static func looksLikeText(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        if head.contains(0) { return false }
        // A cut in the middle of a character at the end of the part is not a fault.
        for trim in 0...3 where head.count >= trim {
            if String(data: head.dropLast(trim), encoding: .utf8) != nil { return true }
        }
        return false
    }
}

/// What writing a file back came to.
nonisolated enum WriteBack: Sendable, Equatable {
    /// Nothing to send: the file is as it was fetched, or as it was last sent.
    case unchanged
    case sent
    /// The server's copy changed since it was fetched. `serverCopy` holds what the
    /// server has now; `serverChecksum` is its checksum.
    case conflict(serverCopy: URL, serverChecksum: String, isText: Bool)
}

/// How the person settles a file changed on both sides, when it is not text.
nonisolated enum ConflictChoice: Sendable, Equatable {
    /// The server's version is kept: the changes made here are lost.
    case keepServers
    /// The changes made here are sent: the server's are lost.
    case overwriteServer
    /// The changes made here are sent under a new name; the file itself is the
    /// server's again.
    case saveAsNew
}

/// Watches a server's shadow for files saved in it, with FSEvents.
final class ShadowWatcher {

    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init(root: URL, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ShadowWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            watcher.handler((0..<count).compactMap { array[$0] as? String })
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

/// Watches every connected server's shadow, and sends what is saved there.
@MainActor
final class ServerEditing {

    static let shared = ServerEditing()

    private var watchers: [String: ShadowWatcher] = [:]
    private var waiting: [String: Task<Void, Never>] = [:]
    private var sending: Set<String> = []
    private var savedAgain: Set<String> = []

    /// How long a file is left after it was written before it is sent: an editor
    /// writes a save in more than one step.
    static let settle: Duration = .seconds(1.5)

    func watch(_ root: URL) {
        guard watchers[root.path] == nil else { return }
        watchers[root.path] = ShadowWatcher(root: root) { [weak self] paths in
            MainActor.assumeIsolated { self?.changed(paths) }
        }
    }

    func stop(_ root: URL) {
        watchers.removeValue(forKey: root.path)?.stop()
    }

    private func changed(_ paths: [String]) {
        for path in Set(paths) {
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            guard RemoteBrowsing.isInside(url), !name.hasPrefix(".downloading-"),
                  BrowserManifestStore.number(of: name) == nil,
                  FileManager.default.fileExists(atPath: path), !SFTPMirror.isDirectory(url)
            else { continue }
            waiting[path]?.cancel()
            waiting[path] = Task { [weak self] in
                try? await Task.sleep(for: Self.settle)
                guard !Task.isCancelled else { return }
                await self?.send(url)
            }
        }
    }

    /// Sends one file, or settles it with the person when the server's copy changed.
    /// A save made while it is sent is looked at again once this one is done.
    private func send(_ url: URL) async {
        let key = url.path
        waiting[key] = nil
        guard !sending.contains(key) else {
            savedAgain.insert(key)
            return
        }
        sending.insert(key)
        let model = Self.frontmost
        let name = url.lastPathComponent
        let host = RemoteBrowsing.server(of: url)?.host ?? "the server"
        do {
            switch try await RemoteBrowsing.writeBack(url) {
            case .unchanged:
                break
            case .sent:
                model?.flash("Saved \u{201C}\(name)\u{201D} on \(host)", error: false)
                Self.reloadPanes(showing: url.deletingLastPathComponent())
            case .conflict(let copy, let checksum, let isText):
                if isText {
                    try await merge(url, with: copy, checksum: checksum, on: host, model: model)
                } else {
                    try await settle(url, with: copy, checksum: checksum, on: host, model: model)
                }
            }
        } catch {
            model?.flash("Could not save \u{201C}\(name)\u{201D} on \(host): " + error.localizedDescription)
        }
        sending.remove(key)
        if savedAgain.remove(key) != nil { await send(url) }
    }

    /// Text changed on both sides: a comparison of the two, the server's on the
    /// left and the one here on the right, to merge in. The server's version
    /// becomes the one compared with, so saving the merge sends it.
    private func merge(_ url: URL, with copy: URL, checksum: String, on host: String,
                       model: AppModel?) async throws {
        let theirs = FileManager.default.temporaryDirectory
            .appendingPathComponent("Diptych server versions")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(url.lastPathComponent)
        try FileManager.default.createDirectory(at: theirs.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: copy, to: theirs)
        // Only the side here can be unlocked and saved.
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: theirs.path)
        try await RemoteBrowsing.adoptBaseline(url, checksum: checksum)
        model?.openDiffWindow?(DiffPair(left: theirs, right: url))
        model?.dialog = .notice(
            title: "\u{201C}\(url.lastPathComponent)\u{201D} Changed on \(host) Too",
            text: "Someone changed it on the server since it was opened here, so your changes "
                + "were not sent. The comparison shows the server\u{2019}s version on the left and "
                + "yours on the right. Unlock yours, take what you need from the left, and save: "
                + "it is then sent. Until then the server keeps its version.")
    }

    /// Anything but text changed on both sides: the person chooses which is kept.
    private func settle(_ url: URL, with copy: URL, checksum: String, on host: String,
                        model: AppModel?) async throws {
        defer { try? FileManager.default.removeItem(at: copy) }
        guard let model, let choice = await model.askServerConflict(name: url.lastPathComponent, host: host)
        else { return }
        switch choice {
        case .keepServers:
            try await RemoteBrowsing.keepServersVersion(url, from: copy, checksum: checksum)
            model.flash("Kept the server\u{2019}s \u{201C}\(url.lastPathComponent)\u{201D}", error: false)
        case .overwriteServer:
            try await RemoteBrowsing.adoptBaseline(url, checksum: checksum)
            if try await RemoteBrowsing.writeBack(url) == .sent {
                model.flash("Saved \u{201C}\(url.lastPathComponent)\u{201D} on \(host), over its version",
                            error: false)
            }
        case .saveAsNew:
            let name = try await RemoteBrowsing.sendAsNew(url)
            try await RemoteBrowsing.keepServersVersion(url, from: copy, checksum: checksum)
            model.flash("Saved your version on \(host) as \u{201C}\(name)\u{201D}", error: false)
        }
        Self.reloadPanes(showing: url.deletingLastPathComponent())
    }

    /// The browser window in front, for what is said and asked.
    static var frontmost: AppModel? {
        let models = KeyRouter.shared.allModels
        return models.first { $0.window?.isKeyWindow == true } ?? models.first
    }

    private static func reloadPanes(showing folder: URL) {
        for model in KeyRouter.shared.allModels {
            for pane in [model.left, model.right] where pane.directory.standardizedFileURL == folder.standardizedFileURL {
                pane.reload()
            }
        }
    }
}
