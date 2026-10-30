import Foundation

/// Shell-style completion for the path bar.
///
/// The rules are the ones a shell uses, because that is what the bar is for:
/// complete the last component against the directory holding it, extend as far
/// as every candidate agrees, and stop where they diverge. Only directories are
/// offered -- the bar navigates, and a file path is refused on commit anyway.
///
/// Everything takes a `base`, the directory the pane is showing, and anything
/// not starting with `/` or `~` is resolved against it. Without that, `../`
/// resolved against the *process's* working directory -- which for an app
/// launched from the Finder is `/` -- so typing `../` went to the root of the
/// disk rather than to the parent of where you were standing.
enum PathCompletion {

    /// The absolute path some typed text names, given where the pane is.
    static func resolve(_ text: String, base: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("~") {
            return ((trimmed as NSString).expandingTildeInPath as NSString).standardizingPath
        }
        if trimmed.hasPrefix("/") {
            return (trimmed as NSString).standardizingPath
        }
        // Relative, including "." and "..", which is what makes typing a child
        // name straight after Command-G work.
        let joined = (base as NSString).appendingPathComponent(trimmed)
        return (joined as NSString).standardizingPath
    }

    /// The completed path, or nil when nothing matches or the text is already
    /// complete. Returned in the form it was typed: relative text stays
    /// relative, so completing does not rewrite `../Doc` into an absolute path
    /// under the cursor.
    ///
    /// `root`, for a folder on a server, is the folder its listing is kept in
    /// here: what is typed is the server's own path, and it is looked up under
    /// `root`. Nil for this Mac's disk.
    static func complete(_ text: String, base: String, root: String? = nil) -> String? {
        let (directory, partial) = split(text, base: base)
        let names = candidates(in: directory, matching: partial, root: root)
        guard !names.isEmpty else { return nil }

        // The longest prefix every candidate shares, which is exactly how far a
        // shell moves the cursor before it stops and waits for another letter.
        var completed = names[0]
        for name in names.dropFirst() {
            completed = String(commonPrefix(completed, name))
            if completed.count <= partial.count { break }
        }
        guard completed.count > partial.count || names.count == 1 else { return nil }

        // A lone directory gets its separator: the next Tab then completes
        // inside it rather than re-completing the name. A file is where the
        // path ends, so it gets none.
        let separator = names.count == 1
            && isDirectory((directory as NSString).appendingPathComponent(names[0]), base: "/", root: root)
            ? "/" : ""
        let prefix = text.hasSuffix("/") ? text : String(text.dropLast(partial.count))
        let result = prefix + completed + separator
        return result == text ? nil : result
    }

    /// Just the part that would be added, for drawing ahead of the cursor.
    static func suffix(for text: String, base: String, root: String? = nil) -> String {
        guard let completed = complete(text, base: base, root: root),
              completed.hasPrefix(text) else { return "" }
        return String(completed.dropFirst(text.count))
    }

    /// Whether what is typed names something that is there -- a folder, or a
    /// file, which the bar now opens in its folder. Drives the red text.
    static func exists(_ text: String, base: String, root: String? = nil) -> Bool {
        let resolved = resolve(text, base: base)
        return !resolved.isEmpty && FileManager.default.fileExists(atPath: onDisk(resolved, root: root))
    }

    /// Whether what is typed names a directory that exists.
    static func isDirectory(_ text: String, base: String, root: String? = nil) -> Bool {
        let resolved = resolve(text, base: base)
        guard !resolved.isEmpty else { return false }
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: onDisk(resolved, root: root),
                                                    isDirectory: &directory)
        return exists && directory.boolValue
    }

    // MARK: - Pieces

    /// The directory to look in, and the partial name to look for.
    private static func split(_ text: String, base: String) -> (directory: String,
                                                                partial: String) {
        // A trailing separator means "inside this", with nothing typed yet.
        if text.isEmpty || text.hasSuffix("/") {
            return (resolve(text.isEmpty ? "." : text, base: base), "")
        }

        let partial = (text as NSString).lastPathComponent
        let parent = (text as NSString).deletingLastPathComponent
        // An empty parent means a bare name, which is a child of where the pane
        // is standing -- not of the root.
        return (resolve(parent.isEmpty ? "." : parent, base: base), partial)
    }

    /// Where a path is on this Mac: as it is, or for a server under `root`.
    private static func onDisk(_ path: String, root: String?) -> String {
        guard let root else { return path }
        return (root as NSString).appendingPathComponent(path)
    }

    private static func candidates(in directory: String, matching partial: String,
                                   root: String? = nil) -> [String] {
        let fm = FileManager()
        let folder = onDisk(directory, root: root)
        // A server folder not listed yet is listed now, behind the scenes: the
        // next Tab finds what is in it.
        if root != nil, BrowserManifestStore.read(in: URL(fileURLWithPath: folder)) == nil {
            let url = URL(fileURLWithPath: folder)
            Task.detached { try? await RemoteBrowsing.refresh(url) }
            return []
        }
        guard var names = try? fm.contentsOfDirectory(atPath: folder) else { return [] }
        // The listing kept for a server folder is Diptych's, not the server's.
        if root != nil { names.removeAll { BrowserManifestStore.number(of: $0) != nil } }

        // Case-insensitively, because the file system usually is -- but the
        // completion carries the name's real spelling.
        let wanted = partial.lowercased()
        return names.filter { name in
            guard name.lowercased().hasPrefix(wanted) else { return false }
            // A hidden entry only shows up once its dot has been typed, which
            // is again what a shell does.
            guard !name.hasPrefix(".") || partial.hasPrefix(".") else { return false }

            // Files too: a file's path goes to its folder and opens it.
            return true
        }.sorted()
    }

    private static func commonPrefix(_ a: String, _ b: String) -> Substring {
        // Compared case-insensitively for the same reason as the match, but the
        // first candidate's spelling is what gets returned.
        var index = a.startIndex
        var other = b.startIndex
        while index < a.endIndex, other < b.endIndex,
              String(a[index]).lowercased() == String(b[other]).lowercased() {
            index = a.index(after: index)
            other = b.index(after: other)
        }
        return a[a.startIndex ..< index]
    }
}
