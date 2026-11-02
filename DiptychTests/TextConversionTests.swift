import XCTest
@testable import Diptych

final class TextConversionTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextConversionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private let hungarian = "Árvíztűrő tükörfúrógép. Őszintén szólva ez egy hosszú magyar mondat, ő és ű betűkkel."

    // MARK: - Encodings

    func testAMarkIsReadBeforeTheNulTestSoUTF16IsText() throws {
        let data = TextEncodings.encode("héllo\n", .utf16LittleEndian, bom: true)!
        XCTAssertTrue(data.contains(0))
        let reading = try XCTUnwrap(TextEncodings.reading(of: data, fallback: .utf8))
        XCTAssertEqual(reading.encoding, .utf16LittleEndian)
        XCTAssertEqual(reading.bomLength, 2)
        XCTAssertEqual(TextEncodings.decode(data, reading), "héllo\n")
    }

    func testANulWithoutAMarkIsNotText() {
        XCTAssertNil(TextEncodings.reading(of: Data([0x41, 0x00, 0x42]), fallback: .utf8))
    }

    /// Without a mark, by where the NUL bytes fall -- and only as a guess.
    func testUTF16AndUTF32WithoutAMarkAreToldByTheirNuls() throws {
        for encoding in [String.Encoding.utf16BigEndian, .utf16LittleEndian,
                         .utf32BigEndian, .utf32LittleEndian] {
            let data = try XCTUnwrap(TextEncodings.encode(hungarian + "\n", encoding, bom: false))
            let reading = try XCTUnwrap(TextEncodings.reading(of: data, fallback: .utf8),
                                        TextEncodings.name(of: encoding))
            XCTAssertEqual(reading.encoding, encoding)
            XCTAssertTrue(reading.guessed)
            XCTAssertEqual(TextEncodings.decode(data, reading), hungarian + "\n")
        }
    }

    func testNulsOutOfThatPatternAreStillBinary() {
        var bytes = [UInt8](repeating: 0x41, count: 400)
        for index in stride(from: 0, to: 400, by: 7) { bytes[index] = 0 }
        XCTAssertNil(TextEncodings.reading(of: Data(bytes), fallback: .utf8))
    }

    /// The system answers Windows Latin 5 for this, which the bytes are not
    /// even valid in; the reading that makes words of it is DOS Latin 1.
    func testADOSFileIsReadAsDOSThoughTheSystemGuessesOtherwise() throws {
        let text = "Grüße aus Köln, café naïve, Ñandú, Ærøskøbing\n"
        let dos = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosLatin1.rawValue)))
        let data = try XCTUnwrap(text.data(using: dos))
        let reading = try XCTUnwrap(TextEncodings.reading(of: data, fallback: .utf8))
        XCTAssertEqual(TextEncodings.decode(data, reading), text,
                       "read as \(TextEncodings.name(of: reading.encoding))")
    }

    /// The system takes KOI8-R for ISO Cyrillic, whose text has capitals in
    /// the middle of words.
    func testKOI8RIsNotTakenForISOCyrillic() throws {
        let text = "Съешь же ещё этих мягких французских булок, да выпей чаю.\n"
        let koi = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.KOI8_R.rawValue)))
        let data = try XCTUnwrap(text.data(using: koi))
        let reading = try XCTUnwrap(TextEncodings.reading(of: data, fallback: .utf8))
        XCTAssertEqual(TextEncodings.decode(data, reading), text,
                       "read as \(TextEncodings.name(of: reading.encoding))")
    }

    func testISO2022JPIsToldByItsEscapes() throws {
        let text = "日本語のテキスト\n"
        let data = try XCTUnwrap(text.data(using: .iso2022JP))
        let reading = try XCTUnwrap(TextEncodings.reading(of: data, fallback: .utf8))
        XCTAssertEqual(reading.encoding, .iso2022JP)
        XCTAssertEqual(TextEncodings.decode(data, reading), text)
    }

    func testAMisreadingScoresBelowTheRightOne() {
        XCTAssertGreaterThan(TextEncodings.plausibility("Grüße aus Köln, café"),
                             TextEncodings.plausibility("GrŁŖe aus K\u{94}ln, cafÄ"))
    }

    func testUTF8IsUTF8AndNotAGuess() throws {
        let reading = try XCTUnwrap(TextEncodings.reading(of: Data(hungarian.utf8), fallback: .isoLatin1))
        XCTAssertEqual(reading, TextEncodings.Reading(encoding: .utf8))
    }

    func testLatin2IsGuessedAsCentralEuropean() throws {
        let data = try XCTUnwrap(hungarian.data(using: .isoLatin2))
        let reading = try XCTUnwrap(TextEncodings.reading(of: data, fallback: .utf8))
        XCTAssertTrue(reading.guessed)
        XCTAssertEqual(TextEncodings.decode(data, reading), hungarian,
                       "read as \(TextEncodings.name(of: reading.encoding))")
    }

    func testAFileTooShortToTellTakesTheFallback() throws {
        let data = Data([0x63, 0x61, 0x66, 0xE9])   // "café" in Latin 1
        let reading = try XCTUnwrap(TextEncodings.reading(of: data, fallback: .utf8))
        XCTAssertEqual(reading.encoding, .utf8)
        XCTAssertTrue(reading.guessed)
        XCTAssertEqual(TextEncodings.decodeForShowing(data, reading), "caf\u{FFFD}")
    }

    func testEncodingRefusesWhatTheTargetCannotHold() {
        XCTAssertNil(TextEncodings.encode("ő", .isoLatin1, bom: false))
        XCTAssertEqual(TextEncodings.unrepresentable(in: "aőbű", .isoLatin1), 2)
        XCTAssertEqual(TextEncodings.encode("ő", .isoLatin2, bom: false), Data([0xF5]))
    }

    func testTheMarkIsWrittenOnlyWhenAsked() {
        XCTAssertEqual(TextEncodings.encode("a", .utf8, bom: true), Data([0xEF, 0xBB, 0xBF, 0x61]))
        XCTAssertEqual(TextEncodings.encode("a", .utf8, bom: false), Data([0x61]))
        XCTAssertEqual(TextEncodings.encode("a", .utf16BigEndian, bom: true), Data([0xFE, 0xFF, 0x00, 0x61]))
        XCTAssertEqual(TextEncodings.encode("a", .utf16BigEndian, bom: false), Data([0x00, 0x61]))
    }

    /// Text Edit reads a Latin-2 file as Latin-2 now, and a marked UTF-16 one
    /// at all -- and gives the mark back when it saves.
    func testTextEditKeepsTheMarkOfAUTF16File() throws {
        let data = TextEncodings.encode("one\ntwo\n", .utf16LittleEndian, bom: true)!
        let url = try file("wide.txt", data)
        let source = try TextDiff.load(url)
        XCTAssertEqual(source.lines, ["one", "two"])
        XCTAssertEqual(source.encoding, .utf16LittleEndian)
        XCTAssertEqual(source.bom, Data([0xFF, 0xFE]))
        XCTAssertEqual(source.bom + source.text(from: source.lines).data(using: source.encoding)!, data)
    }

    func testTextEditReadsLatin2() throws {
        let url = try file("hu.txt", hungarian.data(using: .isoLatin2)!)
        XCTAssertEqual(try TextDiff.load(url).lines, [hungarian])
    }

    // MARK: - Line endings

    func testEachKindIsCounted() {
        XCTAssertEqual(LineEndings.report(of: "a\r\nb\r\n").single, .crlf)
        XCTAssertEqual(LineEndings.report(of: "a\rb\r").single, .cr)
        XCTAssertEqual(LineEndings.report(of: "a\n\rb\n\r").single, .lfcr)
        XCTAssertEqual(LineEndings.report(of: "a\u{85}b").single, .nel)
        XCTAssertEqual(LineEndings.report(of: "a\u{2028}b").single, .ls)
        XCTAssertEqual(LineEndings.report(of: "a\u{2029}b").single, .ps)
        let mixed = LineEndings.report(of: "a\nb\r\nc\n")
        XCTAssertTrue(mixed.isMixed)
        XCTAssertEqual(mixed.counts, [.lf: 2, .crlf: 1])
        XCTAssertEqual(mixed.description, "mixed (LF 2, CRLF 1)")
    }

    /// Acorn's empty line is LF CR LF CR, not LF, CRLF and CR.
    func testAcornPairsUpWhenThatIsWhatTheFileHasMostOf() {
        let report = LineEndings.report(of: "a\n\r\n\rb\n\r")
        XCTAssertEqual(report.counts, [.lfcr: 3])
        XCTAssertEqual(LineEndings.report(of: "a\r\n\r\nb\r\n").counts, [.crlf: 3])
    }

    func testAMissingFinalEndingIsUnusualExceptAfterLSOrPS() {
        XCTAssertTrue(LineEndings.report(of: "a\nb").finalIsUnusual)
        XCTAssertFalse(LineEndings.report(of: "a\nb\n").finalIsUnusual)
        XCTAssertFalse(LineEndings.report(of: "a\u{2028}b").finalIsUnusual)
        XCTAssertTrue(LineEndings.report(of: "a\u{2028}b\u{2028}").finalIsUnusual)
        XCTAssertTrue(LineEndings.report(of: "one line").finalIsUnusual)
        XCTAssertFalse(LineEndings.report(of: "").finalIsUnusual)
    }

    func testConvertingMakesEveryEndingTheTargetAndTheLastAsAsked() {
        XCTAssertEqual(LineEndings.convert("a\r\nb\nc", to: .lf, finalEnding: true), "a\nb\nc\n")
        XCTAssertEqual(LineEndings.convert("a\nb\n", to: .crlf, finalEnding: true), "a\r\nb\r\n")
        XCTAssertEqual(LineEndings.convert("a\nb\n", to: .ls, finalEnding: false), "a\u{2028}b")
        XCTAssertEqual(LineEndings.convert("a\n\nb\n", to: .cr, finalEnding: false), "a\r\rb")
        XCTAssertEqual(LineEndings.convert("", to: .crlf, finalEnding: true), "")
    }

    @MainActor
    func testTheLastLineDefaultFollowsTheTarget() {
        let model = LineEndingsModel(jobId: UUID(), files: [])
        XCTAssertTrue(model.finalEnding)
        model.target = .ps
        XCTAssertFalse(model.finalEnding)
        model.target = .crlf
        XCTAssertTrue(model.finalEnding)
    }

    @MainActor
    func testALineSeparatorThatALatin1FileCannotHoldIsRefused() async throws {
        let url = try file("latin.txt", "caf\u{E9}\nbar\n".data(using: .isoLatin1)!)
        let model = LineEndingsModel(jobId: UUID(), files: [url])
        await model.load()
        model.target = .ls
        guard case .refused = model.plan(for: model.rows[0]) else {
            return XCTFail("LS written into a single-byte file")
        }
        model.target = .crlf
        XCTAssertEqual(model.plan(for: model.rows[0]),
                       .write("caf\u{E9}\r\nbar\r\n".data(using: model.rows[0].reading!.encoding)!))
    }

    @MainActor
    func testConvertingEncodingKeepsWhatCannotBeWritten() async throws {
        let url = try file("hu.txt", hungarian.data(using: .isoLatin2)!)
        let model = EncodingsModel(jobId: UUID(), files: [url])
        await model.load()
        model.setPerceivedForAll(.isoLatin2)
        model.target = .isoLatin1
        guard case .refused(let why) = model.plan(for: model.rows[0]) else {
            return XCTFail("ő and ű written as something else")
        }
        XCTAssertTrue(why.contains("not in"), why)
        model.target = .utf8
        XCTAssertFalse(model.bom)
        XCTAssertEqual(model.plan(for: model.rows[0]), .write(Data(hungarian.utf8)))
        model.target = .utf16LittleEndian
        XCTAssertTrue(model.bom, "UTF-16 is marked by default")
    }

    // MARK: - Checksum files among the selection

    func testAChecksumFileIsOneNamedForAKindAndHoldingASum() throws {
        let sum = try file("a.iso.sha256", Data((String(repeating: "ab", count: 32) + "  a.iso\n").utf8))
        let notes = try file("notes.md5", Data("nothing to see\n".utf8))
        let plain = try file("a.iso", Data("x".utf8))
        XCTAssertEqual(AppModel.checksumFiles(among: [sum, notes, plain]), [sum])
        XCTAssertEqual(AppModel.checksumFiles(among: [notes], pending: [notes]), [notes])
    }

    // MARK: - Installing from a disk image

    func testAVolumeOfAnAppAndALinkToApplicationsOffersToInstall() throws {
        let app = folder.appendingPathComponent("Thing.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("Applications").path,
                                                   withDestinationPath: "/Applications")
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        let image = URL(fileURLWithPath: "/tmp/Thing.dmg")
        let offer = try XCTUnwrap(AppInstalling.offer(on: folder, image: image))
        XCTAssertEqual(offer.app.lastPathComponent, "Thing.app")
        XCTAssertEqual(offer.destination.path, "/Applications/Thing.app")

        try Data().write(to: folder.appendingPathComponent("README.txt"))
        XCTAssertNil(AppInstalling.offer(on: folder, image: image), "more than the two")
    }

    func testApprovingKeepsWhereItCameFrom() {
        XCTAssertEqual(AppInstalling.approved("0083;6543a1b2;Safari;1F2E3D4C-0000-1111-2222-333344445555"),
                       "00c3;6543a1b2;Safari;1F2E3D4C-0000-1111-2222-333344445555")
        XCTAssertEqual(AppInstalling.approved("00c3;1;Chrome;"), "00c3;1;Chrome;")
        XCTAssertNil(AppInstalling.approved("garbage"))
    }

    /// The value is read from the installed copy: a quarantined image's app
    /// may have none of its own, and the copy gets the volume's.
    func testApprovingMarksTheCopyItselfAndLeavesTheRest() throws {
        let app = folder.appendingPathComponent("Thing.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let value = Array("0081;00000000;;D6209135-A5CB-471C-AC47-8B92E2E6F526".utf8)
        XCTAssertEqual(setxattr(app.path, AppInstalling.quarantine, value, value.count, 0, 0), 0)
        XCTAssertNil(AppInstalling.approve(app))
        XCTAssertEqual(AppInstalling.attribute(AppInstalling.quarantine, of: app),
                       "00c1;00000000;;D6209135-A5CB-471C-AC47-8B92E2E6F526")

        let plain = folder.appendingPathComponent("Plain.app", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertNil(AppInstalling.approve(plain), "nothing to approve")
        XCTAssertNil(AppInstalling.attribute(AppInstalling.quarantine, of: plain), "none added")
    }

    func testTheScriptCopiesWithDittoAndMovesAnOldOneAside() {
        let offer = AppInstalling.Offer(image: URL(fileURLWithPath: "/x/T.dmg"),
                                        volume: URL(fileURLWithPath: "/Volumes/T"),
                                        app: URL(fileURLWithPath: "/Volumes/T/T.app"))
        let script = AppInstalling.script(for: offer, choices: .init(),
                                          oldInTheWay: URL(fileURLWithPath: "/Applications/T.app"),
                                          user: 501)
        XCTAssertFalse(script.contains("\n"), "a newline does not parse in AppleScript")
        let lines = script.components(separatedBy: " && ")
        XCTAssertTrue(lines[0].hasPrefix("/bin/mv '/Applications/T.app' "), lines[0])
        XCTAssertTrue(lines[0].contains("/.Trash/"))
        XCTAssertEqual(lines[1], "/usr/bin/ditto '/Volumes/T/T.app' '/Applications/T.app'")
        XCTAssertEqual(lines[2], "/usr/sbin/chown -R 501:admin '/Applications/T.app'")
        XCTAssertFalse(script.contains("xattr"), "the copy is approved afterwards, as its owner")
    }

    // MARK: - The same text in different bytes

    private func differences(_ left: Data, _ right: Data) throws -> [String] {
        let a = try TextDiff.load(file("left-\(UUID()).txt", left))
        let b = try TextDiff.load(file("right-\(UUID()).txt", right))
        XCTAssertEqual(a.lines, b.lines, "the same text")
        return TextDiff.sameTextDifferences(a, b)
    }

    func testOnlyTheLastLineEndingDiffers() throws {
        let parts = try differences(Data("one\ntwo\n".utf8), Data("one\ntwo".utf8))
        XCTAssertEqual(parts, ["only the last line's ending (only the left file's last line has one)"])
    }

    func testAOneLineFileDiffersOnlyInItsEnding() throws {
        let parts = try differences(Data("one".utf8), Data("one\r\n".utf8))
        XCTAssertEqual(parts, ["only the last line's ending (only the right file's last line has one)"])
    }

    func testTheLineEndingsDiffer() throws {
        let parts = try differences(Data("one\ntwo\n".utf8), Data("one\r\ntwo\r\n".utf8))
        XCTAssertEqual(parts, ["the line endings (left LF, right CRLF)"])
    }

    func testTheLineEndingsAndTheLastOneDiffer() throws {
        let parts = try differences(Data("one\ntwo\n".utf8), Data("one\r\ntwo".utf8))
        XCTAssertEqual(parts, ["the line endings (left LF, right CRLF)",
                               "the last line's ending (only the left file's last line has one)"])
    }

    func testTheEncodingDiffers() throws {
        let text = "Привет, это длинная русская строка для проверки кодировки файла.\n"
        let dos = try XCTUnwrap(text.data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosRussian.rawValue)))))
        let parts = try differences(Data(text.utf8), dos)
        XCTAssertEqual(parts.count, 1)
        XCTAssertTrue(parts[0].hasPrefix("the character encoding (left UTF-8, right "), parts[0])
    }

    func testTheEncodingAndTheLineEndingsDiffer() throws {
        let latin2 = try XCTUnwrap((hungarian + "\r\n" + hungarian + "\r\n").data(using: .isoLatin2))
        let parts = try differences(Data((hungarian + "\n" + hungarian + "\n").utf8), latin2)
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[0].hasPrefix("the character encoding"))
        XCTAssertEqual(parts[1], "the line endings (left LF, right CRLF)")
    }

    func testOnlyAByteOrderMarkDiffers() throws {
        let parts = try differences(Data("héllo\n".utf8), Data([0xEF, 0xBB, 0xBF]) + Data("héllo\n".utf8))
        XCTAssertEqual(parts, ["the byte-order mark (only the right file has one)"])
    }
}
