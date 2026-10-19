import XCTest
import Darwin
@testable import Diptych

/// Archive ▸ Create Archive… and Extract: zip through ditto, tar, and Apple
/// Archive, and what unpacking as the user does not give.
final class ArchivingTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychArchiving-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    /// `src/photos/a.txt` with an attribute, `src/photos/run` setuid, and
    /// `src/notes.txt`.
    private func makeSources() throws -> (folder: URL, file: URL) {
        let source = root.appendingPathComponent("src")
        let folder = source.appendingPathComponent("photos")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = folder.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: a)
        XCTAssertNil(ExtendedAttributes.set(Data("v".utf8), name: "dev.diptych.test", on: a.path))
        let run = folder.appendingPathComponent("run")
        try Data("#!/bin/sh\n".utf8).write(to: run)
        XCTAssertEqual(chmod(run.path, 0o4755), 0)
        let notes = source.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: notes)
        return (folder, notes)
    }

    private func create(_ items: [URL], _ options: Archiving.Options, named name: String) throws -> URL {
        let target = root.appendingPathComponent(name)
        do { try Archiving.create(items, at: target, options: options) }
        catch { XCTFail(error.message) }
        return target
    }

    /// Unpacked as the user into a new folder.
    private func unpack(_ archive: URL) throws -> URL {
        let out = root.appendingPathComponent("out-\(UUID().uuidString)")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let kind = try XCTUnwrap(Archiving.kind(of: archive))
        do { try Archiving.unpack(archive, kind: kind, into: out) }
        catch { XCTFail(error.message) }
        return out
    }

    private func entries(_ archive: URL) throws -> [Archiving.Entry] {
        let kind = try XCTUnwrap(Archiving.kind(of: archive))
        do { return try Archiving.entries(of: archive, kind: kind) }
        catch { XCTFail(error.message); return [] }
    }

    private func zipNames(_ archive: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", archive.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        lstat(url.path, &info)
        return info.st_mode & 0o7777
    }

    // MARK: - Zip

    func testAZipKeepsMacDataInAMacOSXFolderAsFinderDoes() throws {
        let (folder, _) = try makeSources()
        let zip = try create([folder], Archiving.Options(), named: "photos.zip")

        let names = try zipNames(zip)
        XCTAssertTrue(names.contains("photos/a.txt"))
        XCTAssertTrue(names.contains("__MACOSX/photos/._a.txt"), "\(names)")

        let out = try unpack(zip)
        XCTAssertEqual(ExtendedAttributes.data(of: out.appendingPathComponent("photos/a.txt").path,
                                               name: "dev.diptych.test"), Data("v".utf8))
        XCTAssertFalse(fm.fileExists(atPath: out.appendingPathComponent("__MACOSX").path))
    }

    func testAZipWithoutMacDataHasNoMacOSXFolder() throws {
        let (folder, _) = try makeSources()
        var options = Archiving.Options()
        options.zipMacMetadata = false
        let zip = try create([folder], options, named: "plain.zip")

        let names = try zipNames(zip)
        XCTAssertFalse(names.contains { $0.hasPrefix("__MACOSX") }, "\(names)")
        XCTAssertFalse(names.contains { $0.contains("/._") }, "\(names)")
        let out = try unpack(zip)
        XCTAssertNil(ExtendedAttributes.data(of: out.appendingPathComponent("photos/a.txt").path,
                                             name: "dev.diptych.test"))
    }

    func testAZipOfOneFileHoldsJustTheFile() throws {
        let (_, notes) = try makeSources()
        let zip = try create([notes], Archiving.Options(), named: "notes.zip")
        XCTAssertEqual(try zipNames(zip).filter { !$0.hasPrefix("__MACOSX") }, ["notes.txt"])
        let folderZip = try create([notes.deletingLastPathComponent()], Archiving.Options(), named: "src.zip")
        XCTAssertTrue(try zipNames(folderZip).contains("src/notes.txt"), "a folder is kept whole")
    }

    func testSeveralItemsGoSideBySideAtTheTop() throws {
        let (folder, notes) = try makeSources()
        for format in [Archiving.Format.zip, .tar, .appleArchive] {
            var options = Archiving.Options()
            options.format = format
            let archive = try create([folder, notes], options, named: "both.\(options.fileExtension)")
            let out = try unpack(archive)
            XCTAssertEqual(Archiving.topLevel(of: out), ["notes.txt", "photos"], "\(format)")
            XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("photos/a.txt").path))
        }
    }

    func testItemsFromSeveralFoldersCanBeArchivedTogether() throws {
        let (folder, _) = try makeSources()
        let elsewhere = root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let other = elsewhere.appendingPathComponent("other.txt")
        try Data("x".utf8).write(to: other)
        for format in [Archiving.Format.zip, .tar, .appleArchive] {
            var options = Archiving.Options()
            options.format = format
            let archive = try create([folder.appendingPathComponent("a.txt"), other], options,
                                     named: "mixed.\(options.fileExtension)")
            XCTAssertEqual(Archiving.topLevel(of: try unpack(archive)), ["a.txt", "other.txt"],
                           "\(format)")
        }
    }

    func testTheProgressCountsWhatTheToolsSay() throws {
        let (folder, notes) = try makeSources()
        let big = folder.appendingPathComponent("big")
        try Data(repeating: 7, count: 3_000_000).write(to: big)
        for format in [Archiving.Format.zip, .tar, .appleArchive] {
            var options = Archiving.Options()
            options.format = format
            let job = Archiving.Job()
            let target = root.appendingPathComponent("progress.\(options.fileExtension)")
            do { try Archiving.create([folder, notes], at: target, options: options, job: job) }
            catch { XCTFail(error.message) }
            let done = job.snapshot()
            XCTAssertEqual(done.totalFiles, 4, "\(format)")
            XCTAssertEqual(done.totalBytes, 3_000_000 + 5 + 10 + 5, "\(format)")
            XCTAssertEqual(done.phase, .finishing)
            XCTAssertNil(done.current, "\(format)")
            if format == .appleArchive {
                XCTAssertFalse(done.countsFiles)
                XCTAssertGreaterThanOrEqual(done.bytes, done.totalBytes,
                                            "the uncompressed stream holds every byte")
            } else {
                XCTAssertEqual(done.files, 4, "\(format)")
                XCTAssertEqual(done.bytes, done.totalBytes, "\(format)")
            }
            XCTAssertEqual(done.fraction ?? 0, 0.999, accuracy: 0.0001)
            XCTAssertEqual(Archiving.topLevel(of: try unpack(target)), ["notes.txt", "photos"])
        }
    }

    func testAStoppedAppleArchiveLeavesNothingBehind() throws {
        let (folder, _) = try makeSources()
        try Data(repeating: 1, count: 50_000_000).write(to: folder.appendingPathComponent("big"))
        var options = Archiving.Options()
        options.format = .appleArchive
        let job = Archiving.Job()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { job.cancel() }
        let target = root.appendingPathComponent("stopped.aar")
        XCTAssertThrowsError(try Archiving.create([folder], at: target, options: options, job: job))
        XCTAssertFalse(fm.fileExists(atPath: target.path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).sorted(), ["src"])
    }

    func testTwoItemsOfTheSameNameAreRefused() throws {
        let (folder, _) = try makeSources()
        let elsewhere = root.appendingPathComponent("elsewhere/a.txt")
        try fm.createDirectory(at: elsewhere.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data("x".utf8).write(to: elsewhere)
        let target = root.appendingPathComponent("clash.zip")
        XCTAssertThrowsError(try Archiving.create([folder.appendingPathComponent("a.txt"), elsewhere],
                                                  at: target, options: Archiving.Options()))
        XCTAssertFalse(fm.fileExists(atPath: target.path))
    }

    func testAStoppedArchiveLeavesNothingBehind() throws {
        let (folder, _) = try makeSources()
        let job = Archiving.Job()
        job.cancel()
        let target = root.appendingPathComponent("stopped.zip")
        XCTAssertThrowsError(try Archiving.create([folder], at: target,
                                                  options: Archiving.Options(), job: job))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).sorted(), ["src"])
    }

    // MARK: - tar

    func testTarCompressionsAndOwners() throws {
        let (folder, _) = try makeSources()
        for compression in Archiving.TarCompression.allCases {
            var options = Archiving.Options()
            options.format = .tar
            options.tarCompression = compression
            options.tarOwners = .root
            let archive = try create([folder], options, named: "p.\(compression.fileExtension)")
            XCTAssertEqual(Archiving.kind(of: archive), .tar)
            let found = try entries(archive)
            XCTAssertEqual(Set(found.map(\.path)), ["photos", "photos/a.txt", "photos/run"])
            XCTAssertTrue(found.allSatisfy { $0.uid == 0 && $0.gid == 0 }, "\(compression)")
        }
    }

    func testTarWithoutMacDataLeavesTheAttributesOut() throws {
        let (folder, _) = try makeSources()
        var options = Archiving.Options()
        options.format = .tar
        options.tarMacMetadata = false
        let out = try unpack(try create([folder], options, named: "p.tar.gz"))
        XCTAssertNil(ExtendedAttributes.data(of: out.appendingPathComponent("photos/a.txt").path,
                                             name: "dev.diptych.test"))
        XCTAssertEqual(Archiving.topLevel(of: out.appendingPathComponent("photos")), ["a.txt", "run"])
    }

    // MARK: - Apple Archive

    func testAnAppleArchiveCanLeaveOwnersAndAttributesOut() throws {
        let (folder, _) = try makeSources()
        var options = Archiving.Options()
        options.format = .appleArchive
        options.aarCompression = .lzma
        options.aarOwners = false
        options.aarExtendedAttributes = false
        let archive = try create([folder], options, named: "p.aar")
        let found = try entries(archive)
        XCTAssertEqual(Set(found.map(\.path)), ["photos", "photos/a.txt", "photos/run"])
        XCTAssertTrue(found.allSatisfy { $0.uid == nil && $0.gid == nil })
        XCTAssertEqual(found.first { $0.path == "photos/run" }?.mode, 0o4755)

        let out = try unpack(archive)
        XCTAssertNil(ExtendedAttributes.data(of: out.appendingPathComponent("photos/a.txt").path,
                                             name: "dev.diptych.test"))
    }

    // MARK: - What unpacking does not give

    func testDittoDropsSetuidAndThatIsSeen() throws {
        let (folder, _) = try makeSources()
        let zip = try create([folder], Archiving.Options(), named: "p.zip")
        let found = try entries(zip)
        XCTAssertEqual(found.first { $0.path == "photos/run" }?.mode, 0o4755,
                       "the zip records setuid")
        XCTAssertFalse(found.contains { $0.path.hasPrefix("__MACOSX") },
                       "libarchive folds __MACOSX into the files")

        let out = try unpack(zip)
        let differences = Archiving.differences(found, in: out)
        XCTAssertEqual(differences.map(\.path), ["photos/run"])
        XCTAssertEqual(differences.first?.specialLost, true)
        XCTAssertEqual(differences.first?.mode, 0o4755)
        XCTAssertEqual(Archiving.summary(differences).count, 1)
    }

    func testAppleArchiveAndTarKeepSetuidOnTheUsersOwnFiles() throws {
        let (folder, _) = try makeSources()
        for format in [Archiving.Format.appleArchive, .tar] {
            var options = Archiving.Options()
            options.format = format
            let archive = try create([folder], options, named: "p.\(options.fileExtension)")
            let out = try unpack(archive)
            XCTAssertEqual(mode(out.appendingPathComponent("photos/run")), 0o4755, "\(format)")
            XCTAssertEqual(Archiving.differences(try entries(archive), in: out), [], "\(format)")
        }
    }

    func testAnotherOwnerIsADifference() throws {
        let (folder, _) = try makeSources()
        var options = Archiving.Options()
        options.format = .tar
        options.tarOwners = .root
        let archive = try create([folder], options, named: "p.tgz")
        let differences = Archiving.differences(try entries(archive), in: try unpack(archive))
        XCTAssertEqual(Set(differences.map(\.path)), ["photos", "photos/a.txt", "photos/run"])
        XCTAssertTrue(differences.allSatisfy { $0.uid == 0 })
        XCTAssertTrue(Archiving.summary(differences).contains("3 items owned by root (0)"),
                      "\(Archiving.summary(differences))")
    }

    // MARK: - Where it goes

    func testOneTopItemIsPlacedByItselfAndSeveralInAFolder() throws {
        let destination = root.appendingPathComponent("dest")
        try fm.createDirectory(at: destination.appendingPathComponent("photos"),
                               withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("holiday.tar.gz")

        let one = Archiving.placement(of: ["photos"], from: archive, into: destination)
        XCTAssertNil(one.wrapper)
        XCTAssertEqual(one.results.map(\.lastPathComponent), ["photos 2"])

        let several = Archiving.placement(of: ["a", "b"], from: archive, into: destination)
        XCTAssertEqual(several.wrapper?.lastPathComponent, "holiday")
        XCTAssertEqual(several.moves.map(\.to.path),
                       ["holiday/a", "holiday/b"].map { destination.appendingPathComponent($0).path })
    }

    func testNamesAndStems() {
        XCTAssertEqual(Archiving.stem(of: URL(fileURLWithPath: "/x/logs.tar.gz")), "logs")
        XCTAssertEqual(Archiving.stem(of: URL(fileURLWithPath: "/x/logs.tgz")), "logs")
        XCTAssertEqual(Archiving.stem(of: URL(fileURLWithPath: "/x/a.b.zip")), "a.b")
        XCTAssertEqual(Archiving.kind(of: URL(fileURLWithPath: "/x/A.TAR.XZ")), .tar)
        XCTAssertEqual(Archiving.kind(of: URL(fileURLWithPath: "/x/a.aar")), .appleArchive)
        XCTAssertNil(Archiving.kind(of: URL(fileURLWithPath: "/x/a.gz")),
                     "a lone gzip is not an archive of files")
        XCTAssertEqual(Archiving.defaultStem(for: [URL(fileURLWithPath: "/x/notes.txt")]), "notes.txt")
        XCTAssertEqual(Archiving.defaultStem(for: [URL(fileURLWithPath: "/x/a"),
                                                   URL(fileURLWithPath: "/x/b")]), "Archive")
    }

    func testANumberIsAddedWhenTheNameIsTaken() throws {
        try Data().write(to: root.appendingPathComponent("Archive.tar.gz"))
        XCTAssertEqual(Archiving.numbered("Archive", extension: "tar.gz", in: root).lastPathComponent,
                       "Archive 2.tar.gz")
    }

    func testMtreeNamesAreUnescaped() {
        XCTAssertEqual(Archiving.unescapeMtree("a\\040b\\134c"), "a b\\c")
        XCTAssertEqual(Archiving.unescapeMtree("caf\\303\\251"), "caf\u{E9}")
        let parsed = Archiving.parseMtree("#mtree\n./d/a\\040b mode=4755 gid=12 uid=0 type=file\n")
        XCTAssertEqual(parsed, [Archiving.Entry(path: "d/a b", uid: 0, gid: 12, mode: 0o4755,
                                                isLink: false)])
    }

    func testTheQuarantineMarkGoesOnEverythingInside() throws {
        let folder = root.appendingPathComponent("x/sub")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("f"))
        let mark = Data("0081;00000000;DiptychTests;".utf8)
        Archiving.markQuarantined(root.appendingPathComponent("x"), with: mark)
        for path in ["x/sub", "x/sub/f"] {
            XCTAssertNotNil(ExtendedAttributes.data(of: root.appendingPathComponent(path).path,
                                                    name: "com.apple.quarantine"), path)
        }
    }

    // MARK: - As an administrator

    func testTheRestoreScriptChecksTheArchiveAndSetsOwnersBeforeModes() throws {
        let destination = root.appendingPathComponent("it's here")
        let placement = Archiving.placement(of: ["d"], from: root.appendingPathComponent("a.zip"),
                                            into: destination)
        let script = Archiving.restoreScript(
            archive: root.appendingPathComponent("a.zip"), sha256: "abc", kind: .zip,
            differences: [Archiving.Difference(path: "d/run", uid: 0, gid: 0, mode: 0o4755,
                                               specialLost: true)],
            placement: placement, destination: destination,
            quarantine: Data("0081;0;Safari;".utf8))

        XCTAssertFalse(script.contains("\n"), "one AppleScript string")
        XCTAssertTrue(script.contains("/usr/bin/shasum -a 256"))
        XCTAssertTrue(script.contains("= 'abc' ]"))
        XCTAssertTrue(script.contains("/usr/bin/ditto '-x' '-k' \"$R\"'/archive' \"$R\"'/x'"), script)
        let chown = try XCTUnwrap(script.range(of: "/usr/sbin/chown -h 0:0 -- './d/run'"))
        let chmod = try XCTUnwrap(script.range(of: "/bin/chmod 4755 -- './d/run'"))
        XCTAssertLessThan(chown.lowerBound, chmod.lowerBound, "chown takes setuid off")
        XCTAssertTrue(script.contains("com.apple.quarantine '0081;0;Safari;'"))
        XCTAssertTrue(script.contains(Shell.quoted(destination.path + "/d")))
        XCTAssertTrue(script.contains("it'\\''s here"), "quoted for the shell")

        // It parses.
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/sh")
        check.arguments = ["-n", "-c", script]
        try check.run()
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)
    }

    func testAnAppleArchiveOfOddNamesTakesExactlyThose() throws {
        let folder = root.appendingPathComponent("odd")
        for name in ["a.b", "a+b (1)", "ab", "a", "[x]"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent(name).creatingFolder())
        }
        var options = Archiving.Options()
        options.format = .appleArchive
        let archive = try create(["a.b", "a+b (1)", "[x]"].map { folder.appendingPathComponent($0) },
                                 options, named: "odd.aar")
        XCTAssertEqual(Set(try entries(archive).map(\.path)), ["a.b", "a+b (1)", "[x]"])
    }

    func testTheSumIsTheArchives() throws {
        let file = root.appendingPathComponent("f")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(Archiving.sha256(of: file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

private extension URL {
    /// Itself, once its folder is there.
    func creatingFolder() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        return self
    }
}
