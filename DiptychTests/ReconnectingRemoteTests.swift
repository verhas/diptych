import XCTest
@testable import Diptych

/// The server connection that keeps itself alive and makes a new connection
/// when the old one has died, against scripted connections.
final class ReconnectingRemoteTests: XCTestCase {

    private struct Broken: Error {}

    /// A connection that fails its first `failures` calls, then answers.
    final class Scripted: RemoteListing, @unchecked Sendable {
        var failures: Int
        let listed: [SFTPEntry]
        init(failures: Int, listed: [SFTPEntry] = []) {
            self.failures = failures
            self.listed = listed
        }
        private func attempt() throws {
            if failures > 0 {
                failures -= 1
                throw Broken()
            }
        }
        func entries(in path: String) async throws -> [SFTPEntry] {
            try attempt()
            return listed
        }
        func download(_ path: String, to destination: URL) async throws { try attempt() }
        func makeDirectory(_ path: String) async throws { try attempt() }
        func removeFile(_ path: String) async throws { try attempt() }
        func removeDirectory(_ path: String) async throws { try attempt() }
        func rename(_ from: String, to: String) async throws { try attempt() }
        func upload(_ local: URL, to path: String) async throws { try attempt() }
        func setPermissions(_ path: String, mode: UInt32) async throws { try attempt() }
        func setOwnership(_ path: String, uid: UInt32, gid: UInt32) async throws { try attempt() }
        func setTimes(_ path: String, modified: Date) async throws { try attempt() }
        func runAsRoot(_ arguments: [String], password: String?) async throws -> SudoOutcome {
            try attempt()
            return .done
        }
    }

    /// Counts how many new connections were made.
    final class Opened: @unchecked Sendable {
        var count = 0
    }

    private static func link(_ remote: RemoteListing, answers: Bool) -> ReconnectingRemote.Link {
        ReconnectingRemote.Link(remote: remote, answers: { answers }, close: {})
    }

    func testARetryOnAConnectionThatDidNotAnswerIsMadeOnANewOne() async throws {
        let opened = Opened()
        let fresh = Scripted(failures: 0, listed: [SFTPEntry(name: "a.txt", kind: .file, size: 3)])
        let remote = ReconnectingRemote(
            link: ReconnectingRemoteTests.link(Scripted(failures: 1), answers: false),
            open: {
                opened.count += 1
                return ReconnectingRemoteTests.link(fresh, answers: true)
            })

        let names = try await remote.entries(in: "/").map(\.name)
        XCTAssertEqual(names, ["a.txt"])
        XCTAssertEqual(opened.count, 1)
    }

    func testAReadThatFailedOnALiveConnectionIsTriedOnceMoreOnANewOne() async throws {
        let opened = Opened()
        let remote = ReconnectingRemote(
            link: ReconnectingRemoteTests.link(Scripted(failures: 1), answers: true),
            open: {
                opened.count += 1
                return ReconnectingRemoteTests.link(Scripted(failures: 0, listed: []), answers: true)
            })

        _ = try await remote.entries(in: "/")
        XCTAssertEqual(opened.count, 1)
    }

    func testAChangeThatFailedOnALiveConnectionIsNotMadeTwice() async {
        let opened = Opened()
        let remote = ReconnectingRemote(
            link: ReconnectingRemoteTests.link(Scripted(failures: 1), answers: true),
            open: {
                opened.count += 1
                return ReconnectingRemoteTests.link(Scripted(failures: 0), answers: true)
            })

        do {
            try await remote.makeDirectory("/new")
            XCTFail("the failure was hidden")
        } catch {
            XCTAssertEqual(opened.count, 0)
        }
    }

    func testAChangeThatFailedOnADeadConnectionIsMadeOnANewOne() async throws {
        let opened = Opened()
        let remote = ReconnectingRemote(
            link: ReconnectingRemoteTests.link(Scripted(failures: 1), answers: false),
            open: {
                opened.count += 1
                return ReconnectingRemoteTests.link(Scripted(failures: 0), answers: true)
            })

        try await remote.makeDirectory("/new")
        XCTAssertEqual(opened.count, 1)
    }

    func testTheCheckDropsAConnectionThatNoLongerAnswers() async throws {
        let opened = Opened()
        let remote = ReconnectingRemote(
            link: ReconnectingRemoteTests.link(Scripted(failures: 0), answers: false),
            open: {
                opened.count += 1
                return ReconnectingRemoteTests.link(Scripted(failures: 0, listed: []), answers: true)
            })

        await remote.checkAlive()
        _ = try await remote.entries(in: "/")
        XCTAssertEqual(opened.count, 1)
    }

    func testAConnectionThatAnswersIsKeptAfterTheCheck() async throws {
        let opened = Opened()
        let remote = ReconnectingRemote(
            link: ReconnectingRemoteTests.link(Scripted(failures: 0, listed: []), answers: true),
            open: {
                opened.count += 1
                return ReconnectingRemoteTests.link(Scripted(failures: 0), answers: true)
            })

        await remote.checkAlive()
        _ = try await remote.entries(in: "/")
        XCTAssertEqual(opened.count, 0)
    }
}
