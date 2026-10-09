import CoreLocation
import Foundation

/// A place pasted into Latitude or Longitude, as a map app copies it: a
/// coordinate pair, a link, or a plus code. All four location fields are
/// filled from it.
enum PastedPlace: Equatable {
    /// `47.469405929393155, 8.673649728835294`, or `47°28'09.9"N 8°40'25.1"E`.
    case coordinates(ExifEditorModel.Location)
    /// `https://maps.app.goo.gl/BRrKKPmumyXESAZ88`, or a whole map URL.
    case link(URL)
    /// `FM9F+MFR Brütten`, or `8FVCFM9F+MFR` with nothing after it.
    case plusCode(String, locality: String?)

    /// What the pasted text is, or nil for text that is none of them -- one
    /// coordinate, say, which is pasted as it is.
    nonisolated static func recognize(_ text: String) -> PastedPlace? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let location = pair(text) { return .coordinates(location) }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https", url.host != nil {
            return .link(url)
        }
        if let match = text.wholeMatch(of: plusCodePattern),
           let code = match.output[1].substring {
            let locality = match.output[2].substring
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            return .plusCode(String(code).uppercased(),
                             locality: locality?.isEmpty == false ? locality : nil)
        }
        return nil
    }

    enum Failure: LocalizedError {
        case noPlaceInLink
        case shortCodeWithoutPlace
        case badPlusCode
        case unknownPlace(String)

        var errorDescription: String? {
            switch self {
            case .noPlaceInLink:
                "No coordinates in that link"
            case .shortCodeWithoutPlace:
                "A short plus code needs its town after it, as Google Maps copies it"
            case .badPlusCode:
                "Not a plus code"
            case .unknownPlace(let place):
                "\u{201C}\(place)\u{201D} could not be found, to place the plus code"
            }
        }
    }

    /// Where it is. A short link is followed to the map URL it stands for,
    /// and a short plus code needs its town looked up: both ask the network.
    func resolve() async throws -> ExifEditorModel.Location {
        switch self {
        case .coordinates(let location):
            return location
        case .link(let url):
            if let location = Self.location(inLink: url.absoluteString) { return location }
            return try await Self.follow(url)
        case .plusCode(let code, let locality):
            if PlusCode.isFull(code) {
                guard let location = PlusCode.decode(code) else { throw Failure.badPlusCode }
                return location
            }
            guard let locality else { throw Failure.shortCodeWithoutPlace }
            let near = try await Self.geocode(locality)
            guard let location = PlusCode.recover(code, near: near) else {
                throw Failure.badPlusCode
            }
            return location
        }
    }

    // MARK: - Pairs

    nonisolated private static let number = #"-?\d{1,3}(?:\.\d+)?"#

    /// Two coordinates: decimal and comma separated, or each with its N/S or
    /// E/W letter, written any way a single coordinate may be.
    nonisolated static func pair(_ text: String) -> ExifEditorModel.Location? {
        let decimal = try! Regex(#"^\s*(\#(number))\s*[,;]?\s+(\#(number))\s*$|^\s*(\#(number))\s*[,;]\s*(\#(number))\s*$"#)
        if let match = text.wholeMatch(of: decimal) {
            let found = (1...4).compactMap { match.output[$0].substring.map(String.init) }
            if found.count == 2, let latitude = Double(found[0]), let longitude = Double(found[1]) {
                return valid(latitude, longitude)
            }
        }
        // 47°28'09.9"N 8°40'25.1"E -- or with the letters first.
        let lettered = try! Regex(#"^\s*([^,;]*?[NSns])\s*[,;]?\s*([^,;]*?[EWew])\s*$|^\s*([NSns][^,;]*?)\s*[,;]?\s*([EWew][^,;]*?)\s*$"#)
        if let match = text.wholeMatch(of: lettered) {
            let found = (1...4).compactMap { match.output[$0].substring.map(String.init) }
            if found.count == 2,
               let latitude = ExifFields.coordinate(from: found[0], latitude: true),
               let longitude = ExifFields.coordinate(from: found[1], latitude: false) {
                return valid(latitude.hemisphere == "S" ? -latitude.degrees : latitude.degrees,
                             longitude.hemisphere == "W" ? -longitude.degrees : longitude.degrees)
            }
        }
        return nil
    }

    nonisolated private static func valid(_ latitude: Double,
                                          _ longitude: Double) -> ExifEditorModel.Location? {
        abs(latitude) <= 90 && abs(longitude) <= 180
            ? ExifEditorModel.Location(latitude: latitude, longitude: longitude) : nil
    }

    // MARK: - Links

    /// The place in a map URL -- Google's `/search/47.46,+8.67`, `@47.46,8.67`
    /// and `!3d47.46!4d8.67`, Apple's `?ll=47.46,8.67`, and `?q=` in either --
    /// also when the URL is wrapped in another, as a consent page does.
    nonisolated static func location(inLink link: String) -> ExifEditorModel.Location? {
        var text = link
        for _ in 0..<3 { text = text.removingPercentEncoding ?? text }
        let n = #"(-?\d{1,3}(?:\.\d+)?)"#
        let patterns = [
            // The place itself; the @ is where the map was looking.
            #"!3d\#(n)!4d\#(n)"#,
            #"[?&](?:q|query|ll|sll|center|destination|daddr)=\+?\#(n)\s*,[\s+]*\#(n)"#,
            #"/(?:search|place|dir)/\+?\#(n)\s*,[\s+]*\#(n)"#,
            #"@\#(n),\#(n)"#,
        ]
        for pattern in patterns {
            let regex = try! Regex(pattern)
            if let match = text.firstMatch(of: regex),
               let latitude = match.output[1].substring.flatMap({ Double($0) }),
               let longitude = match.output[2].substring.flatMap({ Double($0) }),
               let location = valid(latitude, longitude) {
                return location
            }
        }
        return nil
    }

    /// A short link's redirects, up to the first that has the place in it --
    /// not on to the page, which may be a consent form.
    private static func follow(_ url: URL) async throws -> ExifEditorModel.Location {
        let catcher = RedirectCatcher()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(from: url, delegate: catcher)
        if let found = catcher.found { return found }
        if let final = response.url, let location = location(inLink: final.absoluteString) {
            return location
        }
        throw Failure.noPlaceInLink
    }

    private final class RedirectCatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var place: ExifEditorModel.Location?

        var found: ExifEditorModel.Location? { lock.withLock { place } }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url,
                  let location = PastedPlace.location(inLink: url.absoluteString) else {
                return request
            }
            lock.withLock { place = location }
            return nil
        }
    }

    // MARK: - Plus codes

    nonisolated private static var plusCodePattern: Regex<AnyRegexOutput> { try! Regex(
        "^([23456789CFGHJMPQRVWXcfghjmpqrvwx]{2,8}0*\\+[23456789CFGHJMPQRVWXcfghjmpqrvwx]{0,7})"
        + "(?:[\\s,]+(.+))?$") }

    /// The town after a short plus code, through Apple's geocoder.
    private static func geocode(_ place: String) async throws -> ExifEditorModel.Location {
        let found = try? await CLGeocoder().geocodeAddressString(place)
        guard let coordinate = found?.first?.location?.coordinate else {
            throw Failure.unknownPlace(place)
        }
        return ExifEditorModel.Location(latitude: coordinate.latitude,
                                        longitude: coordinate.longitude)
    }
}

/// Open Location Code, which Google Maps calls a plus code: decoded here, as
/// the reference implementation does it, to the middle of its area.
enum PlusCode {

    nonisolated private static let alphabet = Array("23456789CFGHJMPQRVWX")

    /// Eight digits before the +: a code that needs no town.
    nonisolated static func isFull(_ code: String) -> Bool {
        code.firstIndex(of: "+").map { code.distance(from: code.startIndex, to: $0) } == 8
    }

    nonisolated static func decode(_ code: String) -> ExifEditorModel.Location? {
        guard isFull(code) else { return nil }
        let digits = code.uppercased().filter { $0 != "+" && $0 != "0" }
            .compactMap { alphabet.firstIndex(of: $0) }
        guard digits.count >= 2, digits.count % 2 == 0 || digits.count > 10 else { return nil }
        var latitude = -90.0, longitude = -180.0
        var latitudeStep = 400.0, longitudeStep = 400.0
        for pair in 0..<(min(digits.count, 10) / 2) {
            latitudeStep /= 20
            longitudeStep /= 20
            latitude += Double(digits[pair * 2]) * latitudeStep
            longitude += Double(digits[pair * 2 + 1]) * longitudeStep
        }
        // Past ten digits, each splits its cell four columns by five rows.
        for digit in digits.dropFirst(10) {
            latitudeStep /= 5
            longitudeStep /= 4
            latitude += Double(digit / 4) * latitudeStep
            longitude += Double(digit % 4) * longitudeStep
        }
        return ExifEditorModel.Location(latitude: min(latitude + latitudeStep / 2, 90),
                                        longitude: longitude + longitudeStep / 2)
    }

    /// The first ten digits of the code for a place.
    nonisolated static func encode(_ location: ExifEditorModel.Location) -> String {
        var latitude = min(max(location.latitude, -90), 90) + 90
        if latitude >= 180 { latitude = 180 - 1e-9 }
        var longitude = (location.longitude + 180).truncatingRemainder(dividingBy: 360)
        if longitude < 0 { longitude += 360 }
        var code = ""
        var step = 20.0
        for _ in 0..<5 {
            let row = min(Int(latitude / step), 19), column = min(Int(longitude / step), 19)
            latitude -= Double(row) * step
            longitude -= Double(column) * step
            code.append(alphabet[row])
            code.append(alphabet[column])
            step /= 20
        }
        return code
    }

    /// A short code, as Google Maps copies it with a town: the code nearest
    /// the town that ends in these digits.
    nonisolated static func recover(_ short: String,
                                    near: ExifEditorModel.Location) -> ExifEditorModel.Location? {
        guard let plus = short.firstIndex(of: "+") else { return nil }
        let missing = 8 - short.distance(from: short.startIndex, to: plus)
        guard missing > 0, missing % 2 == 0 else { return isFull(short) ? decode(short) : nil }
        let full = String(encode(near).prefix(missing)) + short.uppercased()
        guard var location = decode(full).map({ ($0.latitude, $0.longitude) }) else { return nil }
        // The digits left off are the town's; the place may be over the edge
        // of the town's cell, nearer than the cell's own match.
        let size = pow(20, 2 - Double(missing) / 2)
        if near.latitude + size / 2 < location.0, location.0 - size >= -90 {
            location.0 -= size
        } else if near.latitude - size / 2 > location.0, location.0 + size <= 90 {
            location.0 += size
        }
        if near.longitude + size / 2 < location.1 {
            location.1 -= size
        } else if near.longitude - size / 2 > location.1 {
            location.1 += size
        }
        return ExifEditorModel.Location(latitude: location.0, longitude: location.1)
    }
}
