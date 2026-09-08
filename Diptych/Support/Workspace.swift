import AppKit

/// Thin wrappers over NSWorkspace -- the macOS integration points a file
/// manager needs and that have no cross-platform equivalent.
enum NSWorkspaceOpener {

    /// Hand the file to whatever app owns it, exactly as double-clicking in
    /// Finder would.
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Reveal in Finder, with the item selected.
    static func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
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

    static func icon(for item: FileItem) -> NSImage {
        // The size is part of the key. Without it, zooming served the images
        // cached at the old size for the rest of the session -- the same shape
        // of bug as a folder whose custom icon changed.
        let side = PaneFont.iconSize
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

        let sized = "\(Int(side)):" + key
        if let hit = cache[sized] { return hit }


        let image = NSWorkspace.shared.icon(forFile: item.url.path)
        image.size = NSSize(width: side, height: side)
        cache[sized] = image
        return image
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
