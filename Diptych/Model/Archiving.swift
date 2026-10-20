import Foundation
import CommonCrypto
import CryptoKit
import Darwin

/// Making archives and unpacking them, with the tools macOS comes with.
///
/// `ditto` for zip, because it is what Finder's Compress runs and the only
/// tool that writes Finder's `__MACOSX` folder. `/usr/bin/tar`, which is
/// libarchive, for tar compressed or not, and for a zip under a password,
/// which ditto cannot write. `aa` for Apple Archive, and `aea` to encrypt
/// one. Each is called with an absolute path, never through `$PATH`.
enum Archiving {

    static let ditto = "/usr/bin/ditto"
    static let tar = "/usr/bin/tar"
    static let aa = "/usr/bin/aa"
    static let aea = "/usr/bin/aea"
    static let cat = "/bin/cat"

    struct Failure: Error, Equatable, Sendable {
        let message: String
        /// The archive is encrypted and the password did not open it: asked
        /// again rather than reported.
        var isWrongPassword = false
    }

    // MARK: - Formats

    enum Format: String, Codable, CaseIterable, Identifiable, Sendable {
        case zip
        case tar
        case appleArchive
        case diskImage
        case iso

        var id: String { rawValue }

        var title: String {
            switch self {
            case .zip:          "ZIP"
            case .tar:          "tar"
            case .appleArchive: "Apple Archive"
            case .diskImage:    "Disk Image"
            case .iso:          "ISO"
            }
        }
    }

    /// A zip under a password. Written by tar, as ditto writes no encrypted
    /// zip: the bytes and the permissions only, no `__MACOSX`.
    enum ZipEncryption: String, Codable, CaseIterable, Identifiable, Sendable {
        case none
        /// WinZip's AES: strong, and opened by 7-Zip, Keka, The Unarchiver
        /// and Windows 11 -- not by Archive Utility.
        case aes256
        /// The original PKZip scheme: everything opens it, Archive Utility
        /// included, and it is broken in minutes by anyone who tries.
        case zipCrypto

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none:      "None"
            case .aes256:    "AES-256"
            case .zipCrypto: "ZipCrypto (weak, opens everywhere)"
            }
        }

        /// libarchive's name for it.
        var option: String? {
            switch self {
            case .none:      nil
            case .aes256:    "aes256"
            case .zipCrypto: "zipcrypt"
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

        var zipEncryption = ZipEncryption.none

        var aarCompression = AppleArchiveCompression.lzfse
        var aarOwners = true
        var aarExtendedAttributes = true
        var aarAccessControl = true
        /// An Apple Encrypted Archive, `.aea`, under a password.
        var aarEncrypted = false

        var diskImageFormat = DiskImaging.Format.lzfse
        var diskImageFilesystem = DiskImaging.Filesystem.apfs
        var diskImageEncryption = DiskImaging.Encryption.none
        var isoFilesystems = DiskImaging.ISOFilesystems.all

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
            zipEncryption = value(.zipEncryption, defaults.zipEncryption)
            aarEncrypted = value(.aarEncrypted, defaults.aarEncrypted)
            diskImageFormat = value(.diskImageFormat, defaults.diskImageFormat)
            diskImageFilesystem = value(.diskImageFilesystem, defaults.diskImageFilesystem)
            diskImageEncryption = value(.diskImageEncryption, defaults.diskImageEncryption)
            isoFilesystems = value(.isoFilesystems, defaults.isoFilesystems)
        }

        var fileExtension: String {
            switch format {
            case .zip:          "zip"
            case .tar:          tarCompression.fileExtension
            case .appleArchive: aarEncrypted ? "aea" : "aar"
            case .diskImage:    "dmg"
            case .iso:          "iso"
            }
        }

        /// What was chosen is encrypted: a password must be given.
        var needsPassword: Bool {
            switch format {
            case .zip:          zipEncryption != .none
            case .tar, .iso:    false
            case .appleArchive: aarEncrypted
            case .diskImage:    diskImageEncryption != .none
            }
        }

        /// The shortest password `aea` takes; shorter ones it refuses as
        /// too short.
        static let shortestAppleArchivePassword = 20

        /// Why `password` will not do for what was chosen, or nil.
        func passwordProblem(_ password: String) -> String? {
            guard needsPassword else { return nil }
            if password.isEmpty { return "Type the password twice." }
            if password.contains(where: \.isNewline) { return "A password cannot hold a line break." }
            if format == .appleArchive, password.count < Self.shortestAppleArchivePassword {
                return "Apple Encrypted Archive takes a password of at least "
                    + "\(Self.shortestAppleArchivePassword) characters."
            }
            return nil
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
                                   password: String? = nil,
                                   job: Job = Job()) throws(Failure) {
        guard !items.isEmpty else { throw Failure(message: "Nothing is selected.") }
        if options.needsPassword, let problem = options.passwordProblem(password ?? "") {
            throw Failure(message: problem)
        }
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

        // A password goes to the tool in a file only the user can read,
        // never on its command line, where `ps` would show it.
        var secret: PasswordFile?
        defer { secret?.remove() }
        if options.needsPassword, let password {
            secret = try PasswordFile(password, endsWithNewline: options.format == .zip)
        }

        switch options.format {
        case .diskImage:
            try DiskImaging.makeDiskImage(of: items, at: partial, options: options,
                                          volumeName: stem(of: target), password: secret, job: job)
        case .iso:
            try DiskImaging.makeISO(of: items, at: partial, options: options,
                                    volumeName: stem(of: target), job: job)
        case .zip, .tar, .appleArchive:
            try archive(items, into: partial, options: options, sizes: sizes, secret: secret,
                        staging: &staging, job: job)
        }
        guard !job.isCancelled else { throw Failure(message: "Stopped.") }
        job.set(.finishing)
        guard rename(partial, to: target) else {
            throw Failure(message: "\u{201C}\(target.lastPathComponent)\u{201D} could not be "
                          + "put in place: \(String(cString: strerror(errno)))")
        }
    }

    /// A zip, a tar or an Apple Archive of `items`, written to `partial`.
    private nonisolated static func archive(_ items: [URL], into partial: URL, options: Options,
                                            sizes: [String: Int64], secret: PasswordFile?,
                                            staging: inout URL?, job: Job) throws(Failure) {
        let names = items.map(\.lastPathComponent)
        let invocation: Invocation
        switch options.format {
        case .diskImage, .iso:
            return
        case .zip where secret != nil:
            invocation = encryptedZipInvocation(items, output: partial, options: options,
                                                password: secret!.url)
        case .zip:
            // ditto packs one folder, kept whole with --keepParent, or one
            // file as itself -- --keepParent on a file would put its folder
            // in too. Several are put together in a folder of clones first.
            if items.count == 1 {
                var info = stat()
                let isFolder = stat(items[0].path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
                invocation = zipInvocation(source: items[0], keepParent: isFolder,
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
            // Always into a folder of clones first -- never `aa archive -d`
            // on the items' real parent. aa scans the whole directory it is
            // given before its -include-regex filters the output, and on a
            // large, live parent (a repository with .git and build products,
            // a special file, something it cannot encode) that scan fails the
            // archive outright. The clones are the items and nothing else.
            let stage = try stage(items)
            staging = stage
            invocation = appleArchiveInvocation(folder: stage, names: names,
                                                output: partial, options: options)
        }
        let byTar = options.format == .tar || (options.format == .zip && secret != nil)
        job.prepare(sizes: byTar ? sizes : [:],
                    roots: (items + (staging.map { [$0] } ?? [])).map(resolvedPath),
                    countsFiles: options.format != .appleArchive)
        job.set(.archiving)
        switch options.format {
        case .diskImage, .iso: break
        case .zip:          try run(invocation, job: job, reporter: byTar ? .tar : .ditto)
        case .tar:          try run(invocation, job: job, reporter: .tar)
        case .appleArchive:
            // Uncompressed out of one aa, compressed -- and encrypted -- by
            // the next: what passes between them is the progress.
            var archive = invocation.arguments
            if let output = archive.firstIndex(of: "-o") { archive.removeSubrange(output...(output + 1)) }
            if let algorithm = archive.firstIndex(of: "-a") { archive[algorithm + 1] = "raw" }
            let second = secret.map { secret in
                appleEncryptInvocation(output: partial, compression: options.aarCompression,
                                       password: secret.url)
            } ?? Invocation(executable: aa, arguments: [
                "convert", "-a", options.aarCompression.rawValue, "-b", "4m", "-o", partial.path])
            try runPipeline(Invocation(executable: aa, arguments: archive), into: second, job: job)
        }
    }

    /// tar writing a zip under a password, read from its standard input.
    /// Mac data is left out: tar's zip has nowhere for it but `._` files.
    static func encryptedZipInvocation(_ items: [URL], output: URL, options: Options,
                                       password: URL) -> Invocation {
        var zipOptions = ["zip:encryption=\(options.zipEncryption.option ?? "aes256")"]
        switch options.zipCompression {
        case .none:    zipOptions.append("zip:compression=store")
        case .fastest: zipOptions.append("zip:compression-level=1")
        case .normal:  break
        case .best:    zipOptions.append("zip:compression-level=9")
        }
        var arguments = ["-c", "-v", "--format", "zip", "--options", zipOptions.joined(separator: ","),
                         "--no-mac-metadata", "--no-xattrs", "--no-acls", "--no-fflags",
                         "-f", output.path]
        for item in items {
            let name = item.lastPathComponent
            arguments += ["-C", item.deletingLastPathComponent().path,
                          name.hasPrefix("-") ? "./" + name : name]
        }
        return Invocation(executable: tar, arguments: arguments,
                          environment: ["COPYFILE_DISABLE": "1"], input: password)
    }

    /// `aea` compressing and encrypting an uncompressed Apple Archive from
    /// its standard input, under the password in a file.
    static func appleEncryptInvocation(output: URL, compression: AppleArchiveCompression,
                                       password: URL) -> Invocation {
        Invocation(executable: aea, arguments: [
            "encrypt", "-profile", "hkdf_sha256_aesctr_hmac__scrypt__none",
            "-a", compression == .raw ? "none" : compression.rawValue, "-b", "4m",
            "-password", password.path, "-o", output.path])
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

    /// Items from several places side by side in one folder, copied with
    /// `cp -Rp` so everything an archive should keep comes across: the mode
    /// with its setuid, setgid and sticky bits, the owner, ACLs, file flags
    /// and extended attributes. clonefile would be free on APFS but clears
    /// setuid and setgid, and copyItem drops them too.
    nonisolated static func stage(_ items: [URL]) throws(Failure) -> URL {
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
            let destination = stage.appendingPathComponent(item.lastPathComponent)
            let cp = Process()
            cp.executableURL = URL(fileURLWithPath: "/bin/cp")
            cp.arguments = ["-Rp", item.path, destination.path]
            cp.standardOutput = FileHandle.nullDevice
            cp.standardError = FileHandle.nullDevice
            do {
                try cp.run()
                cp.waitUntilExit()
            } catch {
                try? manager.removeItem(at: stage)
                throw Failure(message: "\u{201C}\(item.lastPathComponent)\u{201D} could not be "
                              + "read: \(error.localizedDescription)")
            }
            guard cp.terminationStatus == 0 else {
                try? manager.removeItem(at: stage)
                throw Failure(message: "\u{201C}\(item.lastPathComponent)\u{201D} could not be copied.")
            }
        }
        return stage
    }

    // MARK: - Unpacking

    enum Kind: Sendable, Equatable {
        case zip, tar, appleArchive
        /// Apple Encrypted Archive: an Apple Archive under a password.
        case appleEncrypted
    }

    /// What Extract understands, by name: the zip family, tar compressed or
    /// not, and Apple Archive, encrypted or not.
    static func kind(of url: URL) -> Kind? {
        let name = url.lastPathComponent.lowercased()
        if multipartExtensions.contains(where: { name.hasSuffix("." + $0) }) { return .tar }
        switch url.pathExtension.lowercased() {
        case "zip", "jar", "war", "ipa": return .zip
        case "tar", "tgz", "tbz", "tbz2", "txz", "taz": return .tar
        case "aar": return .appleArchive
        case "aea": return .appleEncrypted
        default: return nil
        }
    }

    static func isExtractable(_ url: URL) -> Bool { kind(of: url) != nil }

    /// A password is needed to read it: an Apple Encrypted Archive always, a
    /// zip when an entry in it is encrypted.
    nonisolated static func needsPassword(_ archive: URL, kind: Kind) -> Bool {
        switch kind {
        case .appleEncrypted: true
        case .zip:            isEncryptedZip(archive)
        case .tar, .appleArchive: false
        }
    }

    /// A zip read where it matters -- its end record, its central
    /// directory, one entry's local header -- and never whole: it can be
    /// gigabytes.
    private struct ZipFile {
        let handle: FileHandle
        let size: UInt64
        /// The central directory's bytes.
        let directory: [UInt8]

        init?(_ url: URL) {
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let size = try? handle.seekToEnd(), size >= 22 else { return nil }
            self.handle = handle
            self.size = size
            // The end record is in the last 64 KB and 22 bytes: a comment
            // can follow it.
            let tailSize = Int(min(size, 65_557))
            guard let tail = Self.read(handle, size, size - UInt64(tailSize), tailSize),
                  let end = stride(from: tailSize - 22, through: 0, by: -1).first(where: {
                      Self.integer(tail, $0, 4) == 0x0605_4B50 })
            else { try? handle.close(); return nil }
            var offset = Self.integer(tail, end + 16, 4)
            var length = Self.integer(tail, end + 12, 4)
            // Zip64: the real numbers are in a record the locator before it
            // names.
            if offset == 0xFFFF_FFFF || length == 0xFFFF_FFFF, end >= 20,
               Self.integer(tail, end - 20, 4) == 0x0706_4B50,
               let record = Self.read(handle, size, Self.integer(tail, end - 12, 8), 56),
               Self.integer(record, 0, 4) == 0x0606_4B50 {
                length = Self.integer(record, 40, 8)
                offset = Self.integer(record, 48, 8)
            }
            guard length < 512 << 20, let directory = Self.read(handle, size, offset, Int(length)) else {
                try? handle.close()
                return nil
            }
            self.directory = directory
        }

        func close() { try? handle.close() }

        func read(_ offset: UInt64, _ count: Int) -> [UInt8]? {
            Self.read(handle, size, offset, count)
        }

        /// Each central directory entry: its flags, CRC, compressed size and
        /// where its local header is.
        var entries: [(flags: UInt64, crc: UInt64, size: UInt64, local: UInt64)] {
            var found: [(UInt64, UInt64, UInt64, UInt64)] = []
            var at = 0
            while at + 46 <= directory.count, Self.integer(directory, at, 4) == 0x0201_4B50 {
                found.append((Self.integer(directory, at + 8, 2), Self.integer(directory, at + 16, 4),
                              Self.integer(directory, at + 20, 4), Self.integer(directory, at + 42, 4)))
                at += 46 + Int(Self.integer(directory, at + 28, 2) + Self.integer(directory, at + 30, 2)
                               + Self.integer(directory, at + 32, 2))
            }
            return found
        }

        static func read(_ handle: FileHandle, _ size: UInt64, _ offset: UInt64, _ count: Int) -> [UInt8]? {
            guard count >= 0, offset + UInt64(count) <= size, (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: count), data.count == count else { return nil }
            return [UInt8](data)
        }

        /// Little-endian, as everything in a zip is.
        static func integer(_ bytes: [UInt8], _ at: Int, _ width: Int) -> UInt64 {
            guard at >= 0, at + width <= bytes.count else { return 0 }
            return (0..<width).reduce(UInt64(0)) { $0 | UInt64(bytes[at + $1]) << (8 * UInt64($1)) }
        }
    }

    /// Whether any entry of the zip is encrypted, from bit 0 of its flags in
    /// the central directory -- ZipCrypto and AES alike set it. A folder
    /// entry often is not, so every entry is looked at.
    nonisolated static func isEncryptedZip(_ url: URL) -> Bool {
        guard let zip = ZipFile(url) else { return false }
        defer { zip.close() }
        return zip.entries.contains { $0.flags & 1 != 0 }
    }

    /// Whether `password` opens the zip, from the check each scheme keeps:
    /// WinZip AES two bytes derived with the key, ZipCrypto the last byte of
    /// its 12-byte header. Looked at before tar is run, which given a wrong
    /// password asks for another ten thousand times. Nil when it cannot be
    /// told: tar is then left to find out.
    nonisolated static func isZipPassword(_ password: String, rightFor url: URL) -> Bool? {
        ZipPasswordVerifier(url)?.accepts(password)
    }

    /// The parameters an encrypted zip keeps for checking a password, read
    /// from the file once so that a great many candidates can be tried without
    /// opening and parsing it again. `isZipPassword` is this used once;
    /// password recovery is it used a million times.
    ///
    /// Nothing here can decrypt the archive -- only say whether a password is
    /// the right one, from the small verifier each scheme stores. The work per
    /// guess is the scheme's own: AES's is a PBKDF2 of a thousand rounds and
    /// dear by design, ZipCrypto's a few table lookups and all but free.
    struct ZipPasswordVerifier: Sendable {
        enum Scheme: Sendable {
            /// WinZip AES: PBKDF2-HMAC-SHA1, 1000 rounds, two verifier bytes.
            case aes(salt: [UInt8], verifier: [UInt8], keyLength: Int)
            /// The original ZipCrypto: a 12-byte header whose last decrypted
            /// byte is a known one.
            case zipCrypto(header: [UInt8], expected: UInt8)
        }

        let scheme: Scheme

        /// Nil when the zip is not one with an encrypted entry this can check:
        /// `isZipPassword` then returns nil and tar is left to find out.
        init?(_ url: URL) {
            guard let zip = ZipFile(url) else { return nil }
            defer { zip.close() }
            // The first encrypted file with something in it.
            guard let entry = zip.entries.first(where: { $0.flags & 1 != 0 && $0.size > 0 }),
                  entry.local != 0xFFFF_FFFF, let header = zip.read(entry.local, 30),
                  ZipFile.integer(header, 0, 4) == 0x0403_4B50 else { return nil }
            let method = ZipFile.integer(header, 8, 2)
            let time = ZipFile.integer(header, 10, 2)
            let nameLength = ZipFile.integer(header, 26, 2)
            let extraLength = Int(ZipFile.integer(header, 28, 2))
            let start = entry.local + 30 + nameLength + UInt64(extraLength)
            if method == 99 {
                // AES: the strength in the 0x9901 extra field, then salt and
                // verifier at the start of the data.
                guard let extra = zip.read(entry.local + 30 + nameLength, extraLength) else { return nil }
                var field = 0
                var strength: UInt64?
                while field + 4 <= extra.count {
                    let id = ZipFile.integer(extra, field, 2)
                    let length = Int(ZipFile.integer(extra, field + 2, 2))
                    if id == 0x9901, field + 8 < extra.count { strength = ZipFile.integer(extra, field + 8, 1) }
                    field += 4 + length
                }
                guard let strength, (1...3).contains(strength) else { return nil }
                let keyLength = 8 * (Int(strength) + 1)
                let saltLength = keyLength / 2
                guard let data = zip.read(start, saltLength + 2) else { return nil }
                scheme = .aes(salt: Array(data.prefix(saltLength)),
                              verifier: Array(data.suffix(2)), keyLength: keyLength)
                return
            }
            // ZipCrypto: the header's last decrypted byte is the CRC's top --
            // or, written streaming, the modification time's.
            guard let encrypted = zip.read(start, 12) else { return nil }
            scheme = .zipCrypto(header: encrypted,
                                expected: entry.flags & 8 != 0 ? UInt8((time >> 8) & 0xFF)
                                                               : UInt8((entry.crc >> 24) & 0xFF))
        }

        /// Whether this is the password, from the scheme's verifier alone.
        func accepts(_ password: String) -> Bool {
            let secret = Array(password.utf8)
            switch scheme {
            case .aes(let salt, let verifier, let keyLength):
                var derived = [UInt8](repeating: 0, count: 2 * keyLength + 2)
                let status = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), password, secret.count,
                    salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1000, &derived, derived.count)
                return status == kCCSuccess && Array(derived.suffix(2)) == verifier
            case .zipCrypto(let header, let expected):
                // Three keys stirred by the password decrypt the header.
                var keys: (UInt32, UInt32, UInt32) = (0x1234_5678, 0x2345_6789, 0x3456_7890)
                func update(_ byte: UInt8) {
                    keys.0 = Archiving.crc32(keys.0, byte)
                    keys.1 = (keys.1 &+ (keys.0 & 0xFF)) &* 134_775_813 &+ 1
                    keys.2 = Archiving.crc32(keys.2, UInt8(keys.1 >> 24))
                }
                for byte in secret { update(byte) }
                var last: UInt8 = 0
                for byte in header {
                    let temp = UInt16(truncatingIfNeeded: keys.2 | 2)
                    let plain = byte ^ UInt8(truncatingIfNeeded: (UInt32(temp) &* UInt32(temp ^ 1)) >> 8)
                    update(plain)
                    last = plain
                }
                return last == expected
            }
        }

        /// Each guess is dear (AES's PBKDF2) rather than all but free
        /// (ZipCrypto): the difference between a recovery worth attempting over
        /// a long password and one that is hopeless past a handful of characters.
        var guessIsExpensive: Bool { if case .aes = scheme { true } else { false } }
    }

    /// Whether `password` truly opens the zip -- not the one-byte guess of
    /// `isZipPassword`, but tar actually decrypting a file and checking its
    /// CRC. Dear, because it runs tar; used only to confirm a candidate the
    /// fast check already flagged, where ZipCrypto's one-in-256 false positive
    /// would otherwise be reported as the answer. A wrong password fails on
    /// the first file, so it costs little; the right one is confirmed once.
    nonisolated static func zipPasswordOpens(_ password: String, _ url: URL) -> Bool {
        guard let secret = try? PasswordFile(password, endsWithNewline: true),
              let input = try? FileHandle(forReadingFrom: secret.url) else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tar)
        // Extract file data to stdout: that forces decryption and the CRC
        // check, which merely listing the archive would not.
        task.arguments = ["-xO", "-f", url.path]
        task.standardInput = input
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        try? input.close()
        return task.terminationStatus == 0
    }

    /// One byte into a CRC-32, as ZipCrypto's keys take it.
    private nonisolated static func crc32(_ crc: UInt32, _ byte: UInt8) -> UInt32 {
        var value = (crc ^ UInt32(byte)) & 0xFF
        for _ in 0..<8 { value = value & 1 != 0 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1 }
        return (crc >> 8) ^ value
    }

    /// One entry as the archive records it.
    struct Entry: Equatable, Sendable {
        /// Relative, without "./" or a trailing slash.
        let path: String
        let uid: uid_t?
        let gid: gid_t?
        /// The permission bits, special ones included.
        let mode: mode_t?
        let isLink: Bool
        /// The bytes of a file; nil for anything else.
        var size: Int64? = nil
    }

    /// Every entry, with its owner, group and mode. Read with tar's mtree
    /// writer for zip and tar -- libarchive reads the uid and gid ditto
    /// stores in a zip, and folds `__MACOSX` into the files it describes --
    /// and with aa's own JSON listing for Apple Archive.
    /// An encrypted one is read with `password`: tar reads it from its
    /// standard input, and `aea` decrypts into aa's.
    nonisolated static func entries(of archive: URL, kind: Kind, password: PasswordFile? = nil,
                                    job: Job = Job()) throws(Failure) -> [Entry] {
        if kind == .zip, let password, isZipPassword(password.password, rightFor: archive) == false {
            throw Failure(message: "The password is wrong.", isWrongPassword: true)
        }
        switch kind {
        case .zip, .tar:
            let output = try run(Invocation(executable: tar, arguments: [
                "--format=mtree", "--options=!all,type,uid,gid,mode,size", "-cf", "-",
                "@" + archive.path], input: password?.url), job: job)
            return parseMtree(output)
        case .appleArchive:
            let output = try run(Invocation(executable: aa, arguments: [
                "list", "-list-format", "json", "-i", archive.path]), job: job)
            return parseAppleArchiveList(output)
        case .appleEncrypted:
            guard let password else { throw Failure(message: "The archive needs its password.") }
            let output = try runPipeline(decryptInvocation(archive, password: password.url),
                                         into: Invocation(executable: aa, arguments: [
                                             "list", "-list-format", "json"]),
                                         job: job, keepingOutput: true)
            return parseAppleArchiveList(output)
        }
    }

    /// `aea` decrypting `archive` to its standard output.
    static func decryptInvocation(_ archive: URL, password: URL) -> Invocation {
        Invocation(executable: aea, arguments: ["decrypt", "-i", archive.path,
                                                "-password", password.path])
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
                         isLink: keys["type"] == "link",
                         size: keys["type"] == "file" ? keys["size"].flatMap { Int64($0) } : nil)
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
                         isLink: entry["TYP"] as? String == "L",
                         size: entry["TYP"] as? String == "F"
                             ? (entry["DAT"] as? NSNumber).map { $0.int64Value } : nil)
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
    ///
    /// With the progress in `job`: a tar or an Apple Archive is read through
    /// a pipe, so the bytes passed are how far it has got; ditto names each
    /// file of a zip as it is done, and tar each of an encrypted one, whose
    /// sizes come from `entries`.
    nonisolated static func unpack(_ archive: URL, kind: Kind, into folder: URL,
                                   password: PasswordFile? = nil, entries: [Entry] = [],
                                   job: Job = Job()) throws(Failure) {
        let sizes = Dictionary(entries.compactMap { entry in entry.size.map { (entry.path, $0) } },
                               uniquingKeysWith: { first, _ in first })
        var info = stat()
        let archiveSize = stat(archive.path, &info) == 0 ? Int64(info.st_size) : 0
        let encryptedZip = kind == .zip && password != nil
        if encryptedZip, let password, isZipPassword(password.password, rightFor: archive) == false {
            throw Failure(message: "The password is wrong.", isWrongPassword: true)
        }
        switch kind {
        case .zip:
            job.prepare(sizes: sizes, roots: [], countsFiles: true)
            job.counted(files: sizes.count, bytes: sizes.values.reduce(0, +))
            job.set(.archiving)
            // -V: a line for each file ditto has written.
            let invocation = encryptedZip
                ? unpackInvocation(archive, kind: kind, into: folder, password: password?.url)
                : Invocation(executable: ditto, arguments: ["-x", "-k", "-V", archive.path, folder.path])
            try run(invocation, job: job, reporter: encryptedZip ? .tarExtract : .dittoExtract)
        case .tar, .appleArchive:
            job.prepare(sizes: [:], roots: [], countsFiles: false)
            job.counted(files: 0, bytes: archiveSize)
            job.set(.archiving)
            let reader = Invocation(executable: cat, arguments: [archive.path])
            let unpacker = kind == .tar
                ? Invocation(executable: tar, arguments: ["-x", "-p", "-f", "-", "-C", folder.path])
                : Invocation(executable: aa, arguments: ["extract", "-d", folder.path])
            try runPipeline(reader, into: unpacker, job: job)
        case .appleEncrypted:
            guard let password else { throw Failure(message: "The archive needs its password.") }
            job.prepare(sizes: [:], roots: [], countsFiles: false)
            job.counted(files: 0, bytes: sizes.values.reduce(0, +))
            job.set(.archiving)
            try runPipeline(decryptInvocation(archive, password: password.url),
                            into: Invocation(executable: aa, arguments: ["extract", "-d", folder.path]),
                            job: job)
        }
    }

    /// One tool unpacking the archive, as the restore script runs it. An
    /// Apple Encrypted Archive takes two, and is written out there.
    static func unpackInvocation(_ archive: URL, kind: Kind, into folder: URL,
                                 password: URL? = nil) -> Invocation {
        switch kind {
        case .zip where password != nil:
            // ditto reads no password; tar does, from its standard input.
            Invocation(executable: tar, arguments: ["-x", "-p", "-v", "-f", archive.path,
                                                     "-C", folder.path], input: password)
        case .zip:
            Invocation(executable: ditto, arguments: ["-x", "-k", archive.path, folder.path])
        case .tar:
            // -p: the permissions as recorded, setuid on one's own files and
            // ACLs included; the owner stays the user's.
            Invocation(executable: tar, arguments: ["-x", "-p", "-f", archive.path,
                                                     "-C", folder.path])
        case .appleArchive, .appleEncrypted:
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
                              destination: URL, quarantine: Data?,
                              password: URL? = nil) -> String {
        let q = Shell.quoted
        var lines = [
            "set -e",
            "set -o pipefail",
            "R=$(/usr/bin/mktemp -d \(q(destination.path + "/.diptych-extract.XXXXXX")))",
            "trap '/bin/rm -rf \"$R\"' EXIT",
            "/bin/chmod 700 \"$R\"",
            "/bin/cp \(q(archive.path)) \"$R/archive\"",
            "[ \"$(/usr/bin/shasum -a 256 \"$R/archive\" | /usr/bin/cut -d ' ' -f 1)\" = "
                + "\(q(sha256)) ] || { echo 'The archive changed after it was read.' >&2; exit 3; }",
            "/bin/mkdir \"$R/x\"",
        ]
        if kind == .appleEncrypted, let password {
            lines.append("\(aea) decrypt -i \"$R/archive\" -password \(q(password.path)) | "
                         + "\(aa) extract -d \"$R/x\"")
        } else {
            let unpack = unpackInvocation(URL(fileURLWithPath: "/R/archive"), kind: kind,
                                          into: URL(fileURLWithPath: "/R/x"), password: password)
            lines.append(([unpack.executable] + unpack.arguments.map { argument in
                argument.hasPrefix("/R/") ? "\"$R\"" + q(String(argument.dropFirst(2))) : q(argument)
            }).joined(separator: " ") + (unpack.input.map { " < " + q($0.path) } ?? ""))
        }
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
        /// A file read as the tool's standard input: a password.
        var input: URL? = nil
    }

    /// A password, in a file only the user can read inside a folder only
    /// the user can enter, for a tool that reads it from a file or from its
    /// standard input. Never on a command line, where `ps` shows it to
    /// anyone. Removed as soon as the work is done.
    final class PasswordFile: @unchecked Sendable {
        let url: URL
        /// Kept to check a zip's password before tar is given it.
        let password: String
        private let folder: URL

        /// tar reads a line; aea and hdiutil the whole file.
        init(_ password: String, endsWithNewline: Bool) throws(Failure) {
            self.password = password
            let manager = FileManager()
            folder = manager.temporaryDirectory.appendingPathComponent("Diptych-key-\(UUID().uuidString)")
            url = folder.appendingPathComponent("p")
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
                guard manager.createFile(atPath: url.path, contents: nil,
                                         attributes: [.posixPermissions: 0o600]) else {
                    throw Failure(message: "The password could not be handed to the tool.")
                }
                let handle = try FileHandle(forWritingTo: url)
                try handle.write(contentsOf: Data((password + (endsWithNewline ? "\n" : "")).utf8))
                try handle.close()
            } catch let failure as Failure {
                try? manager.removeItem(at: folder)
                throw failure
            } catch {
                try? manager.removeItem(at: folder)
                throw Failure(message: error.localizedDescription)
            }
        }

        func remove() { try? FileManager().removeItem(at: folder) }

        deinit { remove() }
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
            case counting, preparing, archiving
            /// A disk image converted to its format, by the percent hdiutil
            /// gives.
            case converting
            case finishing
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
            /// hdiutil's own, 0 to 100, while it converts; nil while it does
            /// not know.
            var percent: Double?

            /// Never 1 before it is done: the last step is the tool's own.
            var fraction: Double? {
                if phase == .converting { return percent.map { min($0 / 100, 0.999) } }
                guard phase == .archiving || phase == .finishing else { return nil }
                if totalBytes > 0 { return min(Double(bytes) / Double(totalBytes), 0.999) }
                if totalFiles > 0 { return min(Double(files) / Double(totalFiles), 0.999) }
                return nil
            }
        }

        enum Reporter: Sendable {
            case none, ditto, tar
            /// Unpacking: ditto -x -V's lines, and tar -x -v's.
            case dittoExtract, tarExtract
            /// hdiutil -puppetstrings's PERCENT lines, on its standard output.
            case hdiutil
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
        /// A file the tool writes and says nothing about: its size is the
        /// progress -- hdiutil makehybrid's image.
        private var growing: URL?

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
            if let growing {
                var info = stat()
                doneBytes = stat(growing.path, &info) == 0 ? Int64(info.st_size) : 0
            }
            var snapshot = state
            snapshot.bytes = min(doneBytes + reading, max(state.totalBytes, doneBytes))
            return snapshot
        }

        func set(_ phase: Phase) {
            lock.lock(); defer { lock.unlock() }
            state.phase = phase
        }

        func counted(files: Int, bytes: Int64) {
            lock.lock(); defer { lock.unlock() }
            state.totalFiles += files
            state.totalBytes += bytes
        }

        func prepare(sizes: [String: Int64], roots: [String], countsFiles: Bool) {
            lock.lock(); defer { lock.unlock() }
            self.sizes = sizes
            self.roots = roots
            state.countsFiles = countsFiles
        }

        func watchGrowth(of file: URL) {
            lock.lock(); defer { lock.unlock() }
            growing = file
        }

        func relayed(_ count: Int) {
            lock.lock(); defer { lock.unlock() }
            doneBytes += Int64(count)
        }

        func started(_ process: Process, reporter: Reporter, errors: URL) -> Bool {
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

        func finished(_ process: Process) {
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
            case .dittoExtract:
                // "6 bytes for ./photos/a.jpg" once each file is out.
                if let space = line.firstIndex(of: " "), line[space...].hasPrefix(" bytes for "),
                   let count = Int64(line[..<space]) {
                    doneBytes += count
                    state.files += 1
                    state.current = Archiving.normalized(String(line[space...].dropFirst(" bytes for ".count)))
                }
            case .hdiutil:
                if line.hasPrefix("PERCENT:"), let value = Double(line.dropFirst("PERCENT:".count)) {
                    state.percent = value < 0 ? nil : value
                }
            case .tarExtract:
                guard line.hasPrefix("x ") else { return }
                let name = Archiving.normalized(String(line.dropFirst(2)))
                if let size = sizes[name] {
                    doneBytes += size
                    state.files += 1
                }
                state.current = name
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
            process.standardInput = try invocation.input.map { try FileHandle(forReadingFrom: $0) }
                ?? FileHandle.nullDevice
            process.standardOutput = try FileHandle(forWritingTo: out)
            process.standardError = try FileHandle(forWritingTo: err)
        } catch { throw Failure(message: error.localizedDescription) }

        // hdiutil says how far it has got on its standard output.
        guard job.started(process, reporter: reporter, errors: reporter == .hdiutil ? out : err) else {
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
    /// bytes that pass between them are the progress. What `second` prints
    /// is returned when it is kept.
    @discardableResult
    nonisolated static func runPipeline(_ first: Invocation, into second: Invocation,
                                        job: Job, keepingOutput: Bool = false) throws(Failure) -> String {
        let manager = FileManager()
        for invocation in [first, second]
        where !manager.isExecutableFile(atPath: invocation.executable) {
            throw Failure(message: "\(invocation.executable) is not on this Mac.")
        }
        let scratch = try scratchFolder()
        defer { try? manager.removeItem(at: scratch) }
        let firstErrors = scratch.appendingPathComponent("err1")
        let secondErrors = scratch.appendingPathComponent("err2")
        let output = scratch.appendingPathComponent("out")
        manager.createFile(atPath: firstErrors.path, contents: nil)
        manager.createFile(atPath: secondErrors.path, contents: nil)
        manager.createFile(atPath: output.path, contents: nil)

        let producer = makeProcess(first)
        let consumer = makeProcess(second)
        let between = Pipe()
        let into = Pipe()
        do {
            producer.standardInput = try first.input.map { try FileHandle(forReadingFrom: $0) }
                ?? FileHandle.nullDevice
            producer.standardOutput = between
            producer.standardError = try FileHandle(forWritingTo: firstErrors)
            consumer.standardInput = into
            consumer.standardOutput = keepingOutput ? try FileHandle(forWritingTo: output)
                                                    : FileHandle.nullDevice
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
        return keepingOutput ? (try? String(contentsOf: output, encoding: .utf8)) ?? "" : ""
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
                !line.hasPrefix("a ") && !line.hasPrefix("x ") && !line.hasPrefix("copying file ")
                    && !line.hasPrefix(">>> ") && !line.contains(" bytes for ")
            }
        let complaint = lines.suffix(8).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (invocation.executable as NSString).lastPathComponent
        if invocation.input != nil || invocation.arguments.contains("-password"),
           isWrongPassword(complaint) {
            throw Failure(message: "The password is wrong.", isWrongPassword: true)
        }
        if name == "aea", complaint.contains("Password is too short") {
            throw Failure(message: "Apple Encrypted Archive refused the password as too short: "
                          + "it takes at least \(Options.shortestAppleArchivePassword) characters.")
        }
        throw Failure(message: complaint.isEmpty
                      ? "\(name) stopped with code \(process.terminationStatus)."
                      : "\(name): \(complaint)")
    }

    /// How tar and aea say a password did not open the archive. tar asks
    /// again and again on its standard input until that runs out.
    nonisolated static func isWrongPassword(_ complaint: String) -> Bool {
        ["Incorrect passphrase", "incorrect passphrases", "Couldn't read passphrase",
         "Failed to unlock container", "HMAC"].contains { complaint.contains($0) }
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
