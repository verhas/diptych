import AppKit
import SwiftUI

/// A native Share button that puts up the system share sheet -- Mail, Messages,
/// AirDrop, Notes and whatever else offers itself.
///
/// `NSSharingServicePicker` has to be anchored to a real view, which SwiftUI's
/// own controls do not hand out; wrapping an `NSButton` is the clean way to get
/// an anchor without the deprecated service-enumeration API.
struct ShareButton: NSViewRepresentable {

    let items: [URL]
    let title: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator,
                              action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        context.coordinator.items = items
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        context.coordinator.items = items
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSSharingServicePickerDelegate {
        var items: [URL] = []

        @objc func share(_ sender: NSButton) {
            guard !items.isEmpty else { return }
            let picker = NSSharingServicePicker(items: items)
            picker.delegate = self
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
