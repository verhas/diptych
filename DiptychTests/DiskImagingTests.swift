import XCTest
import Darwin
@testable import Diptych

/// Create Archive's Disk Image and ISO: a `.dmg` built empty, filled and
/// converted, encrypted when asked; an `.iso` by makehybrid. Mounted out of
/// Finder's sight to look inside, and detached again.
final class DiskImagingTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default
    private var mounted: [URL] = []

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychImaging-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for point in mounted { detach(point) }
        try? fm.removeItem(at: root)
    }

    private func detach(_ point: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", "-quiet", "-force", point.path]
        try? process.run()
        process.waitUntilExit()
    }

    /// `src/photos/a.txt` with an attribute, and `src/notes.txt`.
    private func makeSources() throws -> [URL] {
        let folder = root.appendingPathComponent("src/photos")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = folder.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: a)
        XCTAssertNil(ExtendedAttributes.set(Data("v".utf8), name: "dev.diptych.test", on: a.path))
        let notes = root.appendingPathComponent("src/notes.txt")
        try Data("notes".utf8).write(to: notes)
        return [folder, notes]
    }

    private func create(_ items: [URL], _ options: Archiving.Options, password: String? = nil,
                        named name: String, job: Archiving.Job = Archiving.Job()) -> URL {
        let target = root.appendingPathComponent(name)
        do { try Archiving.create(items, at: target, options: options, password: password, job: job) }
        catch { XCTFail(error.message) }
        return target
    }

    private func mount(_ image: URL, password: String? = nil) throws -> Result<URL, Archiving.Failure> {
        let secret = try password.map { password -> Archiving.PasswordFile in
            do { return try Archiving.PasswordFile(password, endsWithNewline: false) }
            catch { throw error }
        }
        do {
            let point = try DiskImaging.mount(image, password: secret, browsable: false)
            mounted.append(point)
            return .success(point)
        } catch {
            return .failure(error)
        }
    }

    private func text(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func attachedImages() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: -

    func testADiskImageHoldsTheItemsWithTheirAttributes() throws {
        var options = Archiving.Options()
        options.format = .diskImage
        XCTAssertEqual(options.fileExtension, "dmg")
        let job = Archiving.Job()
        let image = create(try makeSources(), options, named: "Photos.dmg", job: job)
        XCTAssertTrue(DiskImaging.isDiskImage(image))
        XCTAssertFalse(DiskImaging.isEncrypted(image))
        XCTAssertFalse(attachedImages().contains(root.path), "the blank image is left attached")

        let point = try mount(image).get()
        XCTAssertEqual(text(point.appendingPathComponent("photos/a.txt")), "hello")
        XCTAssertEqual(text(point.appendingPathComponent("notes.txt")), "notes")
        XCTAssertEqual(ExtendedAttributes.data(of: point.appendingPathComponent("photos/a.txt").path,
                                               name: "dev.diptych.test"), Data("v".utf8))
        XCTAssertEqual(job.snapshot().files, 2, "ditto's lines counted while copying in")
        // Nothing left beside it but the image.
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).sorted(), ["Photos.dmg", "src"])
    }

    func testAnEncryptedDiskImageMountsWithItsPasswordOnly() throws {
        var options = Archiving.Options()
        options.format = .diskImage
        options.diskImageEncryption = .aes256
        options.diskImageFilesystem = .hfs
        options.diskImageFormat = .zlib
        XCTAssertTrue(options.needsPassword)
        let image = create(try makeSources(), options, password: "s3cret", named: "Locked.dmg")
        XCTAssertTrue(DiskImaging.isEncrypted(image))

        guard case .failure(let failure) = try mount(image, password: "wrong") else {
            return XCTFail("mounted with the wrong password")
        }
        XCTAssertTrue(failure.isWrongPassword, failure.message)
        let point = try mount(image, password: "s3cret").get()
        XCTAssertEqual(text(point.appendingPathComponent("notes.txt")), "notes")
    }

    func testAnISOHoldsTheItems() throws {
        var options = Archiving.Options()
        options.format = .iso
        XCTAssertFalse(options.needsPassword)
        XCTAssertEqual(options.fileExtension, "iso")
        let image = create(try makeSources(), options, named: "Disc.iso")
        // ISO 9660's volume descriptor, at sector 16.
        let data = try Data(contentsOf: image)
        XCTAssertEqual(data.subdata(in: 0x8001..<0x8006), Data("CD001".utf8))
        let point = try mount(image).get()
        XCTAssertEqual(text(point.appendingPathComponent("photos/a.txt")), "hello")
        XCTAssertEqual(text(point.appendingPathComponent("notes.txt")), "notes")
    }

    func testAStoppedImageLeavesNothingBehindOrAttached() throws {
        var options = Archiving.Options()
        options.format = .diskImage
        let job = Archiving.Job()
        job.cancel()
        let target = root.appendingPathComponent("Stopped.dmg")
        XCTAssertThrowsError(try Archiving.create(try makeSources(), at: target, options: options, job: job))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), ["src"])
        XCTAssertFalse(attachedImages().contains(root.path))
    }

    func testTheRoomIsEnoughForWholeBlocks() throws {
        let items = try makeSources()
        // Two files and a folder, a block each, and the file system's own.
        XCTAssertGreaterThanOrEqual(DiskImaging.roomNeeded(for: items), 3 * 4096 + (48 << 20))
    }
}
