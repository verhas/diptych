import AppKit

/// Diptych ▸ About Diptych: macOS's own About panel -- icon, name, version --
/// with the slogan and the website underneath.
@MainActor
enum AboutPanel {

    static let slogan = "Diptych \u{2014} pronounced \u{2018}deep tech\u{2019} \u{2014} "
        + "a two-pane AI driven file manager for macOS."

    static let website = URL(string: "https://verhas.github.io/diptych/")!

    static func show() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private static var credits: NSAttributedString {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.paragraphSpacing = 6
        let text = NSMutableAttributedString(string: slogan + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centred,
        ])
        text.append(NSAttributedString(string: "verhas.github.io/diptych", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .link: website,
            .paragraphStyle: centred,
        ]))
        return text
    }
}
