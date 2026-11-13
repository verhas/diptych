import XCTest
import MCP
@testable import Diptych

/// The commands every way into Diptych shares -- MCP, App Intents -- and the
/// settings they may read and change.
@MainActor
final class DiptychCommandsTests: XCTestCase {

    private var saved: Configuration!

    override func setUp() async throws {
        saved = ConfigStore.shared.configuration
    }

    override func tearDown() async throws {
        ConfigStore.shared.configuration = saved
    }

    func testABooleanSettingTakesTrueFalseAndTheirWords() throws {
        let item = try XCTUnwrap(DiptychSettings.item(for: "foldersFirst"))
        XCTAssertNil(item.set(.bool(false)))
        XCTAssertEqual(item.get(), .bool(false))
        // Some clients send a boolean as a word.
        XCTAssertNil(item.set(.string("TRUE")))
        XCTAssertEqual(item.get(), .bool(true))
        XCTAssertNotNil(item.set(.string("maybe")))
        XCTAssertEqual(item.get(), .bool(true), "a refused value changes nothing")
    }

    func testAChoiceTakesOnlyItsOwnWords() throws {
        let item = try XCTUnwrap(DiptychSettings.item(for: "clipboardImageFormat"))
        let allowed = try XCTUnwrap(item.allowedValues)
        XCTAssertNil(item.set(.string(allowed[0])))
        XCTAssertEqual(item.get(), .string(allowed[0]))
        XCTAssertNotNil(item.set(.string("no such format")))
        XCTAssertNotNil(item.set(.bool(true)))
    }

    /// What lets anything in from outside is never among what is let in.
    func testTheSwitchesThatLetThingsInAreNotSettings() {
        let keys = Set(DiptychSettings.items.map(\.key))
        for forbidden in ["mcpServerEnabled", "mcpServerPort", "appIntentsEnabled"] {
            XCTAssertFalse(keys.contains(forbidden), forbidden)
        }
    }

    func testKeysAreUnique() {
        let keys = DiptychSettings.items.map(\.key)
        XCTAssertEqual(keys.count, Set(keys).count)
    }

    func testMCPValuesBecomeSettingValuesAndBack() {
        XCTAssertEqual(MCPModels.setting(.bool(true)), .bool(true))
        XCTAssertEqual(MCPModels.setting(.string("x")), .string("x"))
        XCTAssertNil(MCPModels.setting(.int(3)))
        XCTAssertEqual(MCPModels.value(.bool(false)), .bool(false))
        XCTAssertEqual(MCPModels.value(.string("y")), .string("y"))
    }

    func testRunListBoundsAreKept() {
        let list = DiptychCommands.runList(from: -5, to: 10_000)
        XCTAssertLessThanOrEqual(list.runs.count, 100)
        XCTAssertTrue(list.runs.allSatisfy { $0.index >= 1 })
    }
}
