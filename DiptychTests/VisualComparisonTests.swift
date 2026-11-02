import XCTest
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import Diptych

/// Two PDFs or pictures compared by what they show: the same pixels, the same
/// to the eye, probably two scans of one page, or different.
final class VisualComparisonTests: XCTestCase {

    private var folder: URL!

    override func setUp() async throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychVisual-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Pages to compare

    private static let letter = [
        "Insurance policy 2026/0415",
        "Policy holder: Jane Example",
        "Annual premium: 1,250.00 EUR",
        "Valid from 15.10.2026 to 14.10.2027",
        "The insured property is covered against fire,",
        "flood, storm and theft as set out in the terms.",
        "Claims must be reported within 30 days.",
    ]

    /// A page of text, 850 x 1100, as a scanner would see it: `turn` degrees
    /// clockwise, moved by `shift` pixels, `paper` the white it comes out as,
    /// `noise` the grain added.
    private func page(_ lines: [String] = letter, turn: Double = 0, shift: CGPoint = .zero,
                      paper: CGFloat = 1, noise: Int = 0, stamp: Bool = false) -> CGImage {
        let width = 850, height = 1100
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: paper, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: CGFloat(width) / 2 + shift.x, y: CGFloat(height) / 2 - shift.y)
        context.rotate(by: -turn * .pi / 180)
        context.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
        let font = CTFontCreateWithName("Helvetica" as CFString, 26, nil)
        for (index, line) in lines.enumerated() {
            let text = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
            ])
            context.textPosition = CGPoint(x: 80, y: CGFloat(height - 150 - index * 60))
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        // A box and a rule, so there is more than text to line up.
        context.setStrokeColor(CGColor(gray: 0.1, alpha: 1))
        context.setLineWidth(3)
        context.stroke(CGRect(x: 60, y: 200, width: 730, height: 300))
        context.stroke(CGRect(x: 60, y: 100, width: 730, height: 2))
        if stamp {
            // A round stamp in the corner, the size of a fingertip.
            context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
            context.fillEllipse(in: CGRect(x: 680, y: 960, width: 70, height: 70))
        }
        if noise > 0, let data = context.data {
            var generator = SystemRandomNumberGenerator()
            let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
            for i in 0..<(context.bytesPerRow * height) where i % 4 != 3 {
                let v = Int(bytes[i]) + Int.random(in: -noise...noise, using: &generator)
                bytes[i] = UInt8(clamping: v)
            }
        }
        return context.makeImage()!
    }

    @discardableResult
    private func save(_ image: CGImage, _ name: String, _ type: UTType,
                      quality: Double? = nil) -> URL {
        let url = folder.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// A PDF of one page per picture, each filling an A4-ish page.
    private func pdf(_ images: [CGImage], _ name: String, producer: String) -> URL {
        let url = folder.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 595, height: 770)
        let context = CGContext(url as CFURL, mediaBox: &box,
                                [kCGPDFContextCreator: producer] as CFDictionary)!
        for image in images {
            context.beginPDFPage(nil)
            context.draw(image, in: box)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func compare(_ a: URL, _ b: URL) throws -> VisualComparison {
        try XCTUnwrap(VisualComparison.compare(a, b))
    }

    // MARK: - The four answers

    func testTheSamePixelsStoredAnotherWay() throws {
        let image = page()
        let a = save(image, "a.png", .png)
        let b = save(image, "b.tiff", .tiff)
        let result = try compare(a, b)
        XCTAssertEqual(result.verdict, .samePixels, result.headline)
        XCTAssertTrue(result.canPreview)
    }

    func testCompressedAgainIsTheSameToTheEye() throws {
        let image = page()
        let a = save(image, "a.png", .png)
        let b = save(image, "b.jpg", .jpeg, quality: 0.5)
        let result = try compare(a, b)
        XCTAssertEqual(result.verdict, .indistinguishable, "\(result.pages)")
    }

    func testOneChangedDigitIsDifferent() throws {
        var changed = Self.letter
        changed[2] = "Annual premium: 1,250.00 EUR".replacingOccurrences(of: "1,250", with: "1,280")
        let a = save(page(), "a.png", .png)
        let b = save(page(changed), "b.png", .png)
        let result = try compare(a, b)
        XCTAssertEqual(result.verdict, .different, "\(result.pages)")
    }

    func testAStampAddedIsNearlyTheSame() throws {
        let a = save(page(), "a.png", .png)
        let b = save(page(stamp: true), "b.png", .png)
        let result = try compare(a, b)
        XCTAssertEqual(result.verdict, .nearlySame, "\(result.pages)")
        XCTAssertTrue(result.pages[0].notes.contains { $0.contains("near the top right") }, "\(result.pages)")
    }

    func testAnotherScanOfTheSamePage() throws {
        let a = save(page(noise: 6), "a.png", .png)
        let b = save(page(turn: 1.2, shift: CGPoint(x: 14, y: -9), paper: 0.93, noise: 10), "b.jpg", .jpeg,
                     quality: 0.7)
        let result = try compare(a, b)
        XCTAssertEqual(result.verdict, .rescanned, "\(result.pages)")
    }

    func testAnotherScanWithOtherNumbersIsDifferent() throws {
        var changed = Self.letter
        changed[2] = "Annual premium: 1,920.00 EUR"
        let a = save(page(noise: 6), "a.png", .png)
        let b = save(page(changed, turn: 1.2, shift: CGPoint(x: 14, y: -9), paper: 0.93, noise: 10),
                     "b.png", .png)
        let result = try compare(a, b)
        XCTAssertEqual(result.verdict, .different, "\(result.pages)")
        XCTAssertTrue(result.pages[0].notes.contains { $0.contains("numbers") }, "\(result.pages)")
    }

    func testAnotherDocumentIsDifferent() throws {
        let a = save(page(), "a.png", .png)
        let b = save(page(["Something else entirely", "with other words on it", "and nothing alike",
                           "at all, really, apart", "from being a page of text."]), "b.png", .png)
        let result = try compare(a, b)
        XCTAssertEqual(result.verdict, .different, "\(result.pages)")
    }

    // MARK: - PDFs

    func testTwoPDFsOfTheSamePagesWrittenByDifferentPrograms() throws {
        let pages = [page(), page(Array(Self.letter.reversed()))]
        let a = pdf(pages, "a.pdf", producer: "Scanner One")
        let b = pdf(pages, "b.pdf", producer: "Scanner Two")
        XCTAssertNotEqual(try Data(contentsOf: a), try Data(contentsOf: b))
        let result = try compare(a, b)
        XCTAssertEqual(result.pages.count, 2)
        XCTAssertEqual(result.verdict, .samePixels, "\(result.pages)")
        XCTAssertTrue(result.notes.contains { $0.contains("Scanner One") }, "\(result.notes)")
    }

    func testPDFsOfDifferentLengthsAreNotPaired() throws {
        let a = pdf([page()], "a.pdf", producer: "x")
        let b = pdf([page(), page()], "b.pdf", producer: "x")
        let result = try compare(a, b)
        XCTAssertNil(result.verdict)
        XCTAssertFalse(result.canPreview)
    }

    func testAPictureAgainstAOnePagePDF() throws {
        let image = page()
        let a = save(image, "a.png", .png)
        let b = pdf([image], "b.pdf", producer: "x")
        let result = try compare(a, b)
        XCTAssertTrue(result.canPreview)
        XCTAssertNotEqual(result.verdict, .different, "\(result.pages)")
    }

    func testNotAPicture() throws {
        let a = folder.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: a)
        let b = save(page(), "b.png", .png)
        XCTAssertNil(VisualComparison.compare(a, b))
    }

    // MARK: - Aligning

    func testAlignmentFindsTheTurnAndTheMove() throws {
        let width = 425, height = 550
        let a = try XCTUnwrap(GrayImage(page(), width: width, height: height))
        let b = try XCTUnwrap(GrayImage(page(turn: 2, shift: CGPoint(x: 30, y: 20)), width: width, height: height))
        let (found, _) = try XCTUnwrap(ImageAlignment.find(a, b))
        // B was drawn turned 2° clockwise and moved; laying it over A undoes it.
        XCTAssertEqual(found.degrees, -2, accuracy: 0.3, found.description)
        let aligned = b.transformed(found)
        XCTAssertGreaterThan(GrayImage.ssim(a, aligned), GrayImage.ssim(a, b) + 0.1)
        XCTAssertGreaterThan(GrayImage.ssim(a, aligned), 0.9, found.description)
    }

    func testTextSimilarity() {
        XCTAssertEqual(VisualComparison.textSimilarity("Hello  World", "hello world"), 1)
        XCTAssertLessThan(VisualComparison.textSimilarity("abc", "xyz"), 0.1)
        XCTAssertEqual(VisualComparison.numbers(in: "Paid 1,250.00 on 15.10.2026, ref 7"),
                       ["1,250.00", "15.10.2026", "7"])
    }
}
