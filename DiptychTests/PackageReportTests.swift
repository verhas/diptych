import CryptoKit
import Security
import XCTest
@testable import Diptych

/// Installer packages: built here with pkgbuild and productbuild, and one
/// xar written by hand and signed with a key made for the test.
final class PackageReportTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PackageReportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String], input: Data? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        if let input {
            let pipe = Pipe()
            process.standardInput = pipe
            try process.run()
            pipe.fileHandleForWriting.write(input)
            try pipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "tool", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(tool) \(arguments.joined(separator: " "))"])
        }
        return data
    }

    private func write(_ text: String, _ path: String, executable: Bool = false) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    /// A component: a tool, a setuid helper, a launch daemon; two hooks and a helper script.
    private func makeComponent(_ name: String = "tool.pkg") throws -> URL {
        try write("#!/bin/sh\necho tool\n", "root/usr/local/bin/sample-tool", executable: true)
        try write("#!/bin/sh\n", "root/usr/local/libexec/sample-helper", executable: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o4755],
                                              ofItemAtPath: folder.appendingPathComponent("root/usr/local/libexec/sample-helper").path)
        try write("<plist version=\"1.0\"><dict/></plist>\n", "root/Library/LaunchDaemons/example.sample.plist")
        try write("#!/bin/sh\n# before\nexit 0\n", "scripts/preinstall", executable: true)
        try write("#!/bin/sh\n# after\n./helper.sh\nexit 0\n", "scripts/postinstall", executable: true)
        try write("#!/bin/sh\necho helping\n", "scripts/helper.sh", executable: true)
        try run("/usr/bin/xattr", ["-cr", folder.path])
        let target = folder.appendingPathComponent(name)
        try run("/usr/bin/pkgbuild", ["--quiet", "--root", folder.appendingPathComponent("root").path,
                                      "--scripts", folder.appendingPathComponent("scripts").path,
                                      "--identifier", "example.sample.tool", "--version", "1.2.0",
                                      "--install-location", "/", target.path])
        return target
    }

    private func package(_ url: URL) throws -> InstallerPackage {
        try InstallerPackage(url: url, data: Data(contentsOf: url))
    }

    func testComponentPackage() throws {
        let url = try makeComponent()
        let package = try package(url)
        XCTAssertEqual(package.kind, .component)
        XCTAssertEqual(package.identifier, "example.sample.tool")
        XCTAssertEqual(package.version, "1.2.0")
        XCTAssertNil(package.signature)
        let component = try XCTUnwrap(package.components.first)
        XCTAssertTrue(component.runsAsRoot)
        XCTAssertTrue(component.hasPayload)
        XCTAssertEqual(component.scripts.map(\.name), ["postinstall", "preinstall", "helper.sh"])
        XCTAssertEqual(component.scripts.map(\.isHook), [true, true, false])
        XCTAssertTrue(component.scripts[0].text?.contains("# after") == true)
        let paths = component.files.map { InstallerPackage.destination(of: $0, in: component) }
        XCTAssertTrue(paths.contains("/usr/local/bin/sample-tool"))
        XCTAssertTrue(paths.contains("/Library/LaunchDaemons/example.sample.plist"))
        XCTAssertFalse(paths.contains { ($0 as NSString).lastPathComponent.hasPrefix("._") })

        let notable = package.notable()
        XCTAssertTrue(notable.contains { $0.path == "/Library/LaunchDaemons/example.sample.plist" && $0.why.contains("launch daemon") })
        XCTAssertTrue(notable.contains { $0.path == "/usr/local/libexec/sample-helper" && $0.why.contains("setuid") })

        let html = PackageReport.html(for: package, size: 1000)
        XCTAssertTrue(html.contains("Component package"))
        XCTAssertTrue(html.contains("Not signed"))
        XCTAssertTrue(html.contains("It runs scripts while installing, as root"))
        XCTAssertTrue(html.contains("runs after the files are installed"))
        XCTAssertTrue(html.contains("echo helping"))
        XCTAssertTrue(html.contains("Worth Knowing"))
        XCTAssertTrue(html.contains("/usr/local/bin"))
    }

    func testProductPackage() throws {
        let tool = try makeComponent()
        try write("Welcome.\n", "resources/en.lproj/Welcome.txt")
        try write("""
            <?xml version="1.0" encoding="utf-8"?>
            <installer-gui-script minSpecVersion="2">
                <title>Sample Product</title>
                <welcome file="Welcome.txt"/>
                <options customize="never" hostArchitectures="arm64"/>
                <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
                <allowed-os-versions><os-version min="14.0"/></allowed-os-versions>
                <installation-check script="check()"/>
                <script>function check() { return true; }</script>
                <choices-outline><line choice="tool"/></choices-outline>
                <choice id="tool" title="Tool"><pkg-ref id="example.sample.tool"/></choice>
                <pkg-ref id="example.sample.tool" version="1.2.0" onConclusion="RequireRestart">tool.pkg</pkg-ref>
                <product id="example.sample.product" version="2.0"/>
            </installer-gui-script>
            """, "distribution.xml")
        let target = folder.appendingPathComponent("Product.pkg")
        try run("/usr/bin/productbuild", ["--quiet", "--distribution", folder.appendingPathComponent("distribution.xml").path,
                                          "--resources", folder.appendingPathComponent("resources").path,
                                          "--package-path", tool.deletingLastPathComponent().path, target.path])
        let package = try package(target)
        XCTAssertEqual(package.kind, .product)
        XCTAssertEqual(package.title, "Sample Product")
        XCTAssertEqual(package.identifier, "example.sample.product")
        XCTAssertEqual(package.version, "2.0")
        XCTAssertEqual(package.minimumSystem, "14.0")
        XCTAssertEqual(package.architectures, ["arm64"])
        XCTAssertTrue(package.startupDiskOnly)
        XCTAssertTrue(package.installationCheck)
        XCTAssertEqual(package.javaScript, "function check() { return true; }")
        XCTAssertEqual(package.components.map(\.identifier), ["example.sample.tool"])
        XCTAssertEqual(package.conclusions, ["RequireRestart"])
        XCTAssertTrue(package.texts.contains { $0.hasSuffix("Welcome.txt") })

        let html = PackageReport.html(for: package, size: 1000)
        XCTAssertTrue(html.contains("macOS 14.0 or later"))
        XCTAssertTrue(html.contains("restarts the Mac"))
        XCTAssertTrue(html.contains("Installer JavaScript"))
        XCTAssertTrue(html.contains("the startup disk only"))
    }

    func testScriptsOnly() throws {
        try write("#!/bin/sh\nexit 0\n", "only/postinstall", executable: true)
        try run("/usr/bin/xattr", ["-cr", folder.path])
        let target = folder.appendingPathComponent("Scripts.pkg")
        try run("/usr/bin/pkgbuild", ["--quiet", "--nopayload", "--scripts", folder.appendingPathComponent("only").path,
                                      "--identifier", "example.sample.scripts", "--version", "1", target.path])
        let package = try package(target)
        XCTAssertTrue(package.installsNothing)
        XCTAssertTrue(package.runsScripts)
        XCTAssertTrue(PackageReport.html(for: package, size: 10).contains("It installs no files"))
    }

    func testNotAPackage() {
        XCTAssertFalse(InstallerPackage.looksLikePackage(Data("text".utf8)))
        XCTAssertThrowsError(try InstallerPackage(url: URL(fileURLWithPath: "/x.pkg"), data: Data("text, not a package".utf8)))
    }

    /// Damaged packages: no trap, whatever the bytes say.
    func testDamagedPackagesDoNotCrash() throws {
        let original = try Data(contentsOf: try makeComponent())
        var generator = SeededGenerator(seed: 7)
        for round in 0..<300 {
            var data = original
            for _ in 0..<(1 + round % 8) {
                let at = Int.random(in: 0..<min(data.count, round < 150 ? 600 : data.count), using: &generator)
                data[at] = UInt8.random(in: 0...255, using: &generator)
            }
            if let package = try? InstallerPackage(url: URL(fileURLWithPath: "/damaged.pkg"), data: data) {
                _ = PackageReport.html(for: package, size: Int64(data.count))
            }
        }
    }

    // MARK: - Signed

    /// A key and a self-signed certificate, made with the system's openssl.
    private func signer() throws -> (key: SecKey, certificate: Data) {
        let keyPEM = folder.appendingPathComponent("key.pem"), certificate = folder.appendingPathComponent("cert.der")
        try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30",
                                     "-subj", "/CN=Developer ID Installer: Sample (TEAMID1234)",
                                     "-keyout", keyPEM.path, "-outform", "DER", "-out", certificate.path])
        let der = try run("/usr/bin/openssl", ["rsa", "-in", keyPEM.path, "-outform", "DER"])
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                         kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue()
        }
        return (key, try Data(contentsOf: certificate))
    }

    private func zlib(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let adler = (b << 16) | a
        return Data([0x78, 0x9C]) + deflated + withUnsafeBytes(of: adler.bigEndian) { Data($0) }
    }

    /// A component package by hand: a table with a SHA-1 checksum and an
    /// RSA signature over it, the heap after.
    private func signedXar(tamperTable: Bool = false, tamperSignature: Bool = false) throws -> Data {
        let (key, certificate) = try signer()
        let info = Data("<pkg-info identifier=\"example.sample.signed\" version=\"1.0\" auth=\"root\" install-location=\"/\"/>".utf8)
        let toc = """
            <?xml version="1.0" encoding="UTF-8"?>
            <xar><toc>
            <creation-time>2026-11-14T10:00:00</creation-time>
            <checksum style="sha1"><offset>0</offset><size>20</size></checksum>
            <signature style="RSA"><offset>20</offset><size>256</size>
            <KeyInfo xmlns="http://www.w3.org/2000/09/xmldsig#"><X509Data><X509Certificate>\(certificate.base64EncodedString())</X509Certificate></X509Data></KeyInfo>
            </signature>
            <file id="1"><name>PackageInfo</name><type>file</type>
            <data><offset>276</offset><length>\(info.count)</length><size>\(info.count)</size>
            <encoding style="application/octet-stream"/></data></file>
            </toc></xar>
            """
        var table = try zlib(Data(toc.utf8))
        let digest = Data(Insecure.SHA1.hash(data: table))
        var error: Unmanaged<CFError>?
        guard var signature = SecKeyCreateSignature(key, .rsaSignatureDigestPKCS1v15SHA1, digest as CFData, &error) as Data? else {
            throw error!.takeRetainedValue()
        }
        XCTAssertEqual(signature.count, 256)
        if tamperSignature { signature[10] ^= 0xFF }
        if tamperTable {
            // The same table compressed differently: what it says is the
            // same, but it is not what was signed.
            table = try zlib(Data((toc + " ").utf8))
        }
        var header = Data("xar!".utf8)
        header += withUnsafeBytes(of: UInt16(28).bigEndian) { Data($0) }
        header += withUnsafeBytes(of: UInt16(1).bigEndian) { Data($0) }
        header += withUnsafeBytes(of: UInt64(table.count).bigEndian) { Data($0) }
        header += withUnsafeBytes(of: UInt64(toc.utf8.count).bigEndian) { Data($0) }
        header += withUnsafeBytes(of: UInt32(1).bigEndian) { Data($0) }
        return header + table + digest + signature + info
    }

    func testSignedPackageVerifies() throws {
        let package = try InstallerPackage(url: URL(fileURLWithPath: "/signed.pkg"), data: try signedXar())
        XCTAssertEqual(package.identifier, "example.sample.signed")
        let signature = try XCTUnwrap(package.signature)
        XCTAssertEqual(signature.intact, true)
        XCTAssertEqual(signature.signer.map { X509.shortName($0.subject) }, "Developer ID Installer: Sample (TEAMID1234)")
        let html = PackageReport.html(for: package, size: 1000)
        XCTAssertTrue(html.contains("Developer ID, for distribution outside the App Store"))
        XCTAssertTrue(html.contains("the table of contents hashes as signed"))
        XCTAssertTrue(html.contains("no ticket stapled"))
    }

    func testChangedTableIsCaught() throws {
        let package = try InstallerPackage(url: URL(fileURLWithPath: "/changed.pkg"), data: try signedXar(tamperTable: true))
        XCTAssertEqual(package.signature?.intact, false)
        XCTAssertEqual(package.signature?.problem, "Its table of contents changed after signing.")
        XCTAssertTrue(PackageReport.html(for: package, size: 1000).contains("It changed after it was signed."))
    }

    func testForgedSignatureIsCaught() throws {
        let package = try InstallerPackage(url: URL(fileURLWithPath: "/forged.pkg"), data: try signedXar(tamperSignature: true))
        XCTAssertEqual(package.signature?.intact, false)
        XCTAssertEqual(package.signature?.problem, "Its signature does not verify with the signer's key.")
    }

    func testStapledTicketTrailer() throws {
        var data = try signedXar()
        data += Data(repeating: 0xAB, count: 64) + Data("t8lr".utf8) + Data([0, 1, 0, 1, 0, 0, 0, 64])
        let package = try InstallerPackage(url: URL(fileURLWithPath: "/stapled.pkg"), data: data)
        XCTAssertTrue(package.stapled)
    }

    // MARK: - Pieces

    func testCPIO() {
        // One file in each form: the old portable one and the new one.
        func odc(_ name: String, _ body: String, mode: Int) -> Data {
            let header = "070707" + String(repeating: "0", count: 12) + String(format: "%06o", mode)
                + String(repeating: "0", count: 24) + String(format: "%011o", 0)
                + String(format: "%06o", name.utf8.count + 1) + String(format: "%011o", body.utf8.count)
            return Data(header.utf8) + Data(name.utf8) + Data([0]) + Data(body.utf8)
        }
        let archive = odc("./postinstall", "#!/bin/sh\n", mode: 0o100755) + odc("TRAILER!!!", "", mode: 0)
        let members = CPIO.members(archive)
        XCTAssertEqual(members.map(\.name), ["postinstall"])
        XCTAssertTrue(members[0].isExecutable)
        XCTAssertEqual(String(decoding: members[0].data, as: UTF8.self), "#!/bin/sh\n")

        func newc(_ name: String, _ body: String) -> Data {
            var header = "070701" + String(format: "%08x", 1) + String(format: "%08x", 0o100644)
            header += String(repeating: "0", count: 8 * 4) + String(format: "%08x", body.utf8.count)
            header += String(repeating: "0", count: 8 * 4) + String(format: "%08x", name.utf8.count + 1) + "00000000"
            var data = Data(header.utf8) + Data(name.utf8) + Data([0])
            while data.count % 4 != 0 { data.append(0) }
            data += Data(body.utf8)
            while data.count % 4 != 0 { data.append(0) }
            return data
        }
        let second = CPIO.members(newc("a.txt", "hello") + newc("b.txt", "world!") + newc("TRAILER!!!", ""))
        XCTAssertEqual(second.map(\.name), ["a.txt", "b.txt"])
        XCTAssertEqual(second.map { String(decoding: $0.data, as: UTF8.self) }, ["hello", "world!"])
    }

    func testGzipUsesItsTrailer() throws {
        try write(String(repeating: "line of text\n", count: 500), "plain.txt")
        let gz = folder.appendingPathComponent("plain.txt.gz")
        try run("/usr/bin/gzip", ["-k", folder.appendingPathComponent("plain.txt").path])
        let decoded = Decompress.gzip(try Data(contentsOf: gz), limit: 1 << 20)
        XCTAssertEqual(decoded?.count, 13 * 500)
    }
}

/// Repeatable "random" damage for the robustness tests.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
