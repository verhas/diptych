import Foundation
import Darwin

/// Disk images made of the selection, and images opened in a pane, with
/// `hdiutil`.
///
/// A `.dmg` is made the way `build.sh` makes Diptych's own: an empty image,
/// attached, the items copied in by ditto, detached, and converted to the
/// format chosen -- encrypted on the way when asked. `hdiutil create
/// -srcfolder` does all of that in one go and fails as a whole with nothing
/// but "Resource busy" when any step is unhappy. An `.iso` is
/// `hdiutil makehybrid` of the items put side by side in a folder of clones.
nonisolated enum DiskImaging {

    static let hdiutil = "/usr/bin/hdiutil"

    typealias Failure = Archiving.Failure

    /// What the `.dmg` is converted to.
    enum Format: String, Codable, CaseIterable, Identifiable, Sendable {
        case lzfse, zlib, lzma, readOnly, readWrite

        var id: String { rawValue }

        var title: String {
            switch self {
            case .lzfse:     "Compressed, LZFSE (macOS 10.11 and later)"
            case .zlib:      "Compressed, zlib (any Mac)"
            case .lzma:      "Smallest, LZMA (macOS 10.15 and later)"
            case .readOnly:  "Read-only, not compressed"
            case .readWrite: "Read/write"
            }
        }

        /// hdiutil's name for it.
        var code: String {
            switch self {
            case .lzfse:     "ULFO"
            case .zlib:      "UDZO"
            case .lzma:      "ULMO"
            case .readOnly:  "UDRO"
            case .readWrite: "UDRW"
            }
        }
    }

    enum Filesystem: String, Codable, CaseIterable, Identifiable, Sendable {
        case apfs, hfs

        var id: String { rawValue }

        var title: String {
            switch self {
            case .apfs: "APFS (macOS 10.13 and later)"
            case .hfs:  "Mac OS Extended (any Mac)"
            }
        }

        var code: String {
            switch self {
            case .apfs: "APFS"
            case .hfs:  "HFS+"
            }
        }
    }

    enum Encryption: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, aes128, aes256

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none:   "None"
            case .aes128: "AES-128"
            case .aes256: "AES-256"
            }
        }

        var code: String? {
            switch self {
            case .none:   nil
            case .aes128: "AES-128"
            case .aes256: "AES-256"
            }
        }
    }

    /// The file systems an `.iso` carries: ISO 9660 with Joliet's long
    /// names for everything old, UDF for files over 4 GB.
    enum ISOFilesystems: String, Codable, CaseIterable, Identifiable, Sendable {
        case all, isoJoliet, udf

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all:       "ISO 9660, Joliet and UDF"
            case .isoJoliet: "ISO 9660 and Joliet only"
            case .udf:       "UDF only"
            }
        }

        var flags: [String] {
            switch self {
            case .all:       ["-iso", "-joliet", "-udf"]
            case .isoJoliet: ["-iso", "-joliet"]
            case .udf:       ["-udf"]
            }
        }
    }

    // MARK: - Making a .dmg

    /// The items side by side at the top of a new image's volume.
    static func makeDiskImage(of items: [URL], at output: URL, options: Archiving.Options,
                              volumeName: String, password: Archiving.PasswordFile?,
                              job: Archiving.Job) throws(Failure) {
        let manager = FileManager()
        let scratch = try scratchFolder(near: output)
        defer { try? manager.removeItem(at: scratch) }
        let blank = scratch.appendingPathComponent("blank.dmg")
        let mount = scratch.appendingPathComponent("volume")
        do { try manager.createDirectory(at: mount, withIntermediateDirectories: false) }
        catch { throw Failure(message: error.localizedDescription) }

        let kilobytes = (roomNeeded(for: items) + 1023) / 1024
        try Archiving.run(Archiving.Invocation(executable: hdiutil, arguments: [
            "create", "-quiet", "-size", "\(kilobytes)k", "-fs", options.diskImageFilesystem.code,
            "-volname", volumeName, blank.path]), job: job)
        guard !job.isCancelled else { throw Failure(message: "Stopped.") }

        let device = try attach(blank, at: mount, job: job)
        do throws(Failure) {
            job.prepare(sizes: [:], roots: items.map(Archiving.resolvedPath), countsFiles: true)
            job.set(.archiving)
            for item in items {
                try Archiving.run(Archiving.Invocation(executable: Archiving.ditto, arguments: [
                    "-V", item.path, mount.appendingPathComponent(item.lastPathComponent).path]),
                                  job: job, reporter: .ditto)
                guard !job.isCancelled else { throw Failure(message: "Stopped.") }
            }
        } catch {
            detach(device)
            throw error
        }
        guard detach(device) else {
            throw Failure(message: "The new image could not be detached to be converted.")
        }

        // hdiutil adds ".dmg" to a name without it: written under one, then
        // renamed.
        let converted = scratch.appendingPathComponent("image.dmg")
        job.set(.converting)
        var arguments = ["convert", blank.path, "-format", options.diskImageFormat.code,
                         "-puppetstrings", "-o", converted.path]
        if let encryption = options.diskImageEncryption.code, password != nil {
            arguments += ["-encryption", encryption, "-stdinpass"]
        }
        try Archiving.run(Archiving.Invocation(executable: hdiutil, arguments: arguments,
                                               input: password?.url),
                          job: job, reporter: .hdiutil)
        guard !job.isCancelled else { throw Failure(message: "Stopped.") }
        guard Archiving.rename(converted, to: output) else {
            throw Failure(message: "The image could not be put in place: \(String(cString: strerror(errno)))")
        }
    }

    /// The image's size: every file rounded up to whole 4 KB blocks, a
    /// block for each folder and link, and room for the file system's own.
    static func roomNeeded(for items: [URL]) -> Int64 {
        var total: Int64 = 0
        func add(_ info: stat) {
            let block: Int64 = 4096
            let size = info.st_mode & S_IFMT == S_IFREG ? Int64(info.st_size) : 0
            total += max(block, (size + block - 1) / block * block)
        }
        for item in items {
            var info = stat()
            guard lstat(item.path, &info) == 0 else { continue }
            add(info)
            guard info.st_mode & S_IFMT == S_IFDIR,
                  let walker = FileManager().enumerator(atPath: item.path) else { continue }
            while let relative = walker.nextObject() as? String {
                if lstat(item.appendingPathComponent(relative).path, &info) == 0 { add(info) }
            }
        }
        return total + total / 10 + (48 << 20)
    }

    // MARK: - Making an .iso

    static func makeISO(of items: [URL], at output: URL, options: Archiving.Options,
                        volumeName: String, job: Archiving.Job) throws(Failure) {
        let manager = FileManager()
        let stage = try Archiving.stage(items)
        defer { try? manager.removeItem(at: stage) }
        let scratch = try scratchFolder(near: output)
        defer { try? manager.removeItem(at: scratch) }
        guard !job.isCancelled else { throw Failure(message: "Stopped.") }

        let image = scratch.appendingPathComponent("image.iso")
        job.prepare(sizes: [:], roots: [], countsFiles: false)
        job.watchGrowth(of: image)
        job.set(.archiving)
        try Archiving.run(Archiving.Invocation(executable: hdiutil, arguments: [
            "makehybrid"] + options.isoFilesystems.flags + [
            "-default-volume-name", volumeName, "-o", image.path, stage.path]), job: job)
        guard !job.isCancelled else { throw Failure(message: "Stopped.") }
        guard Archiving.rename(image, to: output) else {
            throw Failure(message: "The image could not be put in place: \(String(cString: strerror(errno)))")
        }
    }

    // MARK: - Opening

    /// What Return mounts in the pane rather than handing to Finder.
    static func isDiskImage(_ url: URL) -> Bool {
        ["dmg", "iso", "cdr", "sparseimage", "toast"].contains(url.pathExtension.lowercased())
    }

    /// Whether the image asks for a password before it attaches.
    static func isEncrypted(_ image: URL) -> Bool {
        guard let output = try? Archiving.run(Archiving.Invocation(
            executable: hdiutil, arguments: ["isencrypted", "-plist", image.path]), job: Archiving.Job()),
              let plist = try? PropertyListSerialization.propertyList(from: Data(output.utf8),
                                                                       format: nil) as? [String: Any]
        else { return false }
        return plist["encrypted"] as? Bool == true
    }

    /// Mounted as a double-click in Finder mounts it, without the Finder
    /// window: where its volume is. An image already attached gives its
    /// mount point again.
    static func mount(_ image: URL, password: Archiving.PasswordFile?, browsable: Bool = true,
                      job: Archiving.Job = Archiving.Job()) throws(Failure) -> URL {
        var arguments = ["attach", "-plist", "-noautoopen"]
        if !browsable { arguments.append("-nobrowse") }
        if password != nil { arguments.append("-stdinpass") }
        arguments.append(image.path)
        let output: String
        do throws(Failure) {
            output = try Archiving.run(Archiving.Invocation(executable: hdiutil, arguments: arguments,
                                                            input: password?.url), job: job)
        } catch {
            if error.message.contains("Authentication error") || error.message.contains("passphrase") {
                throw Failure(message: "The password is wrong.", isWrongPassword: true)
            }
            throw error
        }
        guard let point = entities(output).compactMap({ $0["mount-point"] as? String }).first else {
            throw Failure(message: "The image attached, but no volume of it was mounted.")
        }
        return URL(fileURLWithPath: point, isDirectory: true)
    }

    /// Attached out of sight at `point`, to be written to: the device to
    /// detach.
    private static func attach(_ image: URL, at point: URL, job: Archiving.Job) throws(Failure) -> String {
        let output = try Archiving.run(Archiving.Invocation(executable: hdiutil, arguments: [
            "attach", "-plist", "-nobrowse", "-noverify", "-noautoopen", "-readwrite",
            "-mountpoint", point.path, image.path]), job: job)
        // The image's own device is listed first, before its partitions and
        // the APFS container synthesised from it: detaching it detaches all.
        guard let device = entities(output).compactMap({ $0["dev-entry"] as? String }).first else {
            throw Failure(message: "The new image did not attach.")
        }
        return device
    }

    @discardableResult
    static func detach(_ device: String) -> Bool {
        for arguments in [["detach", "-quiet", device], ["detach", "-quiet", "-force", device]] {
            if (try? Archiving.run(Archiving.Invocation(executable: hdiutil, arguments: arguments),
                                   job: Archiving.Job())) != nil { return true }
        }
        return false
    }

    private static func entities(_ plist: String) -> [[String: Any]] {
        guard let start = plist.range(of: "<?xml"),
              let root = try? PropertyListSerialization.propertyList(
                from: Data(plist[start.lowerBound...].utf8), format: nil) as? [String: Any]
        else { return [] }
        return root["system-entities"] as? [[String: Any]] ?? []
    }

    /// Beside the output, so the blank image -- as big as everything going
    /// in -- is on the disk that will hold the result.
    private static func scratchFolder(near output: URL) throws(Failure) -> URL {
        let manager = FileManager()
        if let folder = try? manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                         appropriateFor: output.deletingLastPathComponent(),
                                         create: true) {
            return folder
        }
        let folder = manager.temporaryDirectory.appendingPathComponent("Diptych-image-\(UUID().uuidString)")
        do { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { throw Failure(message: error.localizedDescription) }
        return folder
    }
}
