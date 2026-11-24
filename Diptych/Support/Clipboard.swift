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
    /// by Finder. An item of an archive Diptych copied is read back as that
    /// item -- by its own type, so that no copy is made for a paste here.
    static func fileURLs(on pasteboard: NSPasteboard = .general) -> [URL] {
        let items = pasteboard.pasteboardItems ?? []
        guard items.contains(where: { $0.types.contains(archiveItemType) }) else {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
            return (objects ?? []).map(ArchiveBrowsing.original(of:))
        }
        return items.compactMap { item -> URL? in
            // The archive's item while it is still unpacked; after a quit, the
            // copy that was made for the clipboard as Diptych went.
            if let text = item.string(forType: archiveItemType), let original = URL(string: text),
               FileManager.default.fileExists(atPath: original.path) {
                return original
            }
            guard let text = item.string(forType: .fileURL), let url = URL(string: text),
                  url.isFileURL else { return nil }
            return ArchiveBrowsing.original(of: (url as NSURL).filePathURL ?? url)
        }
    }

    // MARK: - Items of an archive

    /// Diptych's own record of an archive item on the clipboard: its path in
    /// the unpacked archive.
    private static let archiveItemType = NSPasteboard.PasteboardType("dev.verhas.diptych.archive-item")

    /// The providers of the items written last; held here, since the
    /// pasteboard item may not.
    private static var providers: [ArchiveItemProvider] = []

    /// Gives every archive item on the clipboard its copy now, while the
    /// unpacked archives are still there: at quit, so that a paste after it
    /// still finds something.
    static func settleArchiveItems(on pasteboard: NSPasteboard = .general) {
        for item in pasteboard.pasteboardItems ?? []
        where item.types.contains(archiveItemType) {
            _ = item.string(forType: .fileURL)
        }
    }

    /// The copies made for the clipboard by an earlier run, still on it:
    /// kept when the rest of that run's copies are removed.
    static func handedOutPaths() -> Set<String> {
        let root = ArchiveBrowsing.handOutRoot.standardizedFileURL.path + "/"
        return Set((NSPasteboard.general.pasteboardItems ?? []).compactMap { item in
            item.string(forType: .fileURL).flatMap(URL.init(string:))?.standardizedFileURL.path
        }.filter { $0.hasPrefix(root) })
    }

    /// The plain-text flavour, if there is one -- what Check Checksum reads to
    /// see whether a sum was copied.
    static func plainText() -> String? {
        NSPasteboard.general.string(forType: .string)
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

    /// An item of an opened archive goes on as a promise of its file URL,
    /// kept until something reads it: then -- at the paste -- a clean copy is
    /// made, with the archive's permissions and quarantine, as a drag gets
    /// (`ArchiveBrowsing.handOut`). Given the unpacked archive itself, Finder
    /// copied its read-only lock. Made at the copy instead, it could be gone
    /// by the paste. Anything else goes on as a plain URL, as Finder's does.
    static func write(_ urls: [URL], to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        ArchiveBrowsing.unpinHandedOut()
        providers = []
        let objects = urls.map { url -> NSPasteboardWriting in
            guard ArchiveBrowsing.isInside(url) else { return url as NSURL }
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: archiveItemType)
            let provider = ArchiveItemProvider(original: url)
            providers.append(provider)
            item.setDataProvider(provider, forTypes: [.fileURL, .URL])
            return item
        }
        pasteboard.writeObjects(objects)
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

    /// What is on `board`: the clipboard, or what is being dropped, which
    /// becomes a file the same way.
    static func contents(of board: NSPasteboard = .general) -> Content {
        // Images first. A copied picture usually arrives with a text flavour
        // as well -- a file name, a URL -- and saving that instead of the
        // picture would be the wrong answer to "New from Clipboard".
        let pdf = board.data(forType: .pdf)
        if let image = NSImage(pasteboard: board) { return .image(image, pdf: pdf) }
        if let pdf, let image = NSImage(data: pdf) { return .image(image, pdf: pdf) }
        if let string = board.string(forType: .string), !string.isEmpty { return .text(string) }
        return .nothing
    }

    /// Whether `contents(of:)` would find something on `board`, told by
    /// the types alone: asked while a drag moves, it must not make a picture.
    static func holdsContent(_ board: NSPasteboard) -> Bool {
        NSImage.canInit(with: board) || board.availableType(from: [.pdf, .string]) != nil
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
    /// The one file copied, for Paste Special; nil for none or several.
    private(set) var pasteSource: PasteSpecial.Source?
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
        let urls = Clipboard.fileURLs()
        pasteSource = urls.count == 1 ? PasteSpecial.Source.read(urls[0]) : nil
        // Copied while Diptych is in front: New from Clipboard may be next.
        if kind != .empty, NSApp.isActive {
            ClipboardNamePrefetcher.shared.anticipateInKeyWindow()
        }
    }
}

/// Makes the clean copy of an archive item when the clipboard is read --
/// once, whichever of its types is asked for first.
final class ArchiveItemProvider: NSObject, NSPasteboardItemDataProvider {
    let original: URL
    private var copy: URL?

    init(original: URL) {
        self.original = original
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        let made = copy ?? ArchiveBrowsing.handOut(original)
        copy = made
        if made != original { ArchiveBrowsing.pinHandedOut(made) }
        item.setString(made.absoluteString, forType: type)
    }
}
