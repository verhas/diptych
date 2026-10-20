import CryptoKit
import Foundation
import Observation

/// Files holding the same bytes as one file, or every set of files holding
/// the same bytes in one folder.
///
/// For a file, the search goes outwards, nearest first: its own folder, the
/// folders under it a level at a time, then -- asked for -- the folder above
/// without the branch already read, and so on to the top of the volume, and
/// after that the other volumes. A copy is most often made next to the
/// original, so the first ones found are the likely ones.
///
/// A folder is read the same way, a level at a time, and what is inside it
/// is grouped by content. A file's size is read for every file; the bytes
/// only of files that share a size with another.
enum DuplicateFinder {

    struct Options: Sendable, Equatable {
        /// Hard links to the same file, and symbolic links leading to a file
        /// of the same content, listed among the copies -- a link together
        /// with the file it leads to, wherever that is. Off, a second name of
        /// a file already found is left out, and links are not looked at.
        var includeLinks = false
        var subfolders = true
        /// For a file: up from its folder to the top of its volume.
        var wholeVolume = false
        /// For a file: these other volumes, by their paths, after this one --
        /// each chosen on its own: the backup disk, say, but not the video
        /// server.
        var volumes: Set<String> = []
    }

    /// How a found item relates to the content it shares.
    enum Kind: Sendable, Equatable {
        /// The file the search was for.
        case original
        case copy
        /// Another name of a file already listed: the same file, not a copy.
        case hardLink
        /// A symbolic link leading to a file of the same content.
        case symbolicLink
    }

    struct Found: Sendable {
        var url: URL
        var kind: Kind
        var size: Int64
        /// Against the group's first file: what sets this one apart besides
        /// the bytes.
        var differences: DirectoryComparison.Difference
        /// Everything the pane shows of a row, for its icons.
        var item: FileItem
        /// For a symbolic link: the file it ends at, and the item it names
        /// itself -- another link, where there is a chain. Either one in the
        /// Trash leaves it leading nowhere.
        var linksTo: URL? = nil
        var pointsAt: URL? = nil
    }

    /// How far a search has got: its own folder, the folders under it, then
    /// wider and wider.
    enum Stage: Sendable, Equatable {
        case folder
        case subfolders
        /// Everything under this folder, one more level up.
        case up(String)
        case volume(name: String, path: String)
    }

    enum Event: Sendable {
        /// `group` counts from 0. A file's search has one group; a folder's
        /// gets one as soon as the second file of some content turns up.
        case found(group: Int, Found)
        case progress(folder: String, foldersRead: Int, filesRead: Int)
        case stage(Stage)
        case unreadable(String)
    }

    /// A volume, or the part of one, to read: everything under `path` on
    /// `device`. The startup disk's own volume is read from `/` -- where
    /// `/Users` and `/Applications` are reached -- but only on the data
    /// volume, not the sealed system under it.
    struct Root: Sendable, Equatable, Identifiable {
        var path: String
        var device: Int32
        var id: String { path }
        /// As Finder names it.
        var name: String { FileManager.default.displayName(atPath: path) }
    }

    // MARK: - The volumes

    /// Every other volume to search after the one `device` is on.
    static func otherVolumes(than device: Int32) -> [Root] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                         options: [.skipHiddenVolumes]) ?? []
        var roots: [Root] = []
        var seen: Set<Int32> = [device]
        for url in urls {
            let path = url.path
            guard !path.hasPrefix("/System/Volumes/") else { continue }
            let found = path == "/" ? startupDisk() : self.device(of: path).map {
                Root(path: path, device: $0)
            }
            guard let found, seen.insert(found.device).inserted else { continue }
            roots.append(found)
        }
        return roots
    }

    /// `/`, on the device the user's files are on.
    static func startupDisk() -> Root? {
        guard let device = device(of: "/System/Volumes/Data") ?? device(of: "/") else { return nil }
        return Root(path: "/", device: device)
    }

    private static func device(of path: String) -> Int32? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_dev : nil
    }

    // MARK: - Searching

    /// Blocks; run it on a thread of its own. `report` is called on that
    /// thread. `others` and `ceiling` stand in for the real volumes and the
    /// real top of the volume, for a test.
    static func search(for url: URL, options: Options, cancelled: CancellationFlag,
                       others: [Root]? = nil, ceiling: String? = nil,
                       report: @escaping (Event) -> Void) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        let isFolder = info.st_mode & S_IFMT == S_IFDIR

        if isFolder {
            guard let path = realPath(url.path) else { return }
            var walk = Walk(mode: .groups, options: options, device: info.st_dev,
                            cancelled: cancelled, report: report)
            walk.pruned = prunedFor(path)
            walk.breadthFirst(path, skipping: nil, descend: options.subfolders,
                              stage: .folder, then: .subfolders)
            return
        }

        // What it is followed to: a link selected is searched for by what it
        // leads to.
        var content = stat()
        guard stat(url.path, &content) == 0, content.st_mode & S_IFMT == S_IFREG,
              let folder = realPath(url.deletingLastPathComponent().path),
              let bytes = realPath(url.path) else { return }
        let original = URL(fileURLWithPath: folder).appendingPathComponent(url.lastPathComponent)
        var walk = Walk(mode: .copies(of: original, bytes: URL(fileURLWithPath: bytes),
                                      size: Int64(content.st_size), inode: Inode(content)),
                        options: options, device: info.st_dev, cancelled: cancelled,
                        report: report)
        walk.pruned = prunedFor(folder)
        walk.announceOriginal()
        guard content.st_size > 0 else { return }

        walk.breadthFirst(folder, skipping: nil,
                          descend: options.subfolders || options.wholeVolume,
                          stage: .folder, then: .subfolders)
        if walk.isOver { return }

        if options.wholeVolume {
            let ceiling = ceiling.flatMap(realPath)
            var current = folder
            while current != "/" && current != ceiling {
                let parent = (current as NSString).deletingLastPathComponent
                // The top of the volume -- except where the startup disk's
                // data volume is reached through `/`.
                guard let device = device(of: parent),
                      device == walk.device || (parent == "/" && startupDisk()?.device == walk.device)
                else { break }
                walk.breadthFirst(parent, skipping: current, descend: true, stage: .up(parent))
                if walk.isOver { return }
                current = parent
            }
        }

        if !options.volumes.isEmpty {
            for root in others ?? otherVolumes(than: walk.device)
            where options.volumes.contains(root.path) {
                walk.device = root.device
                walk.breadthFirst(root.path, skipping: nil, descend: true,
                                  stage: .volume(name: root.name, path: root.path))
                if walk.isOver { return }
            }
        }
    }

    /// `/System/Volumes` holds the startup disk's volumes a second time,
    /// through the firmlinks: read, every file there would be found twice.
    private static func prunedFor(_ start: String) -> Set<String> {
        start.hasPrefix("/System/Volumes/") ? [] : ["/System/Volumes"]
    }

    /// Symbolic links on the way resolved: `/var` and `/private/var` are one
    /// folder, and must not be read as two.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(decoding: Data(bytes: resolved, count: strlen(resolved)), as: UTF8.self)
    }

    struct Inode: Hashable, Sendable {
        var device: Int32
        var number: UInt64
        init(_ info: stat) {
            device = info.st_dev
            number = UInt64(info.st_ino)
        }
    }

    private enum Mode {
        /// `bytes`: the file whose bytes are read -- the original, or what
        /// the selected link leads to.
        case copies(of: URL, bytes: URL, size: Int64, inode: Inode)
        case groups
    }

    /// What content one candidate has, as far as it has been read.
    private struct Candidate {
        var url: URL
        /// The file whose bytes are read: the link's target for a link, the
        /// file itself otherwise. Never the link: its own size is that of
        /// the path it holds.
        var bytes: URL
        var kind: Kind
        var size: Int64
        /// The file whose bytes these are -- a link's target.
        var inode: Inode
    }

    private struct Walk {
        let mode: Mode
        let options: Options
        var device: Int32
        let cancelled: CancellationFlag
        let report: (Event) -> Void
        var pruned: Set<String> = []

        var foldersRead = 0
        var filesRead = 0
        var lastReport = Date.distantPast
        /// Every file met, by inode: a second name for one is a hard link.
        var inodes: Set<Inode> = []
        /// Every path looked at, so a file reached both through a link and
        /// in its own folder is listed once.
        var seen: Set<String> = []
        /// For a file: the files already found holding its bytes.
        var matching: Set<Inode> = []
        /// Folders already read, so none is read twice.
        var read: Set<String> = []

        // For a folder's groups.
        /// The first file of each size, not read yet: until a second of that
        /// size turns up, there is nothing to compare it with.
        var firstOfSize: [Int64: Candidate] = [:]
        var sizesRead: Set<Int64> = []
        var digests: [Inode: String] = [:]
        /// By size and digest, the files found so far, and their group once
        /// there are two.
        var byContent: [String: (members: [Candidate], group: Int?)] = [:]
        var groups = 0
        /// Each group's first file, which the others are compared with.
        var references: [Int: URL] = [:]

        init(mode: Mode, options: Options, device: Int32, cancelled: CancellationFlag,
             report: @escaping (Event) -> Void) {
            self.mode = mode
            self.options = options
            self.device = device
            self.cancelled = cancelled
            self.report = report
        }

        var isOver: Bool { cancelled.isCancelled }

        mutating func announceOriginal() {
            guard case .copies(let original, let bytes, let size, let inode) = mode else { return }
            inodes.insert(inode)
            seen.insert(original.path)
            references[0] = original
            emit(0, Candidate(url: original, bytes: bytes, kind: .original, size: size,
                              inode: inode))
        }

        /// `root` and, with `descend`, everything under it but `skipping`, a
        /// level at a time. `stage` is said first, `then` once the root is read.
        mutating func breadthFirst(_ root: String, skipping: String?, descend: Bool,
                                   stage: Stage, then next: Stage? = nil) {
            report(.stage(stage))
            var queue = [root]
            var at = 0
            while at < queue.count {
                if isOver { return }
                if at == 1, let next { report(.stage(next)) }
                let folder = queue[at]
                at += 1
                let subfolders = readFolder(folder, isRoot: folder == root)
                guard descend else { continue }
                for sub in subfolders where sub != skipping && !pruned.contains(sub) {
                    queue.append(sub)
                }
            }
        }

        /// One folder: its files looked at, its folders returned.
        mutating func readFolder(_ folder: String, isRoot: Bool) -> [String] {
            guard read.insert(folder).inserted else { return [] }
            guard let directory = opendir(folder) else {
                if errno == EACCES || errno == EPERM { report(.unreadable(folder)) }
                return []
            }
            defer { closedir(directory) }
            // Another volume mounted here. The root of a search is let in
            // whatever it is on: `/` is the system volume, and holds the
            // data volume's folders.
            var info = stat()
            guard fstat(dirfd(directory), &info) == 0, isRoot || info.st_dev == device else {
                return []
            }

            foldersRead += 1
            progress(folder)

            let prefix = folder == "/" ? "/" : folder + "/"
            var folders: [String] = []
            var names: [(String, UInt8)] = []
            while let entry = readdir(directory) {
                let name = Self.name(of: entry)
                if name == "." || name == ".." { continue }
                names.append((name, entry.pointee.d_type))
            }
            // In a steady order, the way a listing shows them.
            names.sort { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
            for (name, type) in names {
                if isOver { return [] }
                let path = prefix + name
                switch type {
                case UInt8(DT_DIR): folders.append(path)
                case UInt8(DT_REG): consider(path, isLink: false)
                case UInt8(DT_LNK): if options.includeLinks { consider(path, isLink: true) }
                case UInt8(DT_UNKNOWN):
                    var entryInfo = stat()
                    guard lstat(path, &entryInfo) == 0 else { continue }
                    switch entryInfo.st_mode & S_IFMT {
                    case S_IFDIR: folders.append(path)
                    case S_IFREG: consider(path, isLink: false)
                    case S_IFLNK: if options.includeLinks { consider(path, isLink: true) }
                    default: break
                    }
                default: break
                }
            }
            return folders
        }

        mutating func progress(_ folder: String) {
            let now = Date()
            guard now.timeIntervalSince(lastReport) > 0.1 else { return }
            lastReport = now
            report(.progress(folder: folder, foldersRead: foldersRead, filesRead: filesRead))
        }

        /// One file, or one link: is it a copy? A link is followed, and the
        /// file it leads to listed with it, wherever that is.
        mutating func consider(_ path: String, isLink: Bool) {
            filesRead += 1
            var info = stat()
            // A link by what it leads to; a broken one leads to nothing.
            guard (isLink ? stat(path, &info) : lstat(path, &info)) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else { return }
            let inode = Inode(info)
            let size = Int64(info.st_size)
            let url = URL(fileURLWithPath: path)
            guard isLink else {
                guard let kind = firstSight(path, inode) else { return }
                take(Candidate(url: url, bytes: url, kind: kind, size: size, inode: inode))
                return
            }
            guard seen.insert(path).inserted,
                  let target = DuplicateFinder.realPath(path) else { return }
            let bytes = URL(fileURLWithPath: target)
            guard take(Candidate(url: url, bytes: bytes, kind: .symbolicLink, size: size,
                                 inode: inode)),
                  let kind = firstSight(target, inode) else { return }
            take(Candidate(url: bytes, bytes: bytes, kind: kind, size: size, inode: inode))
        }

        /// How a file met for the first time stands: a copy, another name of
        /// one already met, or -- met before, or a second name not asked
        /// for -- nothing to list.
        mutating func firstSight(_ path: String, _ inode: Inode) -> Kind? {
            guard seen.insert(path).inserted else { return nil }
            if inodes.insert(inode).inserted { return .copy }
            return options.includeLinks ? .hardLink : nil
        }

        /// Listed if it holds the bytes asked for; whether it did.
        @discardableResult
        mutating func take(_ candidate: Candidate) -> Bool {
            switch mode {
            case .copies(_, let bytes, let size, let originalInode):
                guard candidate.size == size else { return false }
                // The original's own inode under another name -- a hard link,
                // or a link to it -- is the same bytes without reading them.
                if candidate.inode != originalInode, !matching.contains(candidate.inode) {
                    guard sameBytes(bytes, candidate.bytes) else { return false }
                    matching.insert(candidate.inode)
                }
                emit(0, candidate)
                return true

            case .groups:
                group(candidate)
                return true
            }
        }

        /// Read side by side, a chunk at a time, so a stop is heeded inside a
        /// large file too. The sizes are known to be the same.
        func sameBytes(_ a: URL, _ b: URL) -> Bool {
            guard let left = FileHandle(forReadingAtPath: a.path),
                  let right = FileHandle(forReadingAtPath: b.path) else { return false }
            defer {
                try? left.close()
                try? right.close()
            }
            while !isOver {
                do {
                    let x = try left.read(upToCount: 1 << 20) ?? Data()
                    let y = try right.read(upToCount: 1 << 20) ?? Data()
                    if x != y { return false }
                    if x.isEmpty { return true }
                } catch {
                    return false
                }
            }
            return false
        }

        /// A folder's file, put with the others of its content -- read only
        /// once another file of its size has turned up.
        mutating func group(_ candidate: Candidate) {
            if let first = firstOfSize.removeValue(forKey: candidate.size) {
                file(first)
            } else if !sizesRead.contains(candidate.size) {
                firstOfSize[candidate.size] = candidate
                sizesRead.insert(candidate.size)
                return
            }
            file(candidate)
        }

        mutating func file(_ candidate: Candidate) {
            guard let digest = digest(candidate) else { return }
            let key = "\(candidate.size):\(digest)"
            var entry = byContent[key] ?? ([], nil)
            entry.members.append(candidate)
            if let group = entry.group {
                emit(group, candidate)
            } else if entry.members.count == 2 {
                let group = groups
                groups += 1
                entry.group = group
                references[group] = entry.members[0].url
                emit(group, entry.members[0])
                emit(group, candidate)
            }
            byContent[key] = entry
        }

        mutating func digest(_ candidate: Candidate) -> String? {
            if let known = digests[candidate.inode] { return known }
            guard let handle = FileHandle(forReadingAtPath: candidate.bytes.path) else { return nil }
            defer { try? handle.close() }
            var hash = SHA256()
            while !isOver, let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hash.update(data: chunk)
            }
            guard !isOver else { return nil }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            digests[candidate.inode] = digest
            return digest
        }

        func emit(_ group: Int, _ candidate: Candidate) {
            var differences: DirectoryComparison.Difference = []
            if let reference = references[group], reference != candidate.url {
                differences = PropertyComparison.of(reference, candidate.url).differences
                if reference.lastPathComponent != candidate.url.lastPathComponent {
                    differences.insert(.name)
                }
            }
            let item = DirectoryLoader.item(at: candidate.url,
                                            keys: DirectoryLoader.keys(for: []))
            var found = Found(url: candidate.url, kind: candidate.kind, size: candidate.size,
                              differences: differences, item: item)
            if candidate.kind == .symbolicLink {
                found.linksTo = candidate.bytes
                if let named = try? FileManager.default
                    .destinationOfSymbolicLink(atPath: candidate.url.path) {
                    found.pointsAt = URL(fileURLWithPath: named,
                                         relativeTo: candidate.url.deletingLastPathComponent())
                        .standardizedFileURL
                }
            }
            report(.found(group: group, found))
        }

        private static func name(of entry: UnsafeMutablePointer<dirent>) -> String {
            let length = Int(entry.pointee.d_namlen)
            return withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: UInt8.self, capacity: length) {
                    String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
                }
            }
        }
    }
}

/// One search, for its window: the options, what has been found, and where
/// it has got to.
@MainActor
@Observable
final class DuplicateSearch {

    struct File: Identifiable {
        var id: URL { found.url }
        var found: DuplicateFinder.Found
    }

    struct Group: Identifiable {
        let id: Int
        var files: [File]
        var size: Int64 { files.first?.found.size ?? 0 }
    }

    let url: URL
    let isFolder: Bool
    var options = DuplicateFinder.Options()
    private(set) var groups: [Group] = []
    /// Selected for the Trash.
    var chosen: Set<URL> = []
    private(set) var isSearching = false
    private(set) var hasSearched = false
    private(set) var wasStopped = false
    private(set) var folder = ""
    /// How wide the search has gone; kept when it is stopped.
    private(set) var stage: DuplicateFinder.Stage?
    /// For a file: the volumes besides its own that can be searched too.
    private(set) var volumes: [DuplicateFinder.Root] = []
    private(set) var foldersRead = 0
    private(set) var filesRead = 0
    private(set) var unreadable: [String] = []
    private(set) var startedAt = Date()
    private(set) var endedAt: Date?
    /// What the last move to the Trash could not move, and why.
    private(set) var failures: [String] = []

    @ObservationIgnored private var cancelled = CancellationFlag()
    /// Searches started since, so events from a stopped one that are still
    /// on their way are not taken for the new one's.
    @ObservationIgnored private var generation = 0

    init(url: URL) {
        self.url = url
        var info = stat()
        isFolder = lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        guard !isFolder else { return }
        // Off the main thread: a server's volume can take its time to answer.
        let device = info.st_dev
        Task.detached { [weak self] in
            let found = DuplicateFinder.otherVolumes(than: device)
            await MainActor.run { self?.volumes = found }
        }
    }

    /// The files found besides the original, or in groups.
    var duplicateCount: Int {
        isFolder ? groups.reduce(0) { $0 + $1.files.count }
            : max((groups.first?.files.count ?? 1) - 1, 0)
    }

    /// Something selected, and no group with every one of its files
    /// selected: this is for keeping one of each, never for losing all.
    var canTrash: Bool {
        !chosen.isEmpty && unkept.isEmpty
    }

    /// Symbolic links in the list, not selected, that lead to a selected
    /// file -- or through a selected link: in the Trash, it leaves them
    /// leading nowhere. Allowed, and said.
    var orphans: [(link: URL, target: URL)] {
        let files = groups.flatMap(\.files)
        let chosenPaths = Dictionary(chosen.map { ($0.standardizedFileURL.path, $0) },
                                     uniquingKeysWith: { a, _ in a })
        return files.compactMap { file in
            guard file.found.kind == .symbolicLink, !chosen.contains(file.id) else { return nil }
            for step in [file.found.pointsAt, file.found.linksTo].compactMap({ $0 }) {
                if let target = chosenPaths[step.standardizedFileURL.path] {
                    return (file.id, target)
                }
            }
            return nil
        }
    }

    /// The groups that would be gone: every file selected but symbolic links
    /// -- a link left behind keeps nothing once its file is in the Trash.
    var unkept: [Group] {
        groups.filter { group in
            group.files.allSatisfy { $0.found.kind == .symbolicLink || chosen.contains($0.id) }
        }
    }

    func start() {
        stop()
        cancelled = CancellationFlag()
        generation += 1
        let generation = generation
        groups = []
        chosen = []
        unreadable = []
        failures = []
        foldersRead = 0
        filesRead = 0
        stage = nil
        wasStopped = false
        hasSearched = true
        isSearching = true
        startedAt = Date()
        endedAt = nil

        let url = url, options = options, cancelled = cancelled
        Thread.detachNewThread { [weak self] in
            DuplicateFinder.search(for: url, options: options, cancelled: cancelled) { event in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.receive(event, generation) }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(generation) }
            }
        }
    }

    func stop() {
        guard isSearching else { return }
        wasStopped = true
        cancelled.cancel()
    }

    /// The window has closed.
    func abandon() { stop() }

    func toggleAll(in group: Group) {
        let ids = Set(group.files.map(\.id))
        if ids.isSubset(of: chosen) {
            chosen.subtract(ids)
        } else {
            chosen.formUnion(ids)
        }
    }

    /// The selected files to the Trash, undoable from the browser window's
    /// Undo as any other move there is.
    func trashChosen() async {
        guard canTrash else { return }
        let urls = groups.flatMap(\.files).map(\.id).filter { chosen.contains($0) }
        let (outcome, moved) = await FileOperations.shared.trashRecording(urls)
        FileHistory.shared.recordTrash(moved)
        TrashOriginals.shared.record(moved)
        if !outcome.succeeded.isEmpty {
            Sounds.playIfEnabled(ConfigStore.shared.configuration.trashSound)
        }
        let gone = Set(outcome.succeeded)
        chosen.subtract(gone)
        failures = outcome.failures.map { "\($0.url.lastPathComponent): \($0.message)" }
        groups = groups.compactMap { group in
            var group = group
            group.files.removeAll { gone.contains($0.id) }
            // A folder's group of one is no longer a group of copies.
            return isFolder && group.files.count < 2 ? nil : group
        }
    }

    private func receive(_ event: DuplicateFinder.Event, _ from: Int) {
        guard from == generation else { return }
        switch event {
        case .found(let group, let found):
            if let at = groups.firstIndex(where: { $0.id == group }) {
                groups[at].files.append(File(found: found))
            } else {
                groups.append(Group(id: group, files: [File(found: found)]))
            }
        case .progress(let folder, let folders, let files):
            self.folder = folder
            foldersRead = folders
            filesRead = files
        case .unreadable(let path):
            unreadable.append(path)
        case .stage(let stage):
            self.stage = stage
        }
    }

    private func finish(_ from: Int) {
        guard from == generation else { return }
        isSearching = false
        endedAt = Date()
        folder = ""
        // Where it got to stays worth knowing only for a search stopped.
        if !wasStopped { stage = nil }
    }
}

/// Which browser window a duplicates window was opened from: a click on a
/// file shows it there.
@MainActor
final class DuplicateOrigins {

    static let shared = DuplicateOrigins()
    private init() {}

    private final class WeakBox {
        weak var model: AppModel?
        init(_ model: AppModel) { self.model = model }
    }

    private var origins: [URL: WeakBox] = [:]

    func register(_ url: URL, from model: AppModel) { origins[url] = WeakBox(model) }

    func origin(for url: URL) -> AppModel? { origins[url]?.model }
}
