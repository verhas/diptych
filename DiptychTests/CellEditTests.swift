import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Diptych

/// Values edited in their cells, video metadata, the columns' order.
@MainActor
final class CellEditTests: XCTestCase {

    private let fm = FileManager.default
    private var root: URL!

    override func setUp() async throws {
        root = fm.temporaryDirectory.appendingPathComponent("CellEditTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: root)
    }

    private func item(_ url: URL) -> FileItem {
        DirectoryLoader.item(at: url, keys: [.isDirectoryKey, .isSymbolicLinkKey])
    }

    // MARK: - What can be edited

    func testWhichCellsCanBeEdited() throws {
        let jpeg = root.appendingPathComponent("photo.jpg")
        try MediaFileTests.picture(at: jpeg, type: .jpeg, width: 8, height: 8,
                                   properties: [kCGImagePropertyExifDictionary: [
                                       kCGImagePropertyExifFNumber: 2.8]])
        let text = root.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: text)

        XCTAssertEqual(CellEdit.target(.modified, for: item(text)), .fileDate(.modified))
        XCTAssertEqual(CellEdit.target(.created, for: item(jpeg)), .fileDate(.created))
        XCTAssertNil(CellEdit.target(.aperture, for: item(text)), "no EXIF in a text file")
        XCTAssertEqual(CellEdit.target(.aperture, for: item(jpeg)),
                       .exif(ExifKey(group: .exif, name: "FNumber")))
        XCTAssertNil(CellEdit.target(.camera, for: item(jpeg)), "make and model are two fields")
        XCTAssertNil(CellEdit.target(.size, for: item(jpeg)))
        XCTAssertEqual(CellEdit.text(of: .exif(ExifKey(group: .exif, name: "FNumber")),
                                     for: item(jpeg)), "2.8")
    }

    // MARK: - What is typed

    func testDatesAsTyped() throws {
        let typed = try XCTUnwrap(CellEdit.date("2024-07-14 18:30"))
        XCTAssertEqual(typed.day, "2024-07-14")
        XCTAssertEqual(typed.time, "18:30:00")
        XCTAssertNil(typed.offset)
        XCTAssertEqual(CellEdit.date("2024:07:14 18:30:05 +0200")?.offset, "+02:00")
        XCTAssertNil(CellEdit.date("2024-13-01 10:00"))
        XCTAssertNil(CellEdit.date("yesterday"))
        XCTAssertEqual(CellEdit.moment("2024-07-14 18:30:00 +02:00"),
                       Date(timeIntervalSince1970: 1_720_974_600))
    }

    func testEXIFAsTyped() throws {
        let taken = CellEdit.taken
        let dated = try CellEdit.exifChanges("2024-07-14 18:30 +02:00", key: taken)
        guard case .set(let text as String)? = dated[taken],
              case .set(let zone as String)? = dated[CellEdit.takenZone] else {
            return XCTFail("\(dated)")
        }
        XCTAssertEqual(text, "2024:07:14 18:30:00")
        XCTAssertEqual(zone, "+02:00")

        let aperture = ExifKey(group: .exif, name: "FNumber")
        guard case .set(let f as NSNumber)? = try CellEdit.exifChanges("f/2.8", key: aperture)[aperture]
        else { return XCTFail() }
        XCTAssertEqual(f.doubleValue, 2.8)
        let shutter = ExifKey(group: .exif, name: "ExposureTime")
        guard case .set(let s as NSNumber)? = try CellEdit.exifChanges("1/250 s", key: shutter)[shutter]
        else { return XCTFail() }
        XCTAssertEqual(s.doubleValue, 0.004, accuracy: 1e-9)
        guard case .remove? = try CellEdit.exifChanges("  ", key: aperture)[aperture] else {
            return XCTFail("emptied is removed")
        }
        XCTAssertThrowsError(try CellEdit.exifChanges("wide", key: aperture))
    }

    // MARK: - File dates, undone

    func testAFileDateIsUndone() async throws {
        let url = root.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: url)
        let before = try XCTUnwrap(FileHistory.date(.modified, of: url))
        let after = Date(timeIntervalSince1970: 1_000_000_000)
        try fm.setAttributes([.modificationDate: after], ofItemAtPath: url.path)
        let history = FileHistory()
        history.recordDates([(url, before, after)], which: .modified)
        XCTAssertEqual(history.undoName, "Date Change")
        let result = await history.perform(.undo) { _ in true }
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(try XCTUnwrap(FileHistory.date(.modified, of: url)).timeIntervalSince1970,
                       before.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - Videos

    func testVideoDatesAndPlacesAsTyped() {
        XCTAssertEqual(VideoMetadata.stored(date: "2024-07-14 18:30 +02:00"),
                       "2024-07-14T18:30:00+0200")
        XCTAssertEqual(VideoMetadata.stored(date: "2024-01-10 08:00:00",
                                            zone: TimeZone(identifier: "Europe/Budapest")!),
                       "2024-01-10T08:00:00+0100", "the Mac's offset on that day: winter")
        XCTAssertNil(VideoMetadata.stored(date: "14/07/2024"))
        XCTAssertEqual(VideoMetadata.shown(date: "2024-07-14T18:30:00+0200"),
                       "2024-07-14 18:30:00 +02:00")
        XCTAssertEqual(VideoMetadata.stored(location: "47.4979, 19.0402", altitude: "105"),
                       "+47.4979+019.0402+105.000/")
        XCTAssertEqual(VideoMetadata.stored(location: "-33.8568, 151.2153", altitude: nil),
                       "-33.8568+151.2153/")
        XCTAssertNil(VideoMetadata.stored(location: "Budapest", altitude: nil))
    }

    func testAMovieIsRewrittenAndPutBack() async throws {
        let url = root.appendingPathComponent("clip.mov")
        try await MediaFileTests.movie(at: url)
        let original = try Data(contentsOf: url)
        let inode = try fm.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int

        let before = try await VideoMetadata.rewrite(url, changes: [
            .make: "DJI", .model: "FC3582", .artist: "Jane", .location: "40.758, -73.9855",
            .altitude: "10", .taken: "2025-05-01 11:15:00 +02:00", .copyright: nil,
        ])
        let values = await VideoMetadata.values(of: url)
        XCTAssertEqual(values[.make], "DJI")
        XCTAssertEqual(values[.model], "FC3582")
        XCTAssertEqual(values[.artist], "Jane")
        XCTAssertEqual(values[.location], "40.758, -73.9855")
        XCTAssertEqual(values[.altitude], "10")
        XCTAssertEqual(values[.taken], "2025-05-01 11:15:00 +02:00")
        XCTAssertEqual(try fm.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int, inode,
                       "the same file, written in place")
        let info = try XCTUnwrap(MediaReader.read(url))
        XCTAssertEqual(info.camera, "DJI FC3582")
        XCTAssertEqual(info.duration ?? 0, 1, accuracy: 0.1, "the picture is all there")

        try UndoSnapshots.putBack(before, into: url)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testAnMP4KeepsWhatItCan() async throws {
        let mov = root.appendingPathComponent("clip.mov")
        try await MediaFileTests.movie(at: mov)
        let url = root.appendingPathComponent("clip.mp4")
        let export = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: mov),
                                                        presetName: AVAssetExportPresetPassthrough))
        try await export.export(to: url, as: .mp4)

        _ = try await VideoMetadata.rewrite(url, changes: [
            .artist: "Jane", .description: "Fireworks", .taken: "2023-12-31 23:59:30 -05:00",
            .location: "40.758, -73.9855",
        ])
        let values = await VideoMetadata.values(of: url)
        XCTAssertEqual(values[.artist], "Jane")
        XCTAssertEqual(values[.description], "Fireworks")
        XCTAssertEqual(values[.taken], "2023-12-31 23:59:30 -05:00")
        XCTAssertEqual(values[.location], "40.758, -73.9855")
        XCTAssertNil(values[.make], "no camera in an MP4")
        XCTAssertFalse(VideoMetadata.Field.make.fits("mp4"))

        // The columns and the flat view's filter read what was written.
        let info = try XCTUnwrap(MediaCache.shared.info(for: url))
        XCTAssertEqual(info.description, "Fireworks")
        XCTAssertEqual(info.artist, "Jane")
        XCTAssertEqual(info.latitude ?? 0, 40.758, accuracy: 0.001)
        XCTAssertEqual(info.taken, CellEdit.moment("2023-12-31 23:59:30 -05:00"))
    }

    func testAVideoInTheEditorReadsAndSavesAsEXIF() async throws {
        let url = root.appendingPathComponent("clip.mov")
        try await MediaFileTests.movie(at: url)
        let model = ExifEditorModel(files: [url], kind: .videos)
        await model.load()
        XCTAssertEqual(model.unreadable, [])
        func text(_ key: ExifKey) -> String? { model.rows.first { $0.id == key }?.text }
        XCTAssertEqual(text(ExifKey(group: .tiff, name: "Make")), "Apple")
        XCTAssertEqual(text(VideoExif.taken), "2024:07:14 15:30:12")
        XCTAssertEqual(text(VideoExif.zone), "+02:00")
        XCTAssertEqual(model.location?.latitude ?? 0, 47.4979, accuracy: 1e-4)

        model.type("Jane", in: ExifKey(group: .tiff, name: "Artist"))
        model.choose("2025:05:01 11:15:00", in: VideoExif.taken)
        let saved = await model.save()
        XCTAssertTrue(saved, model.problems.joined())
        let values = await VideoMetadata.values(of: url)
        XCTAssertEqual(values[.artist], "Jane")
        XCTAssertEqual(values[.taken], "2025-05-01 11:15:00 +02:00", "the zone it had")
        XCTAssertEqual(values[.make], "Apple", "untouched")
    }

    func testNotAVideoIsRefused() async throws {
        let url = root.appendingPathComponent("notes.mov")
        try Data("plain text".utf8).write(to: url)
        XCTAssertFalse(VideoMetadata.canEdit(url), "by the bytes, not the name")
        do {
            _ = try await VideoMetadata.rewrite(url, changes: [.artist: "Jane"])
            XCTFail("rewrote a text file")
        } catch {
            XCTAssertTrue(error.message.contains("not a QuickTime or MP4"))
        }
    }

    // MARK: - Columns arranged in the header

    func testColumnsArrangedKeepNameFirstAndTheHiddenInPlace() {
        var configuration = Configuration()
        configuration.columnOrder = [.name, .size, .kind, .modified, .created]
        configuration.enabledColumns = [.name, .size, .modified, .created]
        configuration.normalise()
        configuration.arrange([.created, .name, .size, .modified])
        XCTAssertEqual(configuration.columns, [.name, .created, .size, .modified])
        XCTAssertEqual(Array(configuration.columnOrder.prefix(5)),
                       [.name, .created, .kind, .size, .modified], "Kind stays where it was")
    }
}
