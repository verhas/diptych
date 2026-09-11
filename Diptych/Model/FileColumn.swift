import Foundation
import SwiftUI

/// A column a pane can show.
///
/// Adding a case here is the whole job of adding a column: the settings list is
/// built from `allCases`, the loader asks each enabled column which resource
/// keys it needs, and the table and the comparator switch on it.
enum FileColumn: String, Codable, CaseIterable, Identifiable, Sendable {
    case name
    case size
    case kind
    case modified
    case created
    case added
    case fileExtension
    case permissions
    case owner
    case group
    case tags
    case git

    var id: String { rawValue }

    var title: String {
        switch self {
        case .git:           "Git"
        case .name:          "Name"
        case .size:          "Size"
        case .kind:          "Kind"
        case .modified:      "Date Modified"
        case .created:       "Date Created"
        case .added:         "Date Added"
        case .fileExtension: "Extension"
        case .permissions:   "Permissions"
        case .owner:         "Owner"
        case .group:         "Group"
        case .tags:          "Tags"
        }
    }

    /// The name column identifies the row; it cannot be turned off or moved.
    var isRemovable: Bool { self != .name }

    /// Only the keys the enabled columns actually need are prefetched, so
    /// switching on Permissions costs a little and leaving it off costs nothing.
    var resourceKeys: [URLResourceKey] {
        switch self {
        case .name:          [.nameKey, .localizedNameKey]
        case .size:          [.fileSizeKey]
        case .kind:          [.localizedTypeDescriptionKey]
        case .modified:      [.contentModificationDateKey]
        case .created:       [.creationDateKey]
        case .added:         [.addedToDirectoryDateKey]
        case .fileExtension: []                       // derived from the name
        case .permissions:   [.fileSecurityKey]
        case .owner:         [.fileSecurityKey]
        case .group:         [.fileSecurityKey]
        case .tags:          [.tagNamesKey]
        // Git state does not come from the file system at all -- it is filled
        // in after the listing, from one status call per repository.
        case .git:           []
        }
    }

    var width: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        switch self {
        case .name:          (160, 300, 10_000)
        case .size:          (70, 90, 140)
        case .kind:          (90, 140, 260)
        case .modified,
             .created,
             .added:         (120, 150, 220)
        case .fileExtension: (60, 80, 140)
        case .permissions:   (90, 100, 130)
        case .owner:         (80, 110, 180)
        case .group:         (80, 110, 180)
        case .tags:          (80, 130, 260)
        case .git:           (70, 90, 160)
        }
    }

    /// Numeric and date columns read better right-aligned.
    var isTrailingAligned: Bool { self == .size }
}

/// Global, cross-pane configuration.
struct Configuration: Codable, Equatable {

    /// Every column, in display order -- including the ones switched off, so
    /// toggling a column back on returns it to where it was rather than to the
    /// end.
    var columnOrder: [FileColumn] = FileColumn.allCases
    var enabledColumns: Set<FileColumn> = [.name, .size, .modified]

    /// Column widths in points, keyed by column. Measured and applied through
    /// AppKit: SwiftUI's own `TableColumnCustomization` records widths but --
    /// verified by experiment -- never restores them for a table whose columns
    /// come from `TableColumnForEach`.
    var columnWidths: [String: Double] = [:]

    /// Sidebar favourites, as paths. Global: a favourite is a favourite in
    /// every window.
    var favourites: [String] = []

    /// The pane font. An empty name means the system font, which is what most
    /// people want and what the panes always used.
    ///
    /// Only the *panes* follow this. Settings, the sidebar, dialogs and the
    /// function bar are chrome and stay at their own sizes -- scaling those too
    /// would be a different feature, and a worse-looking one.
    var fontName = ""
    var fontSize = 11.0

    /// The range the zoom commands and the settings stepper both obey. Below
    /// about 8 the icons stop being recognisable; above about 28 a pane holds
    /// too few rows to be a file manager.
    static let fontSizes = 8.0 ... 28.0
    static let defaultFontSize = 11.0

    /// Which buttons the toolbar shows, in which order, and on which side.
    var toolbar: [ToolbarSlot] = Configuration.defaultToolbar

    /// Version tracking. Off by default: it runs a program Diptych did not
    /// install and cannot vouch for, so switching it on is a decision the user
    /// makes rather than one made for them.
    var gitEnabled = false
    /// An explicit path, when the found one is not the wanted one. Empty means
    /// "look in the usual places".
    var gitPath = ""

    /// Check with the server the first time a tracked folder with changes in it
    /// is opened after Diptych starts.
    ///
    /// Off by default, and it must stay a decision the user makes: it is the
    /// only thing in Diptych that reaches the network without being asked, and
    /// on a slow connection or a large repository it is not instant.
    var gitCheckOnOpen = false

    /// When a send is refused for being behind, catch up and send anyway.
    ///
    /// On by default, because a push is refused whenever the shared copy has
    /// moved on *at all* -- even when nobody went near the files being sent --
    /// and stopping for that is a question with no decision in it.
    ///
    /// Off for anyone who would rather nothing arrived unasked: "I wanted to
    /// send one file, not update my whole folder" is a fair thing to want, and
    /// then the send stops and offers the update instead of taking it.
    var gitUpdateWhenSending = true

    /// Directories above files, rather than everything in one sequence.
    ///
    /// On by default because that is what every file manager does and what the
    /// keyboard expects -- but it is a preference, not a law, and sorting by
    /// size or date is more useful when the two kinds are not separated.
    var foldersFirst = true

    /// One switch for all of them, on top of the per-event choices.
    var soundsEnabled = true

    /// Sounds played after an operation finishes. "None" is silence.
    var copySound = "Pop"
    var moveSound = "Tink"
    var trashSound = "Glass"

    /// The columns a pane actually draws.
    var columns: [FileColumn] {
        let ordered = columnOrder.filter { $0 != .name && enabledColumns.contains($0) }
        return [.name] + ordered
    }

    enum CodingKeys: String, CodingKey {
        case columnOrder, enabledColumns, columnWidths, favourites
        case soundsEnabled, copySound, moveSound, trashSound
        case fontName, fontSize, foldersFirst, gitEnabled, gitPath, gitCheckOnOpen, gitUpdateWhenSending, toolbar
    }

    init() {}

    /// Every key optional. The synthesized decoder throws when a key is
    /// missing, which would quietly discard a whole hand-edited config the
    /// first time a new setting is added.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        columnOrder = (try? container.decode([FileColumn].self, forKey: .columnOrder))
            ?? FileColumn.allCases
        enabledColumns = (try? container.decode(Set<FileColumn>.self, forKey: .enabledColumns))
            ?? [.name, .size, .modified]
        columnWidths = (try? container.decode([String: Double].self, forKey: .columnWidths))
            ?? [:]
        favourites = (try? container.decode([String].self, forKey: .favourites)) ?? []
        foldersFirst = (try? container.decode(Bool.self, forKey: .foldersFirst)) ?? true
        toolbar = (try? container.decode([ToolbarSlot].self, forKey: .toolbar))
            ?? Configuration.defaultToolbar
        gitEnabled = (try? container.decode(Bool.self, forKey: .gitEnabled)) ?? false
        gitPath = (try? container.decode(String.self, forKey: .gitPath)) ?? ""
        gitCheckOnOpen = (try? container.decode(Bool.self, forKey: .gitCheckOnOpen)) ?? false
        gitUpdateWhenSending =
            (try? container.decode(Bool.self, forKey: .gitUpdateWhenSending)) ?? true
        fontName = (try? container.decode(String.self, forKey: .fontName)) ?? ""
        // Clamped on the way in: config.json is hand-editable, and a font size
        // of 0 or 4000 would render the panes unusable with no way back.
        let size = (try? container.decode(Double.self, forKey: .fontSize)) ?? Self.defaultFontSize
        fontSize = min(max(size, Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
        soundsEnabled = (try? container.decode(Bool.self, forKey: .soundsEnabled)) ?? true
        copySound = (try? container.decode(String.self, forKey: .copySound)) ?? "Pop"
        moveSound = (try? container.decode(String.self, forKey: .moveSound)) ?? "Tink"
        trashSound = (try? container.decode(String.self, forKey: .trashSound)) ?? "Glass"
    }

    /// Repairs anything a hand-edited file or a newer build might have left
    /// inconsistent: unknown cases dropped, new cases appended, name pinned.
    mutating func normalise() {
        var order = columnOrder.filter { $0 != .name }
        for column in FileColumn.allCases where column != .name && !order.contains(column) {
            order.append(column)
        }
        columnOrder = [.name] + order
        enabledColumns.insert(.name)
    }
}
