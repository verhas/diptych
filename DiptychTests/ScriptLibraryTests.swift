import XCTest
@testable import Diptych

/// The scripts that come with Diptych, and installing them: File ▸ Get
/// Scripts….
@MainActor
final class ScriptLibraryTests: XCTestCase {

    private var bundled: URL!
    private var target: URL!
    private let manager = FileManager.default

    /// The scripts as they are in the repository, which is what the
    /// application carries.
    private static let repositoryScripts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Diptych/Scripts")

    override func setUp() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychLibrary-\(UUID().uuidString)")
        bundled = root.appendingPathComponent("bundle")
        target = root.appendingPathComponent("scripts")
        try manager.createDirectory(at: bundled, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        let root = bundled.deletingLastPathComponent()
        // Installed scripts are read-only; the folder can still be removed.
        try? manager.removeItem(at: root)
    }

    private func bundle(_ name: String, version: Int, body: String = "echo hello") throws {
        let text = "#!/bin/sh\n# name: \(name)\n# description: Says hello.\n# call: $0 $1\n"
            + "# source: diptych\n# version: \(version)\n\(body)\n"
        try Data(text.utf8).write(to: bundled.appendingPathComponent("\(name).sh"))
    }

    private func put(_ name: String, _ text: String) throws {
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        let url = target.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try manager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
    }

    private var trashed: [String] = []
    private func install(_ scripts: [ScriptLibrary.Script]) -> ScriptLibrary.Outcome {
        ScriptLibrary.install(scripts, into: target) { [self] url in
            trashed.append(url.lastPathComponent)
            try manager.removeItem(at: url)
        }
    }

    // MARK: - What comes with Diptych

    func testEveryScriptThatComesWithDiptychReadsCleanly() throws {
        let names = try manager.contentsOfDirectory(atPath: Self.repositoryScripts.path)
            .filter { $0.hasSuffix(".sh") }
        XCTAssertFalse(names.isEmpty)

        let offered = ScriptLibrary.scripts(in: Self.repositoryScripts)

        // Not one left out: a script that fails to read is never offered, so
        // a mistake in one would otherwise go unnoticed.
        XCTAssertEqual(Set(offered.map(\.fileName)), Set(names))
        for script in offered {
            XCTAssertGreaterThan(script.version, 0, script.fileName)
            XCTAssertFalse(script.summary.isEmpty, "\(script.fileName) needs a description")
        }
    }

    func testOnlyScriptsThatSayTheyAreDiptychsAreOffered() throws {
        try bundle("ours", version: 1)
        try Data("#!/bin/sh\n# call: $0 $1\n".utf8)
            .write(to: bundled.appendingPathComponent("stray.sh"))

        XCTAssertEqual(ScriptLibrary.scripts(in: bundled).map(\.fileName), ["ours.sh"])
    }

    // MARK: - The headers

    func testSourceAndVersionAreRead() {
        let (script, problems) = ScriptDefinition.read(
            URL(fileURLWithPath: "/x/a.sh"),
            contents: "#!/bin/sh\n# source: Diptych\n# version: 4\n# call: $0 $1\n")

        XCTAssertEqual(problems, [])
        XCTAssertEqual(script?.source, "diptych")
        XCTAssertEqual(script?.version, 4)
    }

    func testAVersionThatIsNotAWholeNumberIsReported() {
        let (_, problems) = ScriptDefinition.read(
            URL(fileURLWithPath: "/x/a.sh"), contents: "#!/bin/sh\n# version: 1.2\n# call: $0 $1\n")

        XCTAssertEqual(problems.count, 1)
        XCTAssertEqual(problems.first?.line, 2)
    }

    func testASignatureIsAcceptedForNow() {
        // Checked once scripts can be downloaded; until then a signed script
        // must not be reported as a mistake.
        let (script, problems) = ScriptDefinition.read(
            URL(fileURLWithPath: "/x/a.sh"),
            contents: "#!/bin/sh\n# signature: ed25519 diptych-2026 AAAA\n# call: $0 $1\n")

        XCTAssertEqual(problems, [])
        XCTAssertNotNil(script)
    }

    // MARK: - How each stands

    func testStatusAgainstWhatIsInstalled() throws {
        try bundle("hello", version: 2)
        let script = try XCTUnwrap(ScriptLibrary.scripts(in: bundled).first)

        XCTAssertEqual(ScriptLibrary.status(of: script, in: target), .absent)

        try put("hello.sh", script.contents)
        XCTAssertEqual(ScriptLibrary.status(of: script, in: target), .installed)
    }

    func testAnEarlierVersionOfOursIsAnUpdate() throws {
        try bundle("hello", version: 2)
        let script = try XCTUnwrap(ScriptLibrary.scripts(in: bundled).first)
        try put("hello.sh", script.contents.replacingOccurrences(of: "# version: 2", with: "# version: 1"))

        XCTAssertEqual(ScriptLibrary.status(of: script, in: target), .older(version: 1))
    }

    func testOursChangedByHandIsNotAnUpdate() throws {
        try bundle("hello", version: 2)
        let script = try XCTUnwrap(ScriptLibrary.scripts(in: bundled).first)
        try put("hello.sh", script.contents.replacingOccurrences(of: "echo hello", with: "echo mine"))

        XCTAssertEqual(ScriptLibrary.status(of: script, in: target), .different)
    }

    func testSomebodysOwnScriptOfTheSameNameIsDifferent() throws {
        try bundle("hello", version: 2)
        let script = try XCTUnwrap(ScriptLibrary.scripts(in: bundled).first)
        try put("hello.sh", "#!/bin/sh\n# call: $0 $1\necho mine\n")

        XCTAssertEqual(ScriptLibrary.status(of: script, in: target), .different)
    }

    // MARK: - Installing

    func testAnInstalledScriptPassesEveryRuleAndIsFound() throws {
        try bundle("hello", version: 1)
        let scripts = ScriptLibrary.scripts(in: bundled)

        let outcome = install(scripts)

        XCTAssertEqual(outcome.installed, ["hello.sh"])
        let url = target.appendingPathComponent("hello.sh")
        let attributes = try manager.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o400)
        XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.uint32Value, getuid())
        XCTAssertLessThan(getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0), 0,
                          "an installed script must not look downloaded")

        ScriptCatalogue.shared.reload(from: target, checkingTheSetting: false)
        XCTAssertEqual(ScriptCatalogue.shared.problems, [])
        XCTAssertEqual(ScriptCatalogue.shared.scripts.map(\.name), ["hello"])
    }

    func testWhatWasThereGoesToTheTrashFirst() throws {
        try bundle("hello", version: 1)
        try put("hello.sh", "#!/bin/sh\n# call: $0 $1\necho mine\n")

        let outcome = install(ScriptLibrary.scripts(in: bundled))

        XCTAssertEqual(outcome.trashed, ["hello.sh"])
        XCTAssertEqual(trashed, ["hello.sh"])
        let now = try String(contentsOf: target.appendingPathComponent("hello.sh"), encoding: .utf8)
        XCTAssertTrue(now.contains("# source: diptych"))
    }

    func testAnIdenticalScriptIsLeftAlone() throws {
        try bundle("hello", version: 1)
        let scripts = ScriptLibrary.scripts(in: bundled)
        _ = install(scripts)

        let again = install(scripts)

        XCTAssertEqual(again.installed, [])
        XCTAssertEqual(trashed, [])
    }

    func testNothingHalfWrittenIsLeftBehind() throws {
        try bundle("hello", version: 1)
        _ = install(ScriptLibrary.scripts(in: bundled))

        let names = try manager.contentsOfDirectory(atPath: target.path)
        XCTAssertEqual(names, ["hello.sh"])
    }

    func testTheCopyToCompareIsNotTheApplicationsOwnFile() throws {
        try bundle("hello", version: 3)
        let script = try XCTUnwrap(ScriptLibrary.scripts(in: bundled).first)

        let copy = try XCTUnwrap(ScriptLibrary.comparableCopy(of: script))

        XCTAssertEqual(copy.lastPathComponent, "hello (version 3).sh")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), script.contents)
        try? manager.removeItem(at: copy.deletingLastPathComponent())
    }
}
