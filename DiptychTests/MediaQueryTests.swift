import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Diptych

/// The flat view's tests of pictures and videos: parsing them, what they say
/// about a file's facts, the warnings, completion, and the nearest town.
final class MediaQueryTests: XCTestCase {

    private func query(_ text: String, file: StaticString = #filePath,
                       line: UInt = #line) -> FlatQuery {
        switch FlatQuery.parse(text, saved: [:]) {
        case .success(let query): return query
        case .failure(let problem):
            XCTFail("\(text): \(problem.message)", file: file, line: line)
            return try! FlatQuery.parse("", saved: [:]).get()
        }
    }

    private func problem(_ text: String) -> String? {
        if case .failure(let problem) = FlatQuery.parse(text, saved: [:]) { return problem.message }
        return nil
    }

    private func warnings(_ text: String) -> [String] {
        query(text).warnings.map(\.message)
    }

    /// Whether the expression holds for a picture with these facts.
    private func holds(_ text: String, _ media: MediaInfo?) -> Bool {
        let expression = query(text).expression!
        return Self.evaluate(expression, media)
    }

    private static func evaluate(_ expression: FlatQuery.Expression, _ media: MediaInfo?) -> Bool {
        switch expression {
        case .and(let a, let b): evaluate(a, media) && evaluate(b, media)
        case .or(let a, let b): evaluate(a, media) || evaluate(b, media)
        case .not(let a): !evaluate(a, media)
        case .primitive(let p): media.map { FlatQuery.holds(p, $0) } ?? false
        }
    }

    private var photo: MediaInfo {
        var info = MediaInfo(kind: .image, format: "jpeg")
        info.hasExif = true
        info.camera = "Apple iPhone 15 Pro"
        info.lens = "iPhone 15 Pro back camera 6.86mm f/1.78"
        info.iso = 400
        info.aperture = 1.78
        info.shutter = 1.0 / 250
        info.focal = 6.86
        info.focal35 = 24
        info.flash = false
        info.width = 4032
        info.height = 3024
        info.orientation = 1
        info.latitude = 47.4979
        info.longitude = 19.0402
        info.altitude = 120
        info.rating = 4
        info.taken = try! XCTUnwrap(FlatQuery.moment("2024-07-14T15:30")).start
        return info
    }

    // MARK: - Parsing

    func testTheNewTestsParse() {
        for text in ["image", "video and duration > 10min", "exif", "located and not flash",
                     "landscape or portrait or square", "rotated, transparent, animated",
                     "format = \"jpg\"", "format = \"raw\"", "camera = \"*iPhone*\"",
                     "lens ~ /70-200/", "software ~ /lightroom/i", "artist = \"Peter\"",
                     "copyright != \"*\"", "description ~ /cat/", "city = \"Budapest\"",
                     "state = \"Bavaria\"", "country = \"HU\"", "iso >= 1600",
                     "aperture <= 2.8", "aperture <= f2.8", "aperture <= f/2.8",
                     "shutter >= 1/30", "shutter < 2s", "focal >= 200mm", "focal35 < 24mm",
                     "focal > 2in", "width >= 1920", "height < 1080px", "megapixels > 12",
                     "altitude > 2000m", "altitude > 6000ft", "altitude < 1mi", "rating >= 4",
                     "duration < 1:30", "taken < 2020", "taken = 2024-07", "digitized >= 2024",
                     "near(47.46849710415109, 8.677050041459035, 5km)",
                     "near(-33.8688, 151.2093, 3mi)", "near(0, 0, 500 m)",
                     "iso between [100, 800)", "taken between [2024-06, 2024-08]",
                     "size between (1MB, 10MB]", "modified between [2026, 2026]"] {
            _ = query(text)
        }
    }

    func testValuesInTheirUnits() throws {
        func number(_ text: String) throws -> Double {
            guard case .primitive(.mediaNumber(_, _, let value)) = query(text).expression else {
                throw XCTSkip("not a number test: \(text)")
            }
            return value
        }
        XCTAssertEqual(try number("shutter > 1/250"), 0.004, accuracy: 1e-12)
        XCTAssertEqual(try number("shutter > 500ms"), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try number("aperture = f/2.8"), 2.8)
        XCTAssertEqual(try number("focal > 2in"), 50.8, accuracy: 1e-9)
        XCTAssertEqual(try number("focal > 5 cm"), 50, accuracy: 1e-9)
        XCTAssertEqual(try number("altitude > 1000ft"), 304.8, accuracy: 1e-9)
        XCTAssertEqual(try number("altitude > 2km"), 2000)
        XCTAssertEqual(try number("altitude > -10m"), -10)
        XCTAssertEqual(try number("duration > 1:30"), 90)
        XCTAssertEqual(try number("duration > 1:02:03"), 3723)
        XCTAssertEqual(try number("duration > 2min"), 120)
        guard case .primitive(.near(_, _, let metres)) = query("near(1, 2, 3mi)").expression else {
            return XCTFail("near")
        }
        XCTAssertEqual(metres, 4828.032, accuracy: 1e-6)
    }

    func testProblemsSayWhatIsWrong() {
        XCTAssertTrue(problem("format = \"bitmap\"")?.contains("not a format") == true)
        XCTAssertTrue(problem("iso between 1, 2")?.contains("brackets") == true)
        XCTAssertTrue(problem("iso between [1 2]")?.contains("comma") == true)
        XCTAssertTrue(problem("iso between [1, 2")?.contains("closed") == true)
        XCTAssertTrue(problem("near(47, 19)")?.contains("near takes") == true)
        XCTAssertTrue(problem("near(95, 19, 1km)")?.contains("latitude") == true)
        XCTAssertTrue(problem("near(47, 19, 0km)")?.contains("more than nothing") == true)
        XCTAssertTrue(problem("altitude > 5 parsecs") != nil)
        XCTAssertTrue(problem("taken < 2024-13")?.contains("ISO 8601") == true)
        XCTAssertTrue(problem("iso")?.contains("between") == true)
    }

    func testAYearOrAMonthIsAllOfIt() throws {
        let year = try XCTUnwrap(FlatQuery.moment("2024"))
        let month = try XCTUnwrap(FlatQuery.moment("2024-02"))
        let calendar = Calendar.current
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: year.start),
                       DateComponents(year: 2024, month: 1, day: 1))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: year.end),
                       DateComponents(year: 2025, month: 1, day: 1))
        XCTAssertEqual(month.end.timeIntervalSince(month.start), 29 * 86_400, accuracy: 3600,
                       "2024 is a leap year")
        let created = query("modified = 2024").expression
        guard case .primitive(.modified(.equal, let moment)) = created else {
            return XCTFail("modified = 2024")
        }
        XCTAssertEqual(moment, year)
    }

    // MARK: - What holds

    func testTheFactsCompare() {
        XCTAssertTrue(holds("image and exif", photo))
        XCTAssertFalse(holds("video", photo))
        XCTAssertTrue(holds("camera = \"*iphone*\"", photo), "a pattern, ignoring case")
        XCTAssertTrue(holds("format = \"jpg\" and format = \"jpeg\"", photo))
        XCTAssertTrue(holds("iso between [100, 400]", photo))
        XCTAssertFalse(holds("iso between [100, 400)", photo))
        XCTAssertTrue(holds("shutter = 1/250 and shutter <= 1/250 and shutter >= 1/250", photo))
        XCTAssertTrue(holds("aperture < f/2", photo))
        XCTAssertTrue(holds("focal35 = 24mm and focal < 1cm", photo))
        XCTAssertTrue(holds("landscape and not portrait and not square and not rotated", photo))
        XCTAssertTrue(holds("width = 4032 and megapixels > 12", photo))
        XCTAssertTrue(holds("located and altitude between [100m, 400ft]", photo))
        XCTAssertTrue(holds("near(47.4979, 19.0402, 1m)", photo))
        XCTAssertTrue(holds("near(47.5, 19.1, 5km)", photo))
        XCTAssertFalse(holds("near(48.2082, 16.3738, 100km)", photo), "Vienna is 215 km away")
        XCTAssertTrue(holds("near(47.5, 19.1, 3mi)", photo))
        XCTAssertTrue(holds("taken = 2024 and taken = 2024-07 and taken between [2024-07-14, 2024-07-14]",
                            photo))
        XCTAssertTrue(holds("rating >= 4 and not flash", photo))
    }

    func testWhatAFileDoesNotSayIsFalseAndOnlyNotMakesItTrue() {
        var bare = MediaInfo(kind: .image, format: "png")
        bare.width = 10
        bare.height = 10
        XCTAssertFalse(holds("camera = \"*iPhone*\"", bare))
        XCTAssertFalse(holds("camera != \"*iPhone*\"", bare), "!= is false without a camera")
        XCTAssertFalse(holds("camera !~ /iPhone/", bare))
        XCTAssertTrue(holds("not camera = \"*iPhone*\"", bare))
        XCTAssertFalse(holds("iso != 100", bare))
        XCTAssertFalse(holds("taken < 2020", bare))
        XCTAssertFalse(holds("taken >= 2020", bare))
        XCTAssertFalse(holds("located", bare))
        // A text file has nothing at all.
        XCTAssertFalse(holds("taken < 2020-01-01", nil))
        XCTAssertFalse(holds("camera != \"x\"", nil))
        XCTAssertTrue(holds("not camera = \"x\"", nil))
        XCTAssertTrue(holds("not image", nil))
    }

    func testTheCountryIsItsNameOrItsCode() {
        var info = photo
        info.writtenCountry = "Magyarország"
        XCTAssertTrue(holds("country = \"Magyarország\"", info), "as written in the file")
        XCTAssertTrue(holds("city = \"Budapest\"", info), "the nearest town, written nowhere")
        XCTAssertTrue(holds("country = \"HU\"", info), "the code of the nearest town's country")
        info.writtenCity = "Óbuda"
        XCTAssertTrue(holds("city = \"Óbuda\"", info), "what the file says comes first")
        XCTAssertFalse(holds("city = \"Budapest\"", info))
    }

    // MARK: - Warnings

    func testContradictionsOfPictures() {
        XCTAssertFalse(warnings("landscape and portrait").isEmpty)
        XCTAssertFalse(warnings("image and video").isEmpty)
        XCTAssertFalse(warnings("iso between [800, 100]").isEmpty)
        XCTAssertFalse(warnings("iso > 800 and iso < 400").isEmpty)
        XCTAssertFalse(warnings("taken < 2020 and taken > 2021").isEmpty)
        XCTAssertFalse(warnings("format = \"jpeg\" and format = \"png\"").isEmpty)
        XCTAssertFalse(warnings("located and not located").isEmpty)
        XCTAssertFalse(warnings("directory and image").isEmpty)
        XCTAssertTrue(warnings("format = \"jpg\" and format = \"jpeg\"").isEmpty, "one format")
        XCTAssertTrue(warnings("format = \"dng\" and format = \"raw\"").isEmpty, "a DNG is raw")
        XCTAssertTrue(warnings("iso between [100, 100]").isEmpty)
        XCTAssertFalse(warnings("iso between [100, 100)").isEmpty)
        XCTAssertTrue(warnings("country = \"HU\" and country = \"Hungary\"").isEmpty)
    }

    func testNotOverAPicturesValueIsWarnedUnlessKeptToPictures() {
        XCTAssertTrue(warnings("not camera = \"*iPhone*\"").first?.contains("NOT camera") == true)
        XCTAssertFalse(warnings("not located").isEmpty)
        XCTAssertTrue(warnings("image and not camera = \"*iPhone*\"").isEmpty)
        XCTAssertTrue(warnings("image and not located").isEmpty)
        XCTAssertTrue(warnings("not image").isEmpty, "the opposite of a kind is meant")
        XCTAssertTrue(warnings("camera != \"*iPhone*\"").isEmpty, "!= is false without a camera")
        // Under NOT, true for a file without the number, whatever the ranges.
        XCTAssertFalse(warnings("not iso < 100 and not iso > 50").contains {
            $0.contains("both ranges")
        })
    }

    // MARK: - Completion

    func testCompletionOffersTheUsualValues() {
        XCTAssertTrue(FlatQuery.completions(in: "iso ", at: 4).words.contains("between"))
        XCTAssertTrue(FlatQuery.completions(in: "iso > ", at: 6).words.contains("1600"))
        XCTAssertTrue(FlatQuery.completions(in: "aperture <= ", at: 12).words.contains("2.8"))
        XCTAssertEqual(FlatQuery.completions(in: "shutter > 1/2", at: 13).words,
                       ["1/2000", "1/250", "1/2"])
        XCTAssertTrue(FlatQuery.completions(in: "focal35 < ", at: 10).words.contains("24mm"))
        XCTAssertTrue(FlatQuery.completions(in: "focal35 < 24 ", at: 13).words.contains("in"))
        XCTAssertEqual(FlatQuery.completions(in: "iso between ", at: 12).words, ["[", "("])
        XCTAssertTrue(FlatQuery.completions(in: "iso between [", at: 13).words.contains("100"))
        XCTAssertEqual(FlatQuery.completions(in: "iso between [100 ", at: 17).words, [","])
        XCTAssertTrue(FlatQuery.completions(in: "iso between [100, ", at: 18).words.contains("800"))
        XCTAssertEqual(FlatQuery.completions(in: "iso between [100, 800 ", at: 22).words,
                       ["]", ")"])
        XCTAssertTrue(FlatQuery.completions(in: "iso between [100, 800] ", at: 23).words
            .contains("and"))
        XCTAssertTrue(FlatQuery.completions(in: "near(1, 2, ", at: 11).words.contains("5km"))
        XCTAssertTrue(FlatQuery.completions(in: "format = ", at: 9).words.contains("\"heic\""))
        XCTAssertEqual(FlatQuery.completions(in: "format = \"he", at: 12).words,
                       ["\"heic\"", "\"heif\""])
        XCTAssertTrue(FlatQuery.completions(in: "landscape ", at: 10).words.contains("and"))
    }

    func testCompletionOffersWhatTheFlatViewFound() {
        let found: [FlatQuery.MediaText: [String]] = [.camera: ["Apple iPhone 15 Pro", "Canon EOS R5"]]
        XCTAssertEqual(FlatQuery.completions(in: "camera = ", at: 9, values: found).words,
                       ["\"Apple iPhone 15 Pro\"", "\"Canon EOS R5\""])
        let typed = "image and camera = \"can"
        let result = FlatQuery.completions(in: typed, at: (typed as NSString).length, values: found)
        XCTAssertEqual(result.words, ["\"Canon EOS R5\""])
        XCTAssertEqual(result.range, NSRange(location: 19, length: 4), "from the quote on")
        XCTAssertEqual(FlatQuery.valueField(in: typed, at: (typed as NSString).length), .camera)
        XCTAssertEqual(FlatQuery.valueField(in: "lens = ", at: 7), .lens)
        XCTAssertNil(FlatQuery.valueField(in: "name = ", at: 7))
    }

    func testASavedNameThatIsNowAWordIsNotOffered() {
        let offered = FlatQuery.expected(after: "", saved: ["image", "photos"])
        XCTAssertTrue(offered.contains("photos"))
        XCTAssertEqual(offered.filter { $0 == "image" }.count, 1, "the test, not the saved name")
        // And the word means the test.
        guard case .success(let parsed) = FlatQuery.parse("image", saved: ["image": "size > 1"]),
              case .primitive(.media(.image)) = parsed.expression else {
            return XCTFail("image is the test")
        }
    }

    func testADateSlotForPictures() {
        XCTAssertNotNil(FlatQuery.dateSlot(in: "taken < ", at: 8))
        XCTAssertNotNil(FlatQuery.dateSlot(in: "digitized >= 2024", at: 17))
        XCTAssertNotNil(FlatQuery.dateSlot(in: "taken between [", at: 15))
        XCTAssertNotNil(FlatQuery.dateSlot(in: "taken between [2024, ", at: 21))
        XCTAssertNil(FlatQuery.dateSlot(in: "iso between [", at: 13))
        XCTAssertNil(FlatQuery.dateSlot(in: "taken between [2024, 2025] and ", at: 31))
    }

    func testHints() {
        XCTAssertTrue(FlatQuery.hint(in: "near(", at: 2)?.contains("km") == true)
        XCTAssertTrue(FlatQuery.hint(in: "format", at: 3)?.contains("heic") == true)
        XCTAssertTrue(FlatQuery.hint(in: "iso between", at: 9)?.hasPrefix("between") == true)
    }

    // MARK: - The nearest town

    func testTheNearestTown() throws {
        let places = Places.shared
        XCTAssertFalse(places.isEmpty, "Places.tsv is in the app")
        let budapest = try XCTUnwrap(places.nearest(latitude: 47.4979, longitude: 19.0402))
        XCTAssertEqual(budapest.city, "Budapest")
        XCTAssertEqual(budapest.country, "Hungary")
        XCTAssertEqual(budapest.countryCode, "HU")
        XCTAssertEqual(places.nearest(latitude: 47.5471, longitude: 19.1091)?.city, "Budapest",
                       "the 15th district is Budapest, not a town of its own")
        let sydney = try XCTUnwrap(places.nearest(latitude: -33.8688, longitude: 151.2093))
        XCTAssertEqual(sydney.countryCode, "AU")
        XCTAssertNil(places.nearest(latitude: 0, longitude: -30), "the middle of the Atlantic")
        XCTAssertNotNil(places.nearest(latitude: 64.1466, longitude: -21.9426), "Reykjavík")
    }

    func testTheGroundDistance() {
        XCTAssertEqual(Geo.distance(47.4979, 19.0402, 48.2082, 16.3738), 214_000, accuracy: 2000)
    }

    // MARK: - Columns

    func testColumnsShowTheFacts() {
        let info = photo
        XCTAssertEqual(info.text(for: .format), "JPEG")
        XCTAssertEqual(info.text(for: .iso), "400")
        XCTAssertEqual(info.text(for: .aperture), "f/1.8")
        XCTAssertEqual(info.text(for: .shutter), "1/250 s")
        XCTAssertEqual(info.text(for: .focal35), "24 mm")
        XCTAssertEqual(info.text(for: .dimensions), "4032 \u{00D7} 3024")
        XCTAssertEqual(info.text(for: .megapixels), "12.2 MP")
        XCTAssertEqual(info.text(for: .location), "47.4979, 19.0402")
        XCTAssertEqual(info.text(for: .rating), "\u{2605}\u{2605}\u{2605}\u{2605}")
        XCTAssertEqual(info.text(for: .city), "Budapest")
        XCTAssertEqual(MediaInfo.clock(3723), "1:02:03")
        XCTAssertEqual(MediaInfo.clock(42), "0:42")
        XCTAssertEqual(MediaInfo.exposure(2), "2 s")
        XCTAssertTrue(FileColumn.taken.isMedia)
        XCTAssertFalse(FileColumn.size.isMedia)
    }
}

/// Real files: a JPEG with EXIF, a PNG, an SVG, a video, a text file --
/// read, and walked with an expression.
final class MediaFileTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychMedia-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: root.appendingPathComponent("sub"),
                               withIntermediateDirectories: true)
        try Self.picture(at: root.appendingPathComponent("photo.jpg"), type: .jpeg, width: 60,
                         height: 40, properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2023:05:06 07:08:09",
                kCGImagePropertyExifOffsetTimeOriginal: "+02:00",
                kCGImagePropertyExifISOSpeedRatings: [800],
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifExposureTime: 0.008,
                kCGImagePropertyExifFocalLenIn35mmFilm: 50,
                kCGImagePropertyExifFlash: 1,
                kCGImagePropertyExifLensModel: "Test Lens 50mm",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Testcam",
                kCGImagePropertyTIFFModel: "Testcam One",
                kCGImagePropertyTIFFSoftware: "Diptych Tests",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 47.4979, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 19.0402, kCGImagePropertyGPSLongitudeRef: "E",
                kCGImagePropertyGPSAltitude: 120, kCGImagePropertyGPSAltitudeRef: 0,
            ],
        ])
        try Self.picture(at: root.appendingPathComponent("sub/shot.png"), type: .png, width: 30,
                         height: 30, properties: [:])
        // A JPEG named as text: found by its bytes.
        try Self.picture(at: root.appendingPathComponent("sub/misnamed.txt"), type: .jpeg,
                         width: 20, height: 10, properties: [:])
        try Data("""
            <?xml version="1.0"?>
            <svg xmlns="http://www.w3.org/2000/svg" width="2in" viewBox="0 0 100 50"></svg>
            """.utf8).write(to: root.appendingPathComponent("drawing.svg"))
        try Data("plain text".utf8).write(to: root.appendingPathComponent("notes.txt"))
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: root)
    }

    static func picture(at url: URL, type: UTType, width: Int, height: Int,
                                properties: [CFString: Any]) throws {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func walk(_ text: String) -> [String] {
        let query = try! FlatQuery.parse(text, saved: [:]).get()
        var found: [FileItem] = []
        FlatScanner.walk(root: root, query: query, showHidden: false) { batch, _, _ in
            found += batch
        }
        return found.filter { !$0.isDirectory }.map(\.relativePath).sorted()
    }

    func testAJPEGSaysWhatItIs() throws {
        let info = try XCTUnwrap(MediaReader.read(root.appendingPathComponent("photo.jpg")))
        XCTAssertEqual(info.kind, .image)
        XCTAssertEqual(info.format, "jpeg")
        XCTAssertTrue(info.hasExif)
        XCTAssertEqual(info.camera, "Testcam One", "the make is not said twice")
        XCTAssertEqual(info.lens, "Test Lens 50mm")
        XCTAssertEqual(info.software, "Diptych Tests")
        XCTAssertEqual(info.iso, 800)
        XCTAssertEqual(info.aperture, 2.8)
        XCTAssertEqual(try XCTUnwrap(info.shutter), 0.008, accuracy: 1e-9)
        XCTAssertEqual(info.focal35, 50)
        XCTAssertEqual(info.flash, true)
        XCTAssertEqual(info.orientation, 6)
        XCTAssertEqual(info.width, 40, "turned a quarter: as it is shown")
        XCTAssertEqual(info.height, 60)
        XCTAssertTrue(info.rotated)
        XCTAssertEqual(try XCTUnwrap(info.latitude), 47.4979, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(info.altitude), 120, accuracy: 1e-6)
        XCTAssertEqual(info.city, "Budapest")
        let taken = try XCTUnwrap(info.taken)
        XCTAssertEqual(taken, try XCTUnwrap(FlatQuery.moment("2023-05-06T05:08:09Z")).start,
                       "in the zone written beside it")
    }

    func testOtherPictures() throws {
        let png = try XCTUnwrap(MediaReader.read(root.appendingPathComponent("sub/shot.png")))
        XCTAssertEqual(png.format, "png")
        XCTAssertEqual(png.transparent, true)
        XCTAssertNil(png.taken)
        let svg = try XCTUnwrap(MediaReader.read(root.appendingPathComponent("drawing.svg")))
        XCTAssertEqual(svg.format, "svg")
        XCTAssertEqual(svg.width, 192, "2in at 96 to the inch")
        XCTAssertEqual(svg.height, 50, "from the viewBox")
        let misnamed = try XCTUnwrap(MediaReader.read(root.appendingPathComponent("sub/misnamed.txt")))
        XCTAssertEqual(misnamed.format, "jpeg")
        XCTAssertNil(MediaReader.read(root.appendingPathComponent("notes.txt")))
    }

    func testWalkingWithPictureTests() {
        XCTAssertEqual(walk("image"), ["drawing.svg", "photo.jpg", "sub/misnamed.txt",
                                       "sub/shot.png"])
        XCTAssertEqual(walk("format = \"jpeg\" and name != \"*.jp*g\""), ["sub/misnamed.txt"])
        XCTAssertEqual(walk("camera = \"*testcam*\" and iso between [400, 800]"), ["photo.jpg"])
        XCTAssertEqual(walk("taken = 2023-05"), ["photo.jpg"])
        XCTAssertEqual(walk("near(47.5, 19.04, 1km) and city = \"Budapest\""), ["photo.jpg"])
        XCTAssertEqual(walk("not located"), ["drawing.svg", "notes.txt", "sub/misnamed.txt",
                                             "sub/shot.png"],
                       "NOT is true for what has no location at all")
        XCTAssertEqual(walk("image and not located"), ["drawing.svg", "sub/misnamed.txt",
                                                       "sub/shot.png"])
        XCTAssertEqual(walk("portrait"), ["photo.jpg"])
        XCTAssertEqual(walk("square"), ["sub/shot.png"])
        XCTAssertEqual(walk("width >= 100"), ["drawing.svg"])
    }

    func testAColumnReadsThePicture() {
        let keys = DirectoryLoader.keys(for: [.name, .taken])
        let item = DirectoryLoader.item(at: root.appendingPathComponent("photo.jpg"), keys: keys)
        XCTAssertEqual(item.media?.iso, 800)
        let plain = DirectoryLoader.item(at: root.appendingPathComponent("photo.jpg"),
                                         keys: DirectoryLoader.keys(for: [.name]))
        XCTAssertNil(plain.media, "no column asks, nothing is read")
    }

    func testAVideoSaysWhereAndWhen() async throws {
        let url = root.appendingPathComponent("clip.mov")
        try await Self.movie(at: url)
        let info = try XCTUnwrap(MediaReader.read(url))
        XCTAssertEqual(info.kind, .video)
        XCTAssertEqual(info.format, "mov")
        XCTAssertEqual(info.width, 64)
        XCTAssertEqual(info.height, 48)
        XCTAssertEqual(try XCTUnwrap(info.duration), 1, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(info.latitude), 47.4979, accuracy: 1e-4)
        XCTAssertEqual(info.camera, "Apple iPhone 15 Pro")
        XCTAssertEqual(info.taken, MediaReader.isoDate("2024-07-14T15:30:12+02:00"))
        XCTAssertEqual(walk("video and taken = 2024-07 and located and duration < 2s"),
                       ["clip.mov"])
    }

    /// A second of grey, with a place, a date and a camera.
    static func movie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: nil)
        writer.add(input)
        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
        writer.metadata = [
            item(.quickTimeMetadataLocationISO6709, "+47.4979+019.0402+120.000/"),
            item(.quickTimeMetadataCreationDate, "2024-07-14T15:30:12+0200"),
            item(.quickTimeMetadataMake, "Apple"),
            item(.quickTimeMetadataModel, "iPhone 15 Pro"),
        ]
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<31 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), 0x80, CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame),
                                                                timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error.map { "\($0)" } ?? "")
    }
}
