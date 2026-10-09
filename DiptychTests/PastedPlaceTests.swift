import ImageIO
import XCTest
@testable import Diptych

/// A place pasted into Latitude or Longitude, as Google Maps copies it.
final class PastedPlaceTests: XCTestCase {

    private typealias Location = ExifEditorModel.Location

    private func assertNear(_ found: Location?, _ latitude: Double, _ longitude: Double,
                            within: Double = 1e-6, file: StaticString = #filePath,
                            line: UInt = #line) {
        guard let found else { return XCTFail("no place", file: file, line: line) }
        XCTAssertEqual(found.latitude, latitude, accuracy: within, file: file, line: line)
        XCTAssertEqual(found.longitude, longitude, accuracy: within, file: file, line: line)
    }

    private func coordinates(_ text: String) -> Location? {
        guard case .coordinates(let location)? = PastedPlace.recognize(text) else { return nil }
        return location
    }

    func testAPairAsGoogleMapsCopiesIt() {
        assertNear(coordinates("47.469405929393155, 8.673649728835294"),
                   47.469405929393155, 8.673649728835294)
        assertNear(coordinates(" -33.8568,151.2153 \n"), -33.8568, 151.2153)
        assertNear(coordinates("47.4694 8.6736"), 47.4694, 8.6736)
    }

    func testAPairInDegreesMinutesAndSeconds() {
        assertNear(coordinates("47\u{00B0}28'09.9\"N 8\u{00B0}40'25.1\"E"),
                   47 + 28 / 60.0 + 9.9 / 3600, 8 + 40 / 60.0 + 25.1 / 3600)
        assertNear(coordinates("33\u{00B0}51'24.5\"S 151\u{00B0}12'55.1\"W"),
                   -(33 + 51 / 60.0 + 24.5 / 3600), -(151 + 12 / 60.0 + 55.1 / 3600))
    }

    func testOneCoordinateIsNoPlace() {
        XCTAssertNil(PastedPlace.recognize("47.469405"))
        XCTAssertNil(PastedPlace.recognize("47\u{00B0} 28.165\u{2032}"))
        XCTAssertNil(PastedPlace.recognize("91.5, 8.6"), "no latitude is 91.5")
        XCTAssertNil(PastedPlace.recognize("hello world"))
    }

    func testALinkAndAPlusCodeAreRecognized() {
        XCTAssertEqual(PastedPlace.recognize("https://maps.app.goo.gl/BRrKKPmumyXESAZ88"),
                       .link(URL(string: "https://maps.app.goo.gl/BRrKKPmumyXESAZ88")!))
        XCTAssertEqual(PastedPlace.recognize("FM9F+MFR Brütten"),
                       .plusCode("FM9F+MFR", locality: "Brütten"))
        XCTAssertEqual(PastedPlace.recognize("fm9f+mfr, Brütten, Switzerland"),
                       .plusCode("FM9F+MFR", locality: "Brütten, Switzerland"))
        XCTAssertEqual(PastedPlace.recognize("8FVCFM9F+MFR"),
                       .plusCode("8FVCFM9F+MFR", locality: nil))
    }

    func testThePlaceInAMapLink() {
        // Where maps.app.goo.gl/BRrKKPmumyXESAZ88 redirects.
        assertNear(PastedPlace.location(inLink: "https://www.google.com/maps/search/"
                                        + "47.469428,+8.673682?entry=tts&g_ep=EgoyMDI2"),
                   47.469428, 8.673682)
        assertNear(PastedPlace.location(inLink: "https://www.google.com/maps/place/Br%C3%BCtten/"
                                        + "@47.47,8.66,15z/data=!3m1!4b1!4m6!3m5!3d47.4731!4d8.6754"),
                   47.4731, 8.6754, within: 1e-9)
        assertNear(PastedPlace.location(inLink: "https://www.google.com/maps/@47.47,8.66,15z"),
                   47.47, 8.66)
        assertNear(PastedPlace.location(inLink: "https://maps.apple.com/?ll=47.4694,8.6736&q=Pin"),
                   47.4694, 8.6736)
        // Wrapped in a consent page's own link.
        assertNear(PastedPlace.location(inLink: "https://consent.google.com/ml?continue="
                                        + "https://www.google.com/maps/search/47.469428,%2B8.673682"),
                   47.469428, 8.673682)
        XCTAssertNil(PastedPlace.location(inLink: "https://maps.app.goo.gl/BRrKKPmumyXESAZ88"))
    }

    func testAFullPlusCode() {
        XCTAssertEqual(PlusCode.encode(Location(latitude: 47.469405, longitude: 8.673649))
            .prefix(8), "8FVCFM9F")
        assertNear(PlusCode.decode("8FVCFM9F+MFR"), 47.469405, 8.673649, within: 2e-4)
        XCTAssertNil(PlusCode.decode("FM9F+MFR"), "short: it needs its town")
    }

    /// The town's own code gives the digits left off the front.
    func testAShortPlusCodeNearItsTown() {
        let brutten = Location(latitude: 47.4733, longitude: 8.6750)
        assertNear(PlusCode.recover("FM9F+MFR", near: brutten), 47.469405, 8.673649, within: 2e-4)
        // A town just over the edge of the place's cell, in the one south of
        // it: the place is still the nearer match, not the town's own cell's.
        assertNear(PlusCode.recover("FM9F+MFR", near: Location(latitude: 46.99, longitude: 8.6)),
                   47.469405, 8.673649, within: 2e-4)
    }

    func testThePlusCodeForTheWholeCodeNeedsNoNetwork() async throws {
        assertNear(try await PastedPlace.plusCode("8FVCFM9F+MFR", locality: nil).resolve(),
                   47.469405, 8.673649, within: 2e-4)
        do {
            _ = try await PastedPlace.plusCode("FM9F+MFR", locality: nil).resolve()
            XCTFail("a short code with no town")
        } catch PastedPlace.Failure.shortCodeWithoutPlace {}
    }
}
