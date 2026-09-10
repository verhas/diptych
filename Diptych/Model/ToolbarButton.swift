import SwiftUI

/// A button the toolbar can show, and where it sits.
///
/// Configurable because the set has grown -- one pane, refresh, swap, hidden
/// files, and now sending and getting -- and six buttons is the point at which
/// one person's essentials are another's clutter.
enum ToolbarButton: String, Codable, CaseIterable, Identifiable, Sendable {
    case singlePane
    case refresh
    case swapPanes
    case hiddenFiles
    case sendWork
    case getLatest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singlePane:  "One Pane"
        case .refresh:     "Refresh"
        case .swapPanes:   "Swap Panes"
        case .hiddenFiles: "Hidden Files"
        case .sendWork:    "Send My Work"
        case .getLatest:   "Get the Latest"
        }
    }

    /// What it is for, in the same words the menu uses.
    var explanation: String {
        switch self {
        case .singlePane:  "Show one pane instead of two"
        case .refresh:     "Re-read both panes"
        case .swapPanes:   "Swap the left and right panes"
        case .hiddenFiles: "Show files whose names begin with a dot"
        case .sendWork:    "Save your changes and send them to the shared copy"
        case .getLatest:   "Bring in what other people have sent"
        }
    }

    /// Only meaningful in a tracked folder, so these are left out of the
    /// toolbar entirely when the folder is not one -- a permanently greyed
    /// button teaches nothing.
    var needsRepository: Bool { self == .sendWork || self == .getLatest }
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
    static let defaultToolbar: [ToolbarSlot] = [
        ToolbarSlot(button: .singlePane, isShown: true, side: .left),
        ToolbarSlot(button: .refresh, isShown: true, side: .left),
        ToolbarSlot(button: .swapPanes, isShown: true, side: .left),
        ToolbarSlot(button: .hiddenFiles, isShown: true, side: .left),
        ToolbarSlot(button: .getLatest, isShown: true, side: .right),
        ToolbarSlot(button: .sendWork, isShown: true, side: .right),
    ]

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
