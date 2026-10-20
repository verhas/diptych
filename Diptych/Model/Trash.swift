import Foundation

/// Where a volume keeps its Trash, and whether a folder is one -- what the
/// sidebar's trash button opens and what the pane shows an Original Location
/// column for.
enum Trash {

    private static var fm: FileManager { .default }

    /// The home Trash -- `~/.Trash`, where the startup volume's deletions go.
    static var home: URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    }

    /// Where the Trash is for the volume mounted at `mount`, whether or not it
    /// exists yet: the home Trash for the startup volume, else
    /// `<mount>/.Trashes/<uid>`.
    static func url(forVolumeAt mount: URL) -> URL {
        if mount.standardizedFileURL.path == "/" { return home }
        return mount.appendingPathComponent(".Trashes").appendingPathComponent("\(getuid())")
    }

    /// The Trash for the volume at `mount`, or nil when it is not there --
    /// nothing has been trashed on that volume yet.
    static func directory(forVolumeAt mount: URL) -> URL? {
        let candidate = url(forVolumeAt: mount)
        return fm.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Whether `url` is a Trash folder -- the home one, or a volume's
    /// `.Trashes/<uid>`.
    static func isTrash(_ url: URL) -> Bool {
        if url.standardizedFileURL.path == home.standardizedFileURL.path { return true }
        let parts = url.standardizedFileURL.pathComponents
        // …/.Trashes/<digits>
        return parts.count >= 2
            && parts[parts.count - 2] == ".Trashes"
            && !parts[parts.count - 1].isEmpty
            && parts[parts.count - 1].allSatisfy(\.isNumber)
    }
}
