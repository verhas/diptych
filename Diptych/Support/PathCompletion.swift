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
    static func complete(_ text: String, base: String) -> String? {
        let (directory, partial) = split(text, base: base)
        let names = candidates(in: directory, matching: partial)
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
        // inside it rather than re-completing the name.
        let separator = names.count == 1 ? "/" : ""
        let prefix = text.hasSuffix("/") ? text : String(text.dropLast(partial.count))
        let result = prefix + completed + separator
        return result == text ? nil : result
    }

    /// Just the part that would be added, for drawing ahead of the cursor.
    static func suffix(for text: String, base: String) -> String {
        guard let completed = complete(text, base: base),
              completed.hasPrefix(text) else { return "" }
        return String(completed.dropFirst(text.count))
    }

    /// Whether what is typed names a directory that exists. Drives the red text
    /// -- a path being typed is usually invalid, so this is only consulted for
    /// text the user has finished with, or as a running hint.
    static func isDirectory(_ text: String, base: String) -> Bool {
        let resolved = resolve(text, base: base)
        guard !resolved.isEmpty else { return false }
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &directory)
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

    private static func candidates(in directory: String, matching partial: String) -> [String] {
        let fm = FileManager()
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }

        // Case-insensitively, because the file system usually is -- but the
        // completion carries the name's real spelling.
        let wanted = partial.lowercased()
        return names.filter { name in
            guard name.lowercased().hasPrefix(wanted) else { return false }
            // A hidden entry only shows up once its dot has been typed, which
            // is again what a shell does.
            guard !name.hasPrefix(".") || partial.hasPrefix(".") else { return false }

            var directoryFlag: ObjCBool = false
            let path = (directory as NSString).appendingPathComponent(name)
            return fm.fileExists(atPath: path, isDirectory: &directoryFlag)
                && directoryFlag.boolValue
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
