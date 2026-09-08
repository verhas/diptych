import AppKit

/// The system pasteboard, as a file manager uses it.
@MainActor
enum Clipboard {

    /// macOS has no notion of a "cut" file on the pasteboard -- Finder offers
    /// Move Item Here instead. So the URLs go on the pasteboard exactly as a
    /// copy would, and the intent is remembered here, tied to the pasteboard's
    /// change count: anything else writing to the pasteboard invalidates it.
    private static var cutAtChangeCount: Int?

    static func copy(_ urls: [URL]) {
        write(urls)
        cutAtChangeCount = nil
    }

    static func cut(_ urls: [URL]) {
        write(urls)
        cutAtChangeCount = NSPasteboard.general.changeCount
    }

    static var holdsCut: Bool {
        cutAtChangeCount == NSPasteboard.general.changeCount
    }

    /// A cut is spent once it has been pasted. Leaving it armed made a second
    /// paste try to move sources that are no longer where the pasteboard says.
    static func clearCutIntent() {
        cutAtChangeCount = nil
    }

    /// File URLs on the pasteboard, whether they were put there by Diptych or
    /// by Finder.
    static func fileURLs() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                       options: options) as? [URL]
        return objects ?? []
    }

    static func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        cutAtChangeCount = nil
    }

    private static func write(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }
}
