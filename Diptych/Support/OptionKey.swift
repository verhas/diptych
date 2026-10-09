import AppKit
import Observation

/// Whether Option is held down right now, for views that change while it is --
/// the path bar turns into links to the folders above.
///
/// SwiftUI has no modifier-key state of its own. A local monitor sees every
/// change while Diptych is active; one that happens while another app is in
/// front is not seen, so the state is read again from the keyboard whenever
/// Diptych comes back -- otherwise Option released in another app would leave
/// the links up.
@MainActor
@Observable
final class OptionKey {

    static let shared = OptionKey()

    private(set) var isDown = false

    @ObservationIgnored private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(event.modifierFlags)
            return event
        }
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update(NSEvent.modifierFlags) }
            }
        }
    }

    /// Option alone or with Shift; with Command or Control it is a shortcut
    /// being typed, not a request for the links.
    private func update(_ flags: NSEvent.ModifierFlags) {
        let down = flags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.shift, .capsLock, .numericPad, .function]) == .option
        if down != isDown { isDown = down }
    }
}
