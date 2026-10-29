import XCTest
@testable import Diptych

/// What `~/.ssh/config` says for a host, the keep-alive interval that results,
/// and the sign-in that is forgotten when a connection closes.
final class SSHConfigTests: XCTestCase {

    private func config(_ text: String) -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-config-\(UUID().uuidString)")
        try! text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testTheFirstValueForAHostWinsAndAllowedBlocksApply() {
        let file = config("""
        # comment
        Host javax0.internet-box.ch
          ServerAliveInterval 30
        Host *
          ServerAliveInterval 60
          UseKeychain yes
        """)
        XCTAssertEqual(SSHConfig.serverAliveInterval(for: "javax0.internet-box.ch", file: file), 30)
        XCTAssertEqual(SSHConfig.serverAliveInterval(for: "other", file: file), 60)
        XCTAssertEqual(SSHConfig.value(of: "UseKeychain", for: "other", file: file), "yes")
    }

    func testNegatedAndEqualsSyntaxAndMatchBlocksAreRespected() {
        let file = config("""
        Host *.lan !gate.lan
          ServerAliveInterval=15
        Match host other
          ServerAliveInterval 5
        """)
        XCTAssertEqual(SSHConfig.serverAliveInterval(for: "nas.lan", file: file), 15)
        XCTAssertNil(SSHConfig.serverAliveInterval(for: "gate.lan", file: file))
        XCTAssertNil(SSHConfig.serverAliveInterval(for: "other", file: file))
    }

    func testNoConfigFileSaysNothing() {
        XCTAssertNil(SSHConfig.serverAliveInterval(for: "nas", file: URL(fileURLWithPath: "/nonexistent")))
    }

    func testDiptychsOwnSettingOverridesTheSSHConfiguration() {
        XCTAssertEqual(SFTPKeepAlive.interval(host: "nas", override: 5), .seconds(5))
        XCTAssertNil(SFTPKeepAlive.interval(host: "nas", override: 0))
    }

    func testAMinuteWhenNeitherSaysAnything() {
        XCTAssertEqual(SFTPKeepAlive.interval(host: "no-such-host-\(UUID().uuidString)", override: nil),
                       .seconds(60))
    }

    func testAForgottenSignInIsNoLongerThere() {
        let credential = SFTPCredential(.password("secret"))
        XCTAssertNotNil(credential.login)
        credential.forget()
        XCTAssertNil(credential.login)
    }

    func testHostPatternsMatchAsOpenSSHMatchesThem() {
        XCTAssertTrue(HostPattern.matches("*.internet-box.ch", "javax0.internet-box.ch"))
        XCTAssertTrue(HostPattern.matches("a?c", "abc"))
        XCTAssertTrue(HostPattern.matches("[nas]:22", "[nas]:22"))
        XCTAssertFalse(HostPattern.matches("nas", "nas2"))
    }
}
