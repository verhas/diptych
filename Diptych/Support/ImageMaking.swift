import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// New images made from images: another format, a smaller size, the subject
/// cut out of its background. Always a new file, next to the original or in
/// a folder given; the original is never touched.
nonisolated enum ImageMaking {

    struct Failure: Error, Sendable {
        let message: String
    }

    enum Format: String, CaseIterable, Sendable, Identifiable {
        case same, jpeg, heic, png, tiff

        var id: String { rawValue }

        var title: String {
            switch self {
            case .same: "Keep the format"
            case .jpeg: "JPEG"
            case .heic: "HEIC"
            case .png:  "PNG"
            case .tiff: "TIFF"
            }
        }

        var type: UTType? {
            switch self {
            case .same: nil
            case .jpeg: .jpeg
            case .heic: .heic
            case .png:  .png
            case .tiff: .tiff
            }
        }

        /// Whether a quality is asked for: JPEG and HEIC lose some.
        var isLossy: Bool { self == .jpeg || self == .heic }

        /// This Mac can write it: HEIC needs the hardware for it.
        var isWritable: Bool {
            guard let type else { return true }
            let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
            return writable.contains(type.identifier)
        }
    }

    struct Options: Sendable, Equatable {
        var format: Format = .same
        /// 0 to 1, for JPEG and HEIC.
        var quality = 0.85
        /// The longest side, in pixels; nil keeps the size. An image already
        /// smaller is not made larger.
        var longestSide: Int?
        var keepMetadata = true
        /// Where the new images go; nil is next to each original.
        var folder: URL?

        /// Nothing would come of it: the same format at the same size.
        var changesNothing: Bool { format == .same && longestSide == nil }
    }

    // MARK: - Names

    /// `IMG_1.heic` → `IMG_1.jpg`; resized, `IMG_1 (2048).jpg`; never over
    /// an existing file: `IMG_1-1.jpg` then.
    static func target(for url: URL, extension ext: String, label: String? = nil,
                       folder: URL? = nil) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        let name = label.map { "\(stem) (\($0))" } ?? stem
        let place = folder ?? url.deletingLastPathComponent()
        return FileOperations.uniqueURL(
            for: place.appendingPathComponent(name).appendingPathExtension(ext))
    }

    static func fileExtension(of url: URL, format: Format) -> String {
        switch format {
        case .same: url.pathExtension.isEmpty ? "png" : url.pathExtension
        case .jpeg: "jpg"
        case .heic: "heic"
        case .png:  "png"
        case .tiff: "tiff"
        }
    }

    // MARK: - Convert and resize

    /// The new image, written; its URL.
    static func convert(_ url: URL, _ options: Options) throws(Failure) -> URL {
        let name = url.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let sourceType = CGImageSourceGetType(source) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be read as an image.")
        }
        let type = options.format.type?.identifier as CFString? ?? sourceType
        let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            ?? [:]
        var properties = options.keepMetadata ? original : [:]
        let orientation = ExifWrite.orientation(of: source)
        let width = original[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = original[kCGImagePropertyPixelHeight] as? Int ?? 0

        var image: CGImage?
        var label: String?
        if let side = options.longestSide, max(width, height) > side {
            // Smaller, and turned upright on the way: the thumbnail is drawn
            // as it is shown, so the new image has no turn to keep.
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
            ] as CFDictionary)
            label = "\(side)"
            properties[kCGImagePropertyOrientation] = 1
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            // The pixels as stored: the turn that shows them upright goes along.
            properties[kCGImagePropertyOrientation] = orientation
        }
        guard var image else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be decoded.")
        }
        // The new size, where the metadata says one.
        properties.removeValue(forKey: kCGImagePropertyPixelWidth)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight)
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if options.format == .jpeg, image.alphaInfo.hasAlpha, let flat = flattened(image) {
            // JPEG has no transparency: on white, as a page would show it.
            image = flat
        }
        if options.format.isLossy || (options.format == .same && isLossy(sourceType)) {
            properties[kCGImageDestinationLossyCompressionQuality] = options.quality
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            throw Failure(message: "This Mac cannot write \(options.format.title) images.")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be written as "
                          + "\(options.format == .same ? "it was" : options.format.title).")
        }
        let target = target(for: url, extension: fileExtension(of: url, format: options.format),
                            label: label, folder: options.folder)
        return try write(output as Data, to: target)
    }

    private static func isLossy(_ type: CFString) -> Bool {
        [UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier]
            .contains(type as String)
    }

    /// On white, without transparency.
    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let all = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(all)
        context.draw(image, in: all)
        return context.makeImage()
    }

    private static func write(_ data: Data, to target: URL) throws(Failure) -> URL {
        do {
            try data.write(to: target, options: .withoutOverwriting)
            return target
        } catch {
            throw Failure(message: "\u{201C}\(target.lastPathComponent)\u{201D} could not be "
                          + "written: \(error.localizedDescription)")
        }
    }

    // MARK: - Text in the picture

    /// Where text read from a picture is kept.
    enum TextPlace: String, Sendable, CaseIterable {
        /// The Spotlight comment attribute: Diptych, Spotlight and the flat
        /// view's `xattr` see it; Finder's Get Info does not.
        case comment
        /// `IMG_1.jpg.txt` beside it: every tool reads it.
        case sidecar
    }

    static let commentAttribute = "com.apple.metadata:kMDItemFinderComment"

    /// What Vision reads in the picture, line by line; empty for none.
    static func text(in url: URL) throws(Failure) -> String {
        let name = url.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 100_000,
              ] as CFDictionary) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be read as an image.")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            throw Failure(message: "The text of \u{201C}\(name)\u{201D} could not be read: "
                          + error.localizedDescription)
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// The comment attribute's value for `text`: a property list string, as
    /// Spotlight keeps it.
    static func commentData(_ text: String) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: text, format: .binary, options: 0)
    }

    static func sidecar(for url: URL) -> URL {
        url.appendingPathExtension("txt")
    }

    // MARK: - Remove the background

    /// The subjects Vision finds in the picture, on a transparent
    /// background, as `IMG_1 (cut out).png`.
    static func cutOut(_ url: URL, folder: URL? = nil) throws(Failure) -> URL {
        let name = url.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  // Upright, at full size.
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 100_000,
              ] as CFDictionary) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be read as an image.")
        }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
        } catch {
            throw Failure(message: "The subject of \u{201C}\(name)\u{201D} could not be found: "
                          + error.localizedDescription)
        }
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw Failure(message: "No subject was found in \u{201C}\(name)\u{201D} to cut out.")
        }
        let masked: CVPixelBuffer
        do {
            masked = try result.generateMaskedImage(ofInstances: result.allInstances,
                                                    from: handler, croppedToInstancesExtent: false)
        } catch {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be cut out: "
                          + error.localizedDescription)
        }
        let picture = CIImage(cvPixelBuffer: masked)
        let context = CIContext()
        guard let cut = context.createCGImage(picture, from: picture.extent) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be cut out.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(message: "PNG cannot be written.")
        }
        CGImageDestinationAddImage(destination, cut, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(message: "The cut-out of \u{201C}\(name)\u{201D} could not be written.")
        }
        return try write(output as Data,
                         to: target(for: url, extension: "png", label: "cut out", folder: folder))
    }
}

private extension CGImageAlphaInfo {
    nonisolated var hasAlpha: Bool {
        switch self {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}
