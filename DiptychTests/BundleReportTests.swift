import XCTest
@testable import Diptych

/// The bundle preview: an app's Info.plist, signature, seal, what is inside
/// it and where it came from. Bundles are built here from the executable
/// fixtures and signed ad hoc with codesign.
final class BundleReportTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("BundleReportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let host = ExecutableReport.Host(
        appleSilicon: true, macOS: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))

    private func plist(_ values: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }

    /// An app: the arm64 hello as its executable, a framework, a login item,
    /// a launch agent, two languages and a resource.
    private func makeApp(_ name: String = "Sample", extra: [String: Any] = [:],
                         executable: Data = ExecutableFixtures.helloUnsigned) throws -> URL {
        let app = folder.appendingPathComponent("\(name).app")
        let contents = app.appendingPathComponent("Contents")
        let manager = FileManager.default
        for path in ["MacOS", "Resources/en.lproj", "Resources/hu.lproj", "Frameworks/Kit.framework/Versions/A/Resources",
                     "Library/LaunchAgents"] {
            try manager.createDirectory(at: contents.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try executable.write(to: contents.appendingPathComponent("MacOS/\(name)"))
        var info: [String: Any] = ["CFBundleExecutable": name, "CFBundleIdentifier": "example.diptych.\(name.lowercased())",
                                   "CFBundleShortVersionString": "1.4.2", "CFBundleVersion": "1.4.2.17",
                                   "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "13.0",
                                   "LSApplicationCategoryType": "public.app-category.developer-tools",
                                   "NSHumanReadableCopyright": "Public domain",
                                   "NSCameraUsageDescription": "To show a camera request.",
                                   "CFBundleDocumentTypes": [["CFBundleTypeName": "Sample Document"]],
                                   "CFBundleURLTypes": [["CFBundleURLSchemes": ["diptych-sample"]]]]
        info.merge(extra) { _, new in new }
        try plist(info).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("hello".utf8).write(to: contents.appendingPathComponent("Resources/readme.txt"))
        try Data("notes".utf8).write(to: contents.appendingPathComponent("Resources/notes.txt"))
        try Data("x".utf8).write(to: contents.appendingPathComponent("Resources/en.lproj/a.strings"))
        try Data("x".utf8).write(to: contents.appendingPathComponent("Resources/hu.lproj/a.strings"))
        let kit = contents.appendingPathComponent("Frameworks/Kit.framework")
        try ExecutableFixtures.libSample.write(to: kit.appendingPathComponent("Versions/A/Kit"))
        try plist(["CFBundleExecutable": "Kit", "CFBundleIdentifier": "example.diptych.kit",
                   "CFBundleShortVersionString": "2.0", "CFBundlePackageType": "FMWK"])
            .write(to: kit.appendingPathComponent("Versions/A/Resources/Info.plist"))
        try manager.createSymbolicLink(atPath: kit.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try manager.createSymbolicLink(atPath: kit.appendingPathComponent("Kit").path, withDestinationPath: "Versions/Current/Kit")
        try manager.createSymbolicLink(atPath: kit.appendingPathComponent("Resources").path,
                                       withDestinationPath: "Versions/Current/Resources")
        try plist(["Label": "example.diptych.agent", "Program": "Contents/MacOS/\(name)"])
            .write(to: contents.appendingPathComponent("Library/LaunchAgents/example.diptych.agent.plist"))
        return app
    }

    private func sign(_ paths: URL...) throws {
        for path in paths {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["-f", "-s", "-", path.path]
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw XCTSkip("codesign could not sign here") }
        }
    }

    private func signed() throws -> URL {
        let app = try makeApp()
        try sign(app.appendingPathComponent("Contents/Frameworks/Kit.framework/Versions/A"), app)
        return app
    }

    // MARK: -

    func testTheInfoPlistIsRead() throws {
        let bundle = try AppBundle.read(try makeApp())
        XCTAssertEqual(bundle.name, "Sample")
        XCTAssertEqual(bundle.identifier, "example.diptych.sample")
        XCTAssertEqual(bundle.version, "1.4.2")
        XCTAssertEqual(bundle.build, "1.4.2.17")
        XCTAssertEqual(bundle.kind, "Application")
        XCTAssertEqual(bundle.category, "Developer Tools")
        XCTAssertEqual(bundle.permissions.map(\.what), ["Camera"])
        XCTAssertEqual(bundle.permissions.first?.reason, "To show a camera request.")
        XCTAssertEqual(bundle.documentTypes, ["Sample Document"])
        XCTAssertEqual(bundle.urlSchemes, ["diptych-sample"])
        XCTAssertEqual(bundle.localizations, ["en", "hu"])
        XCTAssertEqual(bundle.executable?.slices.first?.architecture, "arm64")
    }

    func testWhatIsInsideIsListed() throws {
        let bundle = try AppBundle.read(try makeApp())
        let kit = try XCTUnwrap(bundle.embedded.first { $0.name == "Kit.framework" })
        XCTAssertEqual(kit.group, "Frameworks")
        XCTAssertEqual(kit.version, "2.0")
        XCTAssertEqual(kit.identifier, "example.diptych.kit")
        let agent = try XCTUnwrap(bundle.embedded.first { $0.group.hasPrefix("Starts at login") })
        XCTAssertEqual(agent.identifier, "example.diptych.agent")
    }

    func testAnUnsignedAppHasNoSealAndIsWarnedAbout() throws {
        let bundle = try AppBundle.read(try makeApp())
        XCTAssertEqual(bundle.seal(), .none)
        let html = BundleReport.html(for: bundle, seal: .none, size: (1000, 3), icon: nil, host: host)
        XCTAssertTrue(html.contains("It is not signed. Apple silicon Macs run only signed code"))
        XCTAssertTrue(html.contains("Developer Tools"))
        XCTAssertTrue(html.contains("To show a camera request."))
    }

    func testASignedAppsSealIsIntact() throws {
        let app = try signed()
        let bundle = try AppBundle.read(app, verify: true)
        let signature = try XCTUnwrap(bundle.executable?.slices.first?.image?.signature)
        XCTAssertEqual(signature.identifier, "example.diptych.sample")
        XCTAssertEqual(signature.matches(slot: 1, bundle.infoData), true)
        guard case .intact(let files) = bundle.seal() else { return XCTFail("\(bundle.seal())") }
        XCTAssertGreaterThan(files, 3)
        let html = BundleReport.html(for: bundle, seal: bundle.seal(), size: AppBundle.size(of: app), icon: nil, host: host)
        XCTAssertTrue(html.contains("sealed files match"))
        XCTAssertFalse(html.contains("class=warn"))
    }

    func testAChangedResourceAMissingOneAndAnEditedInfoPlistBreakTheSeal() throws {
        let app = try signed()
        let contents = app.appendingPathComponent("Contents")
        try Data("changed".utf8).write(to: contents.appendingPathComponent("Resources/readme.txt"))
        try FileManager.default.removeItem(at: contents.appendingPathComponent("Resources/notes.txt"))
        // Localizations are sealed as optional: one may go missing.
        try FileManager.default.removeItem(at: contents.appendingPathComponent("Resources/hu.lproj/a.strings"))
        guard case .broken(let changed, let missing, _) = try AppBundle.read(app).seal() else {
            return XCTFail("the seal should be broken")
        }
        XCTAssertEqual(changed, ["Resources/readme.txt"])
        XCTAssertEqual(missing, ["Resources/notes.txt"])

        var info = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: contents.appendingPathComponent("Info.plist")), format: nil) as? [String: Any])
        info["CFBundleShortVersionString"] = "9.9"
        try plist(info).write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try AppBundle.read(app)
        guard case .broken(let again, _, _) = bundle.seal() else { return XCTFail("still broken") }
        XCTAssertTrue(again.contains("Info.plist"))
        let html = BundleReport.html(for: bundle, seal: bundle.seal(), size: nil, icon: nil, host: host)
        XCTAssertTrue(html.contains("It is not as it was signed."))
        XCTAssertTrue(html.contains("<code>Resources/readme.txt</code>"))
    }

    func testChangedNestedCodeIsFoundByItsCDHash() throws {
        let app = try signed()
        // Signed again with another identifier: a different code directory.
        let kit = app.appendingPathComponent("Contents/Frameworks/Kit.framework/Versions/A")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-f", "-s", "-", "-i", "example.diptych.other", kit.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard case .broken(let changed, _, _) = try AppBundle.read(app).seal() else { return XCTFail("broken") }
        XCTAssertTrue(changed.contains { $0.hasPrefix("Frameworks/Kit.framework") }, "\(changed)")
    }

    func testWhereADownloadCameFrom() throws {
        let app = try makeApp()
        let flags = "0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));Safari;"
        XCTAssertEqual(setxattr(app.path, "com.apple.quarantine", flags, flags.utf8.count, 0, 0), 0)
        let froms = try PropertyListSerialization.data(fromPropertyList: ["https://example.com/Sample.zip"],
                                                       format: .binary, options: 0)
        _ = froms.withUnsafeBytes { setxattr(app.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, froms.count, 0, 0) }
        let bundle = try AppBundle.read(app)
        XCTAssertEqual(bundle.quarantine?.agent, "Safari")
        XCTAssertEqual(bundle.quarantine?.opened, false)
        XCTAssertEqual(bundle.whereFrom, ["https://example.com/Sample.zip"])
        let html = BundleReport.html(for: bundle, seal: nil, size: nil, icon: nil, host: host)
        XCTAssertTrue(html.contains("downloaded with Safari"))
        XCTAssertTrue(html.contains("https://example.com/Sample.zip"))
        XCTAssertTrue(html.contains("Gatekeeper checks it the first time"))
        XCTAssertTrue(html.contains("checking every file\u{2026}"))
        XCTAssertTrue(html.contains("counting its size\u{2026}"))
    }

    func testAMenuBarAppAndAnIntelOne() throws {
        let menu = try AppBundle.read(try makeApp("Menu", extra: ["LSUIElement": true]))
        XCTAssertEqual(menu.kind, "Menu bar application")
        let intel = try AppBundle.read(try makeApp("Intel", executable: ExecutableFixtures.helloIntel))
        let html = BundleReport.html(for: intel, seal: nil, size: nil, icon: nil, host: host)
        XCTAssertTrue(html.contains("Intel only: on this Mac it runs under Rosetta 2."))
    }

    func testAScriptExecutableSignedInItsAttributes() throws {
        let app = try makeApp("Script", executable: Data("#!/bin/sh\necho hello\n".utf8))
        try sign(app.appendingPathComponent("Contents/Frameworks/Kit.framework/Versions/A"), app)
        let bundle = try AppBundle.read(app, verify: true)
        XCTAssertNil(bundle.executable)
        XCTAssertTrue(bundle.executableProblem?.contains("is a script: #!/bin/sh") == true)
        let signature = try XCTUnwrap(bundle.scriptSignature)
        XCTAssertEqual(signature.identifier, "example.diptych.script")
        XCTAssertEqual(signature.isIntact, true)
        guard case .intact = bundle.seal() else { return XCTFail("\(bundle.seal())") }
        // Changed after signing: the script's own hash no longer matches.
        try Data("#!/bin/sh\necho changed\n".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Script"))
        let changed = try AppBundle.read(app, verify: true)
        XCTAssertEqual(changed.scriptSignature?.isIntact, false)
    }

    func testABundleWithoutCFBundleExecutableUsesItsName() throws {
        let app = try makeApp("Helper", extra: [:])
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        var info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any])
        info["CFBundleExecutable"] = nil
        try plist(info).write(to: infoURL)
        let bundle = try AppBundle.read(app)
        XCTAssertEqual(bundle.executableURL?.lastPathComponent, "Helper")
        XCTAssertNotNil(bundle.executable)
    }

    func testAFolderWithoutAnInfoPlistIsNotABundle() throws {
        let fake = folder.appendingPathComponent("Fake.app")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        XCTAssertThrowsError(try AppBundle.read(fake))
    }

    func testCalculatorIsAsAppleSignedIt() throws {
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no Calculator") }
        let bundle = try AppBundle.read(url, verify: true)
        XCTAssertEqual(bundle.identifier, "com.apple.calculator")
        let signature = try XCTUnwrap(bundle.executable?.slices.compactMap { $0.image?.signature }.first)
        XCTAssertTrue(signature.platformBinary)
        guard case .intact = bundle.seal() else { return XCTFail("\(bundle.seal())") }
    }
}
