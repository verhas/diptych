import Foundation

/// The users and groups the system knows about.
///
/// Read straight from the passwd/group databases rather than shelling out to
/// `dscl`. Both enumerations return duplicates and a large number of system
/// accounts, so both are filtered and de-duplicated here.
@MainActor
enum AccountLookup {

    /// Real user accounts, system ones dropped. Names beginning with "_" are
    /// macOS service accounts.
    static func users() -> [String] {
        var names: Set<String> = []
        setpwent()
        while let entry = getpwent() {
            let name = String(cString: entry.pointee.pw_name)
            if !name.hasPrefix("_") { names.insert(name) }
        }
        endpwent()
        return names.sorted()
    }

    static func groups() -> [String] {
        var names: Set<String> = []
        setgrent()
        while let entry = getgrent() {
            let name = String(cString: entry.pointee.gr_name)
            if !name.hasPrefix("_") { names.insert(name) }
        }
        endgrent()
        return names.sorted()
    }

    /// The groups this user belongs to -- the only ones a non-root user can
    /// actually move a file into, so they are offered first.
    static func ownGroups() -> [String] {
        let count = getgroups(0, nil)
        guard count > 0 else { return [] }
        var gids = [gid_t](repeating: 0, count: Int(count))
        guard getgroups(count, &gids) > 0 else { return [] }

        var names: Set<String> = []
        for gid in gids {
            guard let entry = getgrgid(gid) else { continue }
            names.insert(String(cString: entry.pointee.gr_name))
        }
        return names.sorted()
    }

    static var currentUser: String { NSUserName() }
}
