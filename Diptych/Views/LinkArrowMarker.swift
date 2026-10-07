import AppKit
import SwiftUI

/// Marks where a link's arrow sits in its row, for ClickRouter to find.
///
/// A gesture on the arrow would take part in hit testing, and every gesture
/// put in a cell so far has broken row selection. This takes part in nothing:
/// it is an empty view that refuses every hit, so clicks go to the table as
/// before, and only its frame is ever read.
///
/// It also carries the arrow's tooltip, as AppKit's own: SwiftUI's `.help` on
/// the arrow never showed in the table.
struct LinkArrowMarker: NSViewRepresentable {
    let toolTip: String

    func makeNSView(context: Context) -> LinkArrowMarkerView { LinkArrowMarkerView() }
    func updateNSView(_ view: LinkArrowMarkerView, context: Context) {
        if view.toolTip != toolTip { view.toolTip = toolTip }
    }
}

final class LinkArrowMarkerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The marker under `location` (window coordinates) inside `view`, if any.
    static func contains(_ location: NSPoint, in view: NSView) -> Bool {
        if let marker = view as? LinkArrowMarkerView, !marker.isHiddenOrHasHiddenAncestor,
           marker.bounds.contains(marker.convert(location, from: nil)) {
            return true
        }
        return view.subviews.contains { contains(location, in: $0) }
    }
}
