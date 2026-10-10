import Foundation

/// Sorts rows by any column.
///
/// A single comparator type rather than a `KeyPathComparator` per column,
/// because the table's columns are built dynamically from configuration and
/// SwiftUI needs one concrete comparator type across all of them.
struct FileComparator: SortComparator, Hashable {

    var column: FileColumn
    var order: SortOrder = .forward

    func compare(_ lhs: FileItem, _ rhs: FileItem) -> ComparisonResult {
        let result: ComparisonResult

        switch column {
        case .size:
            // A folder by its total as far as worked out.
            result = Self.compare(lhs.folderTotal ?? lhs.byteSize, rhs.folderTotal ?? rhs.byteSize)
        case .modified:
            result = Self.compare(lhs.modified, rhs.modified)
        case .created:
            result = Self.compare(lhs.created, rhs.created)
        case .added:
            result = Self.compare(lhs.added, rhs.added)
        case .name:
            // By folder and then name, in a flat view: a folder's files stay
            // together.
            result = lhs.relativePath.localizedStandardCompare(rhs.relativePath)
        case .taken, .digitized:
            result = Self.compare(lhs.media?.taken(column) ?? .distantPast,
                                  rhs.media?.taken(column) ?? .distantPast)
        case .iso, .aperture, .shutter, .focal, .focal35, .dimensions, .megapixels, .duration,
             .altitude, .rating:
            // Nothing known first, as an empty date is.
            result = Self.compare(lhs.media?.number(column) ?? -.infinity,
                                  rhs.media?.number(column) ?? -.infinity)
        case .kind, .fileExtension, .permissions, .owner, .group, .tags, .git, .format,
             .camera, .lens, .software, .artist, .copyright, .imageDescription, .location,
             .city, .state, .country:
            // localizedStandardCompare is the Finder-ish one: case-insensitive,
            // and "file10" sorts after "file9" rather than before it.
            result = lhs.text(for: column).localizedStandardCompare(rhs.text(for: column))
        }

        guard result != .orderedSame else { return .orderedSame }
        return order == .forward ? result : (result == .orderedAscending ? .orderedDescending
                                                                         : .orderedAscending)
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}
