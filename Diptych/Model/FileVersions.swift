import Foundation

/// A single file's earlier versions, read straight out of APFS snapshots.
///
/// macOS keeps hourly *local* snapshots of the startup volume -- Time Machine
/// makes them whether or not a backup disk is attached -- and, when the backup
/// disk is there, a longer history on it. Each is a frozen, read-only image of
/// the whole volume, so a file's past self is simply the same path inside the
/// snapshot. The system mounts these under `/Volumes/.timemachine/…`; a process
/// with Full Disk Access can read them with no further ceremony, which is why
/// this never asks for a password or mounts anything itself: a version the
/// system has not exposed is shown as present-but-unavailable rather than
/// forced open.
///
/// Comparing a version is the ordinary file comparison against the copy in the
/// snapshot. Restoring one does not roll the volume back -- that would undo
/// everything else too -- it copies the old bytes over the one file, in place,
/// keeping its name, permissions and attributes, and is a normal Undo step.
enum FileVersions {

    struct Request: Codable, Hashable, Sendable {
        var file: URL
    }

    /// How many of the most recent snapshots to look inside, newest first.
    /// The system keeps these already mounted, so reading one is only a stat
    /// and a listing or two -- cheap enough to cover a month or more of hourly
    /// local snapshots and Time Machine backups. The bound is only there so a
    /// machine with years of backups cannot make opening the window crawl.
    static let rootsToProbe = 512

    enum Source: String, Sendable, Equatable {
        case localSnapshot
        case timeMachine

        var label: String {
            switch self {
            case .localSnapshot: return "Local snapshot"
            case .timeMachine:   return "Time Machine"
            }
        }
    }

    /// One earlier version of a file, at one instant.
    struct Version: Identifiable, Sendable, Equatable {
        let id = UUID()
        let date: Date
        let source: Source
        /// The readable path to the file as it was, when the snapshot is
        /// mounted and reachable right now; `nil` when the version is known to
        /// exist but the system has not exposed it (no prompt is raised to
        /// mount it).
        let url: URL?
        let size: Int64?
        /// The file's own modification date in that snapshot. With the size, it
        /// tells one version's contents from another's without reading them, so
        /// a run of snapshots in which the file never changed shows as the one
        /// moment it last did.
        let modified: Date?
        /// Set when `url` is `nil`: why the version cannot be opened now.
        let unavailableReason: String?

        var isAvailable: Bool { url != nil }

        /// What makes two versions the same file -- same bytes, as far as can
        /// be told without opening them.
        var signature: String { "\(size ?? -1)/\(modified?.timeIntervalSince1970.rounded() ?? -1)" }
    }

    struct Listing: Sendable {
        var versions: [Version]
        /// A line to show above an empty or thin list -- that Full Disk Access
        /// is wanted, that Time Machine is off, or that local snapshots exist
        /// but are not currently reachable.
        var note: String?
    }

    // MARK: - Enumeration

    /// Every earlier version of `file` the system is exposing now, newest
    /// first. Reads only; safe to run off the main actor.
    nonisolated static func list(for file: URL) -> Listing {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else {
            return Listing(versions: [], note: nil)
        }

        let relatives = volumeRelatives(of: file)
        let localDates = localSnapshotDates(forVolumeOf: file)

        var byMinute: [Int: Version] = [:]   // keyed by the minute, newest kept
        var sawPermissionTrouble = false

        // Newest first, one per minute: the same moment can be a folder under
        // more than one base. Reading inside a timestamp folder makes the
        // system mount that backup, so only the most recent are probed -- enough
        // for the hourly local snapshots and the recent backups, without
        // mounting a year of them to open one window.
        var roots: [(date: Date, url: URL)] = []
        var seenMinutes: Set<Int> = []
        for root in timestampRoots(sawTrouble: &sawPermissionTrouble) {
            guard let date = date(fromStamp: root.lastPathComponent) else { continue }
            let key = minuteKey(date)
            if seenMinutes.insert(key).inserted { roots.append((date, root)) }
        }
        let rootsSeen = roots.count
        roots.sort { $0.date > $1.date }

        for (date, root) in roots.prefix(Self.rootsToProbe) {
            let key = minuteKey(date)
            guard let found = fileURL(in: root, relatives: relatives) else { continue }
            let values = try? found.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize.flatMap { Int64($0) }
            let source: Source = localDates.contains(key) ? .localSnapshot : .timeMachine
            let version = Version(date: date, source: source, url: found,
                                  size: size, modified: values?.contentModificationDate,
                                  unavailableReason: nil)
            // One moment can appear in more than one place (a local snapshot
            // that was also written to the backup disk). Keep the readable one.
            if byMinute[key]?.isAvailable != true { byMinute[key] = version }
        }

        // Newest first, then the runs where the file never changed collapsed to
        // the one moment it last did: a file saved once a week should not list
        // the same bytes under a hundred hourly snapshots.
        var versions: [Version] = []
        for version in byMinute.values.sorted(by: { $0.date > $1.date }) {
            if versions.last?.signature != version.signature { versions.append(version) }
        }

        var note: String?
        if versions.isEmpty {
            if sawPermissionTrouble {
                note = "Diptych could not read the snapshots. Grant it Full Disk Access in "
                     + "System Settings \u{203A} Privacy & Security to see earlier versions."
            } else if !localDates.isEmpty {
                note = "This Mac has local snapshots, but the system is not exposing them to "
                     + "read right now. They appear here once it mounts them -- entering Time "
                     + "Machine once, or attaching the backup disk, usually does it."
            } else if rootsSeen == 0 {
                note = "No snapshots were found. Earlier versions need Time Machine turned on "
                     + "(it keeps hourly local snapshots) or its backup disk attached."
            } else {
                note = "No earlier version of this file was found in the snapshots on this Mac."
            }
        }
        return Listing(versions: versions, note: note)
    }

    /// Copies a version's bytes over `file`, in place, and returns a copy of
    /// what the file held before for Undo to put back. The file keeps its
    /// identity: its name, its other hard links, its permissions and its
    /// extended attributes are untouched -- only the contents change.
    nonisolated static func restore(_ version: URL, over file: URL) throws -> URL {
        let before = try UndoSnapshots.keep(file)
        do {
            try UndoSnapshots.putBack(version, into: file)
        } catch {
            try? FileManager.default.removeItem(at: before)
            throw error
        }
        return before
    }

    // MARK: - Where the snapshots are

    /// Where macOS exposes mounted snapshots: the unified Time Machine
    /// namespace and the local-snapshots volume. A test points this at a tree
    /// of its own; nothing else changes it.
    nonisolated(unsafe) static var scanBases = ["/Volumes/.timemachine",
                                                "/Volumes/com.apple.TimeMachine.localsnapshots"]

    /// Timestamp folders under the places macOS exposes snapshots, scanned a
    /// few levels deep so the exact layout -- which has changed between macOS
    /// releases -- does not have to be hard-coded.
    private nonisolated static func timestampRoots(sawTrouble: inout Bool) -> [URL] {
        var roots: [URL] = []
        for base in scanBases {
            collectTimestampDirs(URL(fileURLWithPath: base), depth: 0, maxDepth: 3,
                                 into: &roots, sawTrouble: &sawTrouble)
        }
        return roots
    }

    private nonisolated static func collectTimestampDirs(
        _ dir: URL, depth: Int, maxDepth: Int,
        into roots: inout [URL], sawTrouble: inout Bool) {
        guard depth <= maxDepth, roots.count < 2000 else { return }
        let fm = FileManager.default
        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles])
        } catch {
            // A denial here, at a directory that exists, is the signature of
            // missing Full Disk Access -- worth telling the user about.
            if (error as NSError).code == NSFileReadNoPermissionError
                && fm.fileExists(atPath: dir.path) {
                sawTrouble = true
            }
            return
        }
        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { continue }
            if date(fromStamp: child.lastPathComponent) != nil {
                roots.append(child)
            } else {
                collectTimestampDirs(child, depth: depth + 1, maxDepth: maxDepth,
                                     into: &roots, sawTrouble: &sawTrouble)
            }
        }
    }

    /// The file inside one snapshot folder. The volume holding it sits at
    /// different depths depending on the kind of snapshot -- a local snapshot
    /// puts it under `Data`, a Time-Machine backup under a volume-named folder
    /// -- so rather than hard-code either, the file's tail is tried directly
    /// and then under each folder a couple of levels down, stopping at the
    /// first that is really there.
    private nonisolated static func fileURL(in root: URL, relatives: [String]) -> URL? {
        let fm = FileManager.default
        func search(_ base: URL, depth: Int) -> URL? {
            for rel in relatives {
                let candidate = base.appendingPathComponent(rel)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
            guard depth > 0,
                  let subs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles])
            else { return nil }
            for sub in subs where (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if let hit = search(sub, depth: depth - 1) { return hit }
            }
            return nil
        }
        return search(root, depth: 2)
    }

    /// The tails of the file's path that repeat inside a snapshot of its
    /// volume -- its path minus the mount point. More than one is tried
    /// because the startup data volume is reached through firmlinks (`/Users`
    /// is really `/System/Volumes/Data/Users`) and a snapshot may spell it
    /// either way.
    private nonisolated static func volumeRelatives(of file: URL) -> [String] {
        let full = file.standardizedFileURL.path
        var tails: [String] = []
        func add(_ s: String) {
            let trimmed = s.drop(while: { $0 == "/" })
            if !trimmed.isEmpty, !tails.contains(String(trimmed)) { tails.append(String(trimmed)) }
        }
        add(full)
        let dataPrefix = "/System/Volumes/Data/"
        if full.hasPrefix(dataPrefix) { add(String(full.dropFirst(dataPrefix.count))) }
        if let mount = (try? file.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path,
           mount != "/", full.hasPrefix(mount + "/") {
            add(String(full.dropFirst(mount.count)))
        }
        return tails
    }

    // MARK: - Local snapshot dates

    /// The minutes at which this volume has local snapshots, from `tmutil`.
    /// `listlocalsnapshots` needs neither root nor Full Disk Access, so it is a
    /// reliable way to tell a local snapshot from a backup-disk one.
    private nonisolated static func localSnapshotDates(forVolumeOf file: URL) -> Set<Int> {
        let mount = (try? file.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path ?? "/"
        guard let output = runTmutil(["listlocalsnapshots", mount]) else { return [] }
        var minutes: Set<Int> = []
        for line in output.split(whereSeparator: \.isNewline) {
            if let stamp = timestamp(in: String(line)), let date = stampFormatter.date(from: stamp) {
                minutes.insert(minuteKey(date))
            }
        }
        return minutes
    }

    private nonisolated static func runTmutil(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Dates

    private nonisolated static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.timeZone = .current
        return f
    }()

    /// A date from a snapshot folder or snapshot name -- `2026-10-19-063000`,
    /// however it is wrapped (`…-063000.backup`, `com.apple.TimeMachine.…`).
    nonisolated static func date(fromStamp name: String) -> Date? {
        guard let stamp = timestamp(in: name) else { return nil }
        return stampFormatter.date(from: stamp)
    }

    /// The first `yyyy-MM-dd-HHmmss` run in a string, found without a regular
    /// expression: four digits, dash, two, dash, two, dash, six.
    private nonisolated static func timestamp(in text: String) -> String? {
        let shape: [Int] = [4, 2, 2, 6]      // digit-runs, dash-separated
        let characters = Array(text)
        var start = 0
        while start < characters.count {
            var at = start
            var piece = 0
            var ok = true
            while piece < shape.count {
                if piece > 0 {
                    guard at < characters.count, characters[at] == "-" else { ok = false; break }
                    at += 1
                }
                var run = 0
                while run < shape[piece] {
                    guard at < characters.count, characters[at].isNumber else { ok = false; break }
                    at += 1; run += 1
                }
                if !ok { break }
                piece += 1
            }
            // A match must not run straight into more digits (a longer number).
            if ok, piece == shape.count, !(at < characters.count && characters[at].isNumber) {
                return String(characters[start..<at])
            }
            start += 1
        }
        return nil
    }

    /// Whole minutes since 1970 -- snapshots are at most one a minute, and the
    /// same moment can be named a second apart in two places.
    private nonisolated static func minuteKey(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 60)
    }
}
