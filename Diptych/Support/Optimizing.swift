import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers

/// Making photos, PNGs and PDFs smaller: a candidate written to a temporary
/// file, for the window to weigh against the original before anything is
/// replaced.
///
/// Only with what macOS has. Photos are encoded again by ImageIO at a lower
/// quality, smaller if asked. A PNG is either written again losslessly or
/// given a palette of at most 256 colours, which is what pngquant does and
/// what saves most on a screenshot. A PDF is saved through a Quartz filter of
/// its own -- the same kind of filter as Preview's Reduce File Size, with the
/// quality and the resolution chosen here -- which re-encodes the pictures
/// in it and leaves the text, links and outline as they are.
nonisolated enum Optimizing {

    struct Failure: Error, Equatable, Sendable {
        let message: String
        /// Not an error: the file is as small as this can make it.
        var pointless = false
    }

    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case photo, png, pdf

        var id: String { rawValue }

        var title: String {
            switch self {
            case .photo: "Photos (JPEG, HEIC)"
            case .png:   "PNG"
            case .pdf:   "PDF"
            }
        }

        var short: String {
            switch self {
            case .photo: "Photo"
            case .png:   "PNG"
            case .pdf:   "PDF"
            }
        }
    }

    static func kind(of url: URL) -> Kind? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "heic", "heif": .photo
        case "png": .png
        case "pdf": .pdf
        default: nil
        }
    }

    /// Everything the window asks, one group per kind.
    struct Settings: Codable, Equatable, Sendable {
        /// 0 to 1.
        var photoQuality = 0.75
        /// Pixels; nil keeps the size.
        var photoLongestSide: Int?
        var photoKeepMetadata = true

        /// nil: written again without loss; otherwise the most colours.
        var pngColours: Int? = 256
        var pngDither = true

        /// Of the pictures in a PDF, 0 to 1.
        var pdfQuality = 0.6
        /// Pixels per inch the pictures are brought down to; nil keeps them.
        var pdfResolution: Int? = 150

        /// The modified date the original had, on the smaller file.
        var keepModifiedDate = true
        var replaceOriginals = true

        init() {}

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Settings()
            func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
                (try? container.decode(T.self, forKey: key)) ?? fallback
            }
            photoQuality = value(.photoQuality, defaults.photoQuality)
            photoLongestSide = value(.photoLongestSide, defaults.photoLongestSide)
            photoKeepMetadata = value(.photoKeepMetadata, defaults.photoKeepMetadata)
            pngColours = value(.pngColours, defaults.pngColours)
            pngDither = value(.pngDither, defaults.pngDither)
            pdfQuality = value(.pdfQuality, defaults.pdfQuality)
            pdfResolution = value(.pdfResolution, defaults.pdfResolution)
            keepModifiedDate = value(.keepModifiedDate, defaults.keepModifiedDate)
            replaceOriginals = value(.replaceOriginals, defaults.replaceOriginals)
        }

        /// Only what matters to a file of `kind`: a change elsewhere leaves
        /// its candidate as it is.
        func key(for kind: Kind) -> String {
            switch kind {
            case .photo: "\(photoQuality)|\(photoLongestSide ?? 0)|\(photoKeepMetadata)"
            case .png:   "\(pngColours ?? 0)|\(pngDither)"
            case .pdf:   "\(pdfQuality)|\(pdfResolution ?? 0)"
            }
        }
    }

    /// A candidate for `url`, written to `output`. Nothing is said about
    /// whether it is smaller: that is for whoever weighs it.
    static func optimize(_ url: URL, kind: Kind, settings: Settings,
                         to output: URL) throws(Failure) {
        switch kind {
        case .photo: try photo(url, settings, to: output)
        case .png:   try png(url, settings, to: output)
        case .pdf:   try pdf(url, settings, to: output)
        }
    }

    // MARK: - Photos

    private static func photo(_ url: URL, _ settings: Settings, to output: URL) throws(Failure) {
        let name = url.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil)
        else { throw Failure(message: "\u{201C}\(name)\u{201D} could not be read as an image.") }
        let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = original[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = original[kCGImagePropertyPixelHeight] as? Int ?? 0
        let quality: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: settings.photoQuality]

        if let side = settings.photoLongestSide, max(width, height) > side {
            // Smaller, and turned upright on the way, so there is no turn to keep.
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
            ] as CFDictionary) else {
                throw Failure(message: "\u{201C}\(name)\u{201D} could not be made smaller.")
            }
            var properties = settings.photoKeepMetadata ? original : [:]
            properties.removeValue(forKey: kCGImagePropertyPixelWidth)
            properties.removeValue(forKey: kCGImagePropertyPixelHeight)
            properties[kCGImagePropertyOrientation] = 1
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
            if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = image.width
                exif[kCGImagePropertyExifPixelYDimension] = image.height
                properties[kCGImagePropertyExifDictionary] = exif
            }
            CGImageDestinationAddImage(destination, image,
                                       properties.merging(quality) { $1 } as CFDictionary)
        } else if settings.photoKeepMetadata {
            // Encoded again, everything else carried over as it was.
            CGImageDestinationAddImageFromSource(destination, source, 0, quality as CFDictionary)
        } else {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw Failure(message: "\u{201C}\(name)\u{201D} could not be decoded.")
            }
            // The turn that shows it upright is the one thing kept.
            var properties = quality
            properties[kCGImagePropertyOrientation] = original[kCGImagePropertyOrientation] ?? 1
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be written again.")
        }
    }

    // MARK: - PNG

    private static func png(_ url: URL, _ settings: Settings, to output: URL) throws(Failure) {
        let name = url.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be read as an image.")
        }
        var result = image
        if let colours = settings.pngColours,
           let pixels = Pixels(image), pixels.isOpaque,
           let reduced = pixels.palette(colours: colours, dither: settings.pngDither,
                                        space: image.colorSpace) {
            result = reduced
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL,
                                                                UTType.png.identifier as CFString,
                                                                1, nil) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be written again.")
        }
        CGImageDestinationAddImage(destination, result, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be written again.")
        }
    }

    /// Whether a PNG's colours can be reduced: a palette has no room for
    /// transparency here, so a picture with any is written again without loss.
    static func isOpaque(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let pixels = Pixels(image) else { return false }
        return pixels.isOpaque
    }

    /// RGBA, eight bits each, to count colours in.
    struct Pixels {
        let width: Int
        let height: Int
        var data: [UInt8]

        init?(_ image: CGImage) {
            width = image.width
            height = image.height
            data = [UInt8](repeating: 0, count: width * height * 4)
            let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
                ?? CGColorSpace(name: CGColorSpace.sRGB)!
            let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width,
                                              height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
        }

        var isOpaque: Bool {
            var index = 3
            while index < data.count {
                if data[index] != 255 { return false }
                index += 4
            }
            return true
        }

        /// At most `colours`, chosen by median cut over a 15-bit histogram,
        /// each pixel given the nearest -- carrying its error to the next
        /// ones when dithering, Floyd and Steinberg's way.
        func palette(colours: Int, dither: Bool, space: CGColorSpace?) -> CGImage? {
            let palette = Self.medianCut(histogram(), colours: max(2, min(colours, 256)))
            guard !palette.isEmpty else { return nil }
            // The nearest palette entry for each 15-bit colour, once.
            var nearest = [UInt8](repeating: 0, count: 32768)
            for bin in 0..<32768 {
                let r = (bin >> 10) << 3 | 4, g = ((bin >> 5) & 31) << 3 | 4, b = (bin & 31) << 3 | 4
                var best = 0
                var distance = Int.max
                for (index, entry) in palette.enumerated() {
                    let dr = r - entry.0, dg = g - entry.1, db = b - entry.2
                    let d = dr * dr * 2 + dg * dg * 4 + db * db * 3
                    if d < distance { distance = d; best = index }
                }
                nearest[bin] = UInt8(best)
            }
            var indices = [UInt8](repeating: 0, count: width * height)
            if dither {
                // Two rows of error, in sixteenths.
                var current = [Int](repeating: 0, count: (width + 2) * 3)
                var next = current
                for y in 0..<height {
                    for x in 0..<width {
                        let offset = (y * width + x) * 4
                        let e = (x + 1) * 3
                        let r = clamp(Int(data[offset]) + current[e] / 16)
                        let g = clamp(Int(data[offset + 1]) + current[e + 1] / 16)
                        let b = clamp(Int(data[offset + 2]) + current[e + 2] / 16)
                        let index = nearest[(r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)]
                        indices[y * width + x] = index
                        let chosen = palette[Int(index)]
                        func spread(_ channel: Int, _ error: Int) {
                            current[e + 3 + channel] += error * 7
                            next[e - 3 + channel] += error * 3
                            next[e + channel] += error * 5
                            next[e + 3 + channel] += error
                        }
                        spread(0, r - chosen.0)
                        spread(1, g - chosen.1)
                        spread(2, b - chosen.2)
                    }
                    swap(&current, &next)
                    for index in next.indices { next[index] = 0 }
                }
            } else {
                for pixel in 0..<(width * height) {
                    let offset = pixel * 4
                    indices[pixel] = nearest[Int(data[offset] >> 3) << 10
                                             | Int(data[offset + 1] >> 3) << 5
                                             | Int(data[offset + 2] >> 3)]
                }
            }
            var table: [UInt8] = []
            for entry in palette { table += [UInt8(entry.0), UInt8(entry.1), UInt8(entry.2)] }
            let base = space.flatMap { $0.model == .rgb ? $0 : nil }
                ?? CGColorSpace(name: CGColorSpace.sRGB)!
            guard let indexed = CGColorSpace(indexedBaseSpace: base, last: palette.count - 1,
                                             colorTable: table),
                  let provider = CGDataProvider(data: Data(indices) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                           bytesPerRow: width, space: indexed, bitmapInfo: CGBitmapInfo(rawValue: 0),
                           provider: provider, decode: nil, shouldInterpolate: false,
                           intent: .defaultIntent)
        }

        private func clamp(_ value: Int) -> Int { min(255, max(0, value)) }

        private func histogram() -> [Int] {
            var counts = [Int](repeating: 0, count: 32768)
            var offset = 0
            while offset < data.count {
                counts[Int(data[offset] >> 3) << 10 | Int(data[offset + 1] >> 3) << 5
                       | Int(data[offset + 2] >> 3)] += 1
                offset += 4
            }
            return counts
        }

        /// Boxes of 15-bit colours, the most populous widest one split at its
        /// median until there are enough; each box's average is a colour.
        static func medianCut(_ counts: [Int], colours: Int) -> [(Int, Int, Int)] {
            let used = counts.indices.filter { counts[$0] > 0 }
            guard !used.isEmpty else { return [] }
            func channel(_ bin: Int, _ c: Int) -> Int {
                c == 0 ? bin >> 10 : c == 1 ? (bin >> 5) & 31 : bin & 31
            }
            var boxes: [[Int]] = [used]
            while boxes.count < colours {
                // The box with the widest spread, weighted by how much it holds.
                var choice = -1
                var score = 0
                var axis = 0
                for (index, box) in boxes.enumerated() where box.count > 1 {
                    let weight = box.reduce(0) { $0 + counts[$1] }
                    for c in 0..<3 {
                        let values = box.map { channel($0, c) }
                        let spread = (values.max() ?? 0) - (values.min() ?? 0)
                        if spread * weight > score { score = spread * weight; choice = index; axis = c }
                    }
                }
                guard choice >= 0 else { break }
                let box = boxes[choice].sorted { channel($0, axis) < channel($1, axis) }
                let total = box.reduce(0) { $0 + counts[$1] }
                var running = 0
                var cut = 1
                for (index, bin) in box.enumerated() {
                    running += counts[bin]
                    if running * 2 >= total { cut = max(1, min(index + 1, box.count - 1)); break }
                }
                boxes[choice] = Array(box[..<cut])
                boxes.append(Array(box[cut...]))
            }
            return boxes.map { box in
                var r = 0, g = 0, b = 0, n = 0
                for bin in box {
                    let count = counts[bin]
                    r += (channel(bin, 0) << 3 | 4) * count
                    g += (channel(bin, 1) << 3 | 4) * count
                    b += (channel(bin, 2) << 3 | 4) * count
                    n += count
                }
                return n == 0 ? (0, 0, 0) : (r / n, g / n, b / n)
            }
        }
    }

    // MARK: - PDF

    private static func pdf(_ url: URL, _ settings: Settings, to output: URL) throws(Failure) {
        let name = url.lastPathComponent
        guard let document = PDFDocument(url: url) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be read as a PDF.")
        }
        guard !document.isLocked else {
            throw Failure(message: "\u{201C}\(name)\u{201D} is protected by a password.")
        }
        let pictures = pictures(in: url)
        guard pictures.count > 0 else {
            throw Failure(message: "It has no pictures; only pictures are made smaller.",
                          pointless: true)
        }
        guard !pictures.allBilevel else {
            throw Failure(message: "A black-and-white scan, one bit per pixel, is already "
                          + "compact: as JPEG, which has at least eight, it would only grow.",
                          pointless: true)
        }
        let filterURL = output.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".qfilter")
        defer { try? FileManager.default.removeItem(at: filterURL) }
        guard (filterDefinition(settings) as NSDictionary).write(to: filterURL, atomically: true),
              let filter = QuartzFilter(url: filterURL) else {
            throw Failure(message: "The filter for \u{201C}\(name)\u{201D} could not be made.")
        }
        guard document.write(to: output, withOptions: [
            PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter,
        ]) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be written again.")
        }
    }

    /// The same keys as /System/Library/Filters/Reduce File Size.qfilter,
    /// with the values chosen.
    static func filterDefinition(_ settings: Settings) -> [String: Any] {
        var image: [String: Any] = [
            "Compression Quality": settings.pdfQuality,
            "ImageCompression": "ImageJPEGCompress",
        ]
        if let resolution = settings.pdfResolution {
            image["ImageScaleSettings"] = [
                "ImageResolution": resolution,
                "ImageScaleInterpolate": true,
                "ImageSizeMax": 0,
                "ImageSizeMin": 0,
            ] as [String: Any]
        }
        return [
            "Domains": ["Applications": true],
            "FilterType": 1,
            "Name": "Diptych Optimize",
            "FilterData": ["ColorSettings": ["ImageSettings": image]],
        ]
    }

    // MARK: - What is in a PDF

    /// The pictures in a PDF, as stored: what decides whether a filter that
    /// writes them all as JPEG can make it smaller.
    struct PDFPictures: Equatable, Sendable {
        var count = 0
        /// One bit per pixel, or CCITT or JBIG2: a black-and-white scan. JPEG
        /// has at least eight bits, so it would only grow.
        var bilevel = 0
        /// Pixels per inch, worked out as if each picture filled its page's
        /// width -- which a scan does. Nil without pictures.
        var lowestResolution: Int?
        var highestResolution: Int?

        var allBilevel: Bool { count > 0 && bilevel == count }

        var resolution: String? {
            guard let low = lowestResolution, let high = highestResolution else { return nil }
            return low == high || high - low < 10 ? "about \(high) ppi" : "\(low) to \(high) ppi"
        }

        var summary: String {
            guard count > 0 else { return "No pictures: nothing for the filter to make smaller." }
            var text = count == 1 ? "1 picture" : "\(count) pictures"
            if let resolution { text += ", \(resolution)" }
            if allBilevel {
                text += ", black and white (1 bit)"
            } else if bilevel > 0 {
                text += "; \(bilevel) black and white (1 bit)"
            }
            return text
        }
    }

    static func pictures(in url: URL) -> PDFPictures {
        var found = PDFPictures()
        guard let document = CGPDFDocument(url as CFURL) else { return found }
        var resolutions: [Int] = []
        for number in 1...max(document.numberOfPages, 1) {
            guard let page = document.page(at: number),
                  let dictionary = page.dictionary else { continue }
            let width = page.getBoxRect(.mediaBox).width
            var resources: CGPDFDictionaryRef?
            var objects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources),
                  let resources,
                  CGPDFDictionaryGetDictionary(resources, "XObject", &objects),
                  let objects else { continue }
            final class Box { var images: [CGPDFStreamRef] = [] }
            let box = Box()
            CGPDFDictionaryApplyBlock(objects, { _, object, info in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      let streamDictionary = CGPDFStreamGetDictionary(stream) else { return true }
                var subtype: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(streamDictionary, "Subtype", &subtype), let subtype,
                   String(cString: subtype) == "Image" {
                    Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue().images.append(stream)
                }
                return true
            }, Unmanaged.passUnretained(box).toOpaque())
            for image in box.images {
                guard let info = CGPDFStreamGetDictionary(image) else { continue }
                found.count += 1
                var bits: CGPDFInteger = 8
                CGPDFDictionaryGetInteger(info, "BitsPerComponent", &bits)
                var mask: CGPDFBoolean = 0
                CGPDFDictionaryGetBoolean(info, "ImageMask", &mask)
                let filters = Self.filters(info)
                if bits == 1 || mask != 0 || filters.contains("CCITTFaxDecode")
                    || filters.contains("JBIG2Decode") {
                    found.bilevel += 1
                }
                var pixels: CGPDFInteger = 0
                if CGPDFDictionaryGetInteger(info, "Width", &pixels), width > 0 {
                    resolutions.append(Int((Double(pixels) / (width / 72)).rounded()))
                }
            }
        }
        found.lowestResolution = resolutions.min()
        found.highestResolution = resolutions.max()
        return found
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

    // MARK: - Looking at it

    /// The picture as shown, for the comparison: upright, at most
    /// `maxPixels` on its longest side; a PDF's page `page`.
    static func preview(of url: URL, kind: Kind, page: Int = 0, maxPixels: Int = 3000) -> CGImage? {
        switch kind {
        case .photo, .png:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        case .pdf:
            guard let document = PDFDocument(url: url),
                  let pdfPage = document.page(at: min(page, max(document.pageCount - 1, 0))) else {
                return nil
            }
            let bounds = pdfPage.bounds(for: .mediaBox)
            let scale = Double(maxPixels) / max(bounds.width, bounds.height, 1)
            let size = CGSize(width: (bounds.width * scale).rounded(),
                              height: (bounds.height * scale).rounded())
            let image = pdfPage.thumbnail(of: size, for: .mediaBox)
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
    }

    static func pageCount(of url: URL) -> Int {
        PDFDocument(url: url)?.pageCount ?? 1
    }

    static func size(of url: URL) -> Int64? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Int64(info.st_size)
    }
}
