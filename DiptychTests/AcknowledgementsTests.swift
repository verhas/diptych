import XCTest
@testable import Diptych

/// Every package built into Diptych has its licence in the Acknowledgements
/// window: `Licenses.json` lists what `Package.resolved` does, at the same
/// versions. Failing, run `./make-licenses.sh`.
final class AcknowledgementsTests: XCTestCase {

    /// Resolved, but only used while building; nothing of it ships.
    private let buildOnly: Set<String> = ["swift-argument-parser"]

    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testEveryPackageResolvedHasItsLicence() throws {
        let resolvedURL = repository.appendingPathComponent(
            "Diptych.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let resolved = try JSONSerialization.jsonObject(with: Data(contentsOf: resolvedURL))
            as! [String: Any]
        var wanted: [String: String] = [:]
        for pin in resolved["pins"] as! [[String: Any]] {
            let identity = pin["identity"] as! String
            guard !buildOnly.contains(identity) else { continue }
            let state = pin["state"] as! [String: Any]
            wanted[identity] = state["version"] as? String
        }
        let listed = try JSONDecoder().decode(
            [Acknowledgements.Package].self,
            from: Data(contentsOf: repository.appendingPathComponent("Diptych/Licenses.json")))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: listed.map { ($0.id, $0.version) }), wanted,
                       "run ./make-licenses.sh")
        for package in listed {
            XCTAssertFalse(package.files.isEmpty, package.name)
            XCTAssertTrue(package.files.allSatisfy { $0.text.count > 200 }, package.name)
            XCTAssertNotEqual(package.license, "See the text", package.name)
        }
    }

    func testTheLicencesAreInTheApp() {
        let packages = Acknowledgements.packages
        XCTAssertGreaterThan(packages.count, 10)
        XCTAssertTrue(packages.contains { $0.id == "libwebp-xcode" && $0.license.hasPrefix("BSD") })
    }
}
