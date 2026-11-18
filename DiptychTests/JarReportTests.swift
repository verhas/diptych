import XCTest
@testable import Diptych

/// The `.jar` / `.war` preview: manifest, signature, Maven coordinates,
/// module and class versions, read from the zip without unpacking it.
final class JarReportTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("JarReport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func file(_ data: Data, _ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testTheManifestModuleMavenAndClassesAreRead() throws {
        let jar = JarArchive.read(try file(JarFixtures.sample, "sample.jar"))
        XCTAssertNil(jar.trouble)
        XCTAssertEqual(jar.value("Main-Class"), "sample.Hello")
        XCTAssertEqual(jar.value("implementation-version"), "1.2.3", "names are not case-sensitive")
        XCTAssertTrue(jar.isMultiRelease)
        XCTAssertEqual(jar.maven, [.init(group: "dev.diptych.sample", artifact: "hello", version: "1.2.3")])

        let module = try XCTUnwrap(jar.module)
        XCTAssertEqual(module.name, "dev.diptych.sample")
        XCTAssertTrue(module.requires.contains { $0.name == "java.logging" && $0.flags & 0x0020 != 0 })
        XCTAssertEqual(module.exports.map(\.package), ["sample"])

        XCTAssertEqual(jar.classCount, 2, "Hello and Util; module-info and the Java 17 one apart")
        XCTAssertEqual(jar.lowestMajor, 55)
        XCTAssertEqual(jar.highestMajor, 55, "Java 11")
        XCTAssertEqual(jar.releases.map(\.release), [17])
        XCTAssertEqual(jar.releases.first?.classes, 1)
    }

    func testASignedJarIsCheckedAgainstItsSignatureFile() throws {
        let jar = JarArchive.read(try file(JarFixtures.sample, "sample.jar"))
        let signer = try XCTUnwrap(jar.signers.first)
        XCTAssertEqual(jar.signers.count, 1)
        XCTAssertEqual(signer.name, "SAMPLE")
        XCTAssertEqual(signer.signatureValid, true)
        XCTAssertEqual(signer.manifestDigest, true)
        XCTAssertEqual(signer.certificate.map { X509.shortName($0.subject) }, "Diptych Sample Signer")
        XCTAssertEqual(signer.certificate?.isSelfIssued, true)
        XCTAssertGreaterThan(jar.manifestSections, 0, "a section per signed entry")
    }

    func testAManifestChangedAfterSigningIsCaught() throws {
        let jar = JarArchive.read(try file(JarFixtures.tampered, "tampered.jar"))
        XCTAssertEqual(jar.value("Implementation-Version"), "9.9.9")
        XCTAssertEqual(jar.signers.first?.manifestDigest, false)
        let html = JarReport.html(for: jar, listing: nil, url: folder.appendingPathComponent("tampered.jar"), size: nil)
        XCTAssertTrue(html.contains("changed after it was signed"))
    }

    func testAWebApplication() throws {
        let war = JarArchive.read(try file(JarFixtures.war, "sample.war"))
        XCTAssertTrue(war.webXML)
        XCTAssertEqual(war.webLibraries, 1)
        XCTAssertEqual(war.classCount, 2, "WEB-INF/classes count; the library is not opened")
        XCTAssertTrue(war.signers.isEmpty)
        let html = JarReport.html(for: war, listing: nil, url: folder.appendingPathComponent("sample.war"), size: nil)
        XCTAssertTrue(html.contains("Java web application"))
        XCTAssertTrue(html.contains("Not signed"))
    }

    func testThePageSaysWhatMatters() throws {
        let url = try file(JarFixtures.sample, "sample.jar")
        let html = JarReport.html(for: JarArchive.read(url), listing: Listing.archive(at: url), url: url, size: 5567)
        for expected in ["sample.Hello", "dev.diptych.sample:hello:1.2.3", "Java 11", "Java 17",
                         "Diptych Sample Signer", "holds", "Contents", "pom.properties"] {
            XCTAssertTrue(html.contains(expected), expected)
        }
    }

    func testDamagedArchivesDoNotCrash() throws {
        // Every prefix of the archive, and bytes flipped through it.
        let data = JarFixtures.sample
        for cut in stride(from: 0, to: data.count, by: 97) {
            let url = try file(data.prefix(cut), "cut.jar")
            _ = JarReport.html(for: JarArchive.read(url), listing: nil, url: url, size: nil)
        }
        var bytes = [UInt8](data)
        for at in stride(from: 0, to: bytes.count, by: 53) {
            bytes[at] ^= 0xA5
            let url = try file(Data(bytes), "flipped.jar")
            _ = JarReport.html(for: JarArchive.read(url), listing: nil, url: url, size: nil)
        }
        XCTAssertNotNil(JarArchive.read(try file(Data("not a zip".utf8), "x.jar")).trouble)
    }

    func testAZipWithALauncherBeforeItIsRead() throws {
        // A self-running jar: a shell script, then the zip.
        let url = try file(Data("#!/bin/sh\nexec java -jar \"$0\" \"$@\"\n".utf8) + JarFixtures.sample, "run.jar")
        let jar = JarArchive.read(url)
        XCTAssertEqual(jar.value("Main-Class"), "sample.Hello")
        XCTAssertEqual(jar.signers.first?.manifestDigest, true)
    }
}
