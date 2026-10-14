import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Diptych

/// Edit ▸ Paste Special: one property of the copied file made the same on
/// every selected one, as one step in Undo.
@MainActor
final class PasteSpecialTests: XCTestCase {

    private var folder: URL!
    private let manager = FileManager.default

    override func setUp() async throws {
        folder = manager.temporaryDirectory.appendingPathComponent("PasteSpecial-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? manager.removeItem(at: folder)
    }

    private func file(_ name: String, _ text: String = "text") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func mode(_ url: URL) -> Int {
        ((try? manager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?
            .intValue ?? -1
    }

    private func image(_ name: String, tiff: [CFString: Any] = [:],
                       gps: [CFString: Any] = [:]) -> URL {
        let url = folder.appendingPathComponent(name)
        let context = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString,
                                                          1, nil)!
        var properties: [CFString: Any] = [:]
        if !tiff.isEmpty { properties[kCGImagePropertyTIFFDictionary] = tiff }
        if !gps.isEmpty { properties[kCGImagePropertyGPSDictionary] = gps }
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func value(_ url: URL, _ group: ExifGroup, _ name: CFString) -> Any? {
        ExifWrite.values(of: url)?[ExifKey(group: group, name: name as String)]
    }

    private let place: [CFString: Any] = [
        kCGImagePropertyGPSLatitude: 47.5, kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 19.04, kCGImagePropertyGPSLongitudeRef: "E",
    ]

    // MARK: - What the menu offers

    func testLocationAndExifNeedThemInTheCopiedFileAndPicturesToPasteOnto() throws {
        let located = PasteSpecial.Source.read(image("here.jpg", tiff: [kCGImagePropertyTIFFMake: "Acme"],
                                                     gps: place))
        let plain = PasteSpecial.Source.read(image("plain.jpg", tiff: [kCGImagePropertyTIFFMake: "Acme"]))
        let text = try PasteSpecial.Source.read(file("notes.txt"))
        let picture = image("other.jpg")
        let notes = try file("other.txt")

        XCTAssertTrue(located.hasExif && located.hasLocation)
        XCTAssertTrue(plain.hasExif)
        XCTAssertFalse(plain.hasLocation)
        XCTAssertFalse(text.hasExif)

        XCTAssertTrue(PasteSpecial.isAvailable(.location, source: located, targets: [picture]))
        XCTAssertFalse(PasteSpecial.isAvailable(.location, source: plain, targets: [picture]))
        XCTAssertFalse(PasteSpecial.isAvailable(.location, source: located, targets: [picture, notes]),
                       "any one file that cannot take it greys it")
        XCTAssertFalse(PasteSpecial.isAvailable(.exif, source: text, targets: [picture]))
        XCTAssertTrue(PasteSpecial.isAvailable(.all, source: text, targets: [picture, notes]),
                      "all of the above leaves out what cannot be done")
        XCTAssertTrue(PasteSpecial.isAvailable(.permissions, source: text, targets: [notes]))
        XCTAssertFalse(PasteSpecial.isAvailable(.permissions, source: text, targets: [text.url]),
                       "nothing to paste onto but the copied file itself")
        XCTAssertFalse(PasteSpecial.isAvailable(.permissions, source: nil, targets: [notes]))
    }

    // MARK: - Each kind

    func testPermissionsArePastedAndUndone() async throws {
        let source = try file("source.sh")
        let a = try file("a.sh")
        let b = try file("b.sh")
        chmod(source.path, 0o750)
        chmod(a.path, 0o644)
        chmod(b.path, 0o750)
        let history = FileHistory()

        let result = await PasteSpecial.paste(.permissions, from: source, to: [a, b, source],
                                              history: history)
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(result.changed, [a], "b had them already, the source is left out")
        XCTAssertEqual(mode(a), 0o750)
        XCTAssertEqual(history.undoName, "Paste Permissions")

        let undone = await history.perform(.undo) { _ in true }
        XCTAssertEqual(undone.failures, [])
        XCTAssertEqual(mode(a), 0o644)
    }

    func testAttributesAreMadeTheSameTheMissingOnesTakenAway() async throws {
        let source = try file("source.txt")
        let target = try file("target.txt")
        XCTAssertNil(ExtendedAttributes.set(Data("blue".utf8), name: "dev.test.colour", on: source.path))
        XCTAssertNil(ExtendedAttributes.set(Data("old".utf8), name: "dev.test.colour", on: target.path))
        XCTAssertNil(ExtendedAttributes.set(Data("x".utf8), name: "dev.test.extra", on: target.path))
        let history = FileHistory()

        let result = await PasteSpecial.paste(.attributes, from: source, to: [target], history: history)
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(ExtendedAttributes.data(of: target.path, name: "dev.test.colour"), Data("blue".utf8))
        XCTAssertNil(ExtendedAttributes.data(of: target.path, name: "dev.test.extra"))

        _ = await history.perform(.undo) { _ in true }
        XCTAssertEqual(ExtendedAttributes.data(of: target.path, name: "dev.test.colour"), Data("old".utf8))
        XCTAssertEqual(ExtendedAttributes.data(of: target.path, name: "dev.test.extra"), Data("x".utf8))
    }

    func testTheAccessControlListIsCopiedAndUndone() async throws {
        let source = try file("source.txt")
        let target = try file("target.txt")
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "\(NSUserName()) deny delete", source.path]
        try chmod.run()
        chmod.waitUntilExit()
        let wanted = try XCTUnwrap(AccessControl.text(of: source.path))
        XCTAssertNil(AccessControl.text(of: target.path))
        let history = FileHistory()

        let result = await PasteSpecial.paste(.acl, from: source, to: [target], history: history)
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(AccessControl.text(of: target.path), wanted)

        _ = await history.perform(.undo) { _ in true }
        XCTAssertNil(AccessControl.text(of: target.path))
        _ = AccessControl.setText("", on: source.path)
    }

    func testDatesAreCopiedOneAtATime() async throws {
        let source = try file("source.txt")
        let target = try file("target.txt")
        let created = Date(timeIntervalSince1970: 1_400_000_000)
        let modified = Date(timeIntervalSince1970: 1_500_000_000)
        try manager.setAttributes([.modificationDate: modified, .creationDate: created],
                                  ofItemAtPath: source.path)
        let born = Date(timeIntervalSince1970: 1_600_000_000)
        let changed = Date(timeIntervalSince1970: 1_650_000_000)
        try manager.setAttributes([.modificationDate: changed, .creationDate: born],
                                  ofItemAtPath: target.path)
        let history = FileHistory()

        _ = await PasteSpecial.paste(.created, from: source, to: [target], history: history)
        XCTAssertEqual(FileHistory.date(.created, of: target), created)
        XCTAssertEqual(FileHistory.date(.modified, of: target), changed, "only the one asked for")
        _ = await history.perform(.undo) { _ in true }
        XCTAssertEqual(FileHistory.date(.created, of: target), born)

        // Older than the file's creation: macOS takes the creation date
        // back with it, and Undo puts both back.
        _ = await PasteSpecial.paste(.modified, from: source, to: [target], history: history)
        XCTAssertEqual(FileHistory.date(.modified, of: target), modified)
        XCTAssertEqual(FileHistory.date(.created, of: target), modified)
        let undone = await history.perform(.undo) { _ in true }
        XCTAssertEqual(undone.failures, [])
        XCTAssertEqual(FileHistory.date(.modified, of: target), changed)
        XCTAssertEqual(FileHistory.date(.created, of: target), born)
    }

    /// The dates are the file system's, to the nanosecond: set from a
    /// `Date` they came out a few hundred nanoseconds off, and two files
    /// made the same were still not.
    func testDatesArePastedAndUndoneToTheNanosecond() async throws {
        let source = try file("source.pdf")
        let target = try file("target.pdf")
        let born = FileHistory.FileTime(seconds: 1_700_000_000, nanoseconds: 365_694_812)
        let changed = FileHistory.FileTime(seconds: 1_700_000_100, nanoseconds: 1)
        try FileHistory.setDate(.modified, changed, of: source)
        try FileHistory.setDate(.created, born, of: source)
        let targetBorn = FileHistory.FileTime(seconds: 1_700_000_000, nanoseconds: 365_695_000)
        let targetChanged = FileHistory.FileTime(seconds: 1_700_000_200, nanoseconds: 987_654_321)
        try FileHistory.setDate(.modified, targetChanged, of: target)
        try FileHistory.setDate(.created, targetBorn, of: target)
        let history = FileHistory()

        let result = await PasteSpecial.paste(.all, from: source, to: [target], history: history)
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(FileHistory.exactDate(.created, of: target), born)
        XCTAssertEqual(FileHistory.exactDate(.modified, of: target), changed)
        XCTAssertEqual(PropertyComparison.of(source, target).differing.map(\.name), [])

        let undone = await history.perform(.undo) { _ in true }
        XCTAssertEqual(undone.failures, [])
        XCTAssertEqual(FileHistory.exactDate(.created, of: target), targetBorn)
        XCTAssertEqual(FileHistory.exactDate(.modified, of: target), targetChanged)
        _ = await history.perform(.redo) { _ in true }
        XCTAssertEqual(FileHistory.exactDate(.created, of: target), born)
    }

    func testTheSameOwnerIsNothingToChange() async throws {
        let source = try file("source.txt")
        let target = try file("target.txt")
        let history = FileHistory()
        let result = await PasteSpecial.paste(.owner, from: source, to: [target], history: history)
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(result.changed, [])
        XCTAssertNil(history.undoName, "nothing done, nothing to undo")
    }

    // MARK: - EXIF

    func testLocationAloneIsCopiedAndTheRestOfTheExifStays() async throws {
        let source = image("source.jpg", tiff: [kCGImagePropertyTIFFMake: "Acme"], gps: place)
        let target = image("target.jpg", tiff: [kCGImagePropertyTIFFMake: "Other",
                                                kCGImagePropertyTIFFOrientation: 6])
        let original = try Data(contentsOf: target)
        let history = FileHistory()

        let result = await PasteSpecial.paste(.location, from: source, to: [target], history: history)
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual((value(target, .gps, kCGImagePropertyGPSLatitude) as? NSNumber)?.doubleValue ?? 0,
                       47.5, accuracy: 0.0001)
        XCTAssertEqual(value(target, .tiff, kCGImagePropertyTIFFMake) as? String, "Other")
        XCTAssertEqual((value(target, .tiff, kCGImagePropertyTIFFOrientation) as? NSNumber)?.intValue, 6)

        _ = await history.perform(.undo) { _ in true }
        XCTAssertEqual(try Data(contentsOf: target), original, "put back byte for byte")
    }

    func testExifIsCopiedButNotWhichWayUpThePictureIs() async throws {
        let source = image("source.jpg", tiff: [kCGImagePropertyTIFFMake: "Acme",
                                                kCGImagePropertyTIFFOrientation: 3], gps: place)
        let target = image("target.jpg", tiff: [kCGImagePropertyTIFFModel: "Old model",
                                                kCGImagePropertyTIFFOrientation: 6])
        let result = await PasteSpecial.paste(.exif, from: source, to: [target], history: FileHistory())
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(value(target, .tiff, kCGImagePropertyTIFFMake) as? String, "Acme")
        XCTAssertNil(value(target, .tiff, kCGImagePropertyTIFFModel), "not in the copied file")
        XCTAssertNotNil(value(target, .gps, kCGImagePropertyGPSLongitude), "location comes with it")
        XCTAssertEqual((value(target, .tiff, kCGImagePropertyTIFFOrientation) as? NSNumber)?.intValue, 6)
    }

    func testAllOfTheAboveSkipsTheExifWhereItCannotGoAndUndoesAsOne() async throws {
        let source = image("source.jpg", tiff: [kCGImagePropertyTIFFMake: "Acme"], gps: place)
        chmod(source.path, 0o600)
        let modified = Date(timeIntervalSince1970: 1_500_000_000)
        try manager.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)
        let picture = image("picture.jpg")
        let notes = try file("notes.txt")
        chmod(picture.path, 0o644)
        chmod(notes.path, 0o644)
        let original = try Data(contentsOf: picture)
        let history = FileHistory()

        let result = await PasteSpecial.paste(.all, from: source, to: [picture, notes],
                                              history: history)
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(value(picture, .tiff, kCGImagePropertyTIFFMake) as? String, "Acme")
        XCTAssertEqual(mode(picture), 0o600)
        XCTAssertEqual(mode(notes), 0o600)
        XCTAssertEqual(FileHistory.date(.modified, of: picture), modified,
                       "the date is set after the EXIF is written")
        XCTAssertEqual(FileHistory.date(.modified, of: notes), modified)
        XCTAssertEqual(history.undoName, "Paste Special")

        let plan = try XCTUnwrap(history.plan(.undo))
        XCTAssertEqual(plan.warnings, [], "nothing changed since, the dates included")
        let undone = await history.perform(.undo) { _ in true }
        XCTAssertEqual(undone.failures, [])
        XCTAssertEqual(try Data(contentsOf: picture), original)
        XCTAssertEqual(mode(picture), 0o644)
        XCTAssertEqual(mode(notes), 0o644)

        let redone = await history.perform(.redo) { _ in true }
        XCTAssertEqual(redone.failures, [])
        XCTAssertEqual(value(picture, .tiff, kCGImagePropertyTIFFMake) as? String, "Acme")
        XCTAssertEqual(mode(notes), 0o600)
    }

    func testAllOfTheAboveFromAFileWithoutExifLeavesThePicturesExifAlone() async throws {
        let source = try file("source.txt")
        let picture = image("picture.jpg", tiff: [kCGImagePropertyTIFFMake: "Acme"])
        let result = await PasteSpecial.paste(.all, from: source, to: [picture], history: FileHistory())
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(value(picture, .tiff, kCGImagePropertyTIFFMake) as? String, "Acme")
    }
}
