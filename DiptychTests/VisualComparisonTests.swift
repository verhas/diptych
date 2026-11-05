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
    /// clockwise, `size` times as large, moved by `shift` pixels, `paper` the
    /// white it comes out as, `noise` the grain added.
    private func page(_ lines: [String] = letter, turn: Double = 0, size: Double = 1, shift: CGPoint = .zero,
                      paper: CGFloat = 1, noise: Int = 0, stamp: Bool = false) -> CGImage {
        let width = 850, height = 1100
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: paper, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: CGFloat(width) / 2 + shift.x, y: CGFloat(height) / 2 - shift.y)
        context.rotate(by: -turn * .pi / 180)
        context.scaleBy(x: size, y: size)
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
        let found = try XCTUnwrap(ImageAlignment.find(a, b)).transform
        // B was drawn turned 2° clockwise and moved; laying it over A undoes it.
        XCTAssertEqual(found.degrees, -2, accuracy: 0.3, found.description)
        let aligned = b.transformed(found)
        XCTAssertGreaterThan(GrayImage.ssim(a, aligned), GrayImage.ssim(a, b) + 0.1)
        XCTAssertGreaterThan(GrayImage.ssim(a, aligned), 0.9, found.description)
    }

    func testAlignmentFindsTheSizeToo() throws {
        let width = 425, height = 550
        let a = try XCTUnwrap(GrayImage(page(), width: width, height: height))
        let b = try XCTUnwrap(GrayImage(page(turn: -3, size: 1.06, shift: CGPoint(x: -20, y: 25)),
                                        width: width, height: height))
        let fit = try XCTUnwrap(ImageAlignment.find(a, b))
        let found = fit.transform, similarity = fit.similarity
        XCTAssertEqual(found.degrees, 3, accuracy: 0.3, found.description)
        XCTAssertEqual(found.scale, 1 / 1.06, accuracy: 0.01, found.description)
        XCTAssertTrue(found.description.contains("smaller"), found.description)
        XCTAssertGreaterThan(similarity, 0.85, found.description)
        XCTAssertGreaterThan(GrayImage.ssim(a, b.transformed(found)), 0.9, found.description)
    }

    func testAFitFoundCoarselyIsRefinedNotSoughtAgain() throws {
        let width = 850, height = 1100
        let a = try XCTUnwrap(GrayImage(page(), width: width, height: height))
        let b = try XCTUnwrap(GrayImage(page(turn: 2.5, size: 0.95, shift: CGPoint(x: 40, y: -30)),
                                        width: width, height: height))
        let coarse = try XCTUnwrap(ImageAlignment.find(a, b, finest: 400))
        XCTAssertLessThanOrEqual(coarse.finest, 600)
        var started = Date()
        let full = try XCTUnwrap(ImageAlignment.find(a, b))
        let searched = Date().timeIntervalSince(started)
        started = Date()
        let refined = try XCTUnwrap(ImageAlignment.find(a, b, around: coarse))
        let refining = Date().timeIntervalSince(started)
        XCTAssertEqual(refined.finest, full.finest)
        XCTAssertEqual(refined.transform.degrees, full.transform.degrees, accuracy: 0.15)
        XCTAssertEqual(refined.transform.scale, full.transform.scale, accuracy: 0.005)
        XCTAssertEqual(refined.transform.dx, full.transform.dx, accuracy: 0.004)
        XCTAssertEqual(refined.transform.dy, full.transform.dy, accuracy: 0.004)
        XCTAssertGreaterThanOrEqual(refined.similarity, full.similarity - 0.02)
        XCTAssertLessThan(refining, searched, "refining \(refining) s, searching \(searched) s")
    }

    @MainActor
    func testTheStoreKeepsTheFinerFitAndForgetsAChangedFile() throws {
        let a = save(page(), "a.png", .png)
        let b = save(page(turn: 1), "b.png", .png)
        let pair = DiffPair(left: a, right: b)
        let store = AlignmentStore()
        let key = try XCTUnwrap(AlignmentStore.Key.of(pair))
        let coarse = ImageAlignment.Fit(transform: .identity, similarity: 0.5, finest: 400)
        let fine = ImageAlignment.Fit(transform: .identity, similarity: 0.9, finest: 1600)
        store.store(fine, key, page: 0)
        store.store(coarse, key, page: 0)
        XCTAssertEqual(store.fit(key, page: 0), fine)
        XCTAssertNil(store.fit(key, page: 1))
        // Saved again, otherwise: what is in it is another key, with nothing
        // found for it.
        save(page(turn: 2, noise: 3), "b.png", .png)
        let changed = try XCTUnwrap(AlignmentStore.Key.of(pair))
        XCTAssertNotEqual(changed, key)
        XCTAssertNil(store.fit(changed, page: 0))
        // Back as it was -- under another name, even -- and what was found
        // for it holds again.
        let copy = save(page(turn: 1), "copy of b.png", .png)
        XCTAssertEqual(AlignmentStore.Key.of(DiffPair(left: a, right: copy)), key)
    }

    @MainActor
    func testWhatWasFoundIsKeptAcrossLaunches() throws {
        let a = save(page(noise: 6), "a.png", .png)
        let b = save(page(turn: 1.2, noise: 10), "b.png", .png)
        let key = try XCTUnwrap(AlignmentStore.Key.of(DiffPair(left: a, right: b)))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("visual-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try compare(a, b)

        AlignmentStore(directory: directory).store(result, key)
        let written = directory.appendingPathComponent("\(key.left)-\(key.right).json")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: written.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let later = AlignmentStore(directory: directory)
        let kept = try XCTUnwrap(later.comparison(key))
        XCTAssertEqual(kept.verdict, result.verdict)
        XCTAssertEqual(kept.pages.first?.similarity, result.pages.first?.similarity)
        XCTAssertEqual(later.fit(key, page: 0), result.pages.first?.alignment)
    }

    func testTheComparisonHandsBackWhatItAligned() throws {
        let a = save(page(noise: 6), "a.png", .png)
        let b = save(page(turn: 1.2, shift: CGPoint(x: 14, y: -9), paper: 0.93, noise: 10), "b.jpg", .jpeg,
                     quality: 0.7)
        let result = try compare(a, b)
        let fit = try XCTUnwrap(result.pages.first?.alignment)
        XCTAssertEqual(fit.transform.degrees, -1.2, accuracy: 0.3)
        XCTAssertEqual(VisualComparison.pairedPages(a, b), 1)
    }

    /// `image` turned a quarter clockwise: a page fed into the scanner
    /// sideways.
    private func quarterTurned(_ image: CGImage) -> CGImage {
        let context = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.translateBy(x: CGFloat(image.height) / 2, y: CGFloat(image.width) / 2)
        context.rotate(by: -.pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return context.makeImage()!
    }

    func testAPageScannedSidewaysIsTurnedBack() throws {
        let a = save(page(noise: 6), "a.png", .png)
        let b = save(quarterTurned(page(turn: 1, noise: 8)), "b.png", .png)
        let result = try compare(a, b)
        XCTAssertEqual(result.verdict, .rescanned, "\(result.pages)")
        let fit = try XCTUnwrap(result.pages.first?.alignment)
        // B is a quarter clockwise, and 1° more: three quarters back, less 1°.
        XCTAssertEqual(fit.transform.quarterTurns, 3, fit.transform.description)
        XCTAssertEqual(fit.transform.totalDegrees, -91, accuracy: 0.3, fit.transform.description)
        XCTAssertTrue(fit.transform.description.contains("anticlockwise"), fit.transform.description)
    }

    func testTheSheetHoldsBothWhicheverIsLeft() throws {
        let tall = save(page(), "tall.png", .png)
        // The same page cropped to a short, wide strip.
        let strip = page().cropping(to: CGRect(x: 0, y: 0, width: 850, height: 500))!
        let wide = save(strip, "wide.png", .png)
        let a = try XCTUnwrap(VisualSource.open(tall)), b = try XCTUnwrap(VisualSource.open(wide))
        let one = try XCTUnwrap(PagePair.render(a, b, page: 0, longSide: 1100))
        let other = try XCTUnwrap(PagePair.render(b, a, page: 0, longSide: 1100))
        XCTAssertEqual(one.width, other.width)
        XCTAssertEqual(one.height, other.height)
        let sheet = CGRect(x: 0, y: 0, width: one.width, height: one.height).insetBy(dx: -1, dy: -1)
        for rect in [one.leftRect, one.rightRect, other.leftRect, other.rightRect] {
            XCTAssertTrue(sheet.contains(rect), "\(rect) is cut off the \(sheet)")
        }
        // At one scale, pixels against pixels: the strip is as wide as the page.
        XCTAssertEqual(one.rightRect.width, one.leftRect.width, accuracy: 1)
        XCTAssertEqual(one.rightRect.height, one.leftRect.height * 500 / 1100, accuracy: 2)
    }

    func testSimilarityTellsPagesApart() throws {
        let width = 425, height = 550
        let a = try XCTUnwrap(GrayImage(page(), width: width, height: height))
        let same = try XCTUnwrap(GrayImage(page(noise: 8), width: width, height: height))
        let other = try XCTUnwrap(GrayImage(page(["Something else entirely", "with other words on it",
                                                  "and nothing alike at all"]), width: width, height: height))
        let moved = try XCTUnwrap(GrayImage(page(turn: 2, shift: CGPoint(x: 30, y: 20)),
                                            width: width, height: height))
        XCTAssertEqual(ImageAlignment.similarity(a, a), 1, accuracy: 0.001)
        let sameScore = ImageAlignment.similarity(a, same)
        let otherScore = ImageAlignment.similarity(a, other)
        let movedScore = ImageAlignment.similarity(a, moved)
        let alignedScore = try XCTUnwrap(ImageAlignment.find(a, moved)).similarity
        XCTAssertGreaterThan(sameScore, 0.8)
        // The box and the rule are the same on both: a form filled in otherwise.
        XCTAssertLessThan(otherScore, sameScore - 0.25)
        XCTAssertGreaterThan(alignedScore, movedScore + 0.2)
        print("similarity: same \(sameScore), other \(otherScore), moved \(movedScore), aligned \(alignedScore)")
    }

    func testTextSimilarity() {
        XCTAssertEqual(VisualComparison.textSimilarity("Hello  World", "hello world"), 1)
        XCTAssertLessThan(VisualComparison.textSimilarity("abc", "xyz"), 0.1)
        XCTAssertEqual(VisualComparison.numbers(in: "Paid 1,250.00 on 15.10.2026, ref 7"),
                       ["1,250.00", "15.10.2026", "7"])
    }
}
