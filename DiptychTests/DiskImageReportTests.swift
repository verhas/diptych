import XCTest
@testable import Diptych

/// Disk images: made here from a folder with hdiutil and diskutil, read
/// without attaching them.
final class DiskImageReportTests: XCTestCase {

    private var folder: URL!
    private var source: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DiskImageReportTests-\(UUID().uuidString)")
        source = folder.appendingPathComponent("Sample Volume")
        let app = source.appendingPathComponent("Sample.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try "<plist version=\"1.0\"><dict/></plist>\n".write(to: app.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try String(repeating: "x", count: 1234).write(to: source.appendingPathComponent("Read Me.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("Applications").path,
                                                   withDestinationPath: "/Applications")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// hdiutil now and then answers "resource busy" while another image is
    /// being made: tried again, a few times.
    private func run(_ tool: String, _ arguments: [String], input: String? = nil) throws {
        var attempt = 0
        while true {
            do {
                return try runOnce(tool, arguments, input: input)
            } catch where attempt < 3 {
                attempt += 1
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    private func runOnce(_ tool: String, _ arguments: [String], input: String?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if let input {
            let pipe = Pipe()
            process.standardInput = pipe
            try process.run()
            pipe.fileHandleForWriting.write(Data(input.utf8))
            try pipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "tool", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(tool) \(arguments.joined(separator: " "))"])
        }
    }

    /// diskutil's image from the folder, in a format: APFS.
    private func image(_ format: String, name: String) throws -> URL {
        let target = folder.appendingPathComponent(name)
        try run("/usr/sbin/diskutil", ["image", "create", "from", "--format", format, source.path, target.path])
        return target
    }

    private func read(_ url: URL, verify: Bool = true) throws -> DiskImage {
        try DiskImage(url: url, data: Data(contentsOf: url, options: .alwaysMapped), verify: verify)
    }

    private func assertSampleVolume(_ image: DiskImage, fileSystem: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let volume = try XCTUnwrap(image.partitions.compactMap(\.volume).first, file: file, line: line)
        XCTAssertTrue(volume.fileSystem.hasPrefix(fileSystem), volume.fileSystem, file: file, line: line)
        let items = volume.items.filter { !$0.hidden }.sorted { $0.name < $1.name }
        XCTAssertEqual(items.map(\.name), ["Applications", "Read Me.txt", "Sample.app"], file: file, line: line)
        XCTAssertEqual(items.map(\.isLink), [true, false, false], file: file, line: line)
        XCTAssertEqual(items.map(\.isFolder), [false, false, true], file: file, line: line)
        XCTAssertEqual(items[1].size, 1234, file: file, line: line)
    }

    func testAPFSFormats() throws {
        for (format, code) in [("ULFO", "ULFO"), ("ULMO", "ULMO"), ("UDZO", "UDZO"), ("UDRO", "UDRO"), ("RAW", "UDRW")] {
            let image = try read(try image(format, name: "\(format).dmg"))
            XCTAssertEqual(image.format, code)
            XCTAssertEqual(image.partitionScheme, "GUID partition map")
            try assertSampleVolume(image, fileSystem: "APFS")
            XCTAssertEqual(image.partitions.compactMap(\.volume).first?.name, "Sample Volume")
            XCTAssertNil(image.signature)
        }
    }

    func testHFSPlus() throws {
        let target = folder.appendingPathComponent("hfs.dmg")
        try run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", source.path, "-volname", "Classic",
                                     "-fs", "HFS+", "-format", "UDZO", target.path])
        let image = try read(target)
        XCTAssertEqual(image.format, "UDZO")
        try assertSampleVolume(image, fileSystem: "Mac OS Extended")
        XCTAssertEqual(image.partitions.compactMap(\.volume).first?.name, "Classic")
        let html = DiskImageReport.html(for: image, checking: false)
        XCTAssertTrue(html.contains("Volume \u{201C}Classic\u{201D}"))
        XCTAssertTrue(html.contains("a link to Applications"))
        XCTAssertTrue(html.contains("Read-only disk image, zlib-compressed"))
    }

    func testSparseBundleAndSparseImage() throws {
        let bundle = folder.appendingPathComponent("Sample.sparsebundle")
        try run("/usr/sbin/diskutil", ["image", "create", "from", source.path, bundle.path])
        let read = try DiskImage(bundle: bundle)
        XCTAssertEqual(read.format, "UDSB")
        XCTAssertNil(read.encryption)
        try assertSampleVolume(read, fileSystem: "APFS")

        let sparse = folder.appendingPathComponent("Sample.sparseimage")
        try run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "10m", "-type", "SPARSE", "-fs", "HFS+",
                                     "-volname", "Sparse", sparse.path])
        let image = try self.read(sparse)
        XCTAssertEqual(image.format, "UDSP")
        XCTAssertEqual(image.fullSize, 10 * 1024 * 1024)
        XCTAssertEqual(image.partitions.compactMap(\.volume).first?.name, "Sparse")
    }

    func testSignedAndChanged() throws {
        let target = try image("ULFO", name: "signed.dmg")
        try run("/usr/bin/codesign", ["-s", "-", target.path])
        let signed = try read(target)
        XCTAssertNotNil(signed.signature)
        XCTAssertEqual(signed.signatureMismatch, "")
        XCTAssertFalse(signed.stapled)
        XCTAssertTrue(DiskImageReport.html(for: signed, checking: false).contains("of the whole image matches"))
        XCTAssertNil(try read(target, verify: false).signatureMismatch)

        var data = try Data(contentsOf: target)
        data[1000] ^= 0xFF
        let changed = folder.appendingPathComponent("changed.dmg")
        try data.write(to: changed)
        let broken = try read(changed)
        XCTAssertEqual(broken.signatureMismatch, "Its contents changed after signing.")
        XCTAssertTrue(DiskImageReport.html(for: broken, checking: false).contains("It changed after it was signed."))

        // The trailer is signed too, its signature's length left out.
        var trailer = try Data(contentsOf: target)
        trailer[trailer.count - 512 + 12] ^= 0x02
        try trailer.write(to: changed)
        XCTAssertEqual(try read(changed).signatureMismatch, "Its trailer changed after signing.")
    }

    func testEncrypted() throws {
        let target = folder.appendingPathComponent("encrypted.dmg")
        try run("/usr/sbin/diskutil", ["image", "create", "from", "--encrypt", "--stdinpass", source.path, target.path],
                input: "sample-password")
        let image = try read(target)
        XCTAssertEqual(image.encryption, "AES-256")
        XCTAssertTrue(image.partitions.isEmpty)
        let html = DiskImageReport.html(for: image, checking: false)
        XCTAssertTrue(html.contains("cannot be read without its password"))
        XCTAssertFalse(html.contains("<b>Signature</b>"))
    }

    func testNotAnImage() {
        let data = Data(repeating: 0x41, count: 4096)
        XCTAssertFalse(DiskImage.looksLikeImage(data))
        XCTAssertThrowsError(try DiskImage(url: URL(fileURLWithPath: "/x.dmg"), data: data, verify: true))
    }

    /// Damaged images: never a trap, whatever the trailer, the tables or
    /// the volume say.
    func testDamagedImagesDoNotCrash() throws {
        var originals = [try Data(contentsOf: try image("ULFO", name: "fuzz.dmg"))]
        let hfs = folder.appendingPathComponent("fuzz-hfs.dmg")
        try run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", source.path, "-fs", "HFS+", "-format", "UDRO", hfs.path])
        originals.append(try Data(contentsOf: hfs))
        var generator = SeededGenerator(seed: 11)
        for original in originals {
            for round in 0..<300 {
                var data = original
                for _ in 0..<(1 + round % 6) {
                    // The trailer, the partition table, then anywhere.
                    let region = round % 3 == 0 ? (data.count - 512)..<data.count : round % 3 == 1 ? 0..<min(80_000, data.count) : 0..<data.count
                    data[Int.random(in: region, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
                }
                if let image = try? DiskImage(url: URL(fileURLWithPath: "/damaged.dmg"), data: data, verify: true) {
                    _ = DiskImageReport.html(for: image, checking: false)
                }
            }
        }
    }
}
