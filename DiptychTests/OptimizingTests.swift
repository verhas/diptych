import XCTest
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import Diptych

/// File ▸ Optimize File Size…: photos encoded again, PNGs given a palette,
/// PDFs through a Quartz filter, and the originals replaced in place.
final class OptimizingTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychOptimizing-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    /// Blurred noise: compresses like a photo, not like a flat drawing.
    private func picture(width: Int = 1600, height: Int = 1200, alpha: Bool = false) -> CGImage {
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        var image = noise.applyingGaussianBlur(sigma: 4).cropped(to: noise.extent)
        if !alpha {
            image = image.settingAlphaOne(in: image.extent)
        }
        return CIContext().createCGImage(image, from: image.extent,
                                         format: .RGBA8,
                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
    }

    private func write(_ image: CGImage, as type: UTType, named name: String,
                       properties: [CFString: Any] = [:]) -> URL {
        let url = root.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString,
                                                          1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func optimize(_ url: URL, _ settings: Optimizing.Settings) throws -> URL {
        let output = root.appendingPathComponent("out-\(UUID().uuidString).\(url.pathExtension)")
        let kind = try XCTUnwrap(Optimizing.kind(of: url))
        do { try Optimizing.optimize(url, kind: kind, settings: settings, to: output) }
        catch { XCTFail(error.message) }
        return output
    }

    private func properties(_ url: URL) -> [CFString: Any] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    private func size(_ url: URL) -> Int64 { Optimizing.size(of: url) ?? 0 }

    // MARK: - Photos

    private func photo() -> URL {
        write(picture(), as: .jpeg, named: "photo.jpg", properties: [
            kCGImageDestinationLossyCompressionQuality: 0.98,
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 47.5,
                                            kCGImagePropertyGPSLatitudeRef: "N"],
        ])
    }

    func testAPhotoGetsSmallerAndKeepsItsTurnAndItsLocation() throws {
        let original = photo()
        var settings = Optimizing.Settings()
        settings.photoQuality = 0.6
        let smaller = try optimize(original, settings)

        XCTAssertLessThan(size(smaller), size(original) / 2)
        let kept = properties(smaller)
        XCTAssertEqual(kept[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertNotNil(kept[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(kept[kCGImagePropertyPixelWidth] as? Int, 1600)
    }

    func testAPhotoCanLeaveItsMetadataButNotItsTurn() throws {
        var settings = Optimizing.Settings()
        settings.photoKeepMetadata = false
        let smaller = try optimize(photo(), settings)
        let kept = properties(smaller)
        XCTAssertNil(kept[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(kept[kCGImagePropertyOrientation] as? Int, 6)
    }

    func testAPhotoMadeSmallerIsTurnedUpright() throws {
        var settings = Optimizing.Settings()
        settings.photoLongestSide = 800
        let smaller = try optimize(photo(), settings)
        let kept = properties(smaller)
        // Turned a quarter: 1600 × 1200 shown as 1200 × 1600.
        XCTAssertEqual(kept[kCGImagePropertyPixelWidth] as? Int, 600)
        XCTAssertEqual(kept[kCGImagePropertyPixelHeight] as? Int, 800)
        XCTAssertEqual(kept[kCGImagePropertyOrientation] as? Int ?? 1, 1)
    }

    // MARK: - PNG

    func testAnOpaquePNGGetsAPalette() throws {
        let original = write(picture(), as: .png, named: "shot.png")
        var settings = Optimizing.Settings()
        settings.pngColours = 64
        let smaller = try optimize(original, settings)

        XCTAssertLessThan(size(smaller), size(original) / 2)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            CGImageSourceCreateWithURL(smaller as CFURL, nil)!, 0, nil))
        XCTAssertEqual(image.colorSpace?.model, .indexed)
        XCTAssertLessThanOrEqual((image.colorSpace?.colorTable?.count ?? 999) / 3, 64)
        XCTAssertEqual(image.width, 1600)
    }

    func testAPNGWithTransparencyKeepsItsColours() throws {
        let original = write(picture(alpha: true), as: .png, named: "clear.png")
        XCTAssertFalse(Optimizing.isOpaque(original))
        let written = try optimize(original, Optimizing.Settings())
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            CGImageSourceCreateWithURL(written as CFURL, nil)!, 0, nil))
        XCTAssertNotEqual(image.colorSpace?.model, .indexed)
        XCTAssertTrue(image.alphaInfo != .none && image.alphaInfo != .noneSkipLast)
    }

    func testMedianCutGivesAtMostTheColoursAsked() {
        var counts = [Int](repeating: 0, count: 32768)
        for bin in stride(from: 0, to: 32768, by: 7) { counts[bin] = bin % 13 + 1 }
        let palette = Optimizing.Pixels.medianCut(counts, colours: 16)
        XCTAssertEqual(palette.count, 16)
        XCTAssertTrue(palette.allSatisfy { (0...255).contains($0.0) && (0...255).contains($0.2) })
        XCTAssertEqual(Optimizing.Pixels.medianCut([Int](repeating: 0, count: 32768), colours: 8).count, 0)
    }

    // MARK: - PDF

    func testAPDFGetsSmallerAndKeepsItsLinks() throws {
        let jpeg = write(picture(width: 2400, height: 1800), as: .jpeg, named: "page.jpg",
                         properties: [kCGImageDestinationLossyCompressionQuality: 0.98])
        let document = PDFDocument()
        let page = try XCTUnwrap(PDFPage(image: NSImage(contentsOf: jpeg)!))
        let link = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 100, height: 20),
                                 forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com")
        page.addAnnotation(link)
        document.insert(page, at: 0)
        let original = root.appendingPathComponent("doc.pdf")
        XCTAssertTrue(document.write(to: original))

        var settings = Optimizing.Settings()
        settings.pdfQuality = 0.4
        let smaller = try optimize(original, settings)
        XCTAssertLessThan(size(smaller), size(original) * 3 / 4)
        let back = try XCTUnwrap(PDFDocument(url: smaller))
        XCTAssertEqual(back.pageCount, 1)
        XCTAssertEqual(back.page(at: 0)?.annotations.first?.url, URL(string: "https://example.com"))
        XCTAssertNotNil(Optimizing.preview(of: smaller, kind: .pdf, maxPixels: 400))
    }

    /// An A4 page holding one picture drawn edge to edge, as a scanner
    /// makes it, `bits` per pixel.
    private func scan(bits: Int, named name: String) throws -> URL {
        let width = 1240, height = 1754   // 150 ppi on A4
        var pixels = [UInt8](repeating: 0, count: (width * bits + 7) / 8 * height)
        for index in pixels.indices where index % 3 == 0 { pixels[index] = 0xA5 }
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits,
            bytesPerRow: (width * bits + 7) / 8, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let url = root.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 595.2, height: 841.68)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    func testAPDFSaysWhatPicturesItHolds() throws {
        let grey = Optimizing.pictures(in: try scan(bits: 8, named: "grey.pdf"))
        XCTAssertEqual(grey.count, 1)
        XCTAssertEqual(grey.bilevel, 0)
        XCTAssertEqual(grey.resolution, "about 150 ppi")
        XCTAssertEqual(grey.summary, "1 picture, about 150 ppi")
    }

    func testABlackAndWhiteScanIsLeftAsItIs() throws {
        let original = try scan(bits: 1, named: "bw.pdf")
        let pictures = Optimizing.pictures(in: original)
        XCTAssertTrue(pictures.allBilevel, "\(pictures)")
        XCTAssertTrue(pictures.summary.hasSuffix("black and white (1 bit)"))
        let output = root.appendingPathComponent("bw-out.pdf")
        XCTAssertThrowsError(try Optimizing.optimize(original, kind: .pdf,
                                                     settings: Optimizing.Settings(), to: output)) {
            XCTAssertEqual(($0 as? Optimizing.Failure)?.pointless, true)
        }
        XCTAssertFalse(fm.fileExists(atPath: output.path))
    }

    func testTheFilterIsReduceFileSizeWithOurValues() {
        var settings = Optimizing.Settings()
        settings.pdfQuality = 0.5
        settings.pdfResolution = nil
        let data = Optimizing.filterDefinition(settings)["FilterData"] as? [String: Any]
        let image = ((data?["ColorSettings"] as? [String: Any])?["ImageSettings"]) as? [String: Any]
        XCTAssertEqual(image?["Compression Quality"] as? Double, 0.5)
        XCTAssertNil(image?["ImageScaleSettings"], "no resolution: the pictures keep theirs")
    }

    // MARK: - Putting it in place

    @MainActor
    func testReplacingKeepsTheFileAndItsDateAndUndoPutsItBack() async throws {
        let original = photo()
        let date = FileHistory.FileTime(seconds: 1_600_000_000, nanoseconds: 123_456_789)
        try FileHistory.setDate(.modified, date, of: original)
        let before = try Data(contentsOf: original)
        let inode = try fm.attributesOfItem(atPath: original.path)[.systemFileNumber] as? Int
        var settings = Optimizing.Settings()
        settings.photoQuality = 0.5
        let candidate = try optimize(original, settings)
        let history = FileHistory()

        let outcome = await OptimizeModel.apply([(original, candidate)], settings: settings,
                                                history: history)
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(try Data(contentsOf: original), try Data(contentsOf: candidate))
        XCTAssertEqual(try fm.attributesOfItem(atPath: original.path)[.systemFileNumber] as? Int,
                       inode, "the same file")
        XCTAssertEqual(FileHistory.exactDate(.modified, of: original), date)

        await history.perform(.undo) { _ in true }
        XCTAssertEqual(try Data(contentsOf: original), before)
    }

    @MainActor
    func testBesideMakesANewFile() async throws {
        let original = photo()
        var settings = Optimizing.Settings()
        settings.replaceOriginals = false
        let candidate = try optimize(original, settings)
        let before = try Data(contentsOf: original)

        let outcome = await OptimizeModel.apply([(original, candidate)], settings: settings,
                                                history: FileHistory())
        XCTAssertEqual(outcome.done.map(\.lastPathComponent), ["photo (optimized).jpg"])
        XCTAssertEqual(try Data(contentsOf: original), before)
    }

    func testKinds() {
        XCTAssertEqual(Optimizing.kind(of: URL(fileURLWithPath: "/a/B.JPEG")), .photo)
        XCTAssertEqual(Optimizing.kind(of: URL(fileURLWithPath: "/a/b.heic")), .photo)
        XCTAssertEqual(Optimizing.kind(of: URL(fileURLWithPath: "/a/b.png")), .png)
        XCTAssertEqual(Optimizing.kind(of: URL(fileURLWithPath: "/a/b.pdf")), .pdf)
        XCTAssertNil(Optimizing.kind(of: URL(fileURLWithPath: "/a/b.tiff")))
        var settings = Optimizing.Settings()
        let photoKey = settings.key(for: .photo)
        settings.pdfQuality = 0.3
        XCTAssertEqual(settings.key(for: .photo), photoKey, "a PDF setting leaves photos as they are")
    }
}
