import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Diptych

/// Image ▸ Edit EXIF: which files, what a field holds, writing without
/// touching the picture, and putting it back.
@MainActor
final class ExifEditorTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExifTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Making images

    private func picture() -> CGImage {
        let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for x in 0..<40 {
            context.setFillColor(CGColor(red: CGFloat(x) / 40, green: 0.3, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: 30))
        }
        return context.makeImage()!
    }

    private func image(_ name: String, type: UTType = .jpeg,
                       exif: [CFString: Any] = [:], tiff: [CFString: Any] = [:]) -> URL {
        let url = folder.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString,
                                                          1, nil)!
        var properties: [CFString: Any] = [:]
        if !exif.isEmpty { properties[kCGImagePropertyExifDictionary] = exif }
        if !tiff.isEmpty { properties[kCGImagePropertyTIFFDictionary] = tiff }
        CGImageDestinationAddImage(destination, picture(), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func pixels(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image.dataProvider?.data as Data?
    }

    private func key(_ group: ExifGroup, _ name: CFString) -> ExifKey {
        ExifKey(group: group, name: name as String)
    }

    // MARK: - Which files

    func testOnlyImagesItCanChangeWithoutReEncoding() {
        for name in ["a.jpg", "a.JPEG", "a.heic", "a.HEIF"] {
            XCTAssertTrue(ExifFields.canEdit(URL(fileURLWithPath: "/x/\(name)")), name)
        }
        for name in ["a.png", "a.tiff", "a.avif", "a.gif", "a.txt", "a"] {
            XCTAssertFalse(ExifFields.canEdit(URL(fileURLWithPath: "/x/\(name)")), name)
        }
    }

    // MARK: - Values as text

    func testNumbersAreShownShort() {
        XCTAssertEqual(ExifFields.text(of: NSNumber(value: 2.8)), "2.8")
        XCTAssertEqual(ExifFields.text(of: NSNumber(value: 400)), "400")
        XCTAssertEqual(ExifFields.text(of: [NSNumber(value: 100), NSNumber(value: 200)]), "100, 200")
        XCTAssertNil(ExifFields.text(of: ["a": 1]))
    }

    func testAFractionIsANumber() throws {
        let value = try ExifFields.value(of: "1/125", as: .number) as? NSNumber
        XCTAssertEqual(value?.doubleValue ?? 0, 0.008, accuracy: 1e-9)
    }

    func testAListOfWholeNumbers() throws {
        let value = try ExifFields.value(of: "100, 200", as: .integers) as? [NSNumber]
        XCTAssertEqual(value?.map(\.intValue), [100, 200])
    }

    func testWhatIsNotANumberIsRefused() {
        XCTAssertThrowsError(try ExifFields.value(of: "fast", as: .number))
        XCTAssertThrowsError(try ExifFields.value(of: "2.5", as: .integer))
    }

    func testAnUnknownKeyIsNamedFromItsName() {
        XCTAssertEqual(ExifFields.label(for: "ShutterSpeedValue"), "Shutter Speed Value")
        XCTAssertEqual(ExifFields.label(for: "ISOSpeed"), "ISO Speed")
    }

    // MARK: - What the files hold

    func testOneValueInEveryFileIsShown() {
        XCTAssertEqual(ExifEditorModel.current(of: ["Acme", "Acme"]), .same("Acme"))
    }

    func testValuesThatDisagreeAreDifferent() {
        XCTAssertEqual(ExifEditorModel.current(of: ["Acme", "Other"]), .different)
    }

    func testAValueInSomeFilesOnlyIsDifferent() {
        XCTAssertEqual(ExifEditorModel.current(of: ["Acme", nil]), .different)
    }

    func testAValueInNoFileIsUnset() {
        XCTAssertEqual(ExifEditorModel.current(of: [nil, nil]), .unset)
    }

    func testCommonFieldsAreOfferedEvenWhenNoFileHasThem() {
        let rows = ExifEditorModel.rows(from: [[:]])
        XCTAssertTrue(rows.contains { $0.id == key(.tiff, kCGImagePropertyTIFFArtist) })
        XCTAssertTrue(rows.contains { $0.id == key(.gps, kCGImagePropertyGPSLatitude) })
    }

    // MARK: - Editing

    private func loadedModel(_ urls: [URL]) async -> ExifEditorModel {
        let model = ExifEditorModel(files: urls)
        await model.load()
        return model
    }

    func testTypingTicksTheBoxAndUntickingParksIt() async {
        let model = await loadedModel([image("a.jpg")])
        let artist = key(.tiff, kCGImagePropertyTIFFArtist)
        model.type("Peter", in: artist)
        var row = model.rows.first { $0.id == artist }!
        XCTAssertTrue(row.checked)
        XCTAssertFalse(row.isParked)

        model.setChecked(false, for: artist)
        row = model.rows.first { $0.id == artist }!
        XCTAssertTrue(row.isParked, "greyed and not editable")
        XCTAssertEqual(row.text, "Peter", "what was typed stays")
        XCTAssertNotNil(model.changes())
        XCTAssertTrue(model.changes()!.isEmpty, "a parked field is not written")

        model.setChecked(true, for: artist)
        XCTAssertEqual(model.rows.first { $0.id == artist }?.text, "Peter")
        XCTAssertNotNil(model.changes()?[artist])
    }

    func testADifferentValueIsGreyUntilTypedOver() async {
        let model = await loadedModel([image("a.jpg", tiff: [kCGImagePropertyTIFFMake: "A"]),
                                       image("b.jpg", tiff: [kCGImagePropertyTIFFMake: "B"])])
        let make = key(.tiff, kCGImagePropertyTIFFMake)
        XCTAssertTrue(model.rows.first { $0.id == make }!.isGrey)
        model.type("C", in: make)
        XCTAssertFalse(model.rows.first { $0.id == make }!.isGrey)
    }

    func testAnEmptiedFieldIsRemoved() async {
        let model = await loadedModel([image("a.jpg", tiff: [kCGImagePropertyTIFFMake: "A"])])
        let make = key(.tiff, kCGImagePropertyTIFFMake)
        model.type("", in: make)
        guard case .remove = model.changes()?[make] else { return XCTFail("not removed") }
    }

    func testAWrongNumberStopsTheSave() async {
        let model = await loadedModel([image("a.jpg")])
        let fNumber = key(.exif, kCGImagePropertyExifFNumber)
        model.type("wide open", in: fNumber)
        XCTAssertNil(model.changes())
        XCTAssertNotNil(model.rows.first { $0.id == fNumber }?.error)
    }

    func testRemovingAndKeepingAgain() async {
        let model = await loadedModel([image("a.jpg", tiff: [kCGImagePropertyTIFFMake: "A"])])
        let make = key(.tiff, kCGImagePropertyTIFFMake)
        model.toggleRemoval(of: make)
        XCTAssertTrue(model.rows.first { $0.id == make }!.checked)
        model.toggleRemoval(of: make)
        XCTAssertFalse(model.rows.first { $0.id == make }!.checked)
    }

    func testAnAddedFieldCanBeTakenAwayAgain() async {
        let model = await loadedModel([image("a.jpg")])
        let field = model.addable.first!
        model.add(field)
        XCTAssertTrue(model.rows.contains { $0.id == field.key })
        model.toggleRemoval(of: field.key)
        XCTAssertFalse(model.rows.contains { $0.id == field.key })
    }

    // MARK: - Writing

    func testSetChangeAndRemoveWithoutTouchingThePicture() throws {
        for type in [UTType.jpeg, .heic] {
            let url = image("p.\(type.preferredFilenameExtension!)", type: type,
                            exif: [kCGImagePropertyExifLensModel: "Lens X",
                                   kCGImagePropertyExifUserComment: "old"])
            let before = pixels(url)
            let changed = try ExifWrite.rewrite(Data(contentsOf: url), name: "p", changes: [
                key(.tiff, kCGImagePropertyTIFFArtist): .set("Peter"),
                key(.exif, kCGImagePropertyExifUserComment): .set("new"),
                key(.exif, kCGImagePropertyExifLensModel): .remove,
                key(.exif, kCGImagePropertyExifFNumber): .set(NSNumber(value: 2.8)),
                key(.gps, kCGImagePropertyGPSLatitude): .set(NSNumber(value: 47.5)),
                key(.gps, kCGImagePropertyGPSLatitudeRef): .set("N"),
            ])
            try changed.write(to: url)
            let values = try XCTUnwrap(ExifWrite.values(of: url))
            XCTAssertEqual(values[key(.tiff, kCGImagePropertyTIFFArtist)] as? String, "Peter")
            XCTAssertEqual(values[key(.exif, kCGImagePropertyExifUserComment)] as? String, "new")
            XCTAssertNil(values[key(.exif, kCGImagePropertyExifLensModel)])
            XCTAssertEqual((values[key(.gps, kCGImagePropertyGPSLatitude)] as? NSNumber)?
                .doubleValue ?? 0, 47.5, accuracy: 1e-6)
            XCTAssertEqual(pixels(url), before, "\(type.identifier): the picture is untouched")
        }
    }

    func testSavingKeepsTheFileAndUndoPutsItBack() async throws {
        let url = image("a.jpg", tiff: [kCGImagePropertyTIFFMake: "Acme"])
        let original = try Data(contentsOf: url)
        let inode = FileHistory.identity(of: url)
        let model = await loadedModel([url])
        model.type("Peter", in: key(.tiff, kCGImagePropertyTIFFArtist))
        let closed = await model.save()
        XCTAssertTrue(closed)

        XCTAssertEqual(ExifWrite.values(of: url)?[key(.tiff, kCGImagePropertyTIFFArtist)] as? String,
                       "Peter")
        XCTAssertEqual(FileHistory.identity(of: url), inode, "the same file, written in place")

        // The editor records in the shared history; emptied again below.
        let history = FileHistory.shared
        XCTAssertEqual(history.undoName, "EXIF Change")
        let undone = await history.perform(.undo) { _ in true }
        XCTAssertTrue(undone.failures.isEmpty, undone.failures.joined())
        XCTAssertEqual(try Data(contentsOf: url), original, "put back byte for byte")

        let redone = await history.perform(.redo) { _ in true }
        XCTAssertTrue(redone.failures.isEmpty)
        XCTAssertEqual(ExifWrite.values(of: url)?[key(.tiff, kCGImagePropertyTIFFArtist)] as? String,
                       "Peter")
        history.forgetEverything()
    }

    /// Delete All EXIF Data: everything goes but Orientation, which keeps
    /// the picture upright; the picture is untouched, and Undo brings it back.
    func testErasingAllExifAndUndo() async throws {
        let url = image("a.jpg", exif: [kCGImagePropertyExifLensModel: "50mm",
                                        kCGImagePropertyExifDateTimeOriginal: "2024:06:30 18:45:00"],
                        tiff: [kCGImagePropertyTIFFMake: "Acme", kCGImagePropertyTIFFOrientation: 6])
        let other = image("b.jpg", tiff: [kCGImagePropertyTIFFMake: "Acme"])
        let original = try Data(contentsOf: url)
        let picture = pixels(url)
        let history = FileHistory()

        let saved = await AppModel.eraseExif([url, other], history: history)
        XCTAssertTrue(saved.failures.isEmpty, saved.failures.joined())
        XCTAssertEqual(saved.done.count, 2)
        let left = try XCTUnwrap(ExifWrite.values(of: url))
        XCTAssertEqual(left.keys.map(\.name), [kCGImagePropertyTIFFOrientation as String])
        XCTAssertEqual((left.values.first as? NSNumber)?.intValue, 6)
        XCTAssertEqual(pixels(url), picture, "the picture itself is not touched")

        XCTAssertEqual(history.undoName, "Delete EXIF")
        let undone = await history.perform(.undo) { _ in true }
        XCTAssertTrue(undone.failures.isEmpty, undone.failures.joined())
        XCTAssertEqual(try Data(contentsOf: url), original, "put back byte for byte")
        XCTAssertEqual(ExifWrite.values(of: other)?[key(.tiff, kCGImagePropertyTIFFMake)] as? String,
                       "Acme")
    }

    /// Erased once, there is nothing left to erase: the second time the
    /// image is not written, and Undo gets no step.
    func testAnImageWithNoExifIsLeftAlone() async throws {
        let url = image("a.jpg", tiff: [kCGImagePropertyTIFFMake: "Acme"])
        _ = await AppModel.eraseExif([url], history: FileHistory())
        let erased = try Data(contentsOf: url)
        let history = FileHistory()
        let saved = await AppModel.eraseExif([url], history: history)
        XCTAssertTrue(saved.done.isEmpty)
        XCTAssertTrue(saved.failures.isEmpty)
        XCTAssertNil(history.undoName)
        XCTAssertEqual(try Data(contentsOf: url), erased)
        XCTAssertEqual(AppModel.erasedMessage(0), "There was no EXIF data to erase")
        XCTAssertEqual(AppModel.erasedMessage(3), "3 files\u{2019} EXIF data was erased, undoable")
    }

    func testUndoWarnsWhenTheFileChangedSince() throws {
        let url = image("a.jpg")
        let before = try UndoSnapshots.keep(url)
        let history = FileHistory()
        history.recordContents([(url, before)], name: "EXIF Change", told: "")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 3600)],
                                              ofItemAtPath: url.path)
        let plan = try XCTUnwrap(history.plan(.undo))
        XCTAssertFalse(plan.warnings.isEmpty)
        XCTAssertFalse(plan.doable.isEmpty)
    }

    func testAFailedFileIsLeftAsItWas() async throws {
        let url = folder.appendingPathComponent("broken.jpg")
        try Data("not an image".utf8).write(to: url)
        let model = await loadedModel([url])
        XCTAssertEqual(model.unreadable, [url])
    }
}

extension ExifEditorTests {

    func testANumberIsWrittenAsAFraction() {
        XCTAssertEqual(ExifWrite.fraction(2.8), "14/5")
        XCTAssertEqual(ExifWrite.fraction(0.008), "1/125")
        XCTAssertEqual(ExifWrite.fraction(47.4979), "474979/10000")
    }

    /// Artist alone, in an image with no TIFF fields, is dropped by ImageIO
    /// unless Orientation is beside it.
    func testArtistInAnImageWithoutTIFFFields() throws {
        let url = image("plain.jpg", exif: [kCGImagePropertyExifUserComment: "c"])
        let changed = try ExifWrite.rewrite(Data(contentsOf: url), name: "plain", changes: [
            key(.tiff, kCGImagePropertyTIFFArtist): .set("Peter"),
        ])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(changed as CFData, nil))
        XCTAssertEqual(ExifWrite.values(in: source)?[key(.tiff, kCGImagePropertyTIFFArtist)] as? String,
                       "Peter")
    }
}

extension ExifEditorTests {

    /// A sensible value for every field the editor offers.
    private func sample(for field: ExifField) -> String {
        let fixed: [CFString: String] = [
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitudeRef: "E",
            kCGImagePropertyGPSImgDirectionRef: "T",
            kCGImagePropertyGPSSpeedRef: "K",
            kCGImagePropertyGPSDateStamp: "2024:06:30",
            kCGImagePropertyGPSTimeStamp: "16:45:00",
            kCGImagePropertyTIFFOrientation: "1",
            kCGImagePropertyTIFFResolutionUnit: "2",
            kCGImagePropertyGPSAltitudeRef: "0",
            kCGImagePropertyExifColorSpace: "1",
            kCGImagePropertyExifExposureTime: "1/125",
        ]
        let name = field.key.name
        if let value = fixed.first(where: { $0.key as String == name })?.value { return value }
        if case .choice(let choices) = field.input { return choices[0].value }
        if name.contains("DateTime") { return "2024:06:30 18:45:00" }
        if name.hasPrefix("OffsetTime") { return "+02:00" }
        switch field.kind {
        case .text:             return "Sample \(name)"
        case .integer:          return "1"
        case .integers:         return "400"
        case .number, .numbers: return "12.5"
        case .readOnly:         return ""
        }
    }

    /// Every field, at once, kept by both kinds of image.
    func testEveryFieldOfTheCatalogueIsKept() throws {
        for type in [UTType.jpeg, .heic] {
            let url = image("all.\(type.preferredFilenameExtension!)", type: type)
            var changes: [ExifKey: ExifWrite.Change] = [:]
            for field in ExifFields.catalogue where field.kind != .readOnly {
                changes[field.key] = .set(try ExifFields.value(of: sample(for: field), as: field.kind))
            }
            XCTAssertNoThrow(try ExifWrite.rewrite(Data(contentsOf: url), name: type.identifier,
                                                   changes: changes))
        }
    }

    /// And each on its own, in an image that has none of them: a field
    /// ImageIO keeps only beside another is a field the editor cannot offer
    /// on its own.
    func testEachFieldOfTheCatalogueIsKeptOnItsOwn() throws {
        var lost: [String] = []
        for type in [UTType.jpeg, .heic] {
            let url = image("one.\(type.preferredFilenameExtension!)", type: type,
                            exif: [kCGImagePropertyExifUserComment: "c"])
            let data = try Data(contentsOf: url)
            for field in ExifFields.catalogue where field.kind != .readOnly {
                let value = try ExifFields.value(of: sample(for: field), as: field.kind)
                var changes: [ExifKey: ExifWrite.Change] = [field.key: .set(value)]
                // A HEIC image keeps location details only with a position,
                // and a GPS time only with a GPS date; the editor says so.
                if field.key.group == .gps {
                    changes[key(.gps, kCGImagePropertyGPSLatitude)] = changes[
                        key(.gps, kCGImagePropertyGPSLatitude)] ?? .set(NSNumber(value: 47.5))
                }
                if field.key.name == kCGImagePropertyGPSTimeStamp as String {
                    changes[key(.gps, kCGImagePropertyGPSDateStamp)] = .set("2024:06:30")
                }
                do {
                    _ = try ExifWrite.rewrite(data, name: "x", changes: changes)
                } catch {
                    lost.append("\(type.preferredFilenameExtension!) \(field.key.name)")
                }
            }
        }
        XCTAssertEqual(lost, [])
    }
}

extension ExifEditorTests {

    /// Set one after the other, the date came out as 1916:01:00.
    func testGPSDateAndTimeAreWrittenTogether() throws {
        let url = image("gps.jpg")
        let changed = try ExifWrite.rewrite(Data(contentsOf: url), name: "gps", changes: [
            key(.gps, kCGImagePropertyGPSLatitude): .set(NSNumber(value: 10)),
            key(.gps, kCGImagePropertyGPSDateStamp): .set("2024:06:30"),
            key(.gps, kCGImagePropertyGPSTimeStamp): .set("16:45:00"),
        ])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(changed as CFData, nil))
        let values = try XCTUnwrap(ExifWrite.values(in: source))
        XCTAssertEqual(values[key(.gps, kCGImagePropertyGPSDateStamp)] as? String, "2024:06:30")
        XCTAssertEqual(values[key(.gps, kCGImagePropertyGPSTimeStamp)] as? String, "16:45:00")
    }

    func testAGPSTimeWithoutADateIsRefused() throws {
        let url = image("gps.jpg")
        XCTAssertThrowsError(try ExifWrite.rewrite(Data(contentsOf: url), name: "gps", changes: [
            key(.gps, kCGImagePropertyGPSTimeStamp): .set("16:45:00"),
        ]))
    }
}

// MARK: - Editing help: coordinates, dates, time zones, lists

extension ExifEditorTests {

    private func field(_ group: ExifGroup, _ name: CFString) -> ExifField {
        ExifFields.catalogue.first { $0.key == key(group, name) }!
    }

    func testACoordinateInEveryFormat() {
        let decimal = ExifFields.coordinate(from: "47.4979", latitude: true)
        XCTAssertEqual(decimal?.degrees ?? 0, 47.4979, accuracy: 1e-9)
        let minutes = ExifFields.coordinate(from: "47\u{00B0} 29.874\u{2032}", latitude: true)
        XCTAssertEqual(minutes?.degrees ?? 0, 47.4979, accuracy: 1e-6)
        let seconds = ExifFields.coordinate(from: "47 29 52.44 N", latitude: true)
        XCTAssertEqual(seconds?.degrees ?? 0, 47.4979, accuracy: 1e-6)
        XCTAssertEqual(seconds?.hemisphere, "N")
    }

    func testAMinusSignIsTheOtherHemisphere() {
        XCTAssertEqual(ExifFields.coordinate(from: "-33.8688", latitude: true)?.hemisphere, "S")
        XCTAssertEqual(ExifFields.coordinate(from: "-151.2", latitude: false)?.hemisphere, "W")
        XCTAssertNil(ExifFields.coordinate(from: "-33 S", latitude: true), "said twice")
    }

    func testWhatIsNotACoordinate() {
        XCTAssertNil(ExifFields.coordinate(from: "47 61 0", latitude: true), "61 minutes")
        XCTAssertNil(ExifFields.coordinate(from: "north", latitude: true))
        XCTAssertNil(ExifFields.coordinate(from: "33 E", latitude: true), "E is not a latitude's")
    }

    func testACoordinateOutOfRangeIsWrong() {
        let latitude = field(.gps, kCGImagePropertyGPSLatitude)
        let longitude = field(.gps, kCGImagePropertyGPSLongitude)
        guard case .wrong = ExifFields.verdict(of: "4637299321312", for: latitude) else {
            return XCTFail("a latitude of 4637299321312")
        }
        guard case .wrong = ExifFields.verdict(of: "91", for: latitude) else {
            return XCTFail("a latitude of 91")
        }
        XCTAssertEqual(ExifFields.verdict(of: "179.9", for: longitude), .fine)
        guard case .wrong = ExifFields.verdict(of: "180.5", for: longitude) else {
            return XCTFail("a longitude of 180.5")
        }
    }

    func testTheThreeFormats() {
        XCTAssertEqual(ExifFields.format(degrees: 47.4979, as: .decimal), "47.4979")
        XCTAssertEqual(ExifFields.format(degrees: 47.4979, as: .degreesMinutes),
                       "47\u{00B0} 29.874\u{2032}")
        XCTAssertEqual(ExifFields.format(degrees: 47.4979, as: .degreesMinutesSeconds),
                       "47\u{00B0} 29\u{2032} 52.44\u{2033}")
        // Seconds that round up to 60 carry into the minutes.
        XCTAssertEqual(ExifFields.format(degrees: 10.999999, as: .degreesMinutesSeconds),
                       "11\u{00B0} 0\u{2032} 0\u{2033}")
    }

    func testTheButtonRewritesCoordinatesWithoutTickingThem() async {
        let url = image("gps.jpg")
        let data = try! ExifWrite.rewrite(Data(contentsOf: url), name: "gps", changes: [
            key(.gps, kCGImagePropertyGPSLatitude): .set(NSNumber(value: 47.4979)),
        ])
        try! data.write(to: url)
        let model = await loadedModel([url])
        let latitude = key(.gps, kCGImagePropertyGPSLatitude)
        XCTAssertEqual(model.rows.first { $0.id == latitude }?.text, "47.4979")
        model.rotateCoordinateFormat()
        let row = model.rows.first { $0.id == latitude }!
        XCTAssertEqual(row.text, "47\u{00B0} 29.874\u{2032}")
        XCTAssertFalse(row.checked)
        model.rotateCoordinateFormat()
        model.rotateCoordinateFormat()
        XCTAssertEqual(model.rows.first { $0.id == latitude }?.text, "47.4979")
    }

    func testTypingASouthernLatitudeSetsTheHemisphere() async {
        let model = await loadedModel([image("a.jpg")])
        model.type("-33.8688", in: key(.gps, kCGImagePropertyGPSLatitude))
        let reference = model.rows.first { $0.id == key(.gps, kCGImagePropertyGPSLatitudeRef) }!
        XCTAssertEqual(reference.text, "S")
        XCTAssertTrue(reference.checked)
        guard case .set(let value as NSNumber)? = model.changes()?[key(.gps, kCGImagePropertyGPSLatitude)]
        else { return XCTFail("no latitude") }
        XCTAssertEqual(value.doubleValue, 33.8688, accuracy: 1e-9, "written without the sign")
    }

    func testAWrongCoordinateStopsTheSave() async {
        let model = await loadedModel([image("a.jpg")])
        model.type("4637299321312", in: key(.gps, kCGImagePropertyGPSLatitude))
        XCTAssertNil(model.changes())
    }

    func testDatesACameraWouldNotWrite() {
        let taken = field(.exif, kCGImagePropertyExifDateTimeOriginal)
        let now = ExifFields.exifDate("2026:10:08 12:00:00", format: ExifFields.dateTimeFormat)!
        XCTAssertEqual(ExifFields.verdict(of: "2024:06:30 18:45:00", for: taken, now: now), .fine)
        guard case .unusual = ExifFields.verdict(of: "2030:01:01 00:00:00", for: taken, now: now)
        else { return XCTFail("the future") }
        guard case .unusual = ExifFields.verdict(of: "1960:05:01 10:00:00", for: taken, now: now)
        else { return XCTFail("before digital cameras") }
        guard case .unusual = ExifFields.verdict(of: "30 June 2024", for: taken, now: now)
        else { return XCTFail("not as EXIF writes a date") }
        // A wall clock a few hours ahead of this one is not the future.
        XCTAssertEqual(ExifFields.verdict(of: "2026:10:08 22:00:00", for: taken, now: now), .fine)
    }

    func testTimeZoneOffsets() {
        let zone = field(.exif, kCGImagePropertyExifOffsetTimeOriginal)
        XCTAssertEqual(ExifFields.verdict(of: "+02:00", for: zone), .fine)
        XCTAssertEqual(ExifFields.verdict(of: "-09:30", for: zone), .fine)
        guard case .unusual = ExifFields.verdict(of: "+15:00", for: zone) else {
            return XCTFail("no zone is 15 hours ahead")
        }
        guard case .unusual = ExifFields.verdict(of: "Budapest", for: zone) else {
            return XCTFail("a name is not an offset")
        }
    }

    func testListedValues() {
        let metering = field(.exif, kCGImagePropertyExifMeteringMode)
        XCTAssertEqual(ExifFields.verdict(of: "3", for: metering), .fine)
        guard case .unusual = ExifFields.verdict(of: "7", for: metering) else {
            return XCTFail("7 is not a metering mode")
        }
        guard case .wrong = ExifFields.verdict(of: "spot", for: metering) else {
            return XCTFail("a metering mode is a number")
        }
        let reference = field(.gps, kCGImagePropertyGPSLatitudeRef)
        guard case .unusual = ExifFields.verdict(of: "X", for: reference) else {
            return XCTFail("X is not a hemisphere")
        }
    }

    /// One zone, two images, one in summer time and one not.
    func testAZoneIsEachImagesOwnOffset() throws {
        let summer = image("summer.jpg", exif: [kCGImagePropertyExifDateTimeOriginal: "2024:07:01 12:00:00"])
        let winter = image("winter.jpg", exif: [kCGImagePropertyExifDateTimeOriginal: "2024:01:15 12:00:00"])
        let offset = key(.exif, kCGImagePropertyExifOffsetTimeOriginal)
        let change: [ExifKey: ExifWrite.Change] = [
            offset: .zone("Europe/Budapest", date: key(.exif, kCGImagePropertyExifDateTimeOriginal)),
        ]
        for (url, expected) in [(summer, "+02:00"), (winter, "+01:00")] {
            let data = try ExifWrite.rewrite(Data(contentsOf: url), name: "z", changes: change)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(ExifWrite.values(in: source)?[offset] as? String, expected)
        }
    }

    func testAPickedZoneIsSavedAsAZone() async {
        let model = await loadedModel([image("a.jpg")])
        let offset = key(.exif, kCGImagePropertyExifOffsetTimeOriginal)
        model.chooseZone("Asia/Tokyo", in: offset)
        XCTAssertEqual(model.rows.first { $0.id == offset }?.text, "+09:00")
        guard case .zone("Asia/Tokyo", _)? = model.changes()?[offset] else {
            return XCTFail("not saved as a zone")
        }
    }

    /// Removed, then added back from Add Field: the image's own width.
    func testAPixelDimensionComesBackFromTheImage() async throws {
        let url = image("a.jpg")
        let width = key(.exif, kCGImagePropertyExifPixelXDimension)
        var data = try ExifWrite.rewrite(Data(contentsOf: url), name: "a", changes: [width: .remove])
        try data.write(to: url)
        XCTAssertNil(ExifWrite.values(of: url)?[width])

        let model = await loadedModel([url])
        let field = try XCTUnwrap(model.addable.first { $0.key == width })
        model.add(field)
        XCTAssertTrue(model.rows.first { $0.id == width }!.checked)
        let changes = try XCTUnwrap(model.changes())
        data = try ExifWrite.rewrite(Data(contentsOf: url), name: "a", changes: changes)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual((ExifWrite.values(in: source)?[width] as? NSNumber)?.intValue, 40)
    }
}

// MARK: - The date field, the parked field, and the rest

extension ExifEditorTests {

    private func key(_ field: DatePartsField, _ characters: String, code: UInt16 = 0,
                     shift: Bool = false) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                     modifierFlags: shift ? [.shift] : [], timestamp: 0,
                                     windowNumber: 0, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false,
                                     keyCode: code)!
        field.keyDown(with: event)
    }

    private func digits(_ field: DatePartsField, _ text: String) {
        for character in text { key(field, String(character)) }
    }

    private func dateField(_ text: String) -> (DatePartsField, () -> String?) {
        let field = DatePartsField(parts: .dateTime)
        field.show(text)
        var last: String?
        field.onChange = { last = $0 }
        _ = field.becomeFirstResponder()
        return (field, { last })
    }

    /// Typed slowly or quickly, 2026 is 2026: no clock decides when a new
    /// number starts.
    func testAYearIsTypedWhole() {
        let (field, last) = dateField("2024:06:30 18:45:00")
        digits(field, "202")
        XCTAssertNil(last(), "nothing is taken until the year is complete")
        digits(field, "6")
        XCTAssertEqual(last(), "2026:06:30 18:45:00")
    }

    func testAFullPartStartsAgain() {
        let (field, last) = dateField("2024:06:30 18:45:00")
        digits(field, "20262019")
        XCTAssertEqual(last(), "2019:06:30 18:45:00")
    }

    func testMovingOnTakesWhatWasTyped() {
        let (field, last) = dateField("2024:06:30 18:45:00")
        digits(field, "19")
        key(field, "", code: 124)                         // right
        XCTAssertEqual(last(), "0019:06:30 18:45:00")
        digits(field, "1")
        key(field, "", code: 124)
        XCTAssertEqual(last(), "0019:01:30 18:45:00")
    }

    func testADigitNoOtherCanFollowCompletesThePart() {
        let (field, last) = dateField("2024:06:30 18:45:00")
        key(field, "", code: 124)                         // to the month
        digits(field, "4")
        XCTAssertEqual(last(), "2024:04:30 18:45:00", "a 4 in a month is April")
        digits(field, "13")
        XCTAssertEqual(last(), "2024:03:30 18:45:00", "13 is no month: the 3 starts a new one")
    }

    func testTheDayFitsTheMonth() {
        let (field, last) = dateField("2024:01:31 10:00:00")
        key(field, "", code: 124)
        digits(field, "02")
        XCTAssertEqual(last(), "2024:02:29 10:00:00")
    }

    func testUpAndDownStepAndWrap() {
        let (field, last) = dateField("2024:12:31 23:59:59")
        key(field, "", code: 124)
        key(field, "", code: 126)                         // up
        XCTAssertEqual(last(), "2024:01:31 23:59:59")
    }

    /// Delete on a part already complete takes it up again: 1976, delete,
    /// 7 is 1977, not the year 7.
    func testDeleteCorrectsTheLastDigit() {
        let (field, last) = dateField("2024:06:30 18:45:00")
        digits(field, "1976")
        XCTAssertEqual(last(), "1976:06:30 18:45:00")
        key(field, "\u{7F}", code: 51)                   // delete
        digits(field, "7")
        XCTAssertEqual(last(), "1977:06:30 18:45:00")
    }

    func testDeleteBeforeAnythingIsTypedKeepsTheRest() {
        let (field, last) = dateField("2024:06:30 18:45:00")
        key(field, "", code: 124)                         // to the month
        key(field, "\u{7F}", code: 51)
        digits(field, "9")
        XCTAssertEqual(last(), "2024:09:30 18:45:00", "06, delete, 9 is 09")
    }

    /// A label beside the field lines up with its digits, not its top edge.
    func testTheDateFieldHasABaseline() {
        let field = DatePartsField(parts: .dateTime)
        field.frame.size = field.intrinsicContentSize
        let height = field.intrinsicContentSize.height
        XCTAssertGreaterThan(field.firstBaselineOffsetFromTop, height / 2)
        XCTAssertLessThan(field.firstBaselineOffsetFromTop, height)
    }

    func testAGPSDateBeforeGPSIsUnusual() {
        let gpsDate = field(.gps, kCGImagePropertyGPSDateStamp)
        let now = ExifFields.exifDate("2026:10:08 12:00:00", format: ExifFields.dateTimeFormat)!
        guard case .unusual(let message) = ExifFields.verdict(of: "1979:06:30", for: gpsDate,
                                                               now: now)
        else { return XCTFail("GPS time began in 1980") }
        XCTAssertTrue(message.contains("GPS"))
        XCTAssertEqual(ExifFields.verdict(of: "1980:01:06", for: gpsDate, now: now), .fine)
        // A photo's own date is not held to it.
        let taken = field(.exif, kCGImagePropertyExifDateTimeOriginal)
        XCTAssertEqual(ExifFields.verdict(of: "1979:06:30 10:00:00", for: taken, now: now), .fine)
    }

    /// The o turns into the sign as it is typed, in the text being edited,
    /// not when the field is left.
    func testAnOIsTheDegreeSignAsItIsTyped() {
        var typed: [String] = []
        let representable = CoordinateField(text: "", prompt: "", onChange: { typed.append($0) })
        let coordinator = representable.makeCoordinator()
        let field = CoordinateField.Field()
        field.delegate = coordinator
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(field)
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 22)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try! XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("47o 29", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "47\u{00B0} 29")
        XCTAssertEqual(typed.last, "47\u{00B0} 29")
        XCTAssertEqual(editor.selectedRange().location, 6, "the caret stays at the end")
    }

    func testClickingBackIntoAnUntickedFieldTicksIt() async {
        let model = await loadedModel([image("a.jpg")])
        let artist = key(.tiff, kCGImagePropertyTIFFArtist)
        model.type("Peter", in: artist)
        model.setChecked(false, for: artist)
        XCTAssertTrue(model.rows.first { $0.id == artist }!.isParked)
        model.touch(artist)
        let row = model.rows.first { $0.id == artist }!
        XCTAssertTrue(row.checked)
        XCTAssertFalse(row.isParked)
        XCTAssertEqual(row.text, "Peter")
    }

    func testAnOInACoordinateIsTheDegreeSign() async {
        let model = await loadedModel([image("a.jpg")])
        let latitude = key(.gps, kCGImagePropertyGPSLatitude)
        model.type("47o 29'", in: latitude)
        XCTAssertEqual(model.rows.first { $0.id == latitude }?.text, "47\u{00B0} 29'")
        model.type("47O", in: latitude)
        XCTAssertEqual(model.rows.first { $0.id == latitude }?.text, "47\u{00B0}")
    }

    func testTheLocationNeedsBothCoordinates() async {
        let model = await loadedModel([image("a.jpg")])
        XCTAssertNil(model.location)
        model.type("47.4979", in: key(.gps, kCGImagePropertyGPSLatitude))
        XCTAssertNil(model.location, "a latitude alone is no place")
        model.type("19.0402", in: key(.gps, kCGImagePropertyGPSLongitude))
        XCTAssertEqual(model.location, .init(latitude: 47.4979, longitude: 19.0402))
    }

    func testTheLocationTakesTheHemisphere() async {
        let model = await loadedModel([image("a.jpg")])
        model.type("33\u{00B0} 51\u{2032} 54\u{2033} S", in: key(.gps, kCGImagePropertyGPSLatitude))
        model.type("-151.2093", in: key(.gps, kCGImagePropertyGPSLongitude))
        let location = try! XCTUnwrap(model.location)
        XCTAssertEqual(location.latitude, -33.865, accuracy: 1e-3)
        XCTAssertEqual(location.longitude, -151.2093, accuracy: 1e-9)
    }

    func testNoLocationWhenOutOfRangeOrUnticked() async {
        let model = await loadedModel([image("a.jpg")])
        let latitude = key(.gps, kCGImagePropertyGPSLatitude)
        model.type("91", in: latitude)
        model.type("19", in: key(.gps, kCGImagePropertyGPSLongitude))
        XCTAssertNil(model.location, "no latitude is 91\u{00B0}")
        model.type("47", in: latitude)
        XCTAssertNotNil(model.location)
        model.setChecked(false, for: latitude)
        XCTAssertNil(model.location, "unticked, the image keeps having no latitude")
    }

    func testTheMapOpensGoogleMapsThere() {
        let url = LocationMap.googleMaps(.init(latitude: -33.865, longitude: 151.2093))
        XCTAssertEqual(url.absoluteString,
                       "https://www.google.com/maps/search/?api=1&query=-33.865000,151.209300")
    }

    /// The coastlines are in the app, and Budapest lands where it should.
    func testTheWorldMapHasItsLand() {
        XCTAssertGreaterThan(LocationMap.land.count, 100)
        let size = CGSize(width: 360, height: LocationMap.north - LocationMap.south)
        let budapest = LocationMap.point(CGPoint(x: 19.04, y: 47.5), in: size)
        XCTAssertEqual(budapest.x, 199.04, accuracy: 1e-9)
        XCTAssertEqual(budapest.y, LocationMap.north - 47.5, accuracy: 1e-9)
    }

    /// A place pasted into Latitude fills all four location fields.
    func testAPastedPlaceFillsTheLocation() async {
        let model = await loadedModel([image("a.jpg")])
        let latitude = key(.gps, kCGImagePropertyGPSLatitude)
        XCTAssertFalse(model.paste("47.4694", into: latitude), "one coordinate is pasted as it is")
        XCTAssertTrue(model.paste("-33.8568, -151.2153", into: latitude))
        func text(_ name: CFString) -> String? {
            model.rows.first { $0.id == key(.gps, name) }.map(\.text)
        }
        XCTAssertEqual(text(kCGImagePropertyGPSLatitude), "33.8568")
        XCTAssertEqual(text(kCGImagePropertyGPSLatitudeRef), "S")
        XCTAssertEqual(text(kCGImagePropertyGPSLongitude), "151.2153")
        XCTAssertEqual(text(kCGImagePropertyGPSLongitudeRef), "W")
        XCTAssertTrue(model.rows.filter { $0.id.group == .gps && $0.checked }.count >= 4)
        XCTAssertEqual(model.location, .init(latitude: -33.8568, longitude: -151.2153))
    }

    func testACaptionIsOneTidyLine() {
        XCTAssertEqual(NameSuggester.tidyCaption("  \"A dog\non a\tbeach.\"  "), "A dog on a beach.")
        XCTAssertNil(NameSuggester.tidyCaption(" \n "))
        XCTAssertEqual(NameSuggester.tidyCaption(String(repeating: "a", count: 300))?.count, 200)
    }

    func testTheToolTakesImagesFromAnywhereAndSaysWhatIsWrong() throws {
        let one = image("one.jpg")
        let other = folder.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let two = other.appendingPathComponent("two.heic")
        try FileManager.default.copyItem(at: image("two.heic", type: .heic), to: two)
        var result = AppModel.exifImages(at: [one.path, two.path, one.path])
        XCTAssertEqual(result.urls.map(\.lastPathComponent), ["one.jpg", "two.heic"])
        XCTAssertEqual(result.problems, [])

        let text = folder.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: text)
        result = AppModel.exifImages(at: [one.path, text.path, "/no/such.jpg", "rel.jpg",
                                          folder.path])
        XCTAssertEqual(result.problems.count, 4)
    }

    /// Closed, then shown again by SwiftUI without its view being built
    /// again: coming to the front puts it back on Option-Tab's list.
    func testAWindowShownAgainIsListedAgain() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        AppWindows.shared.register(window)
        XCTAssertFalse(window.isExcludedFromWindowsMenu, "in the Dock's list")
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertFalse(AppWindows.shared.live.contains(window))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(AppWindows.shared.live.contains(window))
        AppWindows.shared.unregister(window)
    }
}
