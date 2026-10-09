import XCTest
@testable import Diptych

/// The circle between Back and Forward: every folder visited, most recent
/// first, each once.
final class RecentFoldersTests: XCTestCase {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private func visit(_ paths: [String]) -> [String] {
        paths.reduce([URL]()) { PaneModel.remembering(url($1), in: $0) }.map(\.path)
    }

    /// A, B, C, back to B, on to D, back to B: Back and Forward have lost C,
    /// the recent list has not.
    func testAFolderLeftBehindByGoingBackIsStillThere() {
        XCTAssertEqual(visit(["/A", "/B", "/C", "/B", "/D", "/B"]), ["/B", "/D", "/C", "/A"])
    }

    func testAFolderVisitedAgainMovesToTheFrontOnlyOnce() {
        XCTAssertEqual(visit(["/A", "/B", "/A", "/A"]), ["/A", "/B"])
    }

    func testATrailingSlashIsTheSameFolder() {
        let recent = PaneModel.remembering(URL(fileURLWithPath: "/A/", isDirectory: true),
                                           in: [url("/A"), url("/B")])
        XCTAssertEqual(recent.map(\.path), ["/A", "/B"])
    }

    func testTheListIsKeptShort() {
        let many = (0..<50).map { "/F\($0)" }
        let recent = visit(many)
        XCTAssertEqual(recent.count, PaneModel.recentLimit)
        XCTAssertEqual(recent.first, "/F49")
    }

    /// A session saved before the list existed still loads, with an empty list.
    func testAnOlderSavedPaneLoads() throws {
        let json = #"{"directory":"/Users","sortField":"name","sortAscending":true}"#
        let state = try JSONDecoder().decode(PaneState.self, from: Data(json.utf8))
        XCTAssertEqual(state.directory, "/Users")
        XCTAssertEqual(state.recent, [])
    }

    func testTheListIsSavedWithThePane() throws {
        let state = PaneState(directory: "/A", recent: ["/A", "/B"])
        let back = try JSONDecoder().decode(PaneState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back.recent, ["/A", "/B"])
    }
}
