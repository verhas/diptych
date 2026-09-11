import SwiftUI

/// A button the toolbar can show, and where it sits.
///
/// Configurable because the set has grown -- one pane, refresh, swap, hidden
/// files, and now sending and getting -- and six buttons is the point at which
/// one person's essentials are another's clutter.
enum ToolbarButton: String, Codable, CaseIterable, Identifiable, Sendable {
    // Panes
    case singlePane
    case refresh
    case swapPanes
    case sameFolder
    case hiddenFiles

    // Going places
    case back
    case forward
    case enclosingFolder
    case goToFolder

    // Making things
    case newFolder
    case newFile

    // Acting on the selection
    case view
    case getInfo
    case rename
    case copyToOther
    case moveToOther
    case permissions
    case trash
    case revealInFinder
    case openTerminal
    case copyPrompt

    // Text size
    case biggerText
    case smallerText
    case actualSize

    // Version tracking
    case sendWork
    case getLatest
    case checkForChanges

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singlePane:      "One Pane"
        case .refresh:         "Refresh"
        case .swapPanes:       "Swap Panes"
        case .sameFolder:      "Same Folder in Other Pane"
        case .hiddenFiles:     "Hidden Files"
        case .back:            "Back"
        case .forward:         "Forward"
        case .enclosingFolder: "Enclosing Folder"
        case .goToFolder:      "Go to Folder"
        case .newFolder:       "New Folder"
        case .newFile:         "New File"
        case .view:            "View"
        case .getInfo:         "Get Info"
        case .rename:          "Rename"
        case .copyToOther:     "Copy to Other Pane"
        case .moveToOther:     "Move to Other Pane"
        case .permissions:     "Change Permissions"
        case .trash:           "Move to Trash"
        case .revealInFinder:  "Reveal in Finder"
        case .openTerminal:    "Open Terminal Here"
        case .copyPrompt:      "Copy Prompt"
        case .biggerText:      "Bigger Text"
        case .smallerText:     "Smaller Text"
        case .actualSize:      "Actual Size"
        case .sendWork:        "Send My Work"
        case .getLatest:       "Get the Latest"
        case .checkForChanges: "Check for Changes"
        }
    }

    /// The icon. Chosen to match the menu wording rather than the underlying
    /// operation, since the toolbar is read at a glance and a wrong-but-pretty
    /// glyph is worse than a plain one.
    var symbol: String {
        switch self {
        case .singlePane:      "rectangle"
        case .refresh:         "arrow.clockwise"
        case .swapPanes:       "arrow.left.arrow.right"
        case .sameFolder:      "equal.square"
        case .hiddenFiles:     "eye"
        case .back:            "chevron.left"
        case .forward:         "chevron.right"
        case .enclosingFolder: "arrow.up"
        case .goToFolder:      "magnifyingglass"
        case .newFolder:       "folder.badge.plus"
        case .newFile:         "doc.badge.plus"
        case .view:            "eye.circle"
        case .getInfo:         "info.circle"
        case .rename:          "pencil"
        case .copyToOther:     "doc.on.doc"
        case .moveToOther:     "arrow.right.doc.on.clipboard"
        case .permissions:     "lock"
        case .trash:           "trash"
        case .revealInFinder:  "finder"
        case .openTerminal:    "terminal"
        case .copyPrompt:      "text.bubble"
        case .biggerText:      "textformat.size.larger"
        case .smallerText:     "textformat.size.smaller"
        case .actualSize:      "textformat.size"
        case .sendWork:        "arrow.up.circle"
        case .getLatest:       "arrow.down.circle"
        case .checkForChanges: "arrow.triangle.2.circlepath"
        }
    }

    /// What it is for, in the same words the menu uses.
    var explanation: String {
        switch self {
        case .singlePane:      "Show one pane instead of two"
        case .refresh:         "Re-read both panes"
        case .swapPanes:       "Swap the left and right panes"
        case .sameFolder:      "Show this folder in the other pane too"
        case .hiddenFiles:     "Show files whose names begin with a dot"
        case .back:            "Back to where you were"
        case .forward:         "Forward again"
        case .enclosingFolder: "Up one folder"
        case .goToFolder:      "Type a path to go to"
        case .newFolder:       "Create a folder here"
        case .newFile:         "Create an empty file here"
        case .view:            "Preview the selected file"
        case .getInfo:         "Everything about the selected file"
        case .rename:          "Rename the selected file"
        case .copyToOther:     "Copy the selection to the other pane"
        case .moveToOther:     "Move the selection to the other pane"
        case .permissions:     "Change who may read and write it"
        case .trash:           "Move the selection to the Trash"
        case .revealInFinder:  "Show the selection in the Finder"
        case .openTerminal:    "Open a Terminal window here"
        case .copyPrompt:      "Copy a description of the selection, to ask an LLM"
        case .biggerText:      "Larger text in the panes"
        case .smallerText:     "Smaller text in the panes"
        case .actualSize:      "Back to the standard text size"
        case .sendWork:        "Save your changes and send them to the shared copy"
        case .getLatest:       "Bring in what other people have sent"
        case .checkForChanges: "Ask the shared copy what is waiting, without changing anything"
        }
    }

    /// Only meaningful in a tracked folder, so these are left out of the
    /// toolbar entirely when the folder is not one -- a permanently greyed
    /// button teaches nothing.
    var needsRepository: Bool {
        self == .sendWork || self == .getLatest || self == .checkForChanges
    }

    var isOnByDefault: Bool {
        switch self {
        case .singlePane, .refresh, .swapPanes, .sameFolder, .hiddenFiles,
             .sendWork, .getLatest, .checkForChanges:
            true
        default:
            false
        }
    }

    var defaultSide: ToolbarSide {
        switch self {
        case .sendWork, .getLatest, .checkForChanges: .right
        default:                    .left
        }
    }
}

/// Where a button sits. Three groups, because that is what a macOS toolbar
/// actually offers: leading, centre and trailing.
enum ToolbarSide: String, Codable, CaseIterable, Identifiable, Sendable {
    case left
    case middle
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left:   "Left"
        case .middle: "Middle"
        case .right:  "Right"
        }
    }
}

/// One row of the toolbar settings: a button, whether it is shown, and where.
struct ToolbarSlot: Codable, Equatable, Identifiable, Sendable {
    var button: ToolbarButton
    var isShown: Bool
    var side: ToolbarSide

    var id: String { button.rawValue }
}

extension Configuration {
    /// The default arrangement: what the toolbar held before it was
    /// configurable, with the two new buttons on the right where the actions
    /// that reach outside the app belong.
    /// Everything is *available*; only a few are on. A toolbar of twenty-six
    /// buttons is not a toolbar, it is a wall -- so the default is what was
    /// there before plus the two version-tracking buttons and Same Folder,
    /// and the rest are switched on by whoever wants them.
    static let defaultToolbar: [ToolbarSlot] = ToolbarButton.allCases.map { button in
        ToolbarSlot(button: button, isShown: button.isOnByDefault, side: button.defaultSide)
    }

    /// The saved arrangement, repaired: a button added in a later version is
    /// appended rather than lost, and one that no longer exists is dropped.
    /// Without this a config written by an older build would silently hide
    /// whatever came next.
    var toolbarSlots: [ToolbarSlot] {
        var slots = toolbar.filter { slot in ToolbarButton.allCases.contains(slot.button) }
        for button in ToolbarButton.allCases where !slots.contains(where: { $0.button == button }) {
            let fallback = Configuration.defaultToolbar.first { $0.button == button }
            slots.append(fallback ?? ToolbarSlot(button: button, isShown: true, side: .right))
        }
        return slots
    }

    func toolbarButtons(on side: ToolbarSide) -> [ToolbarButton] {
        toolbarSlots.filter { $0.isShown && $0.side == side }.map(\.button)
    }
}
