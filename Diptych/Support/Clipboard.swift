import AppKit
import Observation
import UniformTypeIdentifiers

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

    // MARK: - What is in a file, rather than the file

    /// What Copy ▸ Content found, read off the main thread.
    enum FileContents: Sendable {
        case text(String)
        case image(Data, type: String)
        case refused(String)
    }

    /// Big enough for any text anyone pastes, small enough that a mistaken
    /// Copy on a disk image does not try to put gigabytes on the pasteboard.
    nonisolated static let contentLimit = 32 * 1024 * 1024

    /// Whether Copy ▸ Content could do anything with these files, judged
    /// cheaply enough to decide whether the command is offered at all: by
    /// type where the type says, and by the first kilobyte where it does not.
    /// `readContents` still has the last word -- a file can change between
    /// the menu opening and the command running.
    nonisolated static func canReadContents(of files: [(url: URL, bytes: Int64)]) -> Bool {
        guard !files.isEmpty, files.count <= 200,
              files.reduce(Int64(0), { $0 + $1.bytes }) <= Int64(contentLimit) else { return false }
        if files.count == 1, let type = UTType(filenameExtension: files[0].url.pathExtension),
           type.conforms(to: .image) || type.conforms(to: .pdf) {
            return true
        }
        return files.allSatisfy { file in
            if let type = UTType(filenameExtension: file.url.pathExtension),
               !type.isDynamic, type.conforms(to: .text) {
                return true
            }
            return looksLikeText(file.url)
        }
    }

    /// No NUL byte near the start: the same test `readContents` applies to
    /// the whole file, on the part of it a menu can afford to read. An archive,
    /// an executable, a picture among several files -- all fail on it at once.
    nonisolated private static func looksLikeText(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let start = try? handle.read(upToCount: 1024) else { return true }  // empty
        return !start.contains(0)
    }

    /// Text as text, a picture as a picture -- the two things New from
    /// Clipboard can turn back into a file. Several text files are copied one
    /// after another; a picture only on its own, since there is no such thing
    /// as two pictures on the pasteboard as one.
    nonisolated static func readContents(of urls: [URL]) -> FileContents {
        let sizes = urls.map {
            (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        guard sizes.reduce(0, +) <= contentLimit else {
            let limit = ByteCountFormatter.string(fromByteCount: Int64(contentLimit),
                                                  countStyle: .file)
            return .refused("That is more than \(limit), too much for the clipboard.")
        }

        if urls.count == 1, let type = UTType(filenameExtension: urls[0].pathExtension),
           type.conforms(to: .image) || type.conforms(to: .pdf) {
            guard let data = try? Data(contentsOf: urls[0]) else {
                return .refused("\(urls[0].lastPathComponent) could not be read.")
            }
            return .image(data, type: type.identifier)
        }

        var texts: [String] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else {
                return .refused("\(url.lastPathComponent) could not be read.")
            }
            // A NUL byte is the plainest sign of a binary file; UTF-8 alone
            // would accept one, and the clipboard would then hold garbage.
            // Not UTF-8: whatever Foundation can tell the encoding to be.
            var encoding = String.Encoding.utf8
            guard !data.contains(0),
                  let text = String(data: data, encoding: .utf8)
                      ?? (try? String(contentsOf: url, usedEncoding: &encoding)) else {
                return .refused("\(url.lastPathComponent) is neither text nor a picture.")
            }
            texts.append(text)
        }
        // One after another, each starting on a line of its own.
        let joined = texts.enumerated().map { index, text in
            index < texts.count - 1 && !text.hasSuffix("\n") ? text + "\n" : text
        }.joined()
        return .text(joined)
    }

    /// The picture's own bytes under its own type, so a PNG pastes as that
    /// PNG, and TIFF beside it for the many apps that only read TIFF.
    static func copyImage(_ data: Data, type: String) {
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(type))
        if type != NSPasteboard.PasteboardType.tiff.rawValue,
           let tiff = NSImage(data: data)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
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

        // Neither is a format to write: one is a question the caller has to
        // answer first, the other means the command does not exist.
        case .ask, .off:
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
        // Copied while Diptych is in front: New from Clipboard may be next.
        if kind != .empty, NSApp.isActive {
            ClipboardNamePrefetcher.shared.anticipateInKeyWindow()
        }
    }
}
