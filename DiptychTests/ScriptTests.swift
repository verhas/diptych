import XCTest
@testable import Diptych

/// Reading a script file, and deciding when it applies.
///
/// This is where the feature lives or dies: one person writes these and
/// another uses them, so a mistake in a header has to come back as a sentence
/// its author can act on rather than as a script that quietly never appears.
final class ScriptDefinitionTests: XCTestCase {

    private let folder = URL(fileURLWithPath: "/work")

    private func read(_ text: String, named name: String = "thing.sh")
        -> (ScriptDefinition?, [ScriptProblem]) {
        ScriptDefinition.read(folder.appendingPathComponent(name), contents: text)
    }

    private func file(_ name: String) -> ScriptTarget {
        ScriptTarget(url: folder.appendingPathComponent(name), kind: .file)
    }

    // MARK: - Reading the headers

    func testTheFirstLineIsTheShebangAndIsSkipped() throws {
        let (script, problems) = read("""
        #!/bin/sh
        # name: Do the thing
        # call: $0 $1
        echo hello
        """)

        XCTAssertEqual(problems, [])
        XCTAssertEqual(script?.name, "Do the thing")
    }

    func testTheNameFallsBackToTheFileName() throws {
        let (script, _) = read("#!/bin/sh\n# call: $0 $1\n", named: "resize-pictures.sh")

        XCTAssertEqual(script?.name, "resize-pictures")
    }

    func testTheBodyIsEverythingAfterTheHeaders() throws {
        let (script, _) = read("""
        #!/bin/sh
        # call: $0 $1
        echo one
        # this comment is part of the script, not a header
        echo two
        """)

        XCTAssertTrue(script?.contents.contains("part of the script") ?? false)
    }

    func testAMisspeltSettingIsReportedRatherThanIgnored() throws {
        // "extension" for "extensions" would otherwise do nothing at all and
        // say nothing about it, which is the failure this whole report exists
        // to prevent.
        let (script, problems) = read("#!/bin/sh\n# extension: txt\n# call: $0 $1\n")

        XCTAssertNil(script)
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].message.contains("extension"), problems[0].message)
        XCTAssertEqual(problems[0].line, 2, "and says which line")
    }

    func testAScriptWithNoCallIsRefused() throws {
        let (script, problems) = read("#!/bin/sh\n# name: Nameless\n")

        XCTAssertNil(script)
        XCTAssertTrue(problems.contains { $0.message.contains("call") })
    }

    // MARK: - How many items

    func testWithoutArgsItTakesExactlyOne() throws {
        let (script, _) = read("#!/bin/sh\n# call: $0 $1\n")

        XCTAssertTrue(script?.applies(to: [file("a.txt")]) ?? false)
        XCTAssertFalse(script?.applies(to: [file("a.txt"), file("b.txt")]) ?? true)
        XCTAssertFalse(script?.applies(to: []) ?? true)
    }

    func testARangeOfItems() throws {
        let (script, _) = read("#!/bin/sh\n# args: 1,3\n# call: $0 $@\n")

        XCTAssertTrue(script?.applies(to: [file("a")]) ?? false)
        XCTAssertTrue(script?.applies(to: [file("a"), file("b"), file("c")]) ?? false)
        XCTAssertFalse(script?.applies(to: (1...4).map { file("\($0)") }) ?? true)
    }

    func testTwoOrMore() throws {
        let (script, _) = read("#!/bin/sh\n# args: 2,\n# call: $0 $@\n")

        XCTAssertFalse(script?.applies(to: [file("a")]) ?? true)
        XCTAssertTrue(script?.applies(to: (1...50).map { file("\($0)") }) ?? false)
    }

    func testAMissingLowerBoundIsRefusedWithAdvice() throws {
        let (script, problems) = read("#!/bin/sh\n# args: ,7\n# call: $0 $1\n")

        XCTAssertNil(script)
        XCTAssertTrue(problems[0].message.contains("1,3"), problems[0].message)
    }

    func testNoItemsAtAllIsAllowed() throws {
        // For a script about the folder rather than a selection.
        let (script, problems) = read("#!/bin/sh\n# args: 0\n# call: $0\n")

        XCTAssertEqual(problems, [])
        XCTAssertEqual(script?.fewestItems, 0)
    }

    func testACallThatReachesPastTheLimitIsRefused() throws {
        // It would fail every time it ran, and only then.
        let (script, problems) = read("#!/bin/sh\n# args: 1,2\n# call: $0 $1 $3\n")

        XCTAssertNil(script)
        XCTAssertTrue(problems[0].message.contains("$3"), problems[0].message)
    }

    // MARK: - What it applies to

    func testExtensionsAreMatchedWhateverTheirCase() throws {
        let (script, _) = read("#!/bin/sh\n# extensions: txt,PNG\n# call: $0 $1\n")

        XCTAssertTrue(script?.applies(to: [file("notes.TXT")]) ?? false)
        XCTAssertTrue(script?.applies(to: [file("picture.png")]) ?? false)
        XCTAssertFalse(script?.applies(to: [file("thing.pdf")]) ?? true)
    }

    func testExtensionsApplyToFoldersToo() throws {
        // Unusual, but some people do it, and a script that says so means it.
        let (script, _) = read("""
        #!/bin/sh
        # extensions: bundle
        # apply-to: directory
        # call: $0 $1
        """)

        let bundle = ScriptTarget(url: folder.appendingPathComponent("thing.bundle"),
                                  kind: .directory)
        let plain = ScriptTarget(url: folder.appendingPathComponent("thing"), kind: .directory)
        XCTAssertTrue(script?.applies(to: [bundle]) ?? false)
        XCTAssertFalse(script?.applies(to: [plain]) ?? true)
    }

    func testTheKindIsChecked() throws {
        let (script, _) = read("#!/bin/sh\n# apply-to: directory\n# call: $0 $1\n")

        XCTAssertFalse(script?.applies(to: [file("a.txt")]) ?? true)
        XCTAssertTrue(script?.applies(
            to: [ScriptTarget(url: folder.appendingPathComponent("d"), kind: .directory)]) ?? false)
    }

    func testAnUnknownKindIsReported() throws {
        let (_, problems) = read("#!/bin/sh\n# apply-to: file, folder\n# call: $0 $1\n")

        XCTAssertTrue(problems.contains { $0.message.contains("folder") })
    }

    func testEveryItemHasToQualify() throws {
        // Three items where one is wrong is not two-thirds applicable; it is a
        // script about to do something unintended to one of them.
        let (script, _) = read("#!/bin/sh\n# extensions: txt\n# args: 1,5\n# call: $0 $@\n")

        XCTAssertFalse(script?.applies(to: [file("a.txt"), file("b.png")]) ?? true)
    }

    // MARK: - Where it applies

    func testOnlyInLimitsItToOneFolder() throws {
        let (script, _) = read("#!/bin/sh\n# only-in: /work/scripts\n# call: $0 $1\n")

        XCTAssertTrue(script?.isInScope(URL(fileURLWithPath: "/work/scripts/a.sh")) ?? false)
        XCTAssertFalse(script?.isInScope(URL(fileURLWithPath: "/work/a.sh")) ?? true)
        XCTAssertFalse(script?.isInScope(URL(fileURLWithPath: "/work/scripts/deep/a.sh")) ?? true,
                       "in, not under")
    }

    func testOnlyUnderReachesDownwards() throws {
        let (script, _) = read("#!/bin/sh\n# only-under: /work\n# call: $0 $1\n")

        XCTAssertTrue(script?.isInScope(URL(fileURLWithPath: "/work/a.sh")) ?? false)
        XCTAssertTrue(script?.isInScope(URL(fileURLWithPath: "/work/deep/down/a.sh")) ?? false)
        XCTAssertFalse(script?.isInScope(URL(fileURLWithPath: "/elsewhere/a.sh")) ?? true)
        XCTAssertFalse(script?.isInScope(URL(fileURLWithPath: "/workshop/a.sh")) ?? true,
                       "a name that merely starts the same is a different folder")
    }

    func testWithoutEitherItAppliesAnywhere() throws {
        let (script, _) = read("#!/bin/sh\n# call: $0 $1\n")

        XCTAssertTrue(script?.isInScope(URL(fileURLWithPath: "/anywhere/at/all")) ?? false)
    }

    // MARK: - Building the command

    func testEachPlaceholderBecomesExactlyOneArgument() throws {
        // The safety of the whole feature in one test: no shell, so a space in
        // a name cannot become two arguments.
        let (script, _) = read("#!/bin/sh\n# call: /bin/ls -l@ $1\n")
        let awkward = ScriptTarget(url: folder.appendingPathComponent("my notes (draft).txt"),
                                   kind: .file)

        let command = script?.command(for: [awkward], script: folder.appendingPathComponent("s"))

        XCTAssertEqual(command, ["/bin/ls", "-l@", "/work/my notes (draft).txt"])
    }

    func testEverythingBecomesOneArgumentEach() throws {
        let (script, _) = read("#!/bin/sh\n# args: 1,9\n# call: $0 $@\n")

        let command = script?.command(for: [file("a b.txt"), file("c.txt")],
                                      script: folder.appendingPathComponent("s.sh"))

        XCTAssertEqual(command, ["/work/s.sh", "/work/a b.txt", "/work/c.txt"])
    }

    func testTheOldShellStarIsRefusedWithAdvice() throws {
        // It joins the paths into one argument, which is the one construct
        // that brings the space problem back.
        let (script, problems) = read("#!/bin/sh\n# args: 1,9\n# call: $0 $*\n")

        XCTAssertNil(script)
        XCTAssertTrue(problems[0].message.contains("$@"), problems[0].message)
    }

    func testDollarZeroIsTheScript() throws {
        let (script, _) = read("#!/bin/sh\n# call: $0 $1\n")

        let command = script?.command(for: [file("a.txt")],
                                      script: URL(fileURLWithPath: "/tmp/copy.sh"))

        XCTAssertEqual(command?.first, "/tmp/copy.sh")
    }
}

/// Agreeing to a script, and noticing when it changes.
@MainActor
final class ScriptApprovalTests: XCTestCase {

    func testTheFingerprintFollowsTheContents() {
        let one = ScriptCatalogue.fingerprint(of: "#!/bin/sh\necho hello\n")
        let same = ScriptCatalogue.fingerprint(of: "#!/bin/sh\necho hello\n")
        let changed = ScriptCatalogue.fingerprint(of: "#!/bin/sh\necho goodbye\n")

        XCTAssertEqual(one, same)
        XCTAssertNotEqual(one, changed,
                          "a script that changes has to be agreed to again")
    }
}

/// Reading the folder, and refusing what should not be run.
///
/// The refusals are the security of the feature, so they are tested against
/// real files with real permissions rather than against a description of them.
@MainActor
final class ScriptCatalogueTests: XCTestCase {

    private var folder: URL!
    private let manager = FileManager.default
    private var developerMode = false

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychScripts-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        developerMode = ConfigStore.shared.configuration.scriptsDeveloperMode
        ConfigStore.shared.configuration.scriptsDeveloperMode = false
    }

    override func tearDownWithError() throws {
        ConfigStore.shared.configuration.scriptsDeveloperMode = developerMode
        try? manager.removeItem(at: folder)
    }

    @discardableResult
    private func install(_ name: String, _ text: String, mode: Int = 0o444) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    private func load() {
        ScriptCatalogue.shared.reload(from: folder, checkingTheSetting: false)
    }

    private let good = "#!/bin/sh\n# name: Good one\n# call: $0 $1\necho hello\n"

    func testAReadOnlyScriptIsFound() throws {
        try install("good.sh", good)

        load()

        XCTAssertEqual(ScriptCatalogue.shared.scripts.map(\.name), ["Good one"])
        XCTAssertEqual(ScriptCatalogue.shared.problems, [])
    }

    func testAWritableScriptIsRefused() throws {
        // A download lands as rw-r--r--, so requiring no write bit makes
        // installing a script an act rather than an accident.
        try install("writable.sh", good, mode: 0o644)

        load()

        XCTAssertTrue(ScriptCatalogue.shared.scripts.isEmpty)
        XCTAssertTrue(ScriptCatalogue.shared.problems.first?.message.contains("read-only")
                      ?? false, "\(ScriptCatalogue.shared.problems)")
    }

    func testDeveloperModeAllowsAWritableScript() throws {
        try install("writable.sh", good, mode: 0o644)
        ConfigStore.shared.configuration.scriptsDeveloperMode = true

        load()

        XCTAssertEqual(ScriptCatalogue.shared.scripts.count, 1,
                       "for whoever is writing them rather than running them")
    }

    func testAQuarantinedScriptIsRefused() throws {
        // The attack this feature invents: a script that arrived by post.
        // Marked before it is made read-only: setting an attribute needs write
        // permission, which is exactly what the next line takes away.
        let url = try install("downloaded.sh", good, mode: 0o644)
        let value = "0081;00000000;Safari;"
        XCTAssertEqual(setxattr(url.path, "com.apple.quarantine", value, value.utf8.count, 0, 0), 0)
        try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)

        load()

        XCTAssertTrue(ScriptCatalogue.shared.scripts.isEmpty)
        XCTAssertTrue(ScriptCatalogue.shared.problems.first?.message.contains("outside your Mac")
                      ?? false, "\(ScriptCatalogue.shared.problems)")
    }

    func testABrokenScriptIsReportedAndNotListed() throws {
        try install("broken.sh", "#!/bin/sh\n# args: ,7\n# call: $0 $1\n")
        try install("good.sh", good)

        load()

        XCTAssertEqual(ScriptCatalogue.shared.scripts.map(\.name), ["Good one"],
                       "the good one still works")
        XCTAssertEqual(ScriptCatalogue.shared.problems.count, 1)
        XCTAssertEqual(ScriptCatalogue.shared.problems.first?.file, "broken.sh")
    }

    func testOnlyTheApplicableOnesAreOffered() throws {
        try install("pictures.sh", "#!/bin/sh\n# name: Pictures\n# extensions: png\n# call: $0 $1\n")
        try install("anything.sh", "#!/bin/sh\n# name: Anything\n# call: $0 $1\n")
        load()

        let text = [ScriptTarget(url: folder.appendingPathComponent("a.txt"), kind: .file)]
        let picture = [ScriptTarget(url: folder.appendingPathComponent("a.png"), kind: .file)]

        XCTAssertEqual(ScriptCatalogue.shared.applicable(to: text, in: folder,
                                                         checkingTheSetting: false)
                        .map(\.name), ["Anything"])
        XCTAssertEqual(Set(ScriptCatalogue.shared.applicable(to: picture, in: folder,
                                                             checkingTheSetting: false)
                        .map(\.name)), ["Anything", "Pictures"])
    }

    func testAScriptThatTakesNoItemsIsOfferedWithNothingSelected() throws {
        try install("here.sh", "#!/bin/sh\n# name: Here\n# args: 0\n# call: $0\n")
        try install("one.sh", "#!/bin/sh\n# name: One\n# call: $0 $1\n")
        load()

        let offered = ScriptCatalogue.shared.applicable(to: [], in: folder,
                                                        checkingTheSetting: false)

        XCTAssertEqual(offered.map(\.name), ["Here"])
    }
}

/// Actually running one.
@MainActor
final class ScriptRunTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychRun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func run(_ text: String, on targets: [ScriptTarget] = []) async throws -> ScriptRun {
        let url = folder.appendingPathComponent("script.sh")
        try Data(text.utf8).write(to: url)
        let (script, problems) = ScriptDefinition.read(url, contents: text)
        XCTAssertEqual(problems, [])
        let run = ScriptRun(script: try XCTUnwrap(script), targets: targets,
                            left: folder, right: folder, active: folder, other: folder)
        for _ in 0..<200 where run.isRunning {
            try await Task.sleep(for: .milliseconds(25))
        }
        return run
    }

    func testTheOutputAndTheExitStatusComeBack() async throws {
        let run = try await run("#!/bin/sh\n# args: 0\n# call: $0\necho hello\n")

        XCTAssertFalse(run.isRunning)
        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.output.contains("hello"), run.output)
    }

    func testAFailureIsReportedAsOneRatherThanLookingLikeSuccess() async throws {
        let run = try await run("#!/bin/sh\n# args: 0\n# call: $0\necho oh dear\nexit 3\n")

        XCTAssertEqual(run.status, 3)
        XCTAssertTrue(run.output.contains("oh dear"), "and what it said is still there")
    }

    func testWhatItPrintsToStandardErrorIsShownToo() async throws {
        let run = try await run("#!/bin/sh\n# args: 0\n# call: $0\necho trouble >&2\n")

        XCTAssertTrue(run.output.contains("trouble"), run.output)
    }

    func testThePanesAndTheScriptArriveAsEnvironmentVariables() async throws {
        let run = try await run("""
        #!/bin/sh
        # args: 0
        # call: $0
        echo "active=$DIPTYCH_ACTIVE"
        echo "script=$DIPTYCH_SCRIPT"
        """)

        XCTAssertTrue(run.output.contains("active=\(folder.path)"), run.output)
        XCTAssertTrue(run.output.contains("script=\(folder.appendingPathComponent("script.sh").path)"),
                      "the original, not the copy that ran: \(run.output)")
    }

    func testAnAwkwardFileNameArrivesInOnePiece() async throws {
        // The whole no-shell design, proven end to end.
        let awkward = folder.appendingPathComponent("my notes (draft).txt")
        try Data("x".utf8).write(to: awkward)

        let run = try await run("#!/bin/sh\n# call: $0 $1\necho \"[$1]\"\n",
                                on: [ScriptTarget(url: awkward, kind: .file)])

        XCTAssertTrue(run.output.contains("[\(awkward.path)]"), run.output)
    }
}
