import XCTest
import ImageIO
import UniformTypeIdentifiers
import CoreText
@testable import Diptych

/// Convert, Resize and Remove Background: new images, the originals left
/// alone, one Undo step that trashes what was made.
final class ImageMakingTests: XCTestCase {

    private var folder: URL!

    override func setUp() async throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychImages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// 400 × 300, with a half-transparent corner when asked.
    private func image(_ name: String, type: UTType = .jpeg, alpha: Bool = false,
                       properties: [CFString: Any] = [:]) -> URL {
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                                                  : CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        if alpha { context.clear(CGRect(x: 0, y: 0, width: 100, height: 100)) }
        let url = folder.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString,
                                                          1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func info(_ url: URL) -> (type: String, width: Int, height: Int, properties: [CFString: Any]) {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        return (CGImageSourceGetType(source)! as String,
                properties[kCGImagePropertyPixelWidth] as! Int,
                properties[kCGImagePropertyPixelHeight] as! Int, properties)
    }

    func testAnotherFormatKeepsTheMetadataAndTheOriginal() throws {
        let url = image("a.png", type: .png, properties: [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "50mm"],
        ])
        let original = try Data(contentsOf: url)
        var options = ImageMaking.Options()
        options.format = .jpeg
        let made = try ImageMaking.convert(url, options)
        XCTAssertEqual(made.lastPathComponent, "a.jpg")
        let found = info(made)
        XCTAssertEqual(found.type, UTType.jpeg.identifier)
        XCTAssertEqual(found.width, 400)
        let exif = found.properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifLensModel] as? String, "50mm")
        XCTAssertEqual(try Data(contentsOf: url), original, "the original is untouched")

        options.keepMetadata = false
        let bare = try ImageMaking.convert(url, options)
        XCTAssertEqual(bare.lastPathComponent, "a-1.jpg", "never over an existing file")
        let bareExif = info(bare).properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(bareExif?[kCGImagePropertyExifLensModel])
    }

    func testResizingTurnsItUprightAndKeepsTheFormat() throws {
        let url = image("turned.jpg", properties: [kCGImagePropertyOrientation: 6])
        var options = ImageMaking.Options()
        options.longestSide = 200
        let made = try ImageMaking.convert(url, options)
        XCTAssertEqual(made.lastPathComponent, "turned (200).jpg")
        let found = info(made)
        XCTAssertEqual(found.width, 150, "shown turned, so 300 wide becomes the height")
        XCTAssertEqual(found.height, 200)
        XCTAssertEqual(found.properties[kCGImagePropertyOrientation] as? Int ?? 1, 1)

        options.longestSide = 4096
        let notLarger = try ImageMaking.convert(url, options)
        XCTAssertEqual(info(notLarger).width, 400, "never made larger")
    }

    func testTransparencyBecomesWhiteInAJPEG() throws {
        let url = image("clear.png", type: .png, alpha: true)
        var options = ImageMaking.Options()
        options.format = .jpeg
        let made = try ImageMaking.convert(url, options)
        let source = CGImageSourceCreateWithURL(made as CFURL, nil)!
        let picture = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        // The bottom-left corner, which was clear.
        context.draw(picture, in: CGRect(x: 0, y: 0, width: 400, height: 300))
        let pixel = context.data!.assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(pixel[0], 240, "white, not black")
    }

    @MainActor
    func testMadeImagesAreOneUndoStep() async throws {
        let urls = [image("x.jpg"), image("y.jpg")]
        let history = FileHistory()
        var png = ImageMaking.Options()
        png.format = .png
        let options = png
        let outcome = await AppModel.makeImages(urls, undoName: "Convert", history: history) {
            url throws(ImageMaking.Failure) in try ImageMaking.convert(url, options)
        }
        XCTAssertEqual(outcome.made.map(\.lastPathComponent), ["x.png", "y.png"])
        XCTAssertEqual(history.undoName, "Convert")
        let undone = await history.perform(.undo) { _ in true }
        XCTAssertTrue(undone.failures.isEmpty, undone.failures.joined())
        XCTAssertFalse(FileManager.default.fileExists(atPath: outcome.made[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path))
    }

    func testAPictureWithNoSubjectSaysSo() {
        let url = image("plain.jpg")
        XCTAssertThrowsError(try ImageMaking.cutOut(url)) { error in
            XCTAssertTrue((error as? ImageMaking.Failure)?.message.contains("plain.jpg") == true)
        }
    }

    func testTheZebraIsCutOut() throws {
        // A real photo with a subject, given from outside:
        // TEST_RUNNER_DIPTYCH_SUBJECT_PHOTO=/path/to/photo.jpg xcodebuild test …
        guard let path = ProcessInfo.processInfo.environment["DIPTYCH_SUBJECT_PHOTO"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("set DIPTYCH_SUBJECT_PHOTO to a photo with a subject")
        }
        let photo = URL(fileURLWithPath: path)
        let copy = folder.appendingPathComponent("zebra.jpg")
        try FileManager.default.copyItem(at: photo, to: copy)
        let made: URL
        do {
            made = try ImageMaking.cutOut(copy)
        } catch let failure as ImageMaking.Failure {
            return XCTFail(failure.message)
        }
        XCTAssertEqual(made.lastPathComponent, "zebra (cut out).png")
        let found = info(made)
        XCTAssertEqual(found.type, UTType.png.identifier)
        XCTAssertEqual(found.properties[kCGImagePropertyHasAlpha] as? Bool, true)
        print("CUTOUT", made.path)
        try? FileManager.default.copyItem(at: made, to: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-cutout.png"))
    }

    // MARK: - Any picture

    func testWhichFilesArePictures() {
        for name in ["a.png", "b.JPG", "c.heic", "d.tiff", "e.gif"] {
            XCTAssertTrue(AppModel.isReadableImage(URL(fileURLWithPath: "/x/\(name)")), name)
        }
        for name in ["a.txt", "b.pdf", "noextension"] {
            XCTAssertFalse(AppModel.isReadableImage(URL(fileURLWithPath: "/x/\(name)")), name)
        }
    }

    private func pixels(_ data: Data) -> (Data, Int, Int) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        return (image.dataProvider!.data! as Data, image.width, image.height)
    }

    func testAPNGIsTurnedByItsPixelsLosingNothing() throws {
        let url = image("p.png", type: .png, alpha: true)
        let original = try Data(contentsOf: url)
        let right = try ExifWrite.turn(original, name: "p.png", .right)
        let (_, width, height) = pixels(right)
        XCTAssertEqual(width, 300, "turned: the pixels themselves")
        XCTAssertEqual(height, 400)
        let back = try ExifWrite.turn(right, name: "p.png", .left)
        XCTAssertEqual(pixels(back).0, pixels(original).0, "and back, to the same pixels")
    }

    // MARK: - Text

    /// Black words on white, big enough to read.
    private func sign(_ name: String, _ words: String) -> URL {
        let context = CGContext(data: nil, width: 900, height: 200, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 200))
        let attributed = NSAttributedString(string: words, attributes: [
            .font: CTFontCreateWithName("Helvetica-Bold" as CFString, 72, nil),
            .foregroundColor: CGColor(gray: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 40, y: 70)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        let url = folder.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                          1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testTheTextIsRead() throws {
        let text = try ImageMaking.text(in: sign("s.png", "HELLO DIPTYCH"))
        XCTAssertTrue(text.uppercased().contains("HELLO DIPTYCH"), text)
        XCTAssertEqual(try ImageMaking.text(in: image("blank.png", type: .png)), "")
    }

    @MainActor
    func testTheTextGoesBesideTheImageOrIntoItsComment() async throws {
        let url = sign("s.png", "HELLO DIPTYCH")
        let blank = image("blank.png", type: .png)
        let history = FileHistory()

        let beside = await AppModel.recognizeText([url, blank], place: .sidecar, history: history)
        XCTAssertEqual(beside.kept.map(\.lastPathComponent), ["s.png.txt"])
        XCTAssertEqual(beside.without, 1)
        XCTAssertTrue(try String(contentsOf: beside.kept[0], encoding: .utf8).uppercased()
            .contains("HELLO"))
        let again = await AppModel.recognizeText([url], place: .sidecar, history: FileHistory())
        XCTAssertEqual(again.failures.count, 1, "an existing text file is left alone")
        _ = await history.perform(.undo) { _ in true }
        XCTAssertFalse(FileManager.default.fileExists(atPath: beside.kept[0].path))

        let comment = await AppModel.recognizeText([url], place: .comment, history: history)
        XCTAssertEqual(comment.kept, [url])
        let data = try XCTUnwrap(ExtendedAttributes.data(of: url.path,
                                                         name: ImageMaking.commentAttribute))
        let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? String
        XCTAssertTrue(value?.uppercased().contains("HELLO") == true)
        // The flat view finds it.
        let query = try FlatQuery.parse(#"xattr("com.apple.metadata:kMDItemFinderComment") ~ /hello/i"#,
                                        saved: [:]).get()
        let item = DirectoryLoader.item(at: url, keys: DirectoryLoader.keys(for: FlatScanner.columns))
        XCTAssertTrue(query.decide(FlatSubject(item)).list)
        _ = await history.perform(.undo) { _ in true }
        XCTAssertNil(ExtendedAttributes.data(of: url.path, name: ImageMaking.commentAttribute))
    }
}
