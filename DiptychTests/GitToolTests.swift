import XCTest
@testable import Diptych

/// Finding and running the user's git.
final class GitToolTests: XCTestCase {

    func testTheFoundGitAnswersLikeGit() throws {
        let found = try XCTUnwrap(GitTool.locate(override: nil),
                                  "no git on this machine; the rest of these cannot run")
        XCTAssertTrue(found.version.hasPrefix("git version "))
        XCTAssertFalse(found.signature.isEmpty, "the signature is always reported, even as none")
    }

    func testAnOverrideThatIsNotAProgramIsRefused() {
        XCTAssertNil(GitTool.probe(URL(fileURLWithPath: "/etc/hosts")),
                     "a file that cannot be run is not git")
        XCTAssertNil(GitTool.probe(URL(fileURLWithPath: "/nowhere/git")))
    }

    func testSomethingThatIsNotGitIsRefusedEvenThoughItRuns() {
        // The check is weak by design -- anything can print "git version" --
        // but it must at least reject a program that plainly is not git.
        XCTAssertNil(GitTool.probe(URL(fileURLWithPath: "/bin/echo")))
    }

    func testAFailingCommandKeepsGitsOwnWords() throws {
        let git = try XCTUnwrap(GitTool.locate(override: nil))
        let outcome = GitTool.run(["rev-parse", "--show-toplevel"], executable: git.url,
                                  in: URL(fileURLWithPath: "/"), timeout: 10)

        guard case .failed(let status, let text) = outcome else {
            return XCTFail("/ is not a repository, so this should fail: \(outcome)")
        }
        XCTAssertNotEqual(status, 0)
        XCTAssertTrue(text.lowercased().contains("not a git repository"),
                      "the message is git's own, not a paraphrase: \(text)")
    }

    func testOutputLargerThanAPipeBufferIsNotADeadlock() throws {
        // Reading only after the process exits deadlocks past 64 KB: it cannot
        // exit until someone drains the pipe. A repo-wide status passes that
        // easily.
        let outcome = GitTool.run(["-c", "for i in $(seq 20000); do echo aaaaaaaaaaaaaaaaaaaa; done"],
                                  executable: URL(fileURLWithPath: "/bin/sh"),
                                  in: nil, timeout: 30)

        guard case .ok(let text) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertGreaterThan(text.count, 400_000)
    }

    func testACommandThatHangsIsStopped() {
        let started = Date()
        let outcome = GitTool.run(["-c", "sleep 30"],
                                  executable: URL(fileURLWithPath: "/bin/sh"),
                                  in: nil, timeout: 1)

        guard case .timedOut = outcome else { return XCTFail("\(outcome)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "a stuck repository must not hold a pane for ever")
    }

    func testTheEnvironmentForbidsPromptingAndIndexWrites() throws {
        let outcome = GitTool.run(["-c", "echo $GIT_TERMINAL_PROMPT $GIT_OPTIONAL_LOCKS $LC_ALL"],
                                  executable: URL(fileURLWithPath: "/bin/sh"),
                                  in: nil, timeout: 10)

        guard case .ok(let text) = outcome else { return XCTFail("\(outcome)") }
        // No prompting: there is no terminal to prompt on and a blocked git
        // would hold the pane's decoration for ever. No optional locks: a
        // read-only status must not fight a git the user runs in a terminal.
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "0 0 C")
    }
}
