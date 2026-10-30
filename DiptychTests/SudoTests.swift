import XCTest
@testable import Diptych

/// What sudo said, how long a password is kept, and how a word is quoted for
/// the server's shell.
final class SudoTests: XCTestCase {

    func testSudosWordsAreRead() {
        XCTAssertEqual(SudoOutcome.reading("sudo: a password is required\n"), .needsPassword)
        XCTAssertEqual(SudoOutcome.reading("Sorry, try again.\nsudo: 1 incorrect password attempt"),
                       .wrongPassword)
        XCTAssertEqual(SudoOutcome.reading("peter is not in the sudoers file."),
                       .notAllowed("peter is not in the sudoers file."))
        XCTAssertEqual(SudoOutcome.reading("chown: invalid user"), .failed("chown: invalid user"))
    }

    func testAPasswordIsKeptAsLongAsChosenAndNoLonger() {
        let passwords = SudoPasswords()
        let now = Date(timeIntervalSince1970: 1_000)
        passwords.keep("a", for: "s", .fiveMinutes, now: now)
        XCTAssertEqual(passwords.password(for: "s", now: now.addingTimeInterval(299)), "a")
        XCTAssertNil(passwords.password(for: "s", now: now.addingTimeInterval(301)))

        passwords.keep("b", for: "s", .once, now: now)
        XCTAssertNil(passwords.password(for: "s", now: now))

        passwords.keep("c", for: "s", .untilDisconnected, now: now)
        XCTAssertEqual(passwords.password(for: "s", now: now.addingTimeInterval(1_000_000)), "c")
        passwords.forget("s")
        XCTAssertNil(passwords.password(for: "s", now: now))
    }

    func testAQuotedWordCannotBreakOutOfItsQuotes() {
        XCTAssertEqual(shellQuoted("plain"), "'plain'")
        XCTAssertEqual(shellQuoted("it's; rm -rf /"), "'it'\\''s; rm -rf /'")
    }
}
