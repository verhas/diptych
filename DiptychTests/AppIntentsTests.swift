import AppIntents
import XCTest
@testable import Diptych

/// Siri and Shortcuts get what an agent gets, by the same rules: nothing
/// unless switched on, every request in the activity console.
@MainActor
final class AppIntentsTests: XCTestCase {

    private var saved: Configuration!

    override func setUp() async throws {
        saved = ConfigStore.shared.configuration
    }

    override func tearDown() async throws {
        ConfigStore.shared.configuration = saved
    }

    private func refusal(_ body: () async throws -> Void) async -> DiptychIntentError? {
        do {
            try await body()
            return nil
        } catch let error as DiptychIntentError {
            return error
        } catch {
            XCTFail("unexpected \(error)")
            return nil
        }
    }

    func testSwitchedOffNothingIsAnsweredAndTheRefusalIsLogged() async {
        ConfigStore.shared.configuration.appIntentsEnabled = false
        let before = MCPActivityLog.shared.entries.count
        let error = await refusal { _ = try await GetDiptychInfoIntent().perform() }
        guard case .switchedOff = error else { return XCTFail("\(String(describing: error))") }
        let last = MCPActivityLog.shared.entries.last
        XCTAssertEqual(MCPActivityLog.shared.entries.count, before + 1)
        XCTAssertEqual(last?.kind, .rejected)
        XCTAssertEqual(last?.summary, "Siri/Shortcuts: Get Diptych Info")
    }

    func testSwitchedOnItAnswersAndTheCallIsLogged() async throws {
        ConfigStore.shared.configuration.appIntentsEnabled = true
        _ = try await GetDiptychInfoIntent().perform()
        XCTAssertEqual(MCPActivityLog.shared.entries.last?.kind, .call)
        _ = try await ListSettingsIntent().perform()
        XCTAssertEqual(MCPActivityLog.shared.entries.last?.summary, "Siri/Shortcuts: List Settings")
    }

    func testOperationsThatAreNotJSONAreRefusedBeforeAnythingOpens() async {
        ConfigStore.shared.configuration.appIntentsEnabled = true
        let intent = ProposeFileOperationsIntent()
        intent.operations = "move everything"
        let error = await refusal { _ = try await intent.perform() }
        guard case .failed = error else { return XCTFail("\(String(describing: error))") }
    }

    func testOperationsAsJSONAreReadWithTheFieldsAnAgentUses() throws {
        let json = #"[{"op": "move", "source": "/a", "target": "/b", "reason": "tidy"},"#
            + #" {"op": "add_tags", "source": "/c", "tags": ["Red"]}]"#
        guard case .success(let raw) = DiptychCommands.operations(fromJSON: json) else {
            return XCTFail("not read")
        }
        XCTAssertEqual(raw.map(\.op), ["move", "add_tags"])
        XCTAssertEqual(raw[0].target, "/b")
        XCTAssertEqual(raw[0].reason, "tidy")
        XCTAssertEqual(raw[1].tags, ["Red"])
        guard case .failure = DiptychCommands.operations(fromJSON: "[]") else {
            return XCTFail("an empty list proposes nothing")
        }
    }

    func testThePaneViewsAreTheOnesTheCommandsKnow() {
        XCTAssertEqual(Set(PaneViewOption.allCases.map(\.rawValue)),
                       Set(DiptychCommands.PaneView.allCases.map(\.rawValue)))
    }
}
