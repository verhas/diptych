import SwiftUI
import AppKit

/// One horizontal scrollbar driving two columns at once.
///
/// The two halves of a comparison hold different text, so they cannot share a
/// scroll view the way they share a row: scrolling one container sideways
/// slides a whole pane off the screen, which is not a synchronised scroll but
/// a broken layout. What they share is an *offset* -- both panes stay where
/// they are, and the text inside each moves by the same amount.
///
/// `NSScroller` rather than anything drawn here: it is the real control, it
/// looks and behaves like every other scrollbar on the machine, and it handles
/// dragging, clicking in the track and the trackpad without any of that having
/// to be reinvented.
struct SharedScroller: NSViewRepresentable {

    @Binding var offset: CGFloat
    /// How wide the text is, and how much of it can be seen at once.
    let content: CGFloat
    let viewport: CGFloat

    private var travel: CGFloat { max(content - viewport, 0) }

    func makeNSView(context: Context) -> NSScroller {
        let scroller = WheelScroller()
        scroller.scrollerStyle = .legacy
        scroller.controlSize = .small
        scroller.target = context.coordinator
        scroller.action = #selector(Coordinator.moved(_:))
        scroller.onWheel = { context.coordinator.wheel($0) }
        return scroller
    }

    func updateNSView(_ scroller: NSScroller, context: Context) {
        context.coordinator.parent = self
        scroller.isEnabled = travel > 0
        scroller.knobProportion = content > 0 ? min(viewport / content, 1) : 1
        scroller.doubleValue = travel > 0 ? Double(offset / travel) : 0
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {

        var parent: SharedScroller

        init(_ parent: SharedScroller) { self.parent = parent }

        @objc func moved(_ scroller: NSScroller) {
            let travel = parent.travel
            guard travel > 0 else { return }

            switch scroller.hitPart {
            // Dragging the knob, which reports its position directly.
            case .knob, .knobSlot:
                parent.offset = CGFloat(scroller.doubleValue) * travel
            // Clicking the track or an arrow moves by a step, as everywhere
            // else on the system.
            case .decrementPage:
                parent.offset = max(parent.offset - parent.viewport * 0.9, 0)
            case .incrementPage:
                parent.offset = min(parent.offset + parent.viewport * 0.9, travel)
            case .decrementLine:
                parent.offset = max(parent.offset - 20, 0)
            case .incrementLine:
                parent.offset = min(parent.offset + 20, travel)
            default:
                break
            }
        }

        func wheel(_ delta: CGFloat) {
            let travel = parent.travel
            guard travel > 0 else { return }
            parent.offset = min(max(parent.offset - delta, 0), travel)
        }
    }
}

/// A scroller that also answers the trackpad.
///
/// `NSScroller` ignores scroll wheel events by default, so a two-finger swipe
/// over the bar did nothing -- which on a Mac is how most people would try to
/// scroll first.
private final class WheelScroller: NSScroller {

    var onWheel: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaX
            : event.scrollingDeltaX * 10
        guard delta != 0 else { return }
        onWheel?(delta)
    }
}
