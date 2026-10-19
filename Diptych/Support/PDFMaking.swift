import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pictures made into PDFs: a page for each picture, and for each page of a
/// TIFF that has several. A JPEG goes in as the JPEG it is -- Quartz writes
/// the bytes of a picture made from JPEG data as they are, so nothing is
/// lost and nothing grows -- and anything else losslessly.
nonisolated enum PDFMaking {

    struct Failure: Error, Equatable, Sendable {
        let message: String
    }

    enum PageSize: String, CaseIterable, Identifiable, Sendable {
        /// The picture's own, from its resolution: a 300 ppi A4 scan is A4.
        case picture
        case a4
        case letter

        var id: String { rawValue }

        var title: String {
            switch self {
            case .picture: "The picture\u{2019}s own size"
            case .a4:      "A4"
            case .letter:  "US Letter"
            }
        }

        /// Portrait, in points.
        var paper: CGSize? {
            switch self {
            case .picture: nil
            case .a4:      CGSize(width: 595.28, height: 841.89)
            case .letter:  CGSize(width: 612, height: 792)
            }
        }
    }

    struct Options: Sendable, Equatable {
        /// All the pictures in one PDF, in the order given.
        var combine = false
        /// The combined PDF's name, without ".pdf".
        var name = ""
        var pageSize = PageSize.picture
        /// Where the PDFs go; nil is next to each picture.
        var folder: URL?
    }

    /// One page's picture, as drawn.
    struct Page {
        let image: CGImage
        /// EXIF orientation, 1 to 8: drawn turned, so a JPEG stays as it is.
        let orientation: Int
        /// Pixels per inch.
        let resolution: CGSize

        /// Upright, in pixels.
        var shownSize: CGSize {
            let w = CGFloat(image.width), h = CGFloat(image.height)
            return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        }
    }

    /// How many pages `url` will give.
    static func pageCount(of url: URL) -> Int {
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           let pages = OldJPEGTiff.pages(of: data) { return pages.count }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    /// Every page of `url`, as pictures to draw.
    static func pages(of url: URL) throws(Failure) -> [Page] {
        let name = url.lastPathComponent
        // An old-style JPEG TIFF, which ImageIO cannot read: its JPEGs.
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           let pages = OldJPEGTiff.pages(of: data) {
            return try pages.map { page throws(Failure) in
                guard let image = jpegImage(page.jpeg) else {
                    throw Failure(message: "A page of \u{201C}\(name)\u{201D} could not be read.")
                }
                return Page(image: image, orientation: 1, resolution: resolution(of: page.jpeg))
            }
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be read as a picture.")
        }
        let isJPEG = (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier
        var pages: [Page] = []
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any] ?? [:]
            // The JPEG's own bytes, so they go into the PDF untouched.
            let image = isJPEG
                ? (try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap(jpegImage)
                : CGImageSourceCreateImageAtIndex(source, index, nil)
            guard let image else {
                throw Failure(message: "Page \(index + 1) of \u{201C}\(name)\u{201D} could not "
                              + "be decoded.")
            }
            pages.append(Page(image: image,
                              orientation: (properties[kCGImagePropertyOrientation] as? Int) ?? 1,
                              resolution: resolution(properties)))
            if isJPEG { break }
        }
        return pages
    }

    private static func jpegImage(_ data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    private static func resolution(of jpeg: Data) -> CGSize {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else {
            return CGSize(width: 72, height: 72)
        }
        return resolution(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:])
    }

    /// 72 where the picture says nothing believable.
    private static func resolution(_ properties: [CFString: Any]) -> CGSize {
        func value(_ key: CFString) -> CGFloat {
            let number = (properties[key] as? NSNumber)?.doubleValue ?? 72
            return number >= 10 && number <= 10_000 ? number : 72
        }
        return CGSize(width: value(kCGImagePropertyDPIWidth), height: value(kCGImagePropertyDPIHeight))
    }

    /// The PDF at `target`: the pages of every picture, in order.
    static func write(_ urls: [URL], to target: URL, pageSize: PageSize) throws(Failure) {
        var all: [Page] = []
        for url in urls { all += try pages(of: url) }
        guard !all.isEmpty else { throw Failure(message: "There are no pages to make.") }
        let partial = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        guard let context = CGContext(partial as CFURL, mediaBox: nil, [
            kCGPDFContextCreator: "Diptych",
        ] as CFDictionary) else {
            throw Failure(message: "\u{201C}\(target.lastPathComponent)\u{201D} could not be made.")
        }
        for page in all {
            let shown = page.shownSize
            let natural = CGSize(width: shown.width * 72 / (page.orientation >= 5
                                                            ? page.resolution.height : page.resolution.width),
                                 height: shown.height * 72 / (page.orientation >= 5
                                                              ? page.resolution.width : page.resolution.height))
            var box: CGRect
            var picture: CGRect
            if let paper = pageSize.paper {
                // The paper turned to suit the picture, the picture fitted in it.
                let sheet = natural.width > natural.height
                    ? CGSize(width: paper.height, height: paper.width) : paper
                box = CGRect(origin: .zero, size: sheet)
                let scale = min(sheet.width / natural.width, sheet.height / natural.height)
                let size = CGSize(width: natural.width * scale, height: natural.height * scale)
                picture = CGRect(x: (sheet.width - size.width) / 2, y: (sheet.height - size.height) / 2,
                                 width: size.width, height: size.height)
            } else {
                box = CGRect(origin: .zero, size: natural)
                picture = box
            }
            context.beginPage(mediaBox: &box)
            draw(page, in: picture, context)
            context.endPage()
        }
        context.closePDF()
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                throw Failure(message: "\u{201C}\(target.lastPathComponent)\u{201D} is there already.")
            }
            try FileManager.default.moveItem(at: partial, to: target)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(message: "\u{201C}\(target.lastPathComponent)\u{201D} could not be "
                          + "written: \(error.localizedDescription)")
        }
    }

    /// Drawn upright in `rect`, turned by the context rather than by
    /// re-drawing the pixels.
    private static func draw(_ page: Page, in rect: CGRect, _ context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        let w = rect.width, h = rect.height
        // Each EXIF orientation as a transform from the stored picture to
        // the upright one, in PDF space, y up: a point (x, y) of the stored
        // picture lands where the comment says.
        switch page.orientation {
        case 2: // mirrored: (w - x, y)
            context.translateBy(x: w, y: 0); context.scaleBy(x: -1, y: 1)
        case 3: // upside down: (w - x, h - y)
            context.translateBy(x: w, y: h); context.rotate(by: .pi)
        case 4: // mirrored upside down: (x, h - y)
            context.translateBy(x: 0, y: h); context.scaleBy(x: 1, y: -1)
        case 5: // mirrored, a quarter anticlockwise: (w - y, h - x)
            context.translateBy(x: w, y: h); context.rotate(by: .pi / 2)
            context.scaleBy(x: -1, y: 1)
        case 6: // a quarter clockwise: (y, h - x)
            context.translateBy(x: 0, y: h); context.rotate(by: -.pi / 2)
        case 7: // mirrored, a quarter clockwise: (y, x)
            context.rotate(by: -.pi / 2); context.scaleBy(x: -1, y: 1)
        case 8: // a quarter anticlockwise: (w - y, x)
            context.translateBy(x: w, y: 0); context.rotate(by: .pi / 2)
        default:
            break
        }
        let stored = page.orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        context.interpolationQuality = .high
        context.draw(page.image, in: CGRect(origin: .zero, size: stored))
        context.restoreGState()
    }
}
