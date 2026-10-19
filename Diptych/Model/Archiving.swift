import Foundation
import CryptoKit
import Darwin

/// Making archives and unpacking them, with the tools macOS comes with.
///
/// `ditto` for zip, because it is what Finder's Compress runs and the only
/// tool that writes Finder's `__MACOSX` folder. `/usr/bin/tar`, which is
/// libarchive, for tar compressed or not. `aa` for Apple Archive. Each is
/// called with an absolute path, never through `$PATH`.
enum Archiving {

    static let ditto = "/usr/bin/ditto"
    static let tar = "/usr/bin/tar"
    static let aa = "/usr/bin/aa"

    struct Failure: Error, Equatable, Sendable {
        let message: String
    }

    // MARK: - Formats

    enum Format: String, Codable, CaseIterable, Identifiable, Sendable {
        case zip
        case tar
        case appleArchive

        var id: String { rawValue }

        var title: String {
            switch self {
            case .zip:          "ZIP"
            case .tar:          "tar"
            case .appleArchive: "Apple Archive"
            }
        }
    }

    enum ZipCompression: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, fastest, normal, best

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none:    "None"
            case .fastest: "Fastest"
            case .normal:  "Normal"
            case .best:    "Smallest"
            }
        }

        /// zlib's level; nil leaves ditto's own.
        var level: Int? {
            switch self {
            case .none:    0
            case .fastest: 1
            case .normal:  nil
            case .best:    9
            }
        }
    }

    enum TarCompression: String, Codable, CaseIterable, Identifiable, Sendable {
        case gzip, bzip2, xz, none

        var id: String { rawValue }

        var title: String {
            switch self {
            case .gzip:  "gzip (.tar.gz)"
            case .bzip2: "bzip2 (.tar.bz2)"
            case .xz:    "xz (.tar.xz)"
            case .none:  "None (.tar)"
            }
        }

        var fileExtension: String {
            switch self {
            case .gzip:  "tar.gz"
            case .bzip2: "tar.bz2"
            case .xz:    "tar.xz"
            case .none:  "tar"
            }
        }

        var flag: String? {
            switch self {
            case .gzip:  "-z"
            case .bzip2: "-j"
            case .xz:    "-J"
            case .none:  nil
            }
        }
    }

    /// Who a tar archive says owns what.
    enum TarOwners: String, Codable, CaseIterable, Identifiable, Sendable {
        /// The numbers and the names, as the files have them.
        case asTheyAre
        /// The numbers only. A name means another user on another Mac; the
        /// number is what the files had.
        case numbersOnly
        /// root and wheel, as software is packed: unpacked by anyone else,
        /// the files are theirs.
        case root

        var id: String { rawValue }

        var title: String {
            switch self {
            case .asTheyAre:   "Names and numbers"
            case .numbersOnly: "Numbers only"
            case .root:        "root and wheel, whoever owns them"
            }
        }
    }

    enum AppleArchiveCompression: String, Codable, CaseIterable, Identifiable, Sendable {
        case lzfse, lzma, zlib, lz4, raw

        var id: String { rawValue }

        var title: String {
            switch self {
            case .lzfse: "LZFSE (Apple\u{2019}s, fast and small)"
            case .lzma:  "LZMA (smallest, slowest)"
            case .zlib:  "zlib"
            case .lz4:   "LZ4 (fastest)"
            case .raw:   "None"
            }
        }
    }

    /// What Create Archive is asked for. The window offers what was chosen
    /// last.
    struct Options: Codable, Equatable, Sendable {
        var format = Format.zip

        /// Resource forks, extended attributes and ACLs in a `__MACOSX`
        /// folder, as Finder writes them. Off: the bytes and the permissions
        /// only, which is what anything but a Mac would want.
        var zipMacMetadata = true
        var zipCompression = ZipCompression.normal

        var tarCompression = TarCompression.gzip
        /// Extended attributes, ACLs and file flags.
        var tarMacMetadata = true
        var tarOwners = TarOwners.asTheyAre

        var aarCompression = AppleArchiveCompression.lzfse
        var aarOwners = true
        var aarExtendedAttributes = true
        var aarAccessControl = true

        init() {}

        /// Every key optional: a later version may add one.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Options()
            func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
                (try? container.decode(T.self, forKey: key)) ?? fallback
            }
            format = value(.format, defaults.format)
            zipMacMetadata = value(.zipMacMetadata, defaults.zipMacMetadata)
            zipCompression = value(.zipCompression, defaults.zipCompression)
            tarCompression = value(.tarCompression, defaults.tarCompression)
            tarMacMetadata = value(.tarMacMetadata, defaults.tarMacMetadata)
            tarOwners = value(.tarOwners, defaults.tarOwners)
            aarCompression = value(.aarCompression, defaults.aarCompression)
            aarOwners = value(.aarOwners, defaults.aarOwners)
            aarExtendedAttributes = value(.aarExtendedAttributes, defaults.aarExtendedAttributes)
            aarAccessControl = value(.aarAccessControl, defaults.aarAccessControl)
        }

        var fileExtension: String {
            switch format {
            case .zip:          "zip"
            case .tar:          tarCompression.fileExtension
            case .appleArchive: "aar"
            }
        }
    }

    // MARK: - Names

    /// What Finder calls it: the item's name for one, "Archive" for several.
    static func defaultStem(for items: [URL]) -> String {
        items.count == 1 ? items[0].lastPathComponent : "Archive"
    }

    /// `stem.ext`, then `stem 2.ext`: Finder's numbering, with an extension
    /// of two parts kept whole.
    static func numbered(_ stem: String, extension suffix: String, in folder: URL) -> URL {
        for number in 1...9999 {
            let name = (number == 1 ? stem : "\(stem) \(number)")
                + (suffix.isEmpty ? "" : ".\(suffix)")
            let url = folder.appendingPathComponent(name)
            if !exists(url) { return url }
        }
        return folder.appendingPathComponent("\(stem) \(UUID().uuidString).\(suffix)")
    }

    /// The name less every archive extension: `logs.tar.gz` is `logs`.
    static func stem(of archive: URL) -> String {
        var name = archive.lastPathComponent
        let lower = name.lowercased()
        for suffix in multipartExtensions where lower.hasSuffix("." + suffix) {
            name.removeLast(suffix.count + 1)
            return name
        }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    private static let multipartExtensions = ["tar.gz", "tar.bz2", "tar.xz", "tar.z"]

    // MARK: - Creating

    /// Makes `target` from `items`. Written under a hidden name beside it and
    /// renamed when complete, so nothing half-made ever shows under the real
    /// name, and stopping leaves nothing behind.
    nonisolated static func create(_ items: [URL], at target: URL, options: Options,
                                   job: Job = Job()) throws(Failure) {
        guard !items.isEmpty else { throw Failure(message: "Nothing is selected.") }
        let names = items.map(\.lastPathComponent)
        if let twice = Dictionary(grouping: names, by: { $0 }).first(where: { $0.value.count > 1 }) {
            throw Failure(message: "Two of the items are called \u{201C}\(twice.key)\u{201D}, "
                          + "and an archive can hold only one of them at its top.")
        }
        let folder = target.deletingLastPathComponent()
        let partial = folder.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).partial")
        var staging: URL?
        defer {
            try? FileManager().removeItem(at: partial)
            if let staging { try? FileManager().removeItem(at: staging) }
        }

        job.set(.counting)
        let sizes = measure(items, job: job)
        guard !job.isCancelled else { throw Failure(message: "Stopped.") }
        job.set(.preparing)

        let parents = Set(items.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        let invocation: Invocation
        switch options.format {
        case .zip:
            // ditto packs one folder, or one item with --keepParent; several
            // are put together in a folder of clones first.
            if items.count == 1 {
                invocation = zipInvocation(source: items[0], keepParent: true,
                                           output: partial, options: options)
            } else {
                let stage = try stage(items)
                staging = stage
                invocation = zipInvocation(source: stage, keepParent: false,
                                           output: partial, options: options)
            }
        case .tar:
            invocation = tarInvocation(items, output: partial, options: options)
        case .appleArchive:
            if parents.count == 1 {
                invocation = appleArchiveInvocation(folder: items[0].deletingLastPathComponent(),
                                                    names: names, output: partial,
                                                    options: options)
            } else {
                let stage = try stage(items)
                staging = stage
                invocation = appleArchiveInvocation(folder: stage, names: names,
                                                    output: partial, options: options)
            }
        }
        job.prepare(sizes: options.format == .tar ? sizes : [:],
                    roots: (items + (staging.map { [$0] } ?? [])).map(resolvedPath),
                    countsFiles: options.format != .appleArchive)
        job.set(.archiving)
        switch options.format {
        case .zip:          try run(invocation, job: job, reporter: .ditto)
        case .tar:          try run(invocation, job: job, reporter: .tar)
        case .appleArchive:
            // Uncompressed out of one aa, compressed by another: what passes
            // between them is the progress.
            var archive = invocation.arguments
            if let output = archive.firstIndex(of: "-o") { archive.removeSubrange(output...(output + 1)) }
            if let algorithm = archive.firstIndex(of: "-a") { archive[algorithm + 1] = "raw" }
            try runPipeline(Invocation(executable: aa, arguments: archive),
                            into: Invocation(executable: aa, arguments: [
                                "convert", "-a", options.aarCompression.rawValue, "-b", "4m",
                                "-o", partial.path]),
                            job: job)
        }
        guard !job.isCancelled else { throw Failure(message: "Stopped.") }
        job.set(.finishing)
        guard rename(partial, to: target) else {
            throw Failure(message: "\u{201C}\(target.lastPathComponent)\u{201D} could not be "
                          + "put in place: \(String(cString: strerror(errno)))")
        }
    }

    static func zipInvocation(source: URL, keepParent: Bool, output: URL,
                              options: Options) -> Invocation {
        // -V: a line per file, which is the progress.
        var arguments = ["-c", "-k", "-V"]
        arguments += options.zipMacMetadata
            ? ["--sequesterRsrc"]
            : ["--norsrc", "--noextattr", "--noacl", "--noqtn"]
        if let level = options.zipCompression.level {
            arguments += ["--zlibCompressionLevel", String(level)]
        }
        if keepParent { arguments.append("--keepParent") }
        arguments += [source.path, output.path]
        return Invocation(executable: ditto, arguments: arguments)
    }

    static func tarInvocation(_ items: [URL], output: URL, options: Options) -> Invocation {
        // -v: a line per item added, which is the progress.
        var arguments = ["-c", "-v"]
        if let flag = options.tarCompression.flag { arguments.append(flag) }
        arguments += ["-f", output.path]
        var environment: [String: String] = [:]
        if !options.tarMacMetadata {
            arguments += ["--no-mac-metadata", "--no-xattrs", "--no-acls", "--no-fflags"]
            // Or tar adds `._` files of its own for what it was told to leave.
            environment["COPYFILE_DISABLE"] = "1"
        }
        switch options.tarOwners {
        case .asTheyAre:   break
        case .numbersOnly: arguments.append("--numeric-owner")
        case .root:        arguments += ["--uid", "0", "--gid", "0", "--uname", "root",
                                         "--gname", "wheel"]
        }
        // -C before each, so items from different folders -- a flat view --
        // go in side by side. "./" keeps a name starting with a dash a name.
        for item in items {
            let name = item.lastPathComponent
            arguments += ["-C", item.deletingLastPathComponent().path,
                          name.hasPrefix("-") ? "./" + name : name]
        }
        return Invocation(executable: tar, arguments: arguments, environment: environment)
    }

    static func appleArchiveInvocation(folder: URL, names: [String], output: URL,
                                       options: Options) -> Invocation {
        var arguments = ["archive", "-d", folder.path]
        // A regular expression per item, not -include-path: given several,
        // aa leaves out every one that is a file.
        for name in names { arguments += ["-include-regex", "^\(regexQuoted(name))(/|$)"] }
        arguments += ["-o", output.path, "-a", options.aarCompression.rawValue]
        var left: [String] = []
        if !options.aarOwners { left += ["uid", "gid"] }
        if !options.aarExtendedAttributes { left.append("xat") }
        if !options.aarAccessControl { left.append("acl") }
        if !left.isEmpty { arguments += ["-exclude-field", left.joined(separator: ",")] }
        return Invocation(executable: aa, arguments: arguments)
    }

    /// A name matched as itself in a regex(3) expression.
    static func regexQuoted(_ name: String) -> String {
        var quoted = ""
        for character in name {
            if "\\^$.|?*+()[]{}".contains(character) { quoted.append("\\") }
            quoted.append(character)
        }
        return quoted
    }

    /// Items from several places side by side in one folder, as clones where
    /// the volume makes them, so a gigabyte costs nothing to put there.
    private static func stage(_ items: [URL]) throws(Failure) -> URL {
        let manager = FileManager()
        let stage: URL
        do {
            stage = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: items[0], create: true)
        } catch {
            stage = manager.temporaryDirectory
                .appendingPathComponent("Diptych-archive-\(UUID().uuidString)")
            do { try manager.createDirectory(at: stage, withIntermediateDirectories: true) }
            catch { throw Failure(message: error.localizedDescription) }
        }
        for item in items {
            do {
                try manager.copyItem(at: item, to: stage.appendingPathComponent(item.lastPathComponent))
            } catch {
                try? manager.removeItem(at: stage)
                throw Failure(message: "\u{201C}\(item.lastPathComponent)\u{201D} could not be "
                              + "read: \(error.localizedDescription)")
            }
        }
        return stage
    }

    // MARK: - Unpacking

    enum Kind: Sendable, Equatable {
        case zip, tar, appleArchive
    }

    /// What Extract understands, by name: the zip family, tar compressed or
    /// not, and Apple Archive.
    static func kind(of url: URL) -> Kind? {
        let name = url.lastPathComponent.lowercased()
        if multipartExtensions.contains(where: { name.hasSuffix("." + $0) }) { return .tar }
        switch url.pathExtension.lowercased() {
        case "zip", "jar", "war", "ipa": return .zip
        case "tar", "tgz", "tbz", "tbz2", "txz", "taz": return .tar
        case "aar": return .appleArchive
        default: return nil
        }
    }

    static func isExtractable(_ url: URL) -> Bool { kind(of: url) != nil }

    /// One entry as the archive records it.
    struct Entry: Equatable, Sendable {
        /// Relative, without "./" or a trailing slash.
        let path: String
        let uid: uid_t?
        let gid: gid_t?
        /// The permission bits, special ones included.
        let mode: mode_t?
        let isLink: Bool
    }

    /// Every entry, with its owner, group and mode. Read with tar's mtree
    /// writer for zip and tar -- libarchive reads the uid and gid ditto
    /// stores in a zip, and folds `__MACOSX` into the files it describes --
    /// and with aa's own JSON listing for Apple Archive.
    nonisolated static func entries(of archive: URL, kind: Kind,
                                    job: Job = Job()) throws(Failure) -> [Entry] {
        switch kind {
        case .zip, .tar:
            let output = try run(Invocation(executable: tar, arguments: [
                "--format=mtree", "--options=!all,type,uid,gid,mode", "-cf", "-",
                "@" + archive.path]), job: job)
            return parseMtree(output)
        case .appleArchive:
            let output = try run(Invocation(executable: aa, arguments: [
                "list", "-list-format", "json", "-i", archive.path]), job: job)
            return parseAppleArchiveList(output)
        }
    }

    static func parseMtree(_ text: String) -> [Entry] {
        text.split(separator: "\n").compactMap { line -> Entry? in
            guard !line.hasPrefix("#"), !line.hasPrefix("/") else { return nil }
            let fields = line.split(separator: " ")
            guard let first = fields.first else { return nil }
            var keys: [String: String] = [:]
            for field in fields.dropFirst() {
                let parts = field.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { keys[String(parts[0])] = String(parts[1]) }
            }
            let path = normalized(unescapeMtree(String(first)))
            guard !path.isEmpty else { return nil }
            return Entry(path: path,
                         uid: keys["uid"].flatMap { uid_t($0) },
                         gid: keys["gid"].flatMap { gid_t($0) },
                         mode: keys["mode"].flatMap { mode_t($0, radix: 8) },
                         isLink: keys["type"] == "link")
        }
    }

    /// mtree writes anything but plain characters as `\ooo`, in octal, one
    /// byte at a time.
    static func unescapeMtree(_ text: String) -> String {
        var bytes: [UInt8] = []
        let utf8 = Array(text.utf8)
        var index = 0
        while index < utf8.count {
            if utf8[index] == UInt8(ascii: "\\"), index + 3 < utf8.count,
               let value = UInt8(String(decoding: utf8[(index + 1)...(index + 3)], as: UTF8.self),
                                 radix: 8) {
                bytes.append(value)
                index += 4
            } else {
                bytes.append(utf8[index])
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func parseAppleArchiveList(_ text: String) -> [Entry] {
        guard let list = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]
        else { return [] }
        return list.compactMap { entry -> Entry? in
            guard let path = entry["PAT"] as? String else { return nil }
            let normal = normalized(path)
            guard !normal.isEmpty else { return nil }
            return Entry(path: normal,
                         uid: (entry["UID"] as? NSNumber).map { uid_t($0.uint32Value) },
                         gid: (entry["GID"] as? NSNumber).map { gid_t($0.uint32Value) },
                         mode: (entry["MOD"] as? NSNumber).map { mode_t($0.uint16Value) },
                         isLink: entry["TYP"] as? String == "L")
        }
    }

    static func normalized(_ path: String) -> String {
        var path = path
        while path.hasPrefix("./") { path.removeFirst(2) }
        if path == "." { return "" }
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Unpacked as the user, which is all an archive can do unasked: the
    /// files are theirs, in the groups they belong to.
    nonisolated static func unpack(_ archive: URL, kind: Kind, into folder: URL,
                                   job: Job = Job()) throws(Failure) {
        try run(unpackInvocation(archive, kind: kind, into: folder), job: job)
    }

    static func unpackInvocation(_ archive: URL, kind: Kind, into folder: URL) -> Invocation {
        switch kind {
        case .zip:
            Invocation(executable: ditto, arguments: ["-x", "-k", archive.path, folder.path])
        case .tar:
            // -p: the permissions as recorded, setuid on one's own files and
            // ACLs included; the owner stays the user's.
            Invocation(executable: tar, arguments: ["-x", "-p", "-f", archive.path,
                                                     "-C", folder.path])
        case .appleArchive:
            Invocation(executable: aa, arguments: ["extract", "-i", archive.path,
                                                   "-d", folder.path])
        }
    }

    /// Something the archive records that unpacking it did not give.
    struct Difference: Equatable, Sendable {
        let path: String
        let uid: uid_t?
        let gid: gid_t?
        /// The recorded mode, to set again: changing an owner takes setuid
        /// and setgid off. Nil for a link.
        let mode: mode_t?
        /// Setuid, setgid or sticky recorded and not given.
        let specialLost: Bool
    }

    /// Each entry that came out with another owner or group than recorded, or
    /// without its setuid, setgid or sticky bit.
    nonisolated static func differences(_ entries: [Entry], in folder: URL) -> [Difference] {
        entries.compactMap { entry -> Difference? in
            guard !entry.path.hasPrefix("__MACOSX/"), entry.path != "__MACOSX" else { return nil }
            var info = stat()
            guard lstat(folder.appendingPathComponent(entry.path).path, &info) == 0 else {
                return nil
            }
            let uid = entry.uid.flatMap { $0 != info.st_uid ? $0 : nil }
            let gid = entry.gid.flatMap { $0 != info.st_gid ? $0 : nil }
            let special: mode_t = 0o7000
            let lost = !entry.isLink && entry.mode.map {
                $0 & special != info.st_mode & special
            } == true
            guard uid != nil || gid != nil || lost else { return nil }
            return Difference(path: entry.path, uid: uid, gid: gid,
                              mode: entry.isLink ? nil : entry.mode.map { $0 & 0o7777 },
                              specialLost: lost)
        }
    }

    /// How many entries, where `placement` put them, still differ from the
    /// archive: what root could not give either.
    nonisolated static func remaining(_ entries: [Entry], _ placement: Placement) -> Int {
        var left = 0
        for entry in entries where !entry.path.hasPrefix("__MACOSX") {
            var parts = entry.path.split(separator: "/", maxSplits: 1).map(String.init)
            guard let top = parts.first,
                  let move = placement.moves.first(where: { $0.name == top }) else { continue }
            parts.removeFirst()
            let url = parts.isEmpty ? move.to : move.to.appendingPathComponent(parts[0])
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let special: mode_t = 0o7000
            if entry.uid.map({ $0 != info.st_uid }) == true
                || entry.gid.map({ $0 != info.st_gid }) == true
                || (!entry.isLink && entry.mode.map { $0 & special != info.st_mode & special } == true) {
                left += 1
            }
        }
        return left
    }

    /// The differences in words, a line per kind, for the question.
    static func summary(_ differences: [Difference]) -> [String] {
        var lines: [String] = []
        let owners = Dictionary(grouping: differences.compactMap(\.uid), by: { $0 })
        for (uid, items) in owners.sorted(by: { $0.key < $1.key }) {
            lines.append("\(count(items.count)) owned by \(AccountName.user(uid))")
        }
        let groups = Dictionary(grouping: differences.compactMap(\.gid), by: { $0 })
        for (gid, items) in groups.sorted(by: { $0.key < $1.key }) {
            lines.append("\(count(items.count)) in the group \(AccountName.group(gid))")
        }
        let special = differences.filter(\.specialLost)
        if !special.isEmpty {
            let names = special.prefix(3).map { "\u{201C}\(($0.path as NSString).lastPathComponent)\u{201D}" }
                .joined(separator: ", ")
            lines.append("\(count(special.count)) with setuid, setgid or sticky: \(names)"
                         + (special.count > 3 ? " and \(special.count - 3) more" : ""))
        }
        return lines
    }

    private static func count(_ number: Int) -> String {
        number == 1 ? "1 item" : "\(number) items"
    }

    /// The top of what was unpacked, `__MACOSX` aside.
    nonisolated static func topLevel(of folder: URL) -> [String] {
        ((try? FileManager().contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0 != "__MACOSX" }
            .sorted()
    }

    /// Where each top item goes: itself when there is one, numbered if the
    /// name is taken; inside a new folder named after the archive when there
    /// are several, as Archive Utility does it.
    struct Placement: Equatable, Sendable {
        /// Created by the user before anything is moved into it.
        let wrapper: URL?
        let moves: [(name: String, to: URL)]

        static func == (a: Placement, b: Placement) -> Bool {
            a.wrapper == b.wrapper && a.moves.map(\.name) == b.moves.map(\.name)
                && a.moves.map(\.to) == b.moves.map(\.to)
        }

        /// What appears in the destination.
        var results: [URL] { wrapper.map { [$0] } ?? moves.map(\.to) }
    }

    nonisolated static func placement(of top: [String], from archive: URL,
                                      into destination: URL) -> Placement {
        if top.count == 1 {
            let name = top[0]
            let stem = (name as NSString).deletingPathExtension
            let suffix = (name as NSString).pathExtension
            let free = numbered(stem.isEmpty ? name : stem,
                                extension: stem.isEmpty ? "" : suffix, in: destination)
            return Placement(wrapper: nil, moves: [(name, free)])
        }
        let wrapper = numbered(stem(of: archive), extension: "", in: destination)
        return Placement(wrapper: wrapper,
                         moves: top.map { ($0, wrapper.appendingPathComponent($0)) })
    }

    /// The unpacked items moved where they belong, as the user.
    nonisolated static func place(from folder: URL, _ placement: Placement) throws(Failure) {
        let manager = FileManager()
        if let wrapper = placement.wrapper {
            do { try manager.createDirectory(at: wrapper, withIntermediateDirectories: false) }
            catch { throw Failure(message: error.localizedDescription) }
        }
        for move in placement.moves {
            let from = folder.appendingPathComponent(move.name)
            if rename(from, to: move.to) { continue }
            // Another volume: the temporary folder could not be on it.
            do { try manager.moveItem(at: from, to: move.to) }
            catch { throw Failure(message: error.localizedDescription) }
        }
    }

    /// The archive's quarantine mark on everything that came out of it, as
    /// Archive Utility does: a program inside a downloaded archive is a
    /// downloaded program.
    nonisolated static func quarantine(of archive: URL) -> Data? {
        ExtendedAttributes.data(of: archive.path, name: "com.apple.quarantine")
    }

    nonisolated static func markQuarantined(_ folder: URL, with value: Data) {
        var paths = [folder.path]
        if let walker = FileManager().enumerator(atPath: folder.path) {
            while let relative = walker.nextObject() as? String {
                paths.append(folder.appendingPathComponent(relative).path)
            }
        }
        for path in paths.dropFirst()
        where getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) < 0 {
            _ = value.withUnsafeBytes {
                setxattr(path, "com.apple.quarantine", $0.baseAddress, value.count, 0,
                         XATTR_NOFOLLOW)
            }
        }
    }

    // MARK: - As an administrator

    /// The shell script that unpacks the archive again as root, with what
    /// it records, and moves it where `placement` says.
    ///
    /// Nothing root reads may be changed by the user in between: the archive
    /// is copied into a folder only root can enter and must still have the
    /// SHA-256 it had when its contents were shown, and every owner, group
    /// and mode is written into the script itself rather than read from a
    /// file. Each command is joined with "; " -- the script becomes one
    /// AppleScript string, where a newline does not parse.
    static func restoreScript(archive: URL, sha256: String, kind: Kind,
                              differences: [Difference], placement: Placement,
                              destination: URL, quarantine: Data?) -> String {
        let q = Shell.quoted
        var lines = [
            "set -e",
            "R=$(/usr/bin/mktemp -d \(q(destination.path + "/.diptych-extract.XXXXXX")))",
            "trap '/bin/rm -rf \"$R\"' EXIT",
            "/bin/chmod 700 \"$R\"",
            "/bin/cp \(q(archive.path)) \"$R/archive\"",
            "[ \"$(/usr/bin/shasum -a 256 \"$R/archive\" | /usr/bin/cut -d ' ' -f 1)\" = "
                + "\(q(sha256)) ] || { echo 'The archive changed after it was read.' >&2; exit 3; }",
            "/bin/mkdir \"$R/x\"",
        ]
        let unpack = unpackInvocation(URL(fileURLWithPath: "/R/archive"), kind: kind,
                                      into: URL(fileURLWithPath: "/R/x"))
        lines.append(([unpack.executable] + unpack.arguments.map { argument in
            argument.hasPrefix("/R/") ? "\"$R\"" + q(String(argument.dropFirst(2))) : q(argument)
        }).joined(separator: " "))
        lines.append("cd \"$R/x\"")
        // The owner first: changing it takes setuid and setgid off.
        for difference in differences where difference.uid != nil || difference.gid != nil {
            let owner = (difference.uid.map { String($0) } ?? "")
                + (difference.gid.map { ":\($0)" } ?? "")
            lines.append("/usr/sbin/chown -h \(owner) -- \(q("./" + difference.path))")
        }
        for difference in differences {
            guard let mode = difference.mode else { continue }
            lines.append("/bin/chmod \(String(mode, radix: 8)) -- \(q("./" + difference.path))")
        }
        if let quarantine {
            let value = String(decoding: quarantine, as: UTF8.self)
            lines.append("/usr/bin/find . -mindepth 1 -exec /usr/bin/xattr -s -w "
                         + "com.apple.quarantine \(q(value)) {} +")
        }
        for move in placement.moves {
            lines.append("[ ! -e \(q(move.to.path)) ] || { echo \(q("\u{201C}\(move.to.lastPathComponent)\u{201D} is there already.")) >&2; exit 4; }")
            lines.append("/bin/mv -n -- \(q("./" + move.name)) \(q(move.to.path))")
        }
        return lines.joined(separator: "; ")
    }

    nonisolated static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Running the tools

    struct Invocation: Equatable, Sendable {
        let executable: String
        let arguments: [String]
        var environment: [String: String] = [:]
    }

    /// One archive being made, or unpacked: the tools running, which Stop
    /// ends, and how far they have got.
    ///
    /// The tools say what they are doing on stderr, which goes to a file
    /// rather than a pipe -- nothing then has to keep reading it for them --
    /// and `snapshot()` reads what is new each time it is asked: `ditto -V`
    /// writes a line as it starts each file and one with its size when done,
    /// `tar -v` the name as it starts each and the end of the line when done. Within one big file, the tool's own
    /// read position, from libproc, as `lsof` would show it. aa says nothing
    /// as it goes; its data is counted on the way from one aa to the other.
    final class Job: @unchecked Sendable {

        enum Phase: Sendable, Equatable {
            case counting, preparing, archiving, finishing
        }

        /// How far it has got, for the window.
        struct Snapshot: Sendable, Equatable {
            var phase = Phase.counting
            var files = 0
            var totalFiles = 0
            var bytes: Int64 = 0
            var totalBytes: Int64 = 0
            /// The file the tool is on, as it names it.
            var current: String?
            /// aa does not say which files it has done, only how much.
            var countsFiles = true

            /// Never 1 before it is done: the last step is the tool's own.
            var fraction: Double? {
                guard phase == .archiving || phase == .finishing else { return nil }
                if totalBytes > 0 { return min(Double(bytes) / Double(totalBytes), 0.999) }
                if totalFiles > 0 { return min(Double(files) / Double(totalFiles), 0.999) }
                return nil
            }
        }

        enum Reporter: Sendable {
            case none, ditto, tar
        }

        private let lock = NSLock()
        private var processes: [Process] = []
        private var cancelled = false
        private var state = Snapshot()
        private var doneBytes: Int64 = 0
        private var reading: Int64 = 0
        /// For tar, which names a file but not its size.
        private var sizes: [String: Int64] = [:]
        private var reporter = Reporter.none
        private var errors: URL?
        private var errorsRead: UInt64 = 0
        private var partialLine = Data()
        /// Where the items are, resolved as the kernel names open files.
        private var roots: [String] = []

        init() {}

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            for process in processes where process.isRunning { process.terminate() }
        }

        func snapshot() -> Snapshot {
            lock.lock(); defer { lock.unlock() }
            readErrors()
            reading = state.current == nil ? 0 : readPosition()
            var snapshot = state
            snapshot.bytes = min(doneBytes + reading, max(state.totalBytes, doneBytes))
            return snapshot
        }

        fileprivate func set(_ phase: Phase) {
            lock.lock(); defer { lock.unlock() }
            state.phase = phase
        }

        fileprivate func counted(files: Int, bytes: Int64) {
            lock.lock(); defer { lock.unlock() }
            state.totalFiles += files
            state.totalBytes += bytes
        }

        fileprivate func prepare(sizes: [String: Int64], roots: [String], countsFiles: Bool) {
            lock.lock(); defer { lock.unlock() }
            self.sizes = sizes
            self.roots = roots
            state.countsFiles = countsFiles
        }

        fileprivate func relayed(_ count: Int) {
            lock.lock(); defer { lock.unlock() }
            doneBytes += Int64(count)
        }

        fileprivate func started(_ process: Process, reporter: Reporter, errors: URL) -> Bool {
            lock.lock(); defer { lock.unlock() }
            processes.append(process)
            if reporter != .none {
                self.reporter = reporter
                self.errors = errors
                errorsRead = 0
                partialLine = Data()
            }
            return !cancelled
        }

        fileprivate func finished(_ process: Process) {
            lock.lock(); defer { lock.unlock() }
            readErrors()
            processes.removeAll { $0 === process }
            if processes.isEmpty { errors = nil }
        }

        // MARK: Reading what the tools say

        private func readErrors() {
            guard let errors, let handle = try? FileHandle(forReadingFrom: errors) else { return }
            defer { try? handle.close() }
            try? handle.seek(toOffset: errorsRead)
            guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
            errorsRead += UInt64(data.count)
            partialLine.append(data)
            while let newline = partialLine.firstIndex(of: 10) {
                let line = String(decoding: partialLine[partialLine.startIndex..<newline], as: UTF8.self)
                partialLine.removeSubrange(partialLine.startIndex...newline)
                take(line)
            }
            // tar writes "a name" as it starts an item and the newline once
            // it is done: the line still open is the one being read.
            if reporter == .tar, partialLine.starts(with: Array("a ".utf8)) {
                state.current = Archiving.normalized(String(decoding: partialLine.dropFirst(2),
                                                            as: UTF8.self))
            }
        }

        private func take(_ line: String) {
            switch reporter {
            case .none:
                break
            case .ditto:
                if line.hasPrefix("copying file ") {
                    var name = String(line.dropFirst("copying file ".count))
                    if name.hasSuffix(" ... ") { name.removeLast(5) }
                    else if name.hasSuffix(" ...") { name.removeLast(4) }
                    state.current = Archiving.normalized(name)
                } else if let space = line.firstIndex(of: " "),
                          line[space...].hasPrefix(" bytes for "),
                          let count = Int64(line[..<space]) {
                    doneBytes += count
                    state.files += 1
                    state.current = nil
                }
            case .tar:
                guard line.hasPrefix("a ") else { return }
                if let size = sizes[Archiving.normalized(String(line.dropFirst(2)))] {
                    doneBytes += size
                    state.files += 1
                }
                state.current = nil
            }
        }

        /// How far into its current file a tool has read: the largest read
        /// position among its files under the items.
        private func readPosition() -> Int64 {
            var furthest: Int64 = 0
            for process in processes where process.isRunning {
                let pid = process.processIdentifier
                let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
                guard size > 0 else { continue }
                let room = Int(size) / MemoryLayout<proc_fdinfo>.size + 8
                var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: room)
                let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors,
                                       Int32(room * MemoryLayout<proc_fdinfo>.size))
                guard got > 0 else { continue }
                for entry in descriptors.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size)
                where entry.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                    var info = vnode_fdinfowithpath()
                    guard proc_pidfdinfo(pid, entry.proc_fd, PROC_PIDFDVNODEPATHINFO, &info,
                                         Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0,
                          info.pfi.fi_openflags & UInt32(bitPattern: FWRITE) == 0,
                          // A folder's position is a cookie, not a count of bytes.
                          info.pvip.vip_vi.vi_type == 1 /* VREG */
                    else { continue }
                    let path = withUnsafeBytes(of: info.pvip.vip_path) {
                        String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
                    }
                    guard roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
                        continue
                    }
                    furthest = max(furthest, info.pfi.fi_offset)
                }
            }
            return furthest
        }
    }

    /// The path as the kernel gives it for an open file: links resolved,
    /// `/var` as `/private/var`.
    nonisolated static func resolvedPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// What goes in, counted for the progress: the files, their bytes, and
    /// each file's size under the name tar gives it.
    nonisolated static func measure(_ items: [URL], job: Job) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        var files = 0
        var bytes: Int64 = 0
        func add(_ name: String, _ size: Int64) {
            sizes[name] = size
            files += 1
            bytes += size
            if files % 500 == 0 {
                job.counted(files: files, bytes: bytes)
                files = 0
                bytes = 0
            }
        }
        for item in items {
            guard !job.isCancelled else { break }
            var info = stat()
            guard lstat(item.path, &info) == 0 else { continue }
            let name = item.lastPathComponent
            if info.st_mode & S_IFMT == S_IFREG { add(name, Int64(info.st_size)) }
            guard info.st_mode & S_IFMT == S_IFDIR,
                  let walker = FileManager().enumerator(atPath: item.path) else { continue }
            while let relative = walker.nextObject() as? String {
                if job.isCancelled { break }
                guard lstat(item.appendingPathComponent(relative).path, &info) == 0,
                      info.st_mode & S_IFMT == S_IFREG else { continue }
                add(name + "/" + relative, Int64(info.st_size))
            }
        }
        job.counted(files: files, bytes: bytes)
        return sizes
    }

    /// Runs the tool to its end and returns what it printed. Output goes to
    /// files rather than pipes: a listing of a hundred thousand entries would
    /// fill a pipe while nobody read the other one.
    @discardableResult
    nonisolated static func run(_ invocation: Invocation, job: Job,
                                reporter: Job.Reporter = .none) throws(Failure) -> String {
        let manager = FileManager()
        guard manager.isExecutableFile(atPath: invocation.executable) else {
            throw Failure(message: "\(invocation.executable) is not on this Mac.")
        }
        let scratch = try scratchFolder()
        defer { try? manager.removeItem(at: scratch) }
        let out = scratch.appendingPathComponent("out")
        let err = scratch.appendingPathComponent("err")
        manager.createFile(atPath: out.path, contents: nil)
        manager.createFile(atPath: err.path, contents: nil)

        let process = makeProcess(invocation)
        do {
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = try FileHandle(forWritingTo: out)
            process.standardError = try FileHandle(forWritingTo: err)
        } catch { throw Failure(message: error.localizedDescription) }

        guard job.started(process, reporter: reporter, errors: err) else {
            job.finished(process)
            throw Failure(message: "Stopped.")
        }
        do { try process.run() } catch {
            job.finished(process)
            throw Failure(message: error.localizedDescription)
        }
        process.waitUntilExit()
        job.finished(process)

        let output = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        guard !job.isCancelled else { throw Failure(message: "Stopped.") }
        try check(process, invocation, errors: err)
        return output
    }

    /// `first`'s output into `second`, counted on the way: aa archives into
    /// its own uncompressed form, and a second aa compresses it, so the
    /// bytes that pass between them are the progress.
    nonisolated static func runPipeline(_ first: Invocation, into second: Invocation,
                                        job: Job) throws(Failure) {
        let manager = FileManager()
        for invocation in [first, second]
        where !manager.isExecutableFile(atPath: invocation.executable) {
            throw Failure(message: "\(invocation.executable) is not on this Mac.")
        }
        let scratch = try scratchFolder()
        defer { try? manager.removeItem(at: scratch) }
        let firstErrors = scratch.appendingPathComponent("err1")
        let secondErrors = scratch.appendingPathComponent("err2")
        manager.createFile(atPath: firstErrors.path, contents: nil)
        manager.createFile(atPath: secondErrors.path, contents: nil)

        let producer = makeProcess(first)
        let consumer = makeProcess(second)
        let between = Pipe()
        let into = Pipe()
        do {
            producer.standardInput = FileHandle.nullDevice
            producer.standardOutput = between
            producer.standardError = try FileHandle(forWritingTo: firstErrors)
            consumer.standardInput = into
            consumer.standardOutput = FileHandle.nullDevice
            consumer.standardError = try FileHandle(forWritingTo: secondErrors)
        } catch { throw Failure(message: error.localizedDescription) }

        guard job.started(producer, reporter: .none, errors: firstErrors),
              job.started(consumer, reporter: .none, errors: secondErrors) else {
            job.finished(producer)
            job.finished(consumer)
            throw Failure(message: "Stopped.")
        }
        do {
            try consumer.run()
            try producer.run()
        } catch {
            if consumer.isRunning { consumer.terminate() }
            job.finished(producer)
            job.finished(consumer)
            throw Failure(message: error.localizedDescription)
        }
        // Ours closed, so the end of the producer's output is seen as one.
        try? between.fileHandleForWriting.close()
        try? into.fileHandleForReading.close()
        let reader = between.fileHandleForReading
        let writer = into.fileHandleForWriting
        // A consumer stopped by Stop would otherwise end Diptych with
        // SIGPIPE at the next write; this way the write fails instead.
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        while let chunk = try? reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            do { try writer.write(contentsOf: chunk) } catch { break }
            job.relayed(chunk.count)
        }
        try? writer.close()
        producer.waitUntilExit()
        consumer.waitUntilExit()
        job.finished(producer)
        job.finished(consumer)

        guard !job.isCancelled else { throw Failure(message: "Stopped.") }
        try check(producer, first, errors: firstErrors)
        try check(consumer, second, errors: secondErrors)
    }

    private nonisolated static func makeProcess(_ invocation: Invocation) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        if !invocation.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(invocation.environment) { $1 }
        }
        return process
    }

    private nonisolated static func scratchFolder() throws(Failure) -> URL {
        let scratch = FileManager().temporaryDirectory
            .appendingPathComponent("Diptych-tool-\(UUID().uuidString)")
        do { try FileManager().createDirectory(at: scratch, withIntermediateDirectories: true) }
        catch { throw Failure(message: error.localizedDescription) }
        return scratch
    }

    /// The tool's complaint, without the lines it writes as it goes.
    private nonisolated static func check(_ process: Process, _ invocation: Invocation,
                                          errors: URL) throws(Failure) {
        guard process.terminationStatus != 0 else { return }
        let lines = ((try? String(contentsOf: errors, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .filter { line in
                !line.hasPrefix("a ") && !line.hasPrefix("copying file ")
                    && !line.hasPrefix(">>> ") && !line.contains(" bytes for ")
            }
        let complaint = lines.suffix(8).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (invocation.executable as NSString).lastPathComponent
        throw Failure(message: complaint.isEmpty
                      ? "\(name) stopped with code \(process.terminationStatus)."
                      : "\(name): \(complaint)")
    }

    // MARK: - Files

    nonisolated static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// A rename that never replaces anything.
    nonisolated static func rename(_ from: URL, to: URL) -> Bool {
        renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0
    }
}

/// A user or group number as a person reads it: "root (0)", or the number
/// alone when this Mac has nobody by it.
enum AccountName {
    static func user(_ uid: uid_t) -> String {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else {
            return "user \(uid), who has no account on this Mac"
        }
        return "\(String(cString: name)) (\(uid))"
    }

    static func group(_ gid: gid_t) -> String {
        guard let entry = getgrgid(gid), let name = entry.pointee.gr_name else {
            return "\(gid), which this Mac does not have"
        }
        return "\(String(cString: name)) (\(gid))"
    }
}
