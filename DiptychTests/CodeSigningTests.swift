import XCTest
import UniformTypeIdentifiers
@testable import Diptych

/// The Info window's Signature tab: parsing what codesign and spctl say, and
/// reading the real signature of a file.
final class CodeSigningTests: XCTestCase {

    // MARK: - Parsing codesign output

    func testCodesignDisplayIsParsedIntoFields() {
        let display = """
        Executable=/Applications/Example.app/Contents/MacOS/Example
        Identifier=com.example.Example
        Format=app bundle with Mach-O thin (arm64)
        TeamIdentifier=ABCDE12345
        Timestamp=1 Jan 2026 at 12:00:00
        Authority=Developer ID Application: Example Inc (ABCDE12345)
        Authority=Developer ID Certification Authority
        Authority=Apple Root CA
        Signature size=9000
        """
        let report = CodeSigning.parsed(display)
        XCTAssertEqual(report.identifier, "com.example.Example")
        XCTAssertEqual(report.teamIdentifier, "ABCDE12345")
        XCTAssertEqual(report.authorities.first, "Developer ID Application: Example Inc (ABCDE12345)")
        XCTAssertEqual(report.authorities.count, 3)
        XCTAssertEqual(report.timestamp, "1 Jan 2026 at 12:00:00")
        XCTAssertFalse(report.adhoc)
    }

    func testAdhocAndUnsetTeamAreRecognised() {
        let report = CodeSigning.parsed("Identifier=a.out\nTeamIdentifier=not set\nSignature=adhoc\n")
        XCTAssertTrue(report.adhoc)
        XCTAssertNil(report.teamIdentifier)      // "not set" is no team
        XCTAssertEqual(report.identifier, "a.out")
    }

    func testGatekeeperSourceIsReadAndRejectionNoticed() {
        let accepted = """
        /Applications/Example.app: accepted
        source=Notarized Developer ID
        origin=Developer ID Application: Example Inc (ABCDE12345)
        """
        XCTAssertEqual(CodeSigning.source(in: accepted), "Notarized Developer ID")

        let rejected = "/tmp/thing: rejected"
        XCTAssertEqual(CodeSigning.source(in: rejected), "rejected")
    }

    // MARK: - Reading a real file

    func testAnUnsignedFileIsReportedUnsigned() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unsigned-\(UUID().uuidString).txt")
        try Data("plain text, no signature".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let report = CodeSigning.report(for: url)
        XCTAssertFalse(report.signed)
        XCTAssertNil(report.valid)
        XCTAssertTrue(report.summary.localizedCaseInsensitiveContains("not code-signed"))
    }

    func testASystemBinaryIsSignedAndVerifies() throws {
        // /bin/ls ships signed by Apple; this confirms the tools are driven and
        // parsed, not just the canned strings.
        let report = CodeSigning.report(for: URL(fileURLWithPath: "/bin/ls"))
        try XCTSkipUnless(report.signed, "codesign unavailable or /bin/ls unsigned in this environment")
        XCTAssertEqual(report.valid, true)
        XCTAssertNotNil(report.identifier)
        XCTAssertFalse(report.authorities.isEmpty)
    }
}
