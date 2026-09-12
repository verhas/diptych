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
        // Created with a frame that is wider than it is tall, because that is
        // how NSScroller decides whether it is a horizontal scroller or a
        // vertical one -- and it decides once. Built from a zero frame it
        // becomes a vertical scroller squeezed into a horizontal slot, which
        // is to say: nothing you can see or use.
        let scroller = WheelScroller(frame: NSRect(x: 0, y: 0, width: 400, height: 15))
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
        scroller.needsDisplay = true
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

/// Catches two-finger sideways swipes anywhere in one window.
///
/// The scrollbar answers the trackpad when the pointer is over it, which is
/// not where anybody's pointer is. The vertical scroll view in front of the
/// rows swallows the event otherwise, so it is taken before the view hierarchy
/// sees it -- and only when the swipe is more sideways than up, so ordinary
/// scrolling is left alone.
@MainActor
final class SidewaysWheel {

    private var monitor: Any?

    func watch(_ window: NSWindow?, onScroll: @escaping @MainActor (CGFloat) -> Void) {
        stop()
        guard let window else { return }
        let number = window.windowNumber

        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // NSEvent is not Sendable, so only plain values cross the boundary
            // -- the same shape the key monitor uses.
            let sideways = event.scrollingDeltaX
            let upwards = event.scrollingDeltaY
            let precise = event.hasPreciseScrollingDeltas
            let from = event.windowNumber

            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard from == number else { return false }
                // Only a swipe that is more sideways than up, so ordinary
                // scrolling is left entirely alone.
                guard abs(sideways) > abs(upwards), sideways != 0 else { return false }
                onScroll(precise ? sideways : sideways * 10)
                return true
            }
            return consumed ? nil : event
        }
    }

    /// Called when the window goes, which is the only thing that ends a
    /// comparison. A `deinit` cannot reach the monitor from outside the main
    /// actor, so the view takes it down explicitly.
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
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
