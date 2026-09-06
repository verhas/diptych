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
    var tags: [String] = []

    /// `Identifiable` requires `id`. A URL is unique within a directory listing,
    /// so we get identity for free instead of inventing a synthetic key.
    var id: URL { url }

    /// True when a double-click / Return should navigate *into* this row.
    /// Packages are directories on disk but must behave like files in the UI.
    var isEnterable: Bool { isParent || (isDirectory && !isPackage) }

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
