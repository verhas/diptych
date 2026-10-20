import Foundation

/// The right-click menu entries a person can switch off, so the menu the many
/// file tools have grown does not get in the way. Everything is on by default;
/// a preset turns a named set on and the rest off.
///
/// Core navigation and editing -- Open, Copy, Cut, Paste, New, Rename, Move to
/// Trash -- is never in here: a file manager whose menu could lose Paste is not
/// one to trust. These are the tools around that core.
enum MenuItem: String, CaseIterable, Identifiable, Sendable {
    case getInfo
    case findSiblings
    case findDuplicates
    case previousVersions
    case diskUsage
    case archive
    case checksum
    case splitJoin
    case optimize
    case image
    case video
    case run
    case edit            // Text Edit / Bin Edit
    case scripts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .getInfo:          "Get Info"
        case .findSiblings:     "Find Sibling Names"
        case .findDuplicates:   "Find Duplicates"
        case .previousVersions: "Previous Versions"
        case .diskUsage:        "Disk Usage"
        case .archive:          "Archive"
        case .checksum:         "Checksum"
        case .splitJoin:        "Split File / Join Parts"
        case .optimize:         "Optimize File Size"
        case .image:            "Image tools"
        case .video:            "Video tools"
        case .run:              "Run / Run App"
        case .edit:             "Text Edit / Bin Edit"
        case .scripts:          "Scripts"
        }
    }

    /// A word on who tends to want it, for the settings list.
    var note: String {
        switch self {
        case .getInfo:          "The full inspector window."
        case .findSiblings:     "A file's other hard-link names."
        case .findDuplicates:   "Files holding the same bytes."
        case .previousVersions: "Earlier versions from APFS snapshots."
        case .diskUsage:        "The treemap of what fills a folder."
        case .archive:          "Create, open, extract, recover password."
        case .checksum:         "Create and check MD5/SHA sums."
        case .splitJoin:        "Cut a file into parts and rejoin them."
        case .optimize:         "Make pictures and PDFs smaller."
        case .image:            "Rotate, convert, EXIF, make PDF."
        case .video:            "Edit video metadata."
        case .run:              "Run a program, or launch an app."
        case .edit:             "Open in Diptych's text or hex editor."
        case .scripts:          "Your own scripts."
        }
    }
}

/// A named set of menu entries to show -- the rest switched off.
struct MenuPreset: Identifiable, Sendable {
    let name: String
    let shown: Set<MenuItem>
    var id: String { name }

    /// What the preset hides: everything not shown.
    var hidden: Set<String> { Set(MenuItem.allCases.map(\.id)).subtracting(shown.map(\.id)) }

    static let everything = MenuPreset(name: "Everything", shown: Set(MenuItem.allCases))

    static let developer = MenuPreset(name: "Developer", shown: [
        .getInfo, .findSiblings, .findDuplicates, .previousVersions, .diskUsage,
        .archive, .checksum, .splitJoin, .run, .edit, .scripts,
    ])

    static let contentCreator = MenuPreset(name: "Content Creator", shown: [
        .getInfo, .findDuplicates, .previousVersions, .diskUsage, .archive,
        .optimize, .image, .video,
    ])

    static let minimal = MenuPreset(name: "Minimal", shown: [.getInfo, .diskUsage])

    static let all: [MenuPreset] = [everything, developer, contentCreator, minimal]
}
