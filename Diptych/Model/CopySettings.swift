import Foundation
import Darwin

/// What a copy takes along besides the bytes, set in Settings ▸ Behaviour.
///
/// Out of the box everything is kept, as Finder does. Each part can instead
/// be left for the copy to start fresh: no extended attributes, the time of
/// the copy as its dates, the permissions a new file gets, the group of the
/// folder it lands in, no access control list. Applies to copies only -- a
/// move is the same file somewhere else, and a sync's job is to make two
/// folders the same.
struct CopySettings: Codable, Equatable, Sendable {

    enum DateChoice: String, Codable, CaseIterable, Sendable {
        /// The original's, to the nanosecond.
        case original
        /// The moment of the copy.
        case now
    }

    enum PermissionChoice: String, Codable, CaseIterable, Sendable {
        /// The original's.
        case original
        /// What a new file gets: 0666, a folder 0777, less the umask.
        case umask
        /// `filePermissions` and `folderPermissions`.
        case fixed
    }

    enum GroupChoice: String, Codable, CaseIterable, Sendable {
        /// The original's, where the copier may give it.
        case original
        /// The group of the folder the copy lands in, when that folder has
        /// the setgid bit; the original's otherwise -- as Linux does it.
        case setgid
    }

    var extendedAttributes = true
    var createdDate = DateChoice.original
    var modifiedDate = DateChoice.original
    var permissions = PermissionChoice.original
    /// In `ls` form, setuid, setgid and sticky included: `rw-r--r--`,
    /// `rwsr-x--T`. Text rather than a number so config.json reads as `ls`.
    var filePermissions = "rw-r--r--"
    var folderPermissions = "rwxr-xr-x"
    var group = GroupChoice.original
    var accessControlList = true

    init() {}

    /// Every key optional, like `Configuration`'s.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        extendedAttributes = (try? container.decode(Bool.self, forKey: .extendedAttributes)) ?? true
        createdDate = (try? container.decode(DateChoice.self, forKey: .createdDate)) ?? .original
        modifiedDate = (try? container.decode(DateChoice.self, forKey: .modifiedDate)) ?? .original
        permissions = (try? container.decode(PermissionChoice.self, forKey: .permissions))
            ?? .original
        filePermissions = (try? container.decode(String.self, forKey: .filePermissions))
            .flatMap { Self.mode(from: $0) != nil ? $0 : nil } ?? "rw-r--r--"
        folderPermissions = (try? container.decode(String.self, forKey: .folderPermissions))
            .flatMap { Self.mode(from: $0) != nil ? $0 : nil } ?? "rwxr-xr-x"
        group = (try? container.decode(GroupChoice.self, forKey: .group)) ?? .original
        accessControlList = (try? container.decode(Bool.self, forKey: .accessControlList)) ?? true
    }

    /// Nothing to do after the copy itself.
    var keepsEverything: Bool {
        extendedAttributes && accessControlList && permissions == .original
            && group == .original && createdDate == .original && modifiedDate == .original
    }

    // MARK: - Permissions

    /// `rw-r--r--` as bits, or nil when it is not nine characters of that
    /// form. `s`/`S` and `t`/`T` as `ls` writes them are taken too.
    static func mode(from text: String) -> mode_t? {
        let characters = Array(text.trimmingCharacters(in: .whitespaces))
        guard characters.count == 9 else { return nil }
        var mode: mode_t = 0
        let special: [mode_t] = [0o4000, 0o2000, 0o1000]
        for group in 0..<3 {
            let shift = mode_t(6 - 3 * group)
            switch characters[3 * group] {
            case "r": mode |= 4 << shift
            case "-": break
            default: return nil
            }
            switch characters[3 * group + 1] {
            case "w": mode |= 2 << shift
            case "-": break
            default: return nil
            }
            let marker: Character = group == 2 ? "t" : "s"
            switch characters[3 * group + 2] {
            case "x": mode |= 1 << shift
            case "-": break
            case marker: mode |= 1 << shift | special[group]
            case Character(marker.uppercased()): mode |= special[group]
            default: return nil
            }
        }
        return mode
    }

    /// The process's umask. Reading it means setting it, so it is read once,
    /// before any copy can be creating files in between.
    static let processUmask: mode_t = {
        let mask = umask(0o022)
        umask(mask)
        return mask
    }()

    /// The mode a copied item gets, or nil to leave the copy's.
    func mode(folder: Bool) -> mode_t? {
        switch permissions {
        case .original:
            return nil
        case .umask:
            return (folder ? 0o777 : 0o666) & ~Self.processUmask
        case .fixed:
            return Self.mode(from: folder ? folderPermissions : filePermissions)
        }
    }

    // MARK: - Applying

    /// Once the copy at `target` is made: what is not wanted taken off it, the
    /// copy itself and everything in it when it is a folder. Nil when all of it
    /// worked, the first thing that did not otherwise.
    ///
    /// The quarantine mark stays whatever is chosen: taking it off would let a
    /// downloaded program run unchecked just for having been copied.
    nonisolated func apply(to target: URL, copiedAt now: timespec = Self.now()) -> String? {
        guard !keepsEverything else { return nil }
        // Parents before children, as the walk gives them.
        var paths = [target.path]
        var info = stat()
        if lstat(target.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
           let walker = FileManager().enumerator(atPath: target.path) {
            while let relative = walker.nextObject() as? String {
                paths.append(target.appendingPathComponent(relative).path)
            }
        }
        var problem: String?
        func note(_ failure: String?, _ path: String) {
            guard let failure, problem == nil else { return }
            problem = "\u{201C}\((path as NSString).lastPathComponent)\u{201D}: \(failure)"
        }
        // The group first, top down: whether an item takes its folder's group
        // depends on that folder's setgid bit as it will end up. And before
        // the permissions, since changing a file's group clears its setuid
        // and setgid bits.
        if group == .setgid {
            for path in paths {
                note(inheritGroup(path, top: path == target.path), path)
            }
        }
        // Then the rest deepest first, the folder itself last.
        for path in paths.reversed() {
            note(apply(toItem: path, now: now), path)
        }
        return problem
    }

    static func now() -> timespec {
        var spec = timespec()
        clock_gettime(CLOCK_REALTIME, &spec)
        return spec
    }

    /// The folder's group when the folder has setgid. The copy's own folder
    /// is judged by the mode it is about to be given, not the one it has.
    private func inheritGroup(_ path: String, top: Bool) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        var folder = stat()
        guard lstat(parent, &folder) == 0 else { return String(cString: strerror(errno)) }
        let folderMode = top ? folder.st_mode : (mode(folder: true) ?? folder.st_mode)
        guard folderMode & S_ISGID != 0 else { return nil }
        var info = stat()
        guard lstat(path, &info) == 0 else { return String(cString: strerror(errno)) }
        guard info.st_gid != folder.st_gid else { return nil }
        guard lchown(path, uid_t.max, folder.st_gid) == 0 else {
            return "its group could not be set: \(String(cString: strerror(errno)))"
        }
        // The kernel takes setuid and setgid off a file whose group changes;
        // they are put back when the permissions are to be the original's.
        if info.st_mode & S_IFMT != S_IFLNK, info.st_mode & (S_ISUID | S_ISGID) != 0,
           mode(folder: info.st_mode & S_IFMT == S_IFDIR) == nil {
            chmod(path, info.st_mode & 0o7777)
        }
        return nil
    }

    private func apply(toItem path: String, now: timespec) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return String(cString: strerror(errno)) }
        let kind = info.st_mode & S_IFMT
        let isLink = kind == S_IFLNK
        var problem: String?
        func fail(_ what: String) {
            if problem == nil { problem = "\(what): \(String(cString: strerror(errno)))" }
        }

        if !extendedAttributes {
            for name in Self.attributeNames(of: path) where name != "com.apple.quarantine"
                && ExtendedAttributes.protectedReason(for: name) == nil {
                if removexattr(path, name, XATTR_NOFOLLOW) != 0 {
                    fail("its extended attributes could not be removed")
                }
            }
        }
        if !accessControlList, !isLink,
           let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) {
            acl_free(UnsafeMutableRawPointer(acl))
            if let empty = acl_init(0) {
                if acl_set_file(path, ACL_TYPE_EXTENDED, empty) != 0 {
                    fail("its access control list could not be removed")
                }
                acl_free(UnsafeMutableRawPointer(empty))
            }
        }
        if !isLink, let mode = mode(folder: kind == S_IFDIR), chmod(path, mode) != 0 {
            fail("its permissions could not be set")
        }
        if modifiedDate == .now, !Self.setTime(now, ATTR_CMN_MODTIME, of: path) {
            fail("its modification date could not be set")
        }
        if createdDate == .now, !Self.setTime(now, ATTR_CMN_CRTIME, of: path) {
            fail("its creation date could not be set")
        }
        return problem
    }

    private static func attributeNames(of path: String) -> [String] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        guard listxattr(path, &buffer, size, XATTR_NOFOLLOW) > 0 else { return [] }
        return buffer.split(separator: 0).map {
            String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    /// A link's own date, never its target's.
    private static func setTime(_ time: timespec, _ attribute: Int32, of path: String) -> Bool {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(attribute)
        var spec = time
        return setattrlist(path, &list, &spec, MemoryLayout<timespec>.size,
                           UInt32(FSOPT_NOFOLLOW)) == 0
    }
}
