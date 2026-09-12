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
