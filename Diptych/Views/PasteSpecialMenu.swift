import SwiftUI

/// Edit ▸ Paste Special, and the same on a right-click: one item for each
/// property of the copied file that can be pasted onto the selection.
struct PasteSpecialMenu: View {

    let model: AppModel?
    /// The items a right-click is about; nil for the selection.
    var targets: [URL]? = nil
    /// Runs the paste -- a right-click first makes its rows the selection.
    var perform: ((PasteSpecial.Part) -> Void)? = nil

    var body: some View {
        Menu("Paste Special") {
            ForEach(Array(PasteSpecial.Part.menu.enumerated()), id: \.offset) { index, parts in
                if index > 0 { Divider() }
                ForEach(parts) { part in
                    Button(part.title) {
                        if let perform { perform(part) } else { model?.pasteSpecial(part) }
                    }
                    .disabled(model?.canPasteSpecial(part, targets: targets) != true)
                }
            }
        }
        .disabled(model?.canPasteSpecial(.permissions, targets: targets) != true)
    }
}
