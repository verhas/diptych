import CoreGraphics
import Foundation
import ImageIO
import libwebp

/// WebP, which macOS reads but does not write: encoded with Google's libwebp.
/// The picture goes in upright -- WebP has no orientation most programs
/// honour -- with its colour profile and, when kept, its metadata as XMP.
nonisolated enum WebPWriting {

    /// At a quality of 1, lossless: every pixel kept exactly.
    static func encode(_ image: CGImage, quality: Double, xmp: Data?) -> Data? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= Int(WEBP_MAX_DIMENSION),
              height <= Int(WEBP_MAX_DIMENSION) else { return nil }

        // RGBA, 8 bits, in the picture's own colour space when it is RGB.
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: stride, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // libwebp takes colour not multiplied by its alpha.
        for index in Swift.stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            guard alpha != 0, alpha != 255 else { continue }
            for channel in 0..<3 {
                pixels[index + channel] = UInt8(min(255, (Int(pixels[index + channel]) * 255
                                                          + alpha / 2) / alpha))
            }
        }

        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { return nil }
        if quality >= 1 {
            config.lossless = 1
            config.quality = 75   // effort, for lossless
            config.exact = 1      // the colour under clear pixels too
        } else {
            config.quality = Float(max(0, quality) * 100)
        }
        config.method = 4
        guard WebPValidateConfig(&config) != 0 else { return nil }

        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { return nil }
        defer { WebPPictureFree(&picture) }
        picture.width = Int32(width)
        picture.height = Int32(height)
        picture.use_argb = 1
        guard WebPPictureImportRGBA(&picture, pixels, Int32(stride)) != 0 else { return nil }

        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }
        let encoded = withUnsafeMutablePointer(to: &writer) { pointer -> Bool in
            picture.writer = WebPMemoryWrite
            picture.custom_ptr = UnsafeMutableRawPointer(pointer)
            return WebPEncode(&config, &picture) != 0
        }
        guard encoded, let bytes = writer.mem else { return nil }
        let bitstream = Data(bytes: bytes, count: writer.size)

        let icc = space.copyICCData() as Data?
        guard icc != nil || xmp != nil else { return bitstream }
        return withChunks(bitstream, icc: icc, xmp: xmp)
    }

    /// The original's metadata as XMP, for a WebP: upright, at its new size.
    static func xmp(_ source: CGImageSource, _ image: CGImage) -> Data? {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let copy = CGImageMetadataCreateMutableCopy(metadata) else { return nil }
        CGImageMetadataRemoveTagWithPath(copy, nil, "tiff:Orientation" as CFString)
        CGImageMetadataSetValueMatchingImageProperty(
            copy, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelXDimension,
            image.width as CFNumber)
        CGImageMetadataSetValueMatchingImageProperty(
            copy, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelYDimension,
            image.height as CFNumber)
        guard let tags = CGImageMetadataCopyTags(copy) as? [CGImageMetadataTag],
              !tags.isEmpty else { return nil }
        return CGImageMetadataCreateXMPData(copy, nil) as Data?
    }

    /// Whether the WebP in `data` keeps every pixel: its image is a VP8L
    /// bitstream, not a lossy VP8 one. Read from the RIFF chunks.
    static func isLossless(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 20, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46],   // RIFF
              bytes[8..<12] == [0x57, 0x45, 0x42, 0x50] else { return false } // WEBP
        var offset = 12
        while offset + 8 <= bytes.count {
            let tag = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            if tag == "VP8L" { return true }
            if tag == "VP8 " { return false }
            let size = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8
                | Int(bytes[offset + 6]) << 16 | Int(bytes[offset + 7]) << 24
            offset += 8 + size + (size & 1)
        }
        return false
    }

    /// The bitstream in an extended WebP with the profile and XMP chunks.
    private static func withChunks(_ bitstream: Data, icc: Data?, xmp: Data?) -> Data? {
        guard let mux = WebPMuxNew() else { return nil }
        defer { WebPMuxDelete(mux) }
        func set(_ data: Data, _ add: (UnsafePointer<WebPData>) -> WebPMuxError) -> Bool {
            data.withUnsafeBytes { raw in
                var chunk = WebPData(bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                                     size: raw.count)
                return add(&chunk) == WEBP_MUX_OK
            }
        }
        guard set(bitstream, { WebPMuxSetImage(mux, $0, 1) }) else { return nil }
        if let icc, !set(icc, { WebPMuxSetChunk(mux, "ICCP", $0, 1) }) { return nil }
        if let xmp, !set(xmp, { WebPMuxSetChunk(mux, "XMP ", $0, 1) }) { return nil }
        var assembled = WebPData()
        guard WebPMuxAssemble(mux, &assembled) == WEBP_MUX_OK, let bytes = assembled.bytes else {
            return nil
        }
        defer { WebPDataClear(&assembled) }
        return Data(bytes: bytes, count: assembled.size)
    }
}
