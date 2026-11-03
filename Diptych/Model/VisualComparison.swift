import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// One side of a comparison by eye: a PDF, page by page, or a picture, one
/// page of its own.
///
/// `@unchecked Sendable` because PDFKit's and Core Graphics' document types
/// say nothing either way; each source is made and used by one task at a time.
final class VisualSource: @unchecked Sendable {

    enum Kind: Sendable { case pdf, image }

    let url: URL
    let kind: Kind
    private let pdf: CGPDFDocument?
    private let image: CGImageSource?
    /// Read lazily: only a PDF's text is wanted, and only for some answers.
    private lazy var textDocument: PDFDocument? = kind == .pdf ? PDFDocument(url: url) : nil

    private init(url: URL, kind: Kind, pdf: CGPDFDocument?, image: CGImageSource?) {
        self.url = url
        self.kind = kind
        self.pdf = pdf
        self.image = image
    }

    /// The file as something to look at, or nil when it is neither a PDF nor
    /// a picture.
    static func open(_ url: URL) -> VisualSource? {
        if isPDF(url) {
            guard let document = CGPDFDocument(url as CFURL), !document.isEncrypted
                    || document.unlockWithPassword(""), document.numberOfPages > 0 else { return nil }
            return VisualSource(url: url, kind: .pdf, pdf: document, image: nil)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?,
              UTType(type)?.conforms(to: .image) == true,
              CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil else { return nil }
        return VisualSource(url: url, kind: .image, pdf: nil, image: source)
    }

    /// By its first bytes, not its name: a PDF saved without `.pdf` is one.
    private static func isPDF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1024)) ?? Data()
        return head.range(of: Data("%PDF-".utf8)) != nil
    }

    var pageCount: Int { pdf?.numberOfPages ?? 1 }

    /// "PDF", "PNG image", "JPEG image".
    var formatName: String {
        if kind == .pdf { return "PDF" }
        guard let image, let type = CGImageSourceGetType(image) as String? else { return "picture" }
        return UTType(type)?.localizedDescription ?? type
    }

    /// The program that wrote a PDF, as it says itself: the application
    /// that made it, and the library that turned that into PDF, when they
    /// are two.
    var producer: String? {
        guard let info = pdf?.info else { return nil }
        let named = ["Creator", "Producer"].compactMap { key -> String? in
            var value: CGPDFStringRef?
            guard CGPDFDictionaryGetString(info, key, &value), let value,
                  let text = CGPDFStringCopyTextString(value) as String?, !text.isEmpty else { return nil }
            return text
        }
        guard let first = named.first else { return nil }
        return named.count > 1 && named[1] != first ? "\(first) (\(named[1]))" : first
    }

    /// The page as it is shown, upright: in points for a PDF, in pixels for a
    /// picture. `page` counts from 0.
    func size(of page: Int) -> CGSize {
        if let pdf {
            guard let p = pdf.page(at: page + 1) else { return .zero }
            let box = p.getBoxRect(.cropBox)
            return p.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        }
        guard let image,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return .zero }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width)
                                : CGSize(width: width, height: height)
    }

    /// The page drawn upright to fill `rect` of `context`.
    func draw(_ page: Int, in context: CGContext, rect: CGRect) {
        if let pdf {
            guard let p = pdf.page(at: page + 1) else { return }
            let upright = size(of: page)
            guard upright.width > 0, upright.height > 0 else { return }
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / upright.width, y: rect.height / upright.height)
            // At a scale of one, so it only turns the page upright: it never
            // enlarges, which is why the scale is set above instead.
            context.concatenate(p.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: upright),
                                                      rotate: 0, preserveAspectRatio: true))
            context.clip(to: p.getBoxRect(.cropBox))
            context.drawPDFPage(p)
            context.restoreGState()
            return
        }
        guard let image,
              let picture = CGImageSourceCreateThumbnailAtIndex(image, 0, [
                  kCGImageSourceThumbnailMaxPixelSize: max(Int(max(rect.width, rect.height).rounded(.up)), 1),
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
              ] as CFDictionary) else { return }
        context.interpolationQuality = .high
        context.draw(picture, in: rect)
    }

    /// The text a PDF page carries itself -- typed, or put there by an
    /// earlier OCR -- and nil for a picture.
    func embeddedText(of page: Int) -> String? {
        textDocument?.page(at: page)?.string
    }

    // MARK: - The pictures in it, exactly

    /// One picture as stored: its size and how it is encoded, and a digest of
    /// what it decodes to -- the same digest, the same pixels.
    struct Picture: Sendable, Hashable {
        var width: Int
        var height: Int
        var encoding: String
        var digest: String
    }

    /// The pictures on a PDF page, in no particular order; for a picture
    /// file, the picture itself, decoded.
    func pictures(on page: Int) -> [Picture] {
        if let image {
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(image, 0, [
                kCGImageSourceThumbnailMaxPixelSize: 100_000,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
            ] as CFDictionary), let digest = Self.pixelDigest(decoded) else { return [] }
            return [Picture(width: decoded.width, height: decoded.height,
                            encoding: formatName, digest: digest)]
        }
        guard let p = pdf?.page(at: page + 1), let dictionary = p.dictionary else { return [] }
        var found: [Picture] = []
        Self.collect(from: dictionary, into: &found, depth: 0)
        return found
    }

    /// The image objects in a page's or a form's resources, forms within
    /// forms followed a few levels down.
    private static func collect(from owner: CGPDFDictionaryRef, into found: inout [Picture], depth: Int) {
        var resources: CGPDFDictionaryRef?
        var objects: CGPDFDictionaryRef?
        guard depth < 4, CGPDFDictionaryGetDictionary(owner, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return }
        final class Box { var streams: [(CGPDFStreamRef, String)] = [] }
        let box = Box()
        CGPDFDictionaryApplyBlock(objects, { _, object, info in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let streamDictionary = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(streamDictionary, "Subtype", &subtype), let subtype {
                Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue()
                    .streams.append((stream, String(cString: subtype)))
            }
            return true
        }, Unmanaged.passUnretained(box).toOpaque())
        for (stream, subtype) in box.streams {
            guard let info = CGPDFStreamGetDictionary(stream) else { continue }
            if subtype == "Form" {
                collect(from: info, into: &found, depth: depth + 1)
                continue
            }
            guard subtype == "Image" else { continue }
            var width: CGPDFInteger = 0, height: CGPDFInteger = 0
            CGPDFDictionaryGetInteger(info, "Width", &width)
            CGPDFDictionaryGetInteger(info, "Height", &height)
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { continue }
            let encoding: String
            let digest: String?
            switch format {
            case .jpegEncoded, .JPEG2000:
                encoding = format == .JPEG2000 ? "JPEG 2000" : "JPEG"
                // Decoded, so the same pixels stored by another JPEG writer
                // still count as the same.
                if let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    digest = pixelDigest(decoded)
                } else {
                    digest = hex(SHA256.hash(data: data))
                }
            default:
                // Core Graphics has undone the compression: these are the
                // pixels, whatever squeezed them.
                encoding = filters(info).map(filterName).joined(separator: " + ")
                digest = hex(SHA256.hash(data: data + Data(parameters(info).utf8)))
            }
            if let digest {
                found.append(Picture(width: width, height: height,
                                     encoding: encoding.isEmpty ? "uncompressed" : encoding,
                                     digest: digest))
            }
        }
    }

    /// What, besides the bytes, makes the same bytes another picture.
    private static func parameters(_ info: CGPDFDictionaryRef) -> String {
        var bits: CGPDFInteger = 0
        CGPDFDictionaryGetInteger(info, "BitsPerComponent", &bits)
        var name: UnsafePointer<CChar>?
        let space = CGPDFDictionaryGetName(info, "ColorSpace", &name) ? name.map { String(cString: $0) } ?? ""
                                                                       : "other"
        return "|\(bits)|\(space)"
    }

    private static func filters(_ info: CGPDFDictionaryRef) -> [String] {
        var name: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(info, "Filter", &name), let name { return [String(cString: name)] }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(info, "Filter", &array), let array else { return [] }
        return (0..<CGPDFArrayGetCount(array)).compactMap { index in
            var item: UnsafePointer<CChar>?
            return CGPDFArrayGetName(array, index, &item) ? item.map { String(cString: $0) } : nil
        }
    }

    private static func filterName(_ filter: String) -> String {
        switch filter {
        case "FlateDecode": "Flate"
        case "LZWDecode": "LZW"
        case "CCITTFaxDecode": "CCITT fax"
        case "JBIG2Decode": "JBIG2"
        case "RunLengthDecode": "run length"
        case "DCTDecode": "JPEG"
        case "JPXDecode": "JPEG 2000"
        default: filter.replacingOccurrences(of: "Decode", with: "")
        }
    }

    /// The digest of a picture's pixels as 8-bit RGBA, however it was stored.
    static func pixelDigest(_ image: CGImage) -> String? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              width > 0, height > 0 else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        return hex(SHA256.hash(data: Data(bytes: data, count: context.bytesPerRow * height)))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Two pages, or two pictures, drawn the same size, so they can be laid one
/// over the other.
struct PagePair: @unchecked Sendable {
    let left: CGImage
    let right: CGImage
    /// Where on the sheet the left page is, in its pixels: all of it, or
    /// less when the right one needs more room.
    var leftRect: CGRect
    /// Where the right one is, at the shape it is drawn: turned, when it is.
    var rightRect: CGRect

    var width: Int { left.width }
    var height: Int { left.height }

    /// Page `page` of each, on one sheet `longSide` pixels on its longer side.
    ///
    /// When the two are nearly the same shape -- the same page scanned at
    /// another resolution, or cropped a hair differently -- the sheet is the
    /// left one's shape and both fill it. Otherwise each is drawn at its own
    /// shape, centred, on a sheet large enough for both, so neither is cut
    /// off and which is left does not change how they lie: at one scale when
    /// the two measure alike -- points against points, pixels against pixels
    /// -- so two scans at one resolution, cropped differently, match where
    /// they overlap; at the same area otherwise.
    ///
    /// `quarterTurns` turns the right one that many quarters clockwise first,
    /// and lays it out as the page it then is: a scan fed in sideways.
    static func render(_ a: VisualSource, _ b: VisualSource, page: Int, longSide: Int,
                       quarterTurns: Int = 0) -> PagePair? {
        let turns = ((quarterTurns % 4) + 4) % 4
        let sizeA = a.size(of: page), unturnedB = b.size(of: page)
        var sizeB = turns % 2 == 0 ? unturnedB : CGSize(width: unturnedB.height, height: unturnedB.width)
        guard sizeA.width > 0, sizeA.height > 0, sizeB.width > 0, sizeB.height > 0 else { return nil }

        let aspectA = sizeA.width / sizeA.height, aspectB = sizeB.width / sizeB.height
        let alike = abs(aspectA - aspectB) / aspectA <= 0.03
        if alike {
            sizeB = sizeA
        } else if a.kind != b.kind {
            let k = (Double(sizeA.width * sizeA.height) / Double(sizeB.width * sizeB.height)).squareRoot()
            sizeB = CGSize(width: sizeB.width * k, height: sizeB.height * k)
        }
        let sheet = CGSize(width: max(sizeA.width, sizeB.width), height: max(sizeA.height, sizeB.height))
        let scale = Double(longSide) / Double(max(sheet.width, sheet.height))
        let width = max(Int((sheet.width * scale).rounded()), 1)
        let height = max(Int((sheet.height * scale).rounded()), 1)
        func centred(_ size: CGSize) -> CGRect {
            if alike { return CGRect(x: 0, y: 0, width: width, height: height) }
            let w = size.width * scale, h = size.height * scale
            return CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h)
        }
        let rectA = centred(sizeA), rectB = centred(sizeB)
        guard let left = canvas(width, height, { a.draw(page, in: $0, rect: rectA) }),
              let right = canvas(width, height, { context in
                  guard turns != 0 else { return b.draw(page, in: context, rect: rectB) }
                  // About the middle of where it goes, drawn at its own
                  // shape there: clockwise on the page is negative to Core
                  // Graphics, whose y goes up.
                  context.translateBy(x: rectB.midX, y: rectB.midY)
                  context.rotate(by: -Double(turns) * .pi / 2)
                  let w = turns % 2 == 0 ? rectB.width : rectB.height
                  let h = turns % 2 == 0 ? rectB.height : rectB.width
                  b.draw(page, in: context, rect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
              }) else { return nil }
        return PagePair(left: left, right: right, leftRect: rectA, rightRect: rectB)
    }

    /// A white sheet `width` x `height` with `draw` done on it.
    private static func canvas(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        return context.makeImage()
    }

    var grays: (GrayImage, GrayImage)? {
        guard let a = GrayImage(left, width: width, height: height),
              let b = GrayImage(right, width: width, height: height) else { return nil }
        return (a, b)
    }
}

extension PagePair {

    /// The quarter turn of the right one that lies best over the left, with
    /// the fit found for it on small drawings of the two: where the search
    /// at full size starts. Upright first; the other three only when upright
    /// does not already match.
    static func roughFit(_ a: VisualSource, _ b: VisualSource, page: Int, cancel: CancellationFlag?,
                         progress: (@Sendable (Double) -> Void)? = nil) -> ImageAlignment.Fit? {
        var best: ImageAlignment.Fit?
        for turns in 0..<4 {
            if cancel?.isCancelled == true { return nil }
            guard let small = render(a, b, page: page, longSide: 200, quarterTurns: turns),
                  let (ga, gb) = small.grays,
                  var fit = ImageAlignment.find(ga, gb, cancel: cancel, progress: { p in
                      progress?((Double(turns) + p.fraction) / 4)
                  }) else { continue }
            fit.transform.quarterTurns = turns
            if best == nil || fit.similarity > best!.similarity { best = fit }
            if turns == 0, fit.similarity >= 0.8 { break }
        }
        progress?(1)
        return best
    }
}

/// Two PDFs, or two pictures, compared by what they show rather than by how
/// they are stored -- the question for two files whose bytes differ.
///
/// Three answers, from the strongest down, page by page:
///
/// 1. *The same pixels.* The same pictures, decoded, and the same text: the
///    files differ only in how they hold them.
/// 2. *Not so anyone could see.* The pixels differ -- compressed again, at
///    another resolution -- but nowhere enough to show.
/// 3. *Probably two scans of the same page.* Turned and moved a little, lit
///    differently, but the same once laid over each other, and the same text
///    read from both. A guess, and said to be one.
///
/// Anything else is different.
struct VisualComparison: Sendable {

    enum Verdict: Int, Sendable, Comparable {
        case samePixels, indistinguishable, nearlySame, rescanned, different

        static func < (a: Verdict, b: Verdict) -> Bool { a.rawValue < b.rawValue }
    }

    struct Page: Sendable {
        var number: Int
        var verdict: Verdict
        /// How alike the two look, 0 to 1, as they are -- or once aligned,
        /// for a page that needed it.
        var similarity: Double
        var notes: [String]
        /// How the right one lies best over the left, when that was looked
        /// for -- or, for two the same to the eye, that it lies in place.
        var alignment: ImageAlignment.Fit? = nil
    }

    /// Where a comparison has got: what it is doing, and the share of the
    /// whole done.
    struct Step: Sendable {
        var text: String
        var fraction: Double
    }

    var leftFormat: String
    var rightFormat: String
    var leftPages: Int
    var rightPages: Int
    var pages: [Page] = []
    /// About the files as a whole: what made them, how their pictures are
    /// stored.
    var notes: [String] = []

    var samePageCount: Bool { leftPages == rightPages }

    /// The weakest of the pages' answers; nil when they cannot be paired.
    var verdict: Verdict? {
        guard samePageCount, !pages.isEmpty else { return nil }
        return pages.map(\.verdict).max()
    }

    var canPreview: Bool { samePageCount && leftPages > 0 }

    /// Thresholds, tuned on JPEG at quality 50 (passes) and one changed
    /// digit on a page of text (fails).
    static let lookAlike = 0.97
    static let worstSpot = 0.06

    static func looksAlike(_ ssim: Double, _ worst: Double) -> Bool {
        ssim >= lookAlike && worst <= worstSpot
    }

    // MARK: - Comparing

    /// How many pages the two have to lay over each other: 0 unless both
    /// are pictures or PDFs with as many pages. Quick: only the files'
    /// headers are read.
    static func pairedPages(_ leftURL: URL, _ rightURL: URL) -> Int {
        guard let left = VisualSource.open(leftURL), let right = VisualSource.open(rightURL),
              left.pageCount == right.pageCount else { return 0 }
        return left.pageCount
    }

    /// Nil when either file is not something to look at.
    ///
    /// `known` are alignments already found, by page -- by the preview, say,
    /// or an earlier comparison of the same files -- which are not looked
    /// for again.
    static func compare(_ leftURL: URL, _ rightURL: URL, known: [Int: ImageAlignment.Fit] = [:],
                        cancel: CancellationFlag? = nil,
                        progress: (@Sendable (Step) -> Void)? = nil) -> VisualComparison? {
        guard let left = VisualSource.open(leftURL), let right = VisualSource.open(rightURL) else {
            return nil
        }
        var result = VisualComparison(leftFormat: left.formatName, rightFormat: right.formatName,
                                      leftPages: left.pageCount, rightPages: right.pageCount)
        result.notes = fileNotes(left, right)
        guard result.samePageCount else { return result }

        for page in 0..<left.pageCount {
            if cancel?.isCancelled == true { return nil }
            let prefix = left.pageCount > 1 ? "Page \(page + 1) of \(left.pageCount): " : ""
            let pages = Double(left.pageCount)
            progress?(Step(text: prefix + "looking\u{2026}", fraction: Double(page) / pages))
            result.pages.append(comparePage(page, left, right, known: known[page], cancel: cancel) { text, done in
                progress?(Step(text: prefix + text, fraction: (Double(page) + done) / pages))
            })
        }
        return result
    }

    /// `step` is told what is being done and how much of the page is done.
    private static func comparePage(_ page: Int, _ a: VisualSource, _ b: VisualSource,
                                    known: ImageAlignment.Fit?, cancel: CancellationFlag?,
                                    step: @escaping @Sendable (String, Double) -> Void) -> Page {
        let number = page + 1
        guard let pair = PagePair.render(a, b, page: page, longSide: 1600),
              let (grayA, grayB) = pair.grays else {
            return Page(number: number, verdict: .different, similarity: 0,
                        notes: ["It could not be drawn."])
        }
        let ssim = GrayImage.ssim(grayA, grayB)
        let worst = GrayImage.worstBlock(grayA, grayB)
        var notes: [String] = []

        // 1. The same pictures, decoded, and the same text -- and drawn alike,
        //    so they are also where they were.
        let picturesA = a.pictures(on: page), picturesB = b.pictures(on: page)
        let samePictures = picturesA.map(\.digest).sorted() == picturesB.map(\.digest).sorted()
        let sameText = (a.embeddedText(of: page) ?? "") == (b.embeddedText(of: page) ?? "")
        if samePictures, sameText, ssim >= 0.999, worst <= 0.01 {
            let encodingsA = Set(picturesA.map(\.encoding)), encodingsB = Set(picturesB.map(\.encoding))
            if encodingsA != encodingsB {
                notes.append("The same pixels, compressed differently: "
                             + "left \(listed(encodingsA)), right \(listed(encodingsB)).")
            }
            return Page(number: number, verdict: .samePixels, similarity: 1, notes: notes,
                        alignment: ImageAlignment.Fit(transform: .identity, similarity: 1, finest: .max))
        }

        // 2. Not the same pixels, but nothing a person could see.
        if looksAlike(ssim, worst) {
            notes += pictureDifferences(picturesA, picturesB)
            // In place: nothing to align, only how alike, at a size that
            // takes a moment.
            let alike = ImageAlignment.similarity(grayA.halved().halved(), grayB.halved().halved())
            return Page(number: number, verdict: .indistinguishable, similarity: ssim, notes: notes,
                        alignment: ImageAlignment.Fit(transform: .identity, similarity: alike, finest: .max))
        }

        // 3. Two scans of one page? Laid over each other first.
        var fit = known
        if fit == nil {
            step("aligning\u{2026}", 0.1)
            fit = PagePair.roughFit(a, b, page: page, cancel: cancel) { done in
                step("aligning\u{2026}", 0.1 + 0.2 * done)
            }
        }
        // The right one as the fit has it: turned a quarter or more first,
        // when it was fed in sideways.
        // Turned, the sheet both are on can be another shape: the left one is
        // taken from it too.
        let turns = fit?.transform.quarterTurns ?? 0
        var leftImage = pair.left, rightImage = pair.right, leftGray = grayA, rightGray = grayB
        if turns != 0, let turned = PagePair.render(a, b, page: page, longSide: 1600, quarterTurns: turns),
           let grays = turned.grays {
            leftImage = turned.left
            rightImage = turned.right
            leftGray = grays.0
            rightGray = grays.1
        }
        if let rough = fit, known == nil {
            fit = ImageAlignment.find(leftGray, rightGray, finest: 400, around: rough, cancel: cancel) { progress in
                step("aligning\u{2026}", 0.3 + 0.4 * progress.fraction)
            } ?? rough
        }
        if cancel?.isCancelled == true { fit = nil }
        let transform = fit?.transform ?? .identity
        let aligned = rightGray.transformed(transform)
        let alignedSSIM = GrayImage.ssim(leftGray, aligned)
        let alignedWorst = GrayImage.worstBlock(leftGray, aligned)
        // Not moved: no scan's worth of turn, size or shift. Then whatever
        // differs is a detail on the page, not where the page sits.
        let moved = turns != 0 || abs(transform.degrees) >= 0.1 || abs(transform.scale - 1) >= 0.003
            || abs(transform.dx) >= 0.003 || abs(transform.dy) >= 0.003
        // With text to go by, lying in place is enough: two scans would not.
        // Without it, the pictures also have to agree nearly everywhere.
        let inPlace = !moved
        let spot = GrayImage.worstSpot(grayA, grayB)
        let whereItIs = "Where they differ most is " + GrayImage.place(x: spot.x, y: spot.y) + "."
        if moved {
            notes.append("They match best with the right one \(transform.description).")
        }

        // The text a PDF carries, when both carry the same: exact, where
        // reading it off the page is not.
        let carriedA = a.embeddedText(of: page) ?? "", carriedB = b.embeddedText(of: page) ?? ""
        if carriedA.count >= 30, textSimilarity(carriedA, carriedB) == 1 {
            notes.append("The text in them is the same.")
            if inPlace { notes.append(whereItIs) }
            return Page(number: number, verdict: inPlace ? .nearlySame : .rescanned,
                        similarity: inPlace ? ssim : alignedSSIM, notes: notes, alignment: fit)
        }

        step("reading the text\u{2026}", 0.7)
        let textA = recognizedText(leftImage), textB = recognizedText(rightImage)
        let enoughText = textA.count >= 30 && textB.count >= 30
        if enoughText {
            let similarity = textSimilarity(textA, textB)
            // In any order: two readings of one page need not list its lines
            // alike.
            let numbersA = numbers(in: textA).sorted(), numbersB = numbers(in: textB).sorted()
            let percent = Int((similarity * 100).rounded(.down))
            // Lying exactly where the other does, the same page read twice
            // reads alike; scans, each read in its own grain, need slack.
            if numbersA == numbersB, similarity >= (inPlace ? 0.99 : 0.95) {
                notes.append("The text read from them matches (\(percent)%), numbers and all.")
                if inPlace { notes.append(whereItIs) }
                return Page(number: number, verdict: inPlace ? .nearlySame : .rescanned,
                            similarity: inPlace ? ssim : alignedSSIM, notes: notes, alignment: fit)
            }
            if similarity >= 0.8, numbersA != numbersB {
                notes.append("The text is much the same (\(percent)%), but the numbers in it are not"
                             + numberDifference(numbersA, numbersB) + ".")
            } else {
                notes.append("The text read from them is \(percent)% the same.")
            }
            return Page(number: number, verdict: .different, similarity: alignedSSIM, notes: notes, alignment: fit)
        }
        // Little text to go by: the picture has to say it.
        notes.append("There is too little text on it to read, so this goes by how it looks alone.")
        if inPlace, ssim >= 0.98 {
            notes.append(whereItIs)
            return Page(number: number, verdict: .nearlySame, similarity: ssim, notes: notes, alignment: fit)
        }
        if looksAlike(alignedSSIM, alignedWorst) || alignedSSIM >= 0.8 {
            notes.append("Laid over each other, the two match "
                         + "(\(Int((alignedSSIM * 100).rounded(.down)))%).")
            return Page(number: number, verdict: .rescanned, similarity: alignedSSIM, notes: notes, alignment: fit)
        }
        return Page(number: number, verdict: .different, similarity: max(ssim, alignedSSIM), notes: notes, alignment: fit)
    }

    // MARK: - Reading the text

    /// What Vision reads on the page, as one string.
    static func recognizedText(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// 1 for the same text, falling towards 0: one less the edit distance,
    /// over the longer, with case and spacing left out.
    static func textSimilarity(_ a: String, _ b: String) -> Double {
        func plain(_ text: String) -> [Character] {
            Array(text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(5000))
        }
        let x = plain(a), y = plain(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = x[i - 1] == y[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    /// The numbers in the text, in order: what tells one invoice from another
    /// made from the same form.
    static func numbers(in text: String) -> [String] {
        let pattern = /\d+(?:[.,:\/-]\d+)*/
        return text.matches(of: pattern).map { String($0.output) }
    }

    /// The numbers only one side has -- counted, so a number one side has
    /// twice and the other once is told too.
    private static func numberDifference(_ a: [String], _ b: [String]) -> String {
        func minus(_ x: [String], _ y: [String]) -> [String] {
            var left = y
            return x.filter { number in
                guard let index = left.firstIndex(of: number) else { return true }
                left.remove(at: index)
                return false
            }
        }
        let onlyA = minus(a, b).prefix(3)
        let onlyB = minus(b, a).prefix(3)
        guard !onlyA.isEmpty || !onlyB.isEmpty else { return "" }
        var parts: [String] = []
        if !onlyA.isEmpty { parts.append("left " + onlyA.joined(separator: ", ")) }
        if !onlyB.isEmpty { parts.append("right " + onlyB.joined(separator: ", ")) }
        return " (" + parts.joined(separator: "; ") + ")"
    }

    // MARK: - Saying how they are stored

    private static func fileNotes(_ a: VisualSource, _ b: VisualSource) -> [String] {
        var notes: [String] = []
        if a.formatName != b.formatName {
            notes.append("Left is a \(a.formatName), right a \(b.formatName).")
        }
        if a.kind == .image, b.kind == .image {
            let sa = a.size(of: 0), sb = b.size(of: 0)
            if sa != sb {
                notes.append("Left is \(Int(sa.width)) \u{D7} \(Int(sa.height)) pixels, "
                             + "right \(Int(sb.width)) \u{D7} \(Int(sb.height)).")
            }
        }
        if let pa = a.producer, let pb = b.producer, pa != pb {
            notes.append("Left was written by \(pa), right by \(pb).")
        }
        if a.pageCount != b.pageCount {
            notes.append("Left has \(a.pageCount) page\(a.pageCount == 1 ? "" : "s"), "
                         + "right \(b.pageCount): they cannot be compared page by page.")
        }
        return notes
    }

    /// How a page's pictures are stored differently: resolution, encoding.
    private static func pictureDifferences(_ a: [VisualSource.Picture],
                                           _ b: [VisualSource.Picture]) -> [String] {
        guard let biggestA = a.max(by: { $0.width * $0.height < $1.width * $1.height }),
              let biggestB = b.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return [] }
        var notes: [String] = []
        if biggestA.encoding != biggestB.encoding {
            notes.append("Compressed differently: left \(biggestA.encoding), right \(biggestB.encoding).")
        }
        if biggestA.width != biggestB.width || biggestA.height != biggestB.height {
            notes.append("At another resolution: left \(biggestA.width) \u{D7} \(biggestA.height), "
                         + "right \(biggestB.width) \u{D7} \(biggestB.height).")
        }
        return notes
    }

    static func listed(_ parts: Set<String>) -> String {
        let sorted = parts.sorted()
        guard sorted.count > 1 else { return sorted.first ?? "none" }
        return sorted.dropLast().joined(separator: ", ") + " and " + sorted.last!
    }

    // MARK: - Saying it

    /// The answer in a sentence.
    var headline: String {
        guard samePageCount else {
            return "They do not have the same number of pages: left \(leftPages), right \(rightPages)."
        }
        let single = leftPages == 1
        switch verdict {
        case .samePixels?:
            return single
                ? "The same picture, pixel for pixel; only how the file stores it differs."
                : "The same content: every page holds the same pictures, pixel for pixel, and the "
                  + "same text; only how the file stores them differs."
        case .indistinguishable?:
            return "Visually the same: the pixels differ, but nowhere so a person could see it."
        case .nearlySame?:
            return "Nearly the same: they match almost everywhere, with the text the same, but "
                + (single ? "one spot looks" : "a spot on some pages looks")
                + " different \u{2014} a picture, a mark, or how a letter is drawn. "
                + "Look at it in the preview."
        case .rescanned?:
            return "Probably two scans of the same " + (single ? "page" : "document")
                + ": they differ the way two scans do, but match once laid over each other. "
                + "A guess -- look at them in the preview."
        case .different?:
            return "They look different."
        case nil:
            return "Nothing to compare."
        }
    }
}
