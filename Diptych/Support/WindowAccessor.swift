import SwiftUI
import AppKit

/// Hands the enclosing `NSWindow` back to SwiftUI code.
///
/// SwiftUI has no "which window am I in" API, but a file manager needs it: the
/// key router has to tell one window's model from another's. An empty
/// `NSViewRepresentable` is the standard way to reach the AppKit window behind
/// a SwiftUI view.
struct WindowAccessor: NSViewRepresentable {

    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The view has no window yet during makeNSView; it gets one when it is
        // added to the hierarchy, one runloop turn later.
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(view.window) }
    }
}

/// Lets the menu bar reach the model of whichever window is focused.
///
/// `.commands` is declared once for the whole scene, but each window now owns
/// its own `AppModel`. A focused value is SwiftUI's channel from "the window
/// that has focus" up to scene-level code.
struct AppModelFocusKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelFocusKey.self] }
        set { self[AppModelFocusKey.self] = newValue }
    }
}
