import Foundation

/// One row in a pane.
///
/// Swift note: this is a `struct`, i.e. a *value* type. Assigning it copies it.
/// That is the default in Swift and the opposite of Java, where everything you
/// declare with `class` is a reference. Value semantics are what make it safe to
/// hand an array of these from a background actor to the main actor: nobody can
/// mutate it behind your back, which is why `Sendable` conformance below is free.
struct FileItem: Identifiable, Hashable, Sendable {

    /// `..` — the synthetic row that walks up to the parent directory.
    let isParent: Bool

    let url: URL
    let name: String
    /// Effective directory-ness: true for a symlink that points at a directory.
    /// The raw `.isDirectoryKey` says false for such a link, which used to make
    /// Return and double-click hand it to NSWorkspace -- opening it in Finder
    /// and shoving this app behind every other window.
    let isDirectory: Bool
    /// `.app`, `.rtfd`, ... — a directory macOS shows as a single item.
    let isPackage: Bool
    let isSymlink: Bool
    /// Only meaningful for non-directories: every directory carries the execute
    /// bit, since that is what makes it traversable.
    let isExecutable: Bool
    let byteSize: Int64
    let modified: Date

    // Populated only when the matching column is switched on; the loader does
    // not pay for metadata nobody is showing.
    var created: Date = .distantPast
    var added: Date = .distantPast
    var kind: String = ""
    var owner: String = ""
    var group: String = ""
    var permissions: String = ""
    /// The numeric mode behind `permissions`, so the editor starts from the
    /// bits rather than re-parsing the rendered characters.
    var mode: mode_t = 0
    var tags: [String] = []
    /// Where a symbolic link points, exactly as stored -- which may be relative.
    /// Empty for everything else. Read by the loader, because a `readlink` per
    /// symlink is cheap and doing it during a redraw is not.
    var linkTarget: String = ""
    /// Filled in after the listing, once the repository has been asked.
    var gitState: GitState = .clean
    /// Everything found at or under this row, strongest first. One entry for a
    /// file; a folder may hold several.
    var gitStates: [GitState] = []

    /// `Identifiable` requires `id`. A URL is unique within a directory listing,
    /// so we get identity for free instead of inventing a synthetic key.
    var id: URL { url }

    /// `.app` specifically, not every package: a `.rtfd` or a `.pages`
    /// document still opens in its own app, as any other document does --
    /// only an application itself is something to walk into rather than run.
    var isApplication: Bool {
        isPackage && url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }

    /// True when a double-click / Return should navigate *into* this row.
    /// Most packages are directories on disk that must behave like files in
    /// the UI -- but an application is the one package people also want to
    /// browse, and launching it is "Run App" in the row's own menu now,
    /// deliberate rather than the default action.
    var isEnterable: Bool { isParent || (isDirectory && (!isPackage || isApplication)) }

    var sizeText: String {
        if isParent { return "" }
        if isDirectory && !isPackage { return "--" }
        return ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    var modifiedText: String {
        if isParent { return "" }
        return FileItem.dateFormat.string(from: modified)
    }

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    /// The first tag that carries a colour, which is what tints the row.
    /// Finder shows every tag as a dot; a whole-row tint can only show one.
    var tagColourName: String? {
        tags.first { FinderTag.coloured.contains($0) }
    }

    /// What a given column shows for this row.
    func text(for column: FileColumn) -> String {
        if isParent { return column == .name ? ".." : "" }
        switch column {
        case .name:          return name
        case .size:          return sizeText
        case .kind:          return kind
        case .modified:      return Self.dateText(modified)
        case .created:       return Self.dateText(created)
        case .added:         return Self.dateText(added)
        case .fileExtension: return (name as NSString).pathExtension
        case .permissions:   return permissions
        case .owner:         return owner
        case .group:         return group
        case .tags:          return tags.joined(separator: ", ")
        case .git:           return gitStates.map(\.title).joined(separator: ", ")
        }
    }

    private static func dateText(_ date: Date) -> String {
        date == .distantPast ? "" : dateFormat.string(from: date)
    }

    static func parent(of directory: URL) -> FileItem {
        FileItem(isParent: true,
                 url: directory.deletingLastPathComponent(),
                 name: "..",
                 isDirectory: true,
                 isPackage: false,
                 isSymlink: false,
                 isExecutable: false,
                 byteSize: 0,
                 modified: .distantPast)
    }
}
