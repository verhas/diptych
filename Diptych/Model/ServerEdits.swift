import AppKit
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

/// The server files a Diptych editor has open with changes not saved yet. Such
/// a file is never fetched again under the editor, whatever the server did:
/// the save then shows the conflict instead of losing the changes.
nonisolated enum EditedHere {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: [String: Int] = [:]

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// Counted, so two windows on one file each hold it.
    static func hold(_ url: URL) {
        lock.withLock { paths[key(url), default: 0] += 1 }
    }

    static func release(_ url: URL) {
        lock.withLock {
            let key = key(url)
            guard let count = paths[key] else { return }
            paths[key] = count > 1 ? count - 1 : nil
        }
    }

    static func holdsUnsaved(_ url: URL) -> Bool {
        lock.withLock { paths[key(url)] != nil }
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

/// How the person settles a file changed both here and on its server.
nonisolated enum ConflictChoice: Sendable, Equatable {
    /// The server's version is kept: the changes made here are lost.
    case keepServers
    /// The changes made here are sent: the server's are lost.
    case overwriteServer
    /// The changes made here are sent under a new name; the file itself is the
    /// server's again.
    case saveAsNew
    /// Text only: the two side by side, to take from each what is wanted.
    case compare
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
                try await settle(url, with: copy, checksum: checksum, isText: isText, on: host,
                                 model: model)
            }
        } catch {
            model?.flash("Could not save \u{201C}\(name)\u{201D} on \(host): " + error.localizedDescription)
        }
        sending.remove(key)
        if savedAgain.remove(key) != nil { await send(url) }
    }

    /// Changed on both sides: the person chooses which is kept, or -- for text --
    /// compares the two. Asked in front of every window, since the save may have
    /// come from any editor, Diptych's or another app's.
    private func settle(_ url: URL, with copy: URL, checksum: String, isText: Bool,
                        on host: String, model: AppModel?) async throws {
        let name = url.lastPathComponent
        guard let choice = Self.ask(name: name, host: host, isText: isText) else {
            try? FileManager.default.removeItem(at: copy)
            model?.flash("\u{201C}\(name)\u{201D} was not sent: \(host) keeps its version until "
                         + "it is saved again")
            return
        }
        if choice == .compare {
            try await merge(url, with: copy, checksum: checksum, on: host, model: model)
            return
        }
        defer { try? FileManager.default.removeItem(at: copy) }
        switch choice {
        case .keepServers:
            try await RemoteBrowsing.keepServersVersion(url, from: copy, checksum: checksum)
            Self.replacedHere(url)
            model?.flash("Kept the server\u{2019}s \u{201C}\(name)\u{201D}", error: false)
        case .overwriteServer:
            try await RemoteBrowsing.adoptBaseline(url, checksum: checksum)
            if try await RemoteBrowsing.writeBack(url) == .sent {
                model?.flash("Saved \u{201C}\(name)\u{201D} on \(host), over its version", error: false)
            }
        case .saveAsNew:
            let newName = try await RemoteBrowsing.sendAsNew(url)
            try await RemoteBrowsing.keepServersVersion(url, from: copy, checksum: checksum)
            Self.replacedHere(url)
            model?.flash("Saved your version on \(host) as \u{201C}\(newName)\u{201D}", error: false)
        case .compare:
            break
        }
        Self.reloadPanes(showing: url.deletingLastPathComponent())
    }

    /// The question, as an alert of its own: the first answer is the safe one.
    private static func ask(name: String, host: String, isText: Bool) -> ConflictChoice? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\u{201C}\(name)\u{201D} Changed on \(host) Too"
        alert.informativeText = "It was changed on the server after it was fetched, and you saved "
            + "your changes to it here. Nothing has been sent yet. Which is kept?"
        let newName = SFTPMirror.freeName(for: name, among: [])
        var choices: [ConflictChoice] = []
        if isText {
            alert.addButton(withTitle: "Compare the Two\u{2026}")
            choices.append(.compare)
        }
        alert.addButton(withTitle: "Save Mine as a New File (\(newName)\u{2026})")
        choices.append(.saveAsNew)
        alert.addButton(withTitle: "Keep Mine \u{2014} the Server\u{2019}s Changes Are Lost")
        choices.append(.overwriteServer)
        alert.addButton(withTitle: "Keep the Server\u{2019}s \u{2014} My Changes Are Lost")
        choices.append(.keepServers)
        alert.addButton(withTitle: "Decide Later")
        NSApp.activate()
        let index = alert.runSelectable().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(index) ? choices[index] : nil
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
        model?.flash("The server\u{2019}s version is on the left, yours on the right. Saving the "
                     + "right side sends it.", error: false)
    }

    /// Posted when the copy here of a server file was put back to the server's
    /// version: an editor that has it open reads it again.
    static let replaced = Notification.Name("ServerEditing.replaced")

    private static func replacedHere(_ url: URL) {
        OpenTextDocuments.shared.refreshIfOpen(url, discardingChanges: true)
        NotificationCenter.default.post(name: replaced, object: url)
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
