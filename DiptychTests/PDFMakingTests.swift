import XCTest
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import Diptych

/// Image ▸ Make PDF…: a page for each picture and each page of a TIFF.
final class PDFMakingTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychPDFMaking-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    /// Red in the top left, green top right, blue bottom left, yellow
    /// bottom right, as stored.
    private func quarters(width: Int = 160, height: Int = 120) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let w = CGFloat(width) / 2, h = CGFloat(height) / 2
        // y up: the top is the upper half.
        for (colour, rect) in [((1.0, 0.0, 0.0), CGRect(x: 0, y: h, width: w, height: h)),
                               ((0.0, 1.0, 0.0), CGRect(x: w, y: h, width: w, height: h)),
                               ((0.0, 0.0, 1.0), CGRect(x: 0, y: 0, width: w, height: h)),
                               ((1.0, 1.0, 0.0), CGRect(x: w, y: 0, width: w, height: h))] {
            context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1)
            context.fill(rect)
        }
        return context.makeImage()!
    }

    private func write(_ images: [CGImage], as type: UTType, named name: String,
                       properties: [CFString: Any] = [:]) -> URL {
        let url = root.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString,
                                                          images.count, nil)!
        for image in images { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func make(_ urls: [URL], _ size: PDFMaking.PageSize = .picture) throws -> PDFDocument {
        let target = root.appendingPathComponent("out-\(UUID().uuidString).pdf")
        do { try PDFMaking.write(urls, to: target, pageSize: size) } catch { XCTFail(error.message) }
        return try XCTUnwrap(PDFDocument(url: target))
    }

    /// The colour at a corner of a picture, a little way in, as names.
    private func corner(_ image: CGImage, top: Bool, left: Bool) -> String {
        let context = CGContext(data: nil, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        // Memory rows run from the top.
        let x = left ? image.width / 8 : image.width * 7 / 8
        let y = top ? image.height / 8 : image.height * 7 / 8
        let at = (y * image.width + x) * 4
        let (r, g, b) = (data[at] > 128, data[at + 1] > 128, data[at + 2] > 128)
        switch (r, g, b) {
        case (true, false, false): return "red"
        case (false, true, false): return "green"
        case (false, false, true): return "blue"
        case (true, true, false):  return "yellow"
        default: return "other \(data[at]),\(data[at + 1]),\(data[at + 2])"
        }
    }

    private func corners(_ image: CGImage) -> [String] {
        [corner(image, top: true, left: true), corner(image, top: true, left: false),
         corner(image, top: false, left: true), corner(image, top: false, left: false)]
    }

    private func rendered(_ page: PDFPage) -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        return page.thumbnail(of: CGSize(width: bounds.width, height: bounds.height), for: .mediaBox)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    // MARK: -

    func testEveryOrientationIsUprightAsImageIOShowsIt() throws {
        for orientation in 1...8 {
            let url = write([quarters()], as: .jpeg, named: "o\(orientation).jpg", properties: [
                kCGImagePropertyOrientation: orientation,
                kCGImageDestinationLossyCompressionQuality: 1.0,
            ])
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
            ] as CFDictionary)!
            let document = try make([url])
            let page = try XCTUnwrap(document.page(at: 0))
            let bounds = page.bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width > bounds.height, upright.width > upright.height,
                           "orientation \(orientation)")
            XCTAssertEqual(corners(rendered(page)), corners(upright), "orientation \(orientation)")
        }
    }

    func testAJPEGGoesInAsItIs() throws {
        let photo = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600))
        let image = CIContext().createCGImage(photo, from: photo.extent)!
        let url = write([image], as: .jpeg, named: "photo.jpg",
                        properties: [kCGImageDestinationLossyCompressionQuality: 0.7])
        let target = root.appendingPathComponent("photo.pdf")
        do { try PDFMaking.write([url], to: target, pageSize: .picture) } catch { XCTFail(error.message) }
        let jpeg = try XCTUnwrap(Optimizing.size(of: url))
        let pdf = try XCTUnwrap(Optimizing.size(of: target))
        XCTAssertLessThan(pdf, jpeg + 20_000, "not decoded and stored again")
        XCTAssertNotNil(try Data(contentsOf: target).range(of: Data("/DCTDecode".utf8)))
    }

    func testAMultiPageTIFFGivesAPageEach() throws {
        let tiff = write([quarters(), quarters(width: 60, height: 90), quarters()], as: .tiff,
                         named: "three.tif")
        XCTAssertEqual(PDFMaking.pageCount(of: tiff), 3)
        let document = try make([tiff])
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertEqual(document.page(at: 1)?.bounds(for: .mediaBox).size, CGSize(width: 60, height: 90))
    }

    func testAnOldStyleJPEGTIFFIsReadThroughItsJPEGs() throws {
        let jpeg = try Data(contentsOf: write([quarters()], as: .jpeg, named: "q.jpg"))
        // As Office Document Imaging wrote it: the JPEG, then a directory of
        // compression 6 pointing at it, twice.
        func bytes(_ value: Int, _ size: Int) -> [UInt8] { (0..<size).map { UInt8((value >> (8 * $0)) & 0xFF) } }
        var file: [UInt8] = [0x49, 0x49] + bytes(42, 2) + bytes(0, 4)
        var next = 4
        for _ in 0..<2 {
            let start = file.count
            file += jpeg
            file.replaceSubrange(next..<(next + 4), with: bytes(file.count, 4))
            let entries: [(Int, Int, Int)] = [(256, 4, 160), (257, 4, 120), (259, 3, 6),
                                              (513, 4, start), (514, 4, jpeg.count)]
            file += bytes(entries.count, 2)
            for (tag, type, value) in entries {
                file += bytes(tag, 2) + bytes(type, 2) + bytes(1, 4)
                file += type == 3 ? bytes(value, 2) + [0, 0] : bytes(value, 4)
            }
            next = file.count
            file += bytes(0, 4)
        }
        let tiff = root.appendingPathComponent("old.tif")
        try Data(file).write(to: tiff)

        XCTAssertEqual(PDFMaking.pageCount(of: tiff), 2)
        let document = try make([tiff])
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(corners(rendered(document.page(at: 1)!)), ["red", "green", "blue", "yellow"])
    }

    func testThePageIsThePicturesOwnSizeFromItsResolution() throws {
        let url = write([quarters(width: 2480, height: 3508)], as: .png, named: "a4.png", properties: [
            kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300,
        ])
        let size = try XCTUnwrap(try make([url]).page(at: 0)?.bounds(for: .mediaBox).size)
        XCTAssertEqual(size.width, 595.2, accuracy: 0.5)
        XCTAssertEqual(size.height, 841.9, accuracy: 0.5)
    }

    func testOnA4AWidePictureGetsALandscapePage() throws {
        let url = write([quarters(width: 400, height: 200)], as: .png, named: "wide.png")
        let page = try XCTUnwrap(try make([url], .a4).page(at: 0))
        let size = page.bounds(for: .mediaBox).size
        XCTAssertEqual(size.width, 841.89, accuracy: 0.1)
        XCTAssertEqual(size.height, 595.28, accuracy: 0.1)
    }

    func testSeveralPicturesInOnePDFInOrder() throws {
        let a = write([quarters(width: 100, height: 50)], as: .png, named: "a.png")
        let b = write([quarters(width: 50, height: 100)], as: .png, named: "b.png")
        let document = try make([a, b])
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).width, 100)
        XCTAssertEqual(document.page(at: 1)?.bounds(for: .mediaBox).width, 50)
    }

    func testANameTakenIsNotWrittenOver() throws {
        let a = write([quarters()], as: .png, named: "a.png")
        let target = root.appendingPathComponent("taken.pdf")
        try Data("mine".utf8).write(to: target)
        XCTAssertThrowsError(try PDFMaking.write([a], to: target, pageSize: .picture))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "mine")
    }
}
