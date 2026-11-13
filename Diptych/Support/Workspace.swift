import AppKit

/// Thin wrappers over NSWorkspace -- the macOS integration points a file
/// manager needs and that have no cross-platform equivalent.
enum NSWorkspaceOpener {

    /// Hand the file to whatever app owns it, exactly as double-clicking in
    /// Finder would.
    static func open(_ url: URL) {
        Task { @MainActor in JournalViewing.opened([url]) }
        NSWorkspace.shared.open(url)
    }

    /// Reveal in Finder, with the item selected.
    ///
    /// `activateFileViewerSelecting` opens whatever is registered as the file
    /// viewer -- which, when Diptych has made itself the default (Settings ▸
    /// Behaviour), is Diptych itself, so "Reveal in Finder" would just open
    /// another Diptych. Finder is told directly instead, by name, so this
    /// always reaches the real Finder whatever the system default is. If Finder
    /// cannot be scripted (automation refused), it falls back to the system
    /// file viewer rather than doing nothing.
    static func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let items = urls.map { "POSIX file \"\(appleScriptEscaped($0.path))\"" }
            .joined(separator: ", ")
        let script = """
        tell application "Finder"
            activate
            reveal {\(items)}
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if error != nil { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    /// Escape a string to sit inside an AppleScript string literal: backslashes
    /// first, then quotes, or the escaping escapes its own escapes.
    private static func appleScriptEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The Full Disk Access list in System Settings.
    static func openFullDiskAccessSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Open a Terminal window at this directory.
    static func openTerminal(at directory: URL) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([directory],
                                withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Finder icons, cached.
///
/// `NSWorkspace.icon(forFile:)` is not free, and a pane redraw asks for one per
/// visible row. Files are cached by extension because every .swift file shares
/// an icon; directories and packages are cached by path because a folder can
/// carry a custom icon and an .app always does.
@MainActor
enum IconCache {

    private static var cache: [String: NSImage] = [:]

    /// At the size a list row draws it, unless the icon view asks for its own.
    static func icon(for item: FileItem, side requested: CGFloat? = nil) -> NSImage {
        // The size is part of the key. Without it, zooming served the images
        // cached at the old size for the rest of the session -- the same shape
        // of bug as a folder whose custom icon changed.
        let side = requested ?? PaneFont.iconSize
        let key: String
        if item.isDirectory || item.isPackage {
            key = "path:" + item.url.path
        } else {
            let ext = item.url.pathExtension.lowercased()
            // An extension-less file cannot be keyed by extension: every such
            // file would share the single "" entry and show whichever icon was
            // cached first. The executable bit is part of the key too, because
            // a script with the bit set gets a different icon from one without.
            key = ext.isEmpty
                ? "path:" + item.url.path
                : "ext:\(ext):\(item.isExecutable ? "x" : "-")"
        }

        // A plain folder with a coloured tag is drawn in that colour. macOS 26
        // colours a folder by its tag only once Customize Folder has switched
        // its custom icon on; otherwise it stays blue while the row beside it
        // is red. A customised folder is left as macOS draws it -- already in
        // the tag's colour, or a picture of someone's choosing -- and so is a
        // package: an app keeps its own icon.
        let tint = item.isDirectory && !item.isPackage
            && ConfigStore.shared.configuration.tagColourFolderIcons
            ? item.tagColourName.flatMap(Self.tagColour) : nil
        let sized = "\(Int(side)):" + (tint == nil ? "" : "tag:\(item.tagColourName ?? ""):") + key
        if let hit = cache[sized] { return hit }

        var image = NSWorkspace.shared.icon(forFile: item.url.path)
        if let tint, !FolderIcon.isCustomised(item.url.path) {
            image = tinted(image, with: tint)
        }
        image.size = NSSize(width: side, height: side)
        cache[sized] = image
        return image
    }

    /// The colours Finder gives its tags.
    private static func tagColour(_ name: String) -> NSColor? {
        switch name {
        case "Red":    .systemRed
        case "Orange": .systemOrange
        case "Yellow": .systemYellow
        case "Green":  .systemGreen
        case "Blue":   .systemBlue
        case "Purple": .systemPurple
        case "Gray":   .systemGray
        default:       nil
        }
    }

    /// The icon in grey, then the colour laid over it: the folder's own light
    /// and shade stay, in the tag's colour, pale the way Finder's coloured
    /// folders are. Laying the colour straight over the blue would mix the two
    /// -- yellow came out olive -- and the outline is the icon's own.
    private static func tinted(_ icon: NSImage, with colour: NSColor) -> NSImage {
        let size = icon.size.width > 0 ? icon.size : NSSize(width: 128, height: 128)
        return NSImage(size: size, flipped: false) { rect in
            icon.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .saturation)
            colour.set()
            rect.fill(using: .overlay)
            icon.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
    }

    /// Throw away what we remember about one item, or everything when the item
    /// is unknown.
    ///
    /// Directories are cached by path precisely because a folder can carry a
    /// custom icon -- which means that when the custom icon changes, the cache
    /// is the one thing still showing the old one. Tinting a folder and then
    /// untinting it left it coloured until the next launch.
    static func forget(_ url: URL?) {
        guard let url else { return cache.removeAll() }
        // The size prefix means one path has an entry per size it was drawn at.
        let suffix = "path:" + url.path
        for key in cache.keys where key.hasSuffix(suffix) { cache.removeValue(forKey: key) }
    }
}
