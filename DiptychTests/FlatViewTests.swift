import XCTest
@testable import Diptych

/// The flat view's expression: parsing it, what it says about an item, and
/// walking a tree with it.
final class FlatQueryTests: XCTestCase {

    private func query(_ text: String, file: StaticString = #filePath,
                       line: UInt = #line) -> FlatQuery {
        switch FlatQuery.parse(text) {
        case .success(let query): return query
        case .failure(let problem):
            XCTFail("\(text): \(problem.message)", file: file, line: line)
            return try! FlatQuery.parse("").get()
        }
    }

    private func problem(_ text: String) -> FlatQuery.Problem? {
        if case .failure(let problem) = FlatQuery.parse(text) { return problem }
        return nil
    }

    private func subject(_ name: String, directory: Bool = false, size: Int64 = 0,
                         mode: mode_t = 0o644, owner: String = "peter",
                         modified: Date = Date()) -> FlatSubject {
        FlatSubject(url: URL(fileURLWithPath: "/nowhere/\(name)"), name: name,
                    isDirectory: directory, size: size, mode: mode, owner: owner,
                    group: "staff", created: modified, modified: modified)
    }

    // MARK: - Parsing

    func testAndBindsTighterThanOr() {
        let parsed = query("name = a or name = b and size > 1")
        guard case .or(_, .and) = parsed.expression else {
            return XCTFail("\(String(describing: parsed.expression))")
        }
    }

    func testKeywordsInAnyCase() {
        XCTAssertNotNil(query("NAME = \"x\" AND Size >= 1KiB Or NOT FILE").expression)
        XCTAssertTrue(query("Directory Traversed or file").namesKinds)
    }

    func testSizes() {
        XCTAssertEqual(FlatQuery.bytes("1024"), 1024)
        XCTAssertEqual(FlatQuery.bytes("10KB"), 10_000)
        XCTAssertEqual(FlatQuery.bytes("10kib"), 10_240)
        XCTAssertEqual(FlatQuery.bytes("1.5MiB"), 1_572_864)
        XCTAssertEqual(FlatQuery.bytes("2TB"), 2_000_000_000_000)
        XCTAssertNil(FlatQuery.bytes("10XB"))
        guard case .primitive(.size(.greater, 10_000_000))? = query("size > 10 MB").expression
        else { return XCTFail("a unit after a space") }
    }

    func testProblemsSayWhere() {
        let text = "name = \"*.txt\" and siz > 1"
        let found = problem(text)
        XCTAssertEqual(found?.range, (text as NSString).range(of: "siz"))
        XCTAssertNotNil(problem("size >"))
        XCTAssertEqual(problem("size >")?.range.location, 6, "missing: at the end")
        XCTAssertNotNil(problem("(name = a"))
        XCTAssertNotNil(problem("name = \"open"))
        XCTAssertNotNil(problem("name ~ /(/"), "a regex that does not compile")
        XCTAssertNotNil(problem("name ~ \"x\""), "a regular expression is between slashes")
        XCTAssertNotNil(problem("name = /x/"), "= is not for a regular expression")
        XCTAssertNotNil(problem("name ~ /x/q"), "no such flag")
        XCTAssertNotNil(problem("name ~ /open"))
        XCTAssertNotNil(problem("access = \"rwxrwxrw\""), "eight places")
        XCTAssertNotNil(problem("access = \"xwxrwxrwx\""), "x in a read place")
        XCTAssertNotNil(problem("modified > yesterday"))
        XCTAssertNotNil(problem("name = a and"))
        XCTAssertNil(problem(""), "nothing is everything")
    }

    func testDatesToTheirPrecision() throws {
        let zone = TimeZone(identifier: "Europe/Budapest")!
        let day = try XCTUnwrap(FlatQuery.moment("2026-01-31", zone: zone))
        XCTAssertEqual(day.end.timeIntervalSince(day.start), 24 * 3600)
        let minute = try XCTUnwrap(FlatQuery.moment("2026-01-31T14:30", zone: zone))
        XCTAssertEqual(minute.end.timeIntervalSince(minute.start), 60)
        let utc = try XCTUnwrap(FlatQuery.moment("2026-01-31T14:30:00Z", zone: zone))
        let offset = try XCTUnwrap(FlatQuery.moment("2026-01-31T15:30:00+01:00", zone: zone))
        XCTAssertEqual(utc.start, offset.start)
        XCTAssertNil(FlatQuery.moment("2026-02-30"))
        // = is within the day; > is after it.
        let noon = day.start.addingTimeInterval(12 * 3600)
        XCTAssertTrue(day.holds(noon, .equal))
        XCTAssertFalse(day.holds(noon, .greater))
        XCTAssertTrue(day.holds(day.end, .greater))
    }

    func testAccessPatterns() throws {
        let range = NSRange(location: 0, length: 0)
        let mask = try FlatQuery.accessMask("rw*r--***", at: range)
        XCTAssertTrue(mask.holds(0o644))
        XCTAssertTrue(mask.holds(0o744))
        XCTAssertFalse(mask.holds(0o664), "group write must be clear")
        let setuid = try FlatQuery.accessMask("**s******", at: range)
        XCTAssertTrue(setuid.holds(0o4755))
        XCTAssertFalse(setuid.holds(0o755))
        let sticky = try FlatQuery.accessMask("********T", at: range)
        XCTAssertTrue(sticky.holds(0o1777), "case does not matter: T is t")
    }

    // MARK: - What it decides

    /// No `directory` or `file`: about files, every folder listed and walked.
    func testAnExpressionAboutFilesLeavesFoldersAlone() {
        let q = query("name = \"*.txt\"")
        XCTAssertEqual(q.decide(subject("a.txt")), .init(list: true, traverse: false))
        XCTAssertEqual(q.decide(subject("a.md")), .init(list: false, traverse: false))
        XCTAssertEqual(q.decide(subject("src", directory: true)), .init(list: true, traverse: true))
    }

    /// The example from the request: only folders named myDir are walked,
    /// and .txt files are kept.
    func testFoldersByName() {
        let q = query("(directory and name = \"myDir\") or (file and name = \"*.txt\")")
        XCTAssertEqual(q.decide(subject("myDir", directory: true)), .init(list: true, traverse: true))
        XCTAssertEqual(q.decide(subject("yourDir", directory: true)),
                       .init(list: false, traverse: false))
        XCTAssertEqual(q.decide(subject("yourDir.txt", directory: true)),
                       .init(list: false, traverse: false), "file keeps the folder out")
        XCTAssertEqual(q.decide(subject("a.txt")), .init(list: true, traverse: false))
        // Without `file`, a folder named like a text file is walked into.
        let loose = query("(directory and name = \"myDir\") or name = \"*.txt\"")
        XCTAssertEqual(loose.decide(subject("yourDir.txt", directory: true)),
                       .init(list: true, traverse: true))
    }

    func testTraversedAndListed() {
        let walked = query("directory traversed or (file and name = \"*.txt\")")
        XCTAssertEqual(walked.decide(subject("src", directory: true)),
                       .init(list: false, traverse: true))
        let listed = query("directory listed or file")
        XCTAssertEqual(listed.decide(subject("src", directory: true)),
                       .init(list: true, traverse: false))
        XCTAssertEqual(listed.decide(subject("a")), .init(list: true, traverse: false))
    }

    func testValuesIgnoreCase() {
        XCTAssertTrue(query("name = \"*.TXT\"").decide(subject("a.txt")).list)
        XCTAssertTrue(query("name ~ /^readme/i").decide(subject("README.md")).list)
        XCTAssertFalse(query("name ~ /^readme/").decide(subject("README.md")).list,
                       "a regular expression minds case unless told")
        XCTAssertTrue(query("owner = \"PETER\"").decide(subject("a")).list)
        XCTAssertFalse(query("name != \"*.txt\"").decide(subject("a.txt")).list)
    }

    func testSizeIsAboutFiles() {
        let q = query("directory or size >= 1KiB")
        XCTAssertTrue(q.decide(subject("big", size: 1024)).list)
        XCTAssertFalse(q.decide(subject("small", size: 1023)).list)
        XCTAssertTrue(q.decide(subject("d", directory: true)).list)
    }

    // MARK: - Texts, regular expressions, commas

    func testABackslashInQuotesIsItself() {
        guard case .primitive(.name(.equals(let value, _)))? = query(#"name = "a\b""#).expression
        else { return XCTFail("a name") }
        XCTAssertEqual(value, #"a\b"#)
    }

    func testRegularExpressionsBetweenSlashes() {
        let q = query(#"name ~ /.*-\d\d.pdf/"#)
        XCTAssertTrue(q.decide(subject("invoice-2025-08.pdf")).list)
        XCTAssertFalse(q.decide(subject("invoice-2025-08-1.pdf")).list)
        XCTAssertTrue(query(#"name ~ /a\/b/"#).decide(subject("a/b")).list,
                      "a slash escaped inside")
        XCTAssertTrue(query("name ~ /^IMG/i").decide(subject("img_1.jpg")).list)
        XCTAssertTrue(query("name !~ /^IMG/").decide(subject("img_1.jpg")).list)
    }

    func testACommaIsOr() {
        let q = query("directory traversed, name = \"*.txt\"")
        guard case .or(.primitive(.directory(.traversed)), .primitive(.name))? = q.expression
        else { return XCTFail("\(String(describing: q.expression))") }
        guard case .or(_, .and)? = query("directory traversed, file and size > 1").expression
        else { return XCTFail("AND binds tighter than a comma") }
    }

    // MARK: - What cannot be meant

    private func warnings(_ text: String) -> [String] {
        query(text).warnings.map(\.message)
    }

    func testNothingListedIsWarned() {
        XCTAssertEqual(warnings("directory traverse").count, 1)
        XCTAssertTrue(warnings("directory traverse")[0].hasPrefix("This lists nothing"))
    }

    func testAnAndThatCannotHold() {
        let text = "name = \"a\" or directory traversed and file"
        let found = query(text).warnings
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].message.hasPrefix("Never true"))
        XCTAssertEqual(found[0].range, (text as NSString).range(of: "directory traversed and file"))
        XCTAssertTrue(warnings("directory and size > 1KB")[0].hasPrefix("Never true"),
                      "a folder has no size")
    }

    func testNothingWalkedIntoIsWarned() {
        XCTAssertTrue(warnings("file and name = \"*.txt\"").first?
            .hasPrefix("No folder is walked into") == true)
    }

    func testSensibleExpressionsAreNotWarned() {
        for text in ["", "name = \"*.txt\"", "directory traversed, name = \"*.txt\"",
                     "(directory and name = \"myDir\") or (file and name = \"*.txt\")",
                     "directory or size > 1", "contains \"x\""] {
            XCTAssertEqual(warnings(text), [], text)
        }
    }

    /// The examples the agent is given in AGENTS.md.
    func testTheAgentsExamplesParseCleanly() {
        for text in [
            #"directory traversed, file and name ~ /\.(jpe?g|png|gif|heic|heif|tiff?|webp|bmp|dng|cr2|nef|arw)$/i"#,
            #"directory traversed, file and access = "***r**r**" and name ~ /\.(jpe?g|png|gif|heic|tiff?|webp)$/i and name != "*a*""#,
            "directory traversed, file and size > 100MB and modified >= 2026-01-01",
            #"directory traversed, file and xattr("com.apple.quarantine")"#,
            #"(directory and name = "src") or (file and name = "*.swift")"#,
            "image",
            #"image and access = "***r**r**" and name != "*a*""#,
            "(image or video) and located",
            #"image and taken between [2025-06, 2025-08] and city = "Budapest" and not camera = "*iPhone*""#,
            "video and near(40.7580, -73.9855, 3mi)",
            #"name = "*.jpg" and not format = "jpeg""#,
        ] {
            XCTAssertEqual(warnings(text), [], text)
        }
        let q = query(#"directory traversed, file and access = "***r**r**" and name ~ /\.(jpe?g|png)$/i and name != "*a*""#)
        XCTAssertTrue(q.decide(subject("IMG_1.JPG", mode: 0o644)).list)
        XCTAssertFalse(q.decide(subject("cat.jpg", mode: 0o644)).list, "an a")
        XCTAssertFalse(q.decide(subject("IMG_1.jpg", mode: 0o640)).list, "others cannot read")
    }

    // MARK: - Constants, comments, saved expressions

    func testTrueAndFalse() {
        XCTAssertTrue(query("true").decide(subject("a")).list)
        XCTAssertFalse(query("false").decide(subject("a")).list)
        XCTAssertTrue(query("false and name = \"x\" or name = \"a\"").decide(subject("a")).list)
        XCTAssertEqual(warnings("false and (name = \"a\" and name = \"b\")").count, 1,
                       "false switches a part off without a warning of its own")
        XCTAssertEqual(warnings("false"), [], "on purpose")
    }

    func testCommentsAreNothing() {
        let q = query("name = \"a\" /* or name = \"b\" */ and /* a\nsecond line */ size >= 0")
        XCTAssertTrue(q.decide(subject("a")).list)
        XCTAssertFalse(q.decide(subject("b")).list)
        XCTAssertNotNil(problem("name = \"a\" /* not closed"))
        XCTAssertEqual(problem("/* x"), FlatQuery.Problem(message: problem("/* x")!.message,
                                                         range: NSRange(location: 0, length: 2)))
    }

    private func saved(_ text: String, _ names: [String: String]) -> FlatQuery? {
        try? FlatQuery.parse(text, saved: names).get()
    }

    func testASavedExpressionStandsInParentheses() throws {
        let names = ["images": #"name ~ /\.(jpe?g|png)$/i or name = "*.gif""#]
        let q = try XCTUnwrap(saved("Images and size > 1KB", names))
        XCTAssertTrue(q.decide(subject("a.png", size: 2000)).list)
        XCTAssertFalse(q.decide(subject("a.gif", size: 10)).list,
                       "(a or b) and c, not a or (b and c)")
        XCTAssertFalse(q.namesKinds)
        let kinds = try XCTUnwrap(saved("walk, file and images",
                                        ["walk": "directory traversed",
                                         "images": "name = \"*.png\""]))
        XCTAssertTrue(kinds.namesKinds, "the kinds a saved expression names count")
    }

    func testABrokenOrSelfUsingSavedExpressionIsAProblem() {
        guard case .failure(let loop) = FlatQuery.parse("aa", saved: ["aa": "bb", "bb": "aa"]) else {
            return XCTFail("a loop")
        }
        XCTAssertTrue(loop.message.contains("uses itself"), loop.message)
        guard case .failure(let broken) = FlatQuery.parse("x and file",
                                                          saved: ["x": "size >"]) else {
            return XCTFail("broken")
        }
        XCTAssertEqual(broken.range, NSRange(location: 0, length: 1), "at the name")
        XCTAssertNotNil(problem("size"), "a keyword is never a saved name")
    }

    func testSavedNamesAreOffered() {
        XCTAssertTrue(FlatQuery.expected(after: "", saved: ["images"]).contains("images"))
        XCTAssertTrue(FlatQuery.expected(after: "file and ", saved: ["images"]).contains("images"))
        XCTAssertFalse(FlatQuery.expected(after: "size ", saved: ["images"]).contains("images"))
    }

    // MARK: - Contradictions

    func testTheRequestsAccessContradiction() throws {
        let text = #"directory traversed, file and access = "***r**r**" and name ~ /\.(jpe?g|png|gif|heic|heif|tiff?|webp|bmp|dng|cr2|nef|arw|svg)$/i and name != "*a*" and access = "***-*****""#
        let found = query(text).warnings
        XCTAssertEqual(found.count, 1, "\(found.map(\.message))")
        XCTAssertTrue(found[0].message.contains("group\u{2019}s read bit"), found[0].message)
        let ns = text as NSString
        XCTAssertEqual(found[0].range.location, ns.range(of: "access = \"***r").location)
        XCTAssertEqual(NSMaxRange(found[0].range), NSMaxRange(ns.range(of: "\"***-*****\"")))
    }

    func testContradictionsOfOneAnd() {
        let never = [
            "size > 10MB and size < 1MB",
            "size = 5 and size != 5",
            "modified > 2026-02-01 and modified < 2026-01-01",
            "modified = 2026-01-31 and not modified = 2026-01-31",
            "name = \"a.txt\" and name = \"b.txt\"",
            "name = \"a.txt\" and name = \"*.jpg\"",
            "name = \"cat.jpg\" and name != \"*a*\"",
            "name = \"cat.jpg\" and name ~ /^dog/",
            "name = \"*.jpg\" and name = \"*.png\"",
            "name = \"a\" and not name = \"a\"",
            "owner = \"peter\" and owner = \"root\"",
            "access = \"r********\" and access != \"r********\"",
            "not xattr(\"x\") and xattr(\"x\") = \"y\"",
            "contains \"x\" and not contains \"x\"",
        ]
        for text in never {
            XCTAssertTrue(warnings(text).first?.hasPrefix("Never true") == true,
                          "\(text): \(warnings(text))")
        }
        let possible = [
            "size > 1MB and size < 10MB",
            "name = \"*.tar.gz\" and name = \"*.gz\"",
            "name = \"cat.jpg\" and name ~ /^CAT/i",
            "access = \"r********\" and access = \"*w*******\"",
            "modified >= 2026-01-01 and modified < 2026-02-01",
        ]
        for text in possible {
            XCTAssertEqual(warnings(text), [], text)
        }
    }

    // MARK: - The field's menu

    @MainActor
    func testOnlyTheExpressionsOwnItemsStayInTheMenu() {
        let menu = NSMenu()
        for title in ["Save Expression", "-", "Cut", "Copy", "Paste", "Select All"] {
            let item = title == "-" ? NSMenuItem.separator() : NSMenuItem(title: title, action: nil,
                                                                         keyEquivalent: "")
            item.tag = FlatExpressionField.Editor.ownItem
            menu.addItem(item)
        }
        // What the system appends when the menu opens.
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "AutoFill", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "OpenPGP: Insert My Fingerprint", action: nil,
                                keyEquivalent: ""))
        FlatExpressionField.Editor.keepOwn(menu)
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "-" : $0.title },
                       ["Save Expression", "-", "Cut", "Copy", "Paste", "Select All"])
    }

    // MARK: - Where a date goes

    func testADateSlotIsAfterADateComparison() {
        let text = "file and modified >= 2026-01-31T14:30 and created < "
        let ns = text as NSString
        let written = ns.range(of: "2026-01-31T14:30")
        XCTAssertEqual(FlatQuery.dateSlot(in: text, at: written.location + 3)?.range, written,
                       "the whole date, from inside it")
        XCTAssertEqual(FlatQuery.dateSlot(in: text, at: NSMaxRange(written))?.written,
                       "2026-01-31T14:30")
        XCTAssertEqual(FlatQuery.dateSlot(in: text, at: ns.length)?.range,
                       NSRange(location: ns.length, length: 0), "none yet: where it goes")
        XCTAssertNil(FlatQuery.dateSlot(in: text, at: 2))
        XCTAssertNil(FlatQuery.dateSlot(in: "size > 10", at: 9), "a size, not a date")
        XCTAssertNotNil(FlatQuery.dateSlot(in: "MODIFIED != ", at: 12))
    }

    func testADateIsWrittenToItsPrecision() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Budapest"))
        let moment = try XCTUnwrap(FlatQuery.moment("2026-03-05T07:09", zone: zone))
        XCTAssertEqual(FlatQuery.written(moment.start, withTime: true, zone: zone),
                       "2026-03-05T07:09")
        XCTAssertEqual(FlatQuery.written(moment.start, withTime: false, zone: zone), "2026-03-05")
    }

    // MARK: - Typing an access pattern

    func testTheAccessPatternIsFoundAroundTheCaret() {
        let text = "file and access = \"*********\""
        let places = FlatQuery.accessPlaces(in: text, at: 19)
        XCTAssertEqual(places, NSRange(location: 19, length: 9))
        XCTAssertEqual(FlatQuery.accessPlaces(in: text, at: 28), places, "after the last place")
        XCTAssertNil(FlatQuery.accessPlaces(in: text, at: 3))
        XCTAssertNil(FlatQuery.accessPlaces(in: "access = \"rw\"", at: 11), "not nine yet")
    }

    func testTypingInAnAccessPatternOverwrites() {
        let any = FlatQuery.anyAccess
        // r, w, x set the caret's three, and the caret stays.
        XCTAssertEqual(FlatQuery.typeAccess("w", in: any, at: 4)?.0, "****w****")
        XCTAssertEqual(FlatQuery.typeAccess("w", in: any, at: 4)?.1, 4)
        XCTAssertEqual(FlatQuery.typeAccess("R", in: any, at: 7, shift: true)?.0, "******-**")
        XCTAssertEqual(FlatQuery.typeAccess("r", in: "r********", at: 1, option: true)?.0,
                       "-********")
        // - + * and space are the place itself, and move on.
        XCTAssertEqual(FlatQuery.typeAccess("-", in: any, at: 0)?.0, "-********")
        XCTAssertEqual(FlatQuery.typeAccess("-", in: any, at: 0)?.1, 1)
        XCTAssertEqual(FlatQuery.typeAccess("+", in: any, at: 5)?.0, "*****x***")
        XCTAssertEqual(FlatQuery.typeAccess(" ", in: "r********", at: 0)?.0, "-********")
        XCTAssertEqual(FlatQuery.typeAccess(" ", in: "-********", at: 0)?.0, "*********")
        XCTAssertEqual(FlatQuery.typeAccess(" ", in: any, at: 0)?.0, "r********")
        XCTAssertEqual(FlatQuery.typeAccess("*", in: "rwxrwxrwx", at: 8)?.0, "rwxrwxrw*")
        // s for the user and group, t for others.
        XCTAssertEqual(FlatQuery.typeAccess("s", in: any, at: 3)?.0, "*****s***")
        XCTAssertNil(FlatQuery.typeAccess("s", in: any, at: 6))
        XCTAssertEqual(FlatQuery.typeAccess("t", in: any, at: 6)?.0, "********t")
        XCTAssertNil(FlatQuery.typeAccess("q", in: any, at: 0))
        XCTAssertNil(FlatQuery.typeAccess("-", in: any, at: 9), "past the last place")
        // Whatever it makes, parses.
        XCTAssertNoThrow(try FlatQuery.accessMask("*****s**t", at: NSRange()))
    }

    // MARK: - Completion and hints

    func testCompletionsFollowWhatCameBefore() {
        XCTAssertTrue(FlatQuery.completions(in: "", at: 0).words.contains("size"))
        XCTAssertEqual(FlatQuery.completions(in: "si", at: 2).words, ["size"])
        XCTAssertEqual(FlatQuery.completions(in: "si", at: 2).range, NSRange(location: 0, length: 2))
        XCTAssertTrue(FlatQuery.completions(in: "size ", at: 5).words.contains(">="))
        XCTAssertTrue(FlatQuery.completions(in: "size > 10 ", at: 10).words.contains("MiB"))
        XCTAssertEqual(FlatQuery.completions(in: "directory t", at: 11).words, ["traversed"])
        XCTAssertTrue(FlatQuery.completions(in: "name = \"a\" ", at: 11).words.contains("and"))
        XCTAssertTrue(FlatQuery.completions(in: "name = \"a\" and ", at: 15).words
            .contains("modified"))
        XCTAssertEqual(FlatQuery.completions(in: "access = ", at: 9).words, ["\"*********\""])
        XCTAssertEqual(FlatQuery.completions(in: "name ~ ", at: 7).words, ["/"])
        XCTAssertTrue(FlatQuery.completions(in: "name ~ /a/i ", at: 12).words.contains(","))
    }

    func testTheHintIsForTheWordAtTheCaret() {
        let text = "name = \"a\" and size > 1"
        XCTAssertTrue(FlatQuery.hint(in: text, at: 2)?.hasPrefix("name") == true)
        XCTAssertTrue(FlatQuery.hint(in: text, at: (text as NSString).length)?
            .hasPrefix("size") == true)
    }
}

/// Walking a real tree, and the pane showing it.
@MainActor
final class FlatViewTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychFlat-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        for folder in ["myDir/inner", "yourDir", "yourDir.txt"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder),
                                   withIntermediateDirectories: true)
        }
        for (path, text) in [("top.txt", "hello"), ("top.md", "Needle here"),
                             ("myDir/a.txt", "x"), ("myDir/inner/deep.txt", "line one\nTODO: it"),
                             ("yourDir/b.txt", "y"), ("yourDir.txt/c.txt", "z")] {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
        try fm.createSymbolicLink(at: root.appendingPathComponent("loop"),
                                  withDestinationURL: root)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: root)
    }

    private func walk(_ text: String) -> [String] {
        let query = try! FlatQuery.parse(text).get()
        var found: [FileItem] = []
        FlatScanner.walk(root: root, query: query, showHidden: false) { batch, _, _ in
            found += batch
        }
        return found.map(\.relativePath).sorted()
    }

    func testEverything() {
        XCTAssertEqual(walk(""), ["loop", "myDir", "myDir/a.txt", "myDir/inner",
                                  "myDir/inner/deep.txt", "top.md", "top.txt", "yourDir",
                                  "yourDir.txt", "yourDir.txt/c.txt", "yourDir/b.txt"],
                       "a link to a folder is listed, never walked into")
    }

    func testTheRequestsExample() {
        XCTAssertEqual(walk("(directory and name = \"myDir\") or (file and name = \"*.txt\")"),
                       ["myDir", "myDir/a.txt", "top.txt"],
                       "only myDir is walked, and inner is not named myDir")
        XCTAssertEqual(walk("directory traversed or (file and name = \"*.txt\")"),
                       ["myDir/a.txt", "myDir/inner/deep.txt", "top.txt", "yourDir.txt/c.txt",
                        "yourDir/b.txt"])
    }

    func testContents() {
        // About files only: the folders -- a link to one too -- are listed.
        XCTAssertEqual(walk("contains \"needle\""),
                       ["loop", "myDir", "myDir/inner", "top.md", "yourDir", "yourDir.txt"])
        // With `file` in it, folders are asked too: walked only when it says so.
        XCTAssertEqual(walk("file and contains ~ /^todo:/i"), [])
        XCTAssertEqual(walk("directory traversed or (file and contains ~ /^todo:/i)"),
                       ["myDir/inner/deep.txt"])
        XCTAssertEqual(walk("directory traversed, file and content ~ /^todo:/"), [],
                       "TODO is not todo")
        XCTAssertEqual(walk("directory traversed, file and contains /^TODO:/"),
                       ["myDir/inner/deep.txt"])
    }

    func testBinaryFilesAreNotSearched() throws {
        var bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])
        bytes.append(Data("needle".utf8))
        try bytes.write(to: root.appendingPathComponent("image.png"))
        XCTAssertEqual(walk("directory traversed, file and contains \"needle\""), ["top.md"])
        XCTAssertEqual(walk("directory traversed, file and contains /needle/i"), ["top.md"])
        XCTAssertEqual(walk("directory traversed, file and (contains \"needle\" or name = "
                            + "\"*.png\")"), ["image.png", "top.md"],
                       "the rest of the expression still counts for a binary file")
    }

    func testExtendedAttributes() throws {
        let url = root.appendingPathComponent("top.md")
        XCTAssertEqual(setxattr(url.path, "dev.verhas.test", "Blue", 4, 0, 0), 0)
        XCTAssertEqual(walk("file and xattr(\"DEV.verhas.test\")"), ["top.md"])
        XCTAssertEqual(walk("file and xattr(\"dev.verhas.test\") = \"blue\""), ["top.md"])
        XCTAssertEqual(walk("file and xattr(\"dev.verhas.test\") ~ /^bl/i"), ["top.md"])
        XCTAssertEqual(walk("file and xattr(\"dev.verhas.test\") = \"red\""), [])
    }

    func testAStoppedWalkStops() {
        let query = try! FlatQuery.parse("").get()
        let cancelled = CancellationFlag()
        cancelled.cancel()
        var found = 0
        FlatScanner.walk(root: root, query: query, showHidden: false, cancelled: cancelled) {
            batch, _, _ in found += batch.count
        }
        XCTAssertEqual(found, 0)
    }

    // MARK: - The pane

    private func settle(_ pane: PaneModel) async {
        for _ in 0..<200 {
            if pane.flatProgress == nil, !pane.isLoading { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("the walk did not finish")
    }

    func testThePaneGoesFlatAndBack() async {
        let pane = PaneModel(directory: root)
        pane.flatDraft = "directory traversed or (file and name = \"*.txt\")"
        pane.toggleFlat()
        XCTAssertTrue(pane.isFlat)
        await settle(pane)
        XCTAssertEqual(pane.rows.map(\.relativePath).sorted(),
                       ["myDir/a.txt", "myDir/inner/deep.txt", "top.txt", "yourDir.txt/c.txt",
                        "yourDir/b.txt"])
        XCTAssertFalse(pane.hasFilter, "the ordinary filter is not used in a flat view")

        // Opening a folder from it leaves it; Back returns at once, from the
        // remembered walk, with the folder selected.
        pane.navigate(to: root.appendingPathComponent("myDir"))
        XCTAssertFalse(pane.isFlat)
        pane.goBack()
        XCTAssertTrue(pane.isFlat)
        XCTAssertNil(pane.flatProgress, "remembered, not walked again")
        XCTAssertEqual(pane.rows.count, 5)

        pane.toggleFlat()
        XCTAssertFalse(pane.isFlat)
        XCTAssertEqual(pane.directory.path, root.path)
    }

    func testRunningAChangedExpressionIsANewPlace() async {
        let pane = PaneModel(directory: root)
        pane.toggleFlat()
        await settle(pane)
        XCTAssertEqual(pane.rows.count, 11)
        pane.flatDraft = "name = \"*.md\""
        pane.runFlat()
        await settle(pane)
        XCTAssertEqual(pane.rows.filter { !$0.isDirectory }.map(\.name), ["top.md"])
        pane.goBack()
        XCTAssertEqual(pane.flat?.expression, "")
        XCTAssertEqual(pane.rows.count, 11)
    }

    func testRefreshDropsWhatIsGoneAndAddsWhatWasMade() async throws {
        let pane = PaneModel(directory: root)
        pane.flatDraft = "directory traversed or file"
        pane.toggleFlat()
        await settle(pane)
        try fm.removeItem(at: root.appendingPathComponent("top.md"))
        let made = root.appendingPathComponent("myDir/new.txt")
        try Data().write(to: made)
        pane.pendingSelection = [made]
        await pane.reloadAndWait()
        XCTAssertFalse(pane.rows.contains { $0.name == "top.md" })
        XCTAssertEqual(pane.rows.first { $0.name == "new.txt" }?.folderPrefix, "myDir/")
        XCTAssertEqual(pane.selectedRows.map(\.name), ["new.txt"])
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("it did not happen")
    }

    func testARenamedRowStaysAndTheViewGoesStale() async throws {
        let pane = PaneModel(directory: root)
        pane.flatDraft = "directory traversed, name = \"*.txt\""
        pane.toggleFlat()
        await settle(pane)
        let before = pane.rows.count
        let old = root.appendingPathComponent("top.txt")
        let new = root.appendingPathComponent("top.text")
        try fm.moveItem(at: old, to: new)
        pane.refreshRows([], renamed: [(old, new)])
        await until { pane.rows.contains { $0.name == "top.text" } }
        XCTAssertEqual(pane.rows.count, before, "in place of the old name, not dropped")
        XCTAssertTrue(pane.flatStale)

        pane.runFlat()
        await settle(pane)
        XCTAssertFalse(pane.flatStale, "only running it again makes it fresh")
        XCTAssertFalse(pane.rows.contains { $0.name == "top.text" })
    }

    func testARenamedFolderTakesItsRowsAlong() async throws {
        let pane = PaneModel(directory: root)
        pane.flatDraft = "directory traversed, name = \"*.txt\""
        pane.toggleFlat()
        await settle(pane)
        let old = root.appendingPathComponent("myDir")
        let new = root.appendingPathComponent("ourDir")
        try fm.moveItem(at: old, to: new)
        pane.refreshRows([], renamed: [(old, new)])
        await until { pane.rows.contains { $0.relativePath == "ourDir/a.txt" } }
        XCTAssertTrue(pane.rows.contains { $0.relativePath == "ourDir/inner/deep.txt" })
        XCTAssertFalse(pane.rows.contains { $0.folderPrefix.hasPrefix("myDir") })
        XCTAssertFalse(pane.flatStale, "they still pass")
    }

    func testChangedPermissionsKeepTheRow() async throws {
        let pane = PaneModel(directory: root)
        pane.flatDraft = "directory traversed, file and access = \"rw-******\""
        pane.toggleFlat()
        await settle(pane)
        let url = root.appendingPathComponent("top.txt")
        XCTAssertTrue(pane.rows.contains { $0.relativePath == "top.txt" })
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        pane.refreshRows([url])
        await until {
            pane.rows.first { $0.relativePath == "top.txt" }.map { $0.mode & 0o777 } == 0o444
        }
        XCTAssertTrue(pane.flatStale)
        // A whole refresh keeps it too.
        await pane.reloadAndWait()
        XCTAssertTrue(pane.rows.contains { $0.relativePath == "top.txt" })
    }

    func testAnAgentNamesTheFolderAndTheExpression() async {
        let pane = PaneModel(directory: URL(fileURLWithPath: "/"))
        XCTAssertFalse(pane.showFlat(of: root, expression: "name ~ \"x\""), "does not parse")
        XCTAssertFalse(pane.isFlat)
        XCTAssertTrue(pane.showFlat(of: root, expression: "directory traversed, name = \"*.md\""))
        await settle(pane)
        XCTAssertEqual(pane.directory.path, root.path)
        XCTAssertEqual(pane.rows.map(\.relativePath), ["top.md"])
    }

    func testPathsCompareWithoutPrivate() {
        XCTAssertEqual(FlatScanner.canonicalPath(URL(fileURLWithPath: "/private/var/x/a")),
                       "/var/x/a")
        XCTAssertEqual(FlatScanner.canonicalPath(URL(fileURLWithPath: "/private/varnish")),
                       "/private/varnish")
    }

    func testRenameManyFollowsAFlatViewsRows() async throws {
        let pane = PaneModel(directory: root)
        pane.flatDraft = "directory traversed, name = \"*.txt\""
        pane.toggleFlat()
        await settle(pane)
        let a = root.appendingPathComponent("myDir/a.txt")
        let b = root.appendingPathComponent("myDir/a.text")
        try fm.moveItem(at: a, to: b)
        pane.refreshRows([], renamed: [(a, b)])
        await until { pane.rows.contains { $0.relativePath == "myDir/a.text" } }
        XCTAssertTrue(pane.flatStale)
    }

    func testAFlatPaneIsSavedAndComesBack() async {
        let pane = PaneModel(directory: root)
        pane.flatDraft = "directory traversed or file"
        pane.toggleFlat()
        await settle(pane)
        let state = pane.snapshot
        XCTAssertEqual(state.flatExpression, "directory traversed or file")

        let again = PaneModel(directory: URL(fileURLWithPath: "/"))
        again.restore(state)
        XCTAssertTrue(again.isFlat)
        again.reload()
        await settle(again)
        XCTAssertEqual(again.rows.count, 6)
    }
}
