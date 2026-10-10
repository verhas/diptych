import XCTest
@testable import Diptych

final class ExifDatabaseTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExifDatabaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private typealias Gear = ExifDatabase.Gear
    private typealias Town = Places.Gazetteer.Town

    private func town(_ id: Int?, _ name: String, _ latitude: Double, manual: Bool = false,
                      disabled: Bool = false) -> Town {
        var town = Town(id: id, name: name, latitude: latitude, longitude: 19,
                        country: "HU", region: "05")
        town.manual = manual
        town.disabled = disabled
        return town
    }

    private var builtIn: ExifDatabase.Lists {
        ExifDatabase.Lists(
            cameras: [Gear(make: "Apple", model: "iPhone X"), Gear(make: "Canon", model: "Canon EOS R5")],
            lenses: [Gear(make: "Canon", model: "RF50mm F1.8 STM")],
            gazetteer: Places.Gazetteer(
                countries: [.init(code: "HU", name: "Hungary")],
                regions: [.init(country: "HU", code: "05", name: "Budapest")],
                towns: [town(1, "Budapest", 47.5), town(2, "Érd", 47.4)]))
    }

    // MARK: - Merging

    func testGearMergeKeepsTheUsersAndAddsTheNew() {
        let file = [Gear(make: "Apple", model: "iPhone X", disabled: true),
                    Gear(make: "Mine", model: "Pinhole")]
        let merged = ExifDatabase.merge(file, builtIn.cameras, renew: false)
        XCTAssertEqual(merged, [Gear(make: "Apple", model: "iPhone X", disabled: true),
                                Gear(make: "Mine", model: "Pinhole"),
                                Gear(make: "Canon", model: "Canon EOS R5")])
    }

    func testPlacesMergeRenewsAllButTheManual() {
        let file = [town(1, "Budapest", 40, disabled: true), town(2, "Erd", 41, manual: true),
                    town(nil, "My village", 46)]
        let ours = [town(1, "Budapest", 47.5), town(2, "Érd", 47.4), town(3, "Vác", 47.8)]
        let merged = ExifDatabase.merge(file, ours, renew: true)
        XCTAssertEqual(merged.map(\.latitude), [47.5, 41, 46, 47.8],
                       "corrected, kept as corrected by hand, added by hand, new")
        XCTAssertTrue(merged[0].disabled, "disabled stays disabled")
        XCTAssertEqual(merged[1].name, "Erd")
        XCTAssertFalse(merged[3].disabled)
    }

    // MARK: - The files

    private func prepare(_ version: String) -> ExifDatabase.Lists {
        ExifDatabase.prepare(in: directory, version: version, builtIn: builtIn)
    }

    private func text(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testTheFirstStartWritesTheLists() throws {
        let lists = prepare("1.8.0")
        XCTAssertEqual(lists.problems, [])
        XCTAssertEqual(lists.cameras, builtIn.cameras)
        let cameras = try text("cameras.json")
        XCTAssertTrue(cameras.contains("\"version\": \"1.8.0\""))
        XCTAssertTrue(cameras.contains("\n    {\"disabled\":false,\"make\":\"Apple\",\"model\":\"iPhone X\"}"),
                      "one item a line")
        let places = try text("places.json")
        XCTAssertTrue(places.contains("\"manual\":false"), "manual is there to be set")
        XCTAssertTrue(places.contains("\"name\":\"Érd\""))
        XCTAssertEqual(prepare("1.8.0").gazetteer, builtIn.gazetteer, "read back the same")
    }

    func testTheSameVersionOnlyReads() throws {
        _ = prepare("1.8.0")
        try write("cameras.json", """
            {"version": "1.8.0", "items": [{"make": "Mine", "model": "Pinhole"}]}
            """)
        XCTAssertEqual(prepare("1.8.0").cameras, [Gear(make: "Mine", model: "Pinhole")],
                       "nothing added, and disabled may be left out")
        XCTAssertFalse(try text("cameras.json").contains("Apple"), "not written")
    }

    func testANewVersionMerges() throws {
        _ = prepare("1.8.0")
        try write("cameras.json", """
            {"version": "1.8.0", "items": [{"make": "Apple", "model": "iPhone X", "disabled": true}]}
            """)
        try write("places.json", """
            {"version": "1.8.0", "countries": [], "regions": [],
             "towns": [{"id": 1, "name": "Pest", "latitude": 1, "longitude": 2, "manual": true},
                       {"id": 2, "name": "Erd", "latitude": 1, "longitude": 2, "disabled": true}]}
            """)
        let lists = prepare("1.9.0")
        XCTAssertEqual(lists.cameras, [Gear(make: "Apple", model: "iPhone X", disabled: true),
                                       Gear(make: "Canon", model: "Canon EOS R5")])
        XCTAssertEqual(lists.gazetteer.towns.map(\.name), ["Pest", "Érd"])
        XCTAssertEqual(lists.gazetteer.towns[1].latitude, 47.4)
        XCTAssertTrue(lists.gazetteer.towns[1].disabled)
        XCTAssertEqual(lists.gazetteer.countries.map(\.code), ["HU"])
        XCTAssertTrue(try text("cameras.json").contains("\"version\": \"1.9.0\""))
    }

    func testABrokenFileIsLeftAndTold() throws {
        try write("lenses.json", "{\"version\": \"1.8.0\", \"items\": [")
        let lists = prepare("1.9.0")
        XCTAssertEqual(lists.lenses, builtIn.lenses, "the version's own list instead")
        XCTAssertEqual(lists.problems.count, 1)
        XCTAssertTrue(lists.problems[0].path.hasSuffix("/lenses.json"))
        XCTAssertTrue(lists.problems[0].message.hasPrefix("it is not JSON"))
        XCTAssertEqual(try text("lenses.json"), "{\"version\": \"1.8.0\", \"items\": [")
    }

    // MARK: - Using them

    func testDisabledTownsAreNotUsed() {
        var gazetteer = builtIn.gazetteer
        XCTAssertEqual(Places(gazetteer).nearest(latitude: 47.5, longitude: 19)?.city, "Budapest")
        gazetteer.towns[0].disabled = true
        XCTAssertEqual(Places(gazetteer).nearest(latitude: 47.5, longitude: 19)?.city, "Érd")
        gazetteer.countries[0].disabled = true
        XCTAssertNil(Places(gazetteer).nearest(latitude: 47.5, longitude: 19)?.country)
    }

    func testTheBundledListHasIds() {
        let towns = Places.builtIn.towns
        XCTAssertGreaterThan(towns.count, 20_000)
        XCTAssertTrue(towns.allSatisfy { $0.id != nil })
        XCTAssertEqual(Set(towns.map(\.id)).count, towns.count, "an id is one town")
    }

    func testValuesOffered() {
        var lists = builtIn
        lists.cameras.append(Gear(make: "Apple", model: "iPhone 15", disabled: true))
        let make = ExifKey(group: .tiff, name: "Make")
        let model = ExifKey(group: .tiff, name: "Model")
        XCTAssertTrue(ExifDatabase.offers(model))
        XCTAssertEqual(ExifDatabase.values(for: make, in: lists), ["Apple", "Canon"])
        XCTAssertEqual(ExifDatabase.values(for: model, make: "apple", in: lists), ["iPhone X"],
                       "the make's models, not the disabled one")
        XCTAssertEqual(ExifDatabase.values(for: model, make: "Leica", in: lists),
                       ["iPhone X", "Canon EOS R5"], "a make not listed: every model")
        XCTAssertEqual(ExifDatabase.values(for: ExifKey(group: .exif, name: "LensModel"),
                                           make: "", in: lists), ["RF50mm F1.8 STM"])
        XCTAssertEqual(ExifDatabase.values(for: ExifKey(group: .tiff, name: "Artist"), in: lists), [])
    }

    func testTheBuiltInListsAreWhole() {
        XCTAssertEqual(Set(ExifGearList.cameras).count, ExifGearList.cameras.count, "no twice")
        XCTAssertEqual(Set(ExifGearList.lenses).count, ExifGearList.lenses.count)
        XCTAssertTrue(ExifGearList.cameras.contains(Gear(make: "Apple", model: "iPhone X")))
    }

    func testTypingNarrowsTheValues() {
        let values = ["Canon EOS R5", "Canon EOS R6", "NIKON Z 6", "Sony R6 copy"]
        XCTAssertEqual(SuggestingField.matches("", in: values), values)
        XCTAssertEqual(SuggestingField.matches("canon eos r", in: values),
                       ["Canon EOS R5", "Canon EOS R6"])
        XCTAssertEqual(SuggestingField.matches("R6", in: values), ["Canon EOS R6", "Sony R6 copy"])
        XCTAssertEqual(SuggestingField.matches("z 6", in: values), ["NIKON Z 6"])
    }

    // MARK: - Saved expressions under a name no longer allowed

    func testANameNoLongerAllowedIsIgnoredAndTold() throws {
        try write("image.json", """
            {"name": "image", "expression": "name = \\"*.jpg\\"", "saved": "2026-01-01T00:00:00Z", "history": []}
            """)
        try write("big.json", """
            {"name": "big", "expression": "size > 1MB", "saved": "2026-01-01T00:00:00Z", "history": []}
            """)
        try write("junk.json", "not json")
        let (found, ignored) = FlatFilterStore.read(directory)
        XCTAssertEqual(Array(found.keys), ["big"])
        XCTAssertEqual(ignored.map(\.name), ["image", nil], "by path: image, then junk")
        let message = StartupWarnings.ignoredText(ignored)
        XCTAssertTrue(message.contains("The name \u{201C}image\u{201D} is not allowed."))
        XCTAssertTrue(message.contains(directory.appendingPathComponent("image.json").path))
        XCTAssertTrue(message.contains(directory.appendingPathComponent("junk.json").path))
        XCTAssertTrue(message.contains("These files are ignored."))

        let store = FlatFilterStore(directory: directory)
        XCTAssertEqual(store.takeIgnored().count, 2)
        XCTAssertEqual(store.takeIgnored(), [], "told once")
    }
}
