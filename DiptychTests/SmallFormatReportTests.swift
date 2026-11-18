import XCTest
@testable import Diptych

/// Crash reports, provisioning profiles, Internet locations and Java
/// properties: every sample made up here, every name an example.
final class SmallFormatReportTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SmallFormatReportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "tool", code: Int(process.terminationStatus)) }
        return data
    }

    // MARK: - Crash reports

    private let crashHeader = #"{"app_name":"Sample","timestamp":"2026-11-10 09:15:00.00 +0100","app_version":"1.2","bug_type":"309","os_version":"macOS 27.2 (26B123)","bundleID":"com.example.sample","name":"Sample","incident_id":"00000000-0000-0000-0000-000000000001"}"#

    private func crashBody(top: String) -> String {
        """
        {"procName":"Sample","procPath":"/Applications/Sample.app/Contents/MacOS/Sample","pid":42,
         "parentProc":"launchd","parentPid":1,"cpuType":"ARM-64","modelCode":"Mac14,2","uptime":7260,
         "captureTime":"2026-11-10 09:15:00.0000 +0100","osVersion":{"train":"macOS 27.2","build":"26B123"},
         "bundleInfo":{"CFBundleShortVersionString":"1.2","CFBundleVersion":"34","CFBundleIdentifier":"com.example.sample"},
         "exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP","codes":"0x1, 0x100"},
         "termination":{"namespace":"SIGNAL","indicator":"Trace/BPT trap: 5","byProc":"exc handler"},
         "asi":{"libswiftCore.dylib":["Fatal error"]},
         "faultingThread":1,
         "usedImages":[{"name":"Sample","path":"/Applications/Sample.app/Contents/MacOS/Sample","base":4294967296,"size":65536,"arch":"arm64"},
                       {"name":"libswiftCore.dylib","path":"/usr/lib/swift/libswiftCore.dylib","base":8589934592,"size":4096}],
         "threads":[{"id":1,"queue":"com.apple.main-thread","frames":[{"imageIndex":1,"imageOffset":16,"symbol":"mach_msg","symbolLocation":8}]},
                    {"id":2,"triggered":true,"frames":[{"imageIndex":1,"imageOffset":32,"symbol":"\(top)"},
                      {"imageIndex":0,"imageOffset":256,"symbol":"Sample.load(_:)","symbolLocation":40,"sourceFile":"Loader.swift","sourceLine":17},
                      {"imageIndex":9,"imageOffset":1}]}]}
        """
    }

    func testCrashReport() throws {
        let data = Data((crashHeader + "\n" + crashBody(top: "Swift runtime failure: arithmetic overflow")).utf8)
        XCTAssertTrue(CrashLog.looksLikeReport(data))
        let log = try CrashLog(data: data)
        XCTAssertTrue(log.isCrash)
        XCTAssertEqual(log.process, "Sample")
        XCTAssertEqual(log.version, "1.2")
        XCTAssertEqual(log.build, "34")
        XCTAssertEqual(log.crashedThread, 1)
        XCTAssertEqual(log.threads[1].frames.map(\.own), [false, true, false])
        XCTAssertEqual(log.threads[1].frames[1].address, 4294967296 + 256)
        XCTAssertEqual(log.applicationNotes, ["libswiftCore.dylib: Fatal error"])
        XCTAssertTrue(log.explanation?.contains("arithmetic overflow") == true)

        let html = CrashReport.html(for: log, url: URL(fileURLWithPath: "/Sample.ips"), size: data.count)
        XCTAssertTrue(html.contains("Crash report"))
        XCTAssertTrue(html.contains("Crashed Thread"))
        XCTAssertTrue(html.contains("Loader.swift:17"))
        XCTAssertTrue(html.contains("<tr class=own>"))
        XCTAssertTrue(html.contains("Other Threads <span class=count>1</span>"))
        XCTAssertTrue(html.contains("2 hours, 1 minute"))
    }

    func testOtherReportsAndDamage() throws {
        // An old crash report: JSON header, text body.
        let text = Data((#"{"bug_type":"109","app_name":"Old"}"# + "\nProcess: Old [1]\nCrashed Thread: 0\n").utf8)
        let old = try CrashLog(data: text)
        XCTAssertFalse(old.isCrash)
        XCTAssertTrue(CrashReport.html(for: old, url: URL(fileURLWithPath: "/Old.ips"), size: text.count).contains("Crashed Thread: 0"))
        XCTAssertThrowsError(try CrashLog(data: Data("not a report\n{}".utf8)))

        let original = Data((crashHeader + "\n" + crashBody(top: "abort")).utf8)
        var generator = SeededGenerator(seed: 5)
        for round in 0..<300 {
            var data = original
            for _ in 0..<(1 + round % 4) {
                data[Int.random(in: 0..<data.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            if let log = try? CrashLog(data: data) {
                _ = CrashReport.html(for: log, url: URL(fileURLWithPath: "/x.ips"), size: data.count)
            }
        }
    }

    // MARK: - Provisioning profiles

    /// A profile signed with a made-up certificate, as Apple signs real ones.
    private func profile(tamper: Bool = false) throws -> Data {
        let key = folder.appendingPathComponent("key.pem"), certificate = folder.appendingPathComponent("cert.pem")
        try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30",
                                     "-subj", "/CN=Apple Development: Sample Person (ABCDE12345)",
                                     "-keyout", key.path, "-out", certificate.path])
        let der = try run("/usr/bin/openssl", ["x509", "-in", certificate.path, "-outform", "DER"])
        let list: [String: Any] = [
            "Name": "Sample Development Profile", "UUID": "00000000-0000-0000-0000-00000000000A",
            "AppIDName": "Sample", "TeamName": "Example Team", "TeamIdentifier": ["ABCDE12345"],
            "Platform": ["iOS"], "CreationDate": Date(timeIntervalSince1970: 1_700_000_000),
            "ExpirationDate": Date(timeIntervalSince1970: 1_800_000_000), "IsXcodeManaged": true,
            "ProvisionedDevices": ["00008110-000000000000001E", "00008110-000000000000002E"],
            "DeveloperCertificates": [der],
            "Entitlements": ["application-identifier": "ABCDE12345.com.example.sample", "get-task-allow": true,
                             "keychain-access-groups": ["ABCDE12345.*"]],
        ]
        let plist = folder.appendingPathComponent("profile.plist")
        try PropertyListSerialization.data(fromPropertyList: list, format: .xml, options: 0).write(to: plist)
        var signed = try run("/usr/bin/openssl", ["smime", "-sign", "-binary", "-nodetach", "-outform", "DER",
                                                  "-in", plist.path, "-signer", certificate.path, "-inkey", key.path])
        if tamper, let range = signed.range(of: Data("Sample Development".utf8)) {
            signed[range.lowerBound] = UInt8(ascii: "T")
        }
        return signed
    }

    func testProvisioningProfile() throws {
        let data = try profile()
        XCTAssertTrue(ProvisioningProfile.looksLikeProfile(data))
        let profile = try ProvisioningProfile(data: data)
        XCTAssertEqual(profile.name, "Sample Development Profile")
        XCTAssertEqual(profile.distribution, .development)
        XCTAssertEqual(profile.bundleIdentifier, "com.example.sample")
        XCTAssertEqual(profile.devices.count, 2)
        XCTAssertEqual(profile.certificates.count, 1)
        XCTAssertEqual(profile.signatureValid, true)
        XCTAssertFalse(profile.byApple)
        XCTAssertNotEqual(profile.trusted, true, "a made-up certificate leads to no trusted root")

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let html = ProvisioningReport.html(for: profile, url: URL(fileURLWithPath: "/p.mobileprovision"), size: data.count, now: now)
        XCTAssertTrue(html.contains("Provisioning profile, Development, iOS"))
        XCTAssertTrue(html.contains("a debugger may attach"))
        XCTAssertTrue(html.contains("Devices <span class=count>2</span>"))
        XCTAssertTrue(html.contains("Apple Development: Sample Person"))
        XCTAssertTrue(html.contains("<span class=good>intact</span>"))
        let later = ProvisioningReport.html(for: profile, url: URL(fileURLWithPath: "/p.mobileprovision"), size: 1,
                                            now: Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertTrue(later.contains("This profile expired"))
        XCTAssertTrue(later.contains("Every certificate in it has expired"), "the made-up certificate lasts 30 days from today")

        let changed = try ProvisioningProfile(data: try self.profile(tamper: true))
        XCTAssertEqual(changed.signatureValid, false)
        XCTAssertTrue(ProvisioningReport.html(for: changed, url: URL(fileURLWithPath: "/p.mobileprovision"), size: 1)
            .contains("changed after it was signed"))
        XCTAssertThrowsError(try ProvisioningProfile(data: Data("<plist/>".utf8)))
    }

    // MARK: - Internet locations

    func testWebLocation() throws {
        let list = try PropertyListSerialization.data(fromPropertyList: ["URL": "https://www.example.com/a?utm_source=x&q=1"],
                                                      format: .binary, options: 0)
        let location = try InternetLocation(finder: list, resourceFork: nil)
        XCTAssertEqual(location.target, "https://www.example.com/a?utm_source=x&q=1")
        XCTAssertTrue(location.warnings.isEmpty)
        let html = LocationReport.html(for: location, url: URL(fileURLWithPath: "/Example.webloc"), size: list.count, opener: "Safari")
        XCTAssertTrue(html.contains("<a href=\"https://www.example.com/a?utm_source=x&amp;q=1\">"))
        XCTAssertTrue(html.contains("campaign tracking"))
        XCTAssertTrue(html.contains("Safari"))

        let tricky = try InternetLocation(finder: try PropertyListSerialization.data(
            fromPropertyList: ["URL": "http://www.example.com@xn--bcher-kva.example/setup.exe"], format: .xml, options: 0), resourceFork: nil)
        let warnings = tricky.warnings.joined(separator: " ")
        XCTAssertTrue(warnings.contains("only a user name: the address goes to bücher.example"), warnings)
        XCTAssertTrue(warnings.contains("letters beyond plain Latin"))
        XCTAssertTrue(warnings.contains("setup.exe"))
        XCTAssertFalse(LocationReport.html(for: tricky, url: URL(fileURLWithPath: "/x.webloc"), size: 1, opener: nil).contains("<a href"))
        XCTAssertThrowsError(try InternetLocation(finder: Data(), resourceFork: nil))
    }

    func testOldLocationInTheResourceFork() throws {
        // A resource fork with one 'url ' resource, laid out as the Resource Manager does.
        let address = Data("https://www.example.org/".utf8)
        var fork = Data(count: 256)
        func put32(_ value: Int, at: Int) { withUnsafeBytes(of: UInt32(value).bigEndian) { fork.replaceSubrange(at..<at + 4, with: $0) } }
        func put16(_ value: Int, at: Int) { withUnsafeBytes(of: UInt16(value).bigEndian) { fork.replaceSubrange(at..<at + 2, with: $0) } }
        let dataStart = 256, map = 256 + 4 + address.count
        put32(dataStart, at: 0); put32(map, at: 4); put32(4 + address.count, at: 8); put32(50, at: 12)
        fork += withUnsafeBytes(of: UInt32(address.count).bigEndian) { Data($0) } + address + Data(count: 50)
        put16(28, at: map + 24)                 // type list, from the map
        put16(0, at: map + 28)                  // one type
        fork.replaceSubrange(map + 30..<map + 34, with: Data("url ".utf8))
        put16(0, at: map + 34)                  // one resource
        put16(10, at: map + 36)                 // its reference, from the type list
        put16(256, at: map + 38)                // id
        put32(0, at: map + 28 + 10 + 4)         // attributes and data offset 0
        let location = try InternetLocation(finder: Data(), resourceFork: fork)
        XCTAssertEqual(location.target, "https://www.example.org/")
        XCTAssertTrue(location.fromResourceFork)
    }

    func testWindowsShortcut() throws {
        let text = "[{000214A0-0000-0000-C000-000000000046}]\r\nProp3=19,11\r\n[InternetShortcut]\r\nIDList=\r\n"
            + "URL=file://fileserver.example/share/report.pdf.exe\r\nIconFile=\\\\fileserver.example\\icons\\pdf.ico\r\n"
            + "IconIndex=0\r\nModified=00A0E4A2C0D6DA0100\r\n"
        let location = try InternetLocation(windows: Data(text.utf8))
        XCTAssertEqual(location.target, "file://fileserver.example/share/report.pdf.exe")
        XCTAssertEqual(location.iconFile, "\\\\fileserver.example\\icons\\pdf.ico")
        XCTAssertNotNil(location.modified)
        let warnings = location.warnings.joined(separator: " ")
        XCTAssertTrue(warnings.contains("sends the user's sign-in"), warnings)
        XCTAssertTrue(warnings.contains("Its icon is fetched from another computer"))
        XCTAssertTrue(warnings.contains("report.pdf.exe"))
        let html = LocationReport.html(for: location, url: URL(fileURLWithPath: "/Report.url"), size: text.count, opener: nil)
        XCTAssertTrue(html.contains("Windows Internet shortcut"))
        XCTAssertTrue(html.contains("Other Settings <span class=count>3</span>"))

        let utf16 = Data([0xFF, 0xFE]) + "[InternetShortcut]\r\nURL=https://www.example.net/\r\n".data(using: .utf16LittleEndian)!
        XCTAssertEqual(try InternetLocation(windows: utf16).target, "https://www.example.net/")
        XCTAssertThrowsError(try InternetLocation(windows: Data("URL=https://www.example.net/".utf8)))
    }

    func testPunycode() {
        XCTAssertEqual(Punycode.decode("bcher-kva"), "bücher")
        XCTAssertEqual(Punycode.decode("mnchen-3ya"), "münchen")
        XCTAssertEqual(Punycode.decode("rvztr-wqa0gx3bwi"), "árvíztűrő")
        XCTAssertNil(Punycode.decode("ab-c!d"))
    }

    // MARK: - Properties

    func testProperties() {
        let text = """
            # Greetings
            ! another comment
            greeting = Hello, \\
                       world
            path:C:\\\\temp\\tnext
            key\\ with\\ spaces value
            unicode=\\u00e1rv\\u00edzt\\u0171r\\u0151 \\uD83D\\uDE00
            empty=
            greeting=Again\u{20}\u{20}
            broken=\\u12
            continued#not=a comment \\
              # still the value
            """
        let properties = JavaProperties(data: Data(text.utf8))
        let entries = properties.entries
        XCTAssertEqual(entries.map(\.key), ["greeting", "path", "key with spaces", "unicode", "empty", "greeting", "broken", "continued#not"])
        XCTAssertEqual(entries[0].value, "Hello, world")
        XCTAssertEqual(entries[0].lines, 2)
        XCTAssertEqual(entries[0].overriddenAt, 9)
        XCTAssertEqual(entries[1].value, "C:\\temp\tnext")
        XCTAssertEqual(entries[2].value, "value")
        XCTAssertEqual(entries[3].value, "árvíztűrő 😀")
        XCTAssertEqual(entries[4].value, "")
        XCTAssertEqual(entries[5].value, "Again  ")
        XCTAssertTrue(entries[6].badEscape)
        XCTAssertEqual(entries[7].value, "a comment # still the value")

        let html = PropertiesReport.html(for: properties, url: URL(fileURLWithPath: "/Messages_de_CH.properties"), size: text.utf8.count)
        XCTAssertTrue(html.contains("Java properties, 7 keys"))
        XCTAssertTrue(html.contains("strings for German (Switzerland)"))
        XCTAssertTrue(html.contains("set more than once"))
        XCTAssertTrue(html.contains("Java refuses to load the whole file"))
        XCTAssertTrue(html.contains("<td colspan=2>Greetings</td>"))
        XCTAssertTrue(html.contains("Again<i class=mark>\u{2423}</i><i class=mark>\u{2423}</i>"))

        let latin = JavaProperties(data: Data([0x61, 0x3D, 0xE9]))
        XCTAssertEqual(latin.entries.first?.value, "é")
        XCTAssertFalse(latin.utf8)
        XCTAssertTrue(JavaProperties(data: Data("a=\u{E9}".utf8)).utf8)
    }

    func testDamagedSmallFilesDoNotCrash() throws {
        let originals = [
            Data("a=b\\\nc\\u00e1\\uD83D\\uDE00 x=y\n#c\n".utf8),
            Data("[InternetShortcut]\nURL=https://xn--bcher-kva.example/\nModified=00A0E4A2C0D6DA01\n".utf8),
        ]
        var generator = SeededGenerator(seed: 9)
        for (index, original) in originals.enumerated() {
            for round in 0..<300 {
                var data = original
                for _ in 0..<(1 + round % 4) {
                    data[Int.random(in: 0..<data.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
                }
                if index == 0 {
                    _ = PropertiesReport.html(for: JavaProperties(data: data), url: URL(fileURLWithPath: "/x.properties"), size: data.count)
                } else if let location = try? InternetLocation(windows: data) {
                    _ = LocationReport.html(for: location, url: URL(fileURLWithPath: "/x.url"), size: data.count, opener: nil)
                }
                _ = InternetLocation.resource("url ", in: data)
                _ = Punycode.decode(String(decoding: data.prefix(20), as: UTF8.self))
            }
        }
    }
}
