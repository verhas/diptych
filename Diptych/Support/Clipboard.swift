import AppKit
import Observation

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

    // MARK: - Making a file out of what is on the clipboard

    enum Kind: Equatable {
        case empty, text, image
    }

    /// What is there, and in a form that can be written to a file.
    enum Content {
        case nothing
        case text(String)
        case image(NSImage, pdf: Data?)

        var kind: Kind {
            switch self {
            case .nothing: .empty
            case .text:    .text
            case .image:   .image
            }
        }
    }

    static func contents() -> Content {
        let board = NSPasteboard.general
        // Images first. A copied picture usually arrives with a text flavour
        // as well -- a file name, a URL -- and saving that instead of the
        // picture would be the wrong answer to "New from Clipboard".
        let pdf = board.data(forType: .pdf)
        if let image = NSImage(pasteboard: board) { return .image(image, pdf: pdf) }
        if let pdf, let image = NSImage(data: pdf) { return .image(image, pdf: pdf) }
        if let string = board.string(forType: .string), !string.isEmpty { return .text(string) }
        return .nothing
    }

    /// Turn a pasted picture into the bytes of a file.
    ///
    /// PDF data is passed through untouched when the clipboard already holds
    /// it: a diagram copied from a drawing program is vector art, and putting
    /// it through a bitmap on the way to a PDF would throw that away for
    /// nothing.
    static func data(for image: NSImage, pdf: Data?,
                     as format: Configuration.ClipboardImageFormat) -> Data? {
        if format == .pdf, let pdf { return pdf }

        switch format {
        case .pdf:
            let size = image.size
            guard size.width > 0, size.height > 0 else { return nil }
            let data = NSMutableData()
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
                return nil
            }
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: box)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
            context.closePDF()
            return data as Data

        case .png, .jpeg:
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
            return bitmap.representation(using: format == .png ? .png : .jpeg,
                                         properties: format == .jpeg
                                             ? [.compressionFactor: 0.9] : [:])

        case .ask:
            return nil
        }
    }
}

/// Whether there is anything worth pasting, current enough for a menu item to
/// be greyed out when there is not.
///
/// Polled, because AppKit gives no notification when the pasteboard changes --
/// `changeCount` is the whole API. Reading one integer now and then costs
/// nothing, and the alternative is a menu item that is always enabled and
/// sometimes does nothing, which teaches people to distrust it.
@MainActor
@Observable
final class ClipboardWatcher {

    static let shared = ClipboardWatcher()

    private(set) var kind: Clipboard.Kind = .empty
    @ObservationIgnored private var lastChange = -1
    @ObservationIgnored private var timer: Timer?

    private init() {
        look()
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardWatcher.shared.look() }
        }
    }

    private func look() {
        guard NSPasteboard.general.changeCount != lastChange else { return }
        lastChange = NSPasteboard.general.changeCount
        kind = Clipboard.contents().kind
    }
}
