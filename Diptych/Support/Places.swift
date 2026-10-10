import Foundation

/// The town nearest to a place, from the list `make-places.sh` makes out of
/// GeoNames: towns of 15,000 people or more, with their region and country.
/// What the flat view's `city`, `state` and `country` fall back on when a
/// picture or a video has a location but no place names written into it --
/// looked up on this Mac, without asking any service.
nonisolated final class Places: Sendable {

    struct Place: Sendable, Hashable {
        let city: String
        let state: String?
        let country: String?
        /// ISO 3166 code: `HU`.
        let countryCode: String
        /// How far the town is from where asked, in metres.
        let distance: Double
    }

    /// Farther than this from every town, no town is named: a picture from
    /// the middle of a sea, or of a desert, is from none of them.
    static let reach = 50_000.0

    /// The list in `~/.diptych/exif/places.json`, as corrected there --
    /// or, when it cannot be read, the one that comes with Diptych.
    static let shared = Places(ExifDatabase.shared.gazetteer)

    /// The list that comes with Diptych: `Places.tsv`, made by
    /// `make-places.sh`.
    static let builtIn: Gazetteer = Gazetteer(
        tsv: Bundle.main.url(forResource: "Places", withExtension: "tsv")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")

    private struct Spot: Sendable {
        let latitude: Double
        let longitude: Double
        let country: String
        let region: String
        let name: String
    }

    /// By the whole degrees of latitude and longitude they are in.
    private let cells: [Int: [Spot]]
    private let countries: [String: String]
    /// "HU.05" → "Budapest".
    private let regions: [String: String]

    convenience init(text: String) {
        self.init(Gazetteer(tsv: text))
    }

    /// Whatever is disabled left out: a town, a region's or a country's
    /// name a user found wrong.
    init(_ gazetteer: Gazetteer) {
        var cells: [Int: [Spot]] = [:]
        for town in gazetteer.towns where !town.disabled {
            let spot = Spot(latitude: town.latitude, longitude: town.longitude,
                            country: town.country, region: town.region, name: town.name)
            cells[Self.cell(town.latitude, town.longitude), default: []].append(spot)
        }
        self.cells = cells
        countries = Dictionary(gazetteer.countries.filter { !$0.disabled }.map { ($0.code, $0.name) },
                               uniquingKeysWith: { first, _ in first })
        regions = Dictionary(gazetteer.regions.filter { !$0.disabled }
                                 .map { ("\($0.country).\($0.code)", $0.name) },
                             uniquingKeysWith: { first, _ in first })
    }

    var isEmpty: Bool { cells.isEmpty }

    private static func cell(_ latitude: Double, _ longitude: Double) -> Int {
        let row = Int(floor(latitude)) + 90
        let column = (Int(floor(longitude)) + 180 + 360) % 360
        return row * 360 + column
    }

    /// The nearest town within `reach`, or nil.
    func nearest(latitude: Double, longitude: Double) -> Place? {
        // Enough whole degrees around to cover the reach -- more of them
        // east and west near the poles, where a degree is short.
        let rows = 1
        let squeeze = max(cos(latitude * .pi / 180), 0.05)
        let columns = min(180, Int(ceil(1 / squeeze)))
        var best: (Spot, Double)?
        let row = Int(floor(latitude))
        let column = Int(floor(longitude))
        for r in (row - rows)...(row + rows) where r >= -90 && r < 90 {
            for c in (column - columns)...(column + columns) {
                for town in cells[Self.cell(Double(r), Double(c))] ?? [] {
                    let distance = Geo.distance(latitude, longitude, town.latitude, town.longitude)
                    if distance <= Self.reach, distance < best?.1 ?? .infinity {
                        best = (town, distance)
                    }
                }
            }
        }
        guard let (town, distance) = best else { return nil }
        return Place(city: town.name, state: regions["\(town.country).\(town.region)"],
                     country: countries[town.country], countryCode: town.country,
                     distance: distance)
    }
}

extension Places {

    /// Countries, regions and towns, as `places.json` holds them: each can be
    /// disabled, and each a user corrected is `manual`, which a new version
    /// of Diptych then leaves as it is.
    struct Gazetteer: Sendable, Equatable {
        var countries: [Country] = []
        var regions: [Region] = []
        var towns: [Town] = []

        struct Country: Codable, Sendable, Hashable, ExifDatabase.Item {
            /// ISO 3166: `HU`.
            var code: String
            var name: String
            var disabled = false
            var manual = false

            var key: String? { code }

            init(code: String, name: String) {
                self.code = code
                self.name = name
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                code = try values.decode(String.self, forKey: .code)
                name = try values.decode(String.self, forKey: .name)
                disabled = try values.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
                manual = try values.decodeIfPresent(Bool.self, forKey: .manual) ?? false
            }
        }

        struct Region: Codable, Sendable, Hashable, ExifDatabase.Item {
            var country: String
            /// GeoNames' first-level code within the country: `05`.
            var code: String
            var name: String
            var disabled = false
            var manual = false

            var key: String? { "\(country).\(code)" }

            init(country: String, code: String, name: String) {
                self.country = country
                self.code = code
                self.name = name
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                country = try values.decode(String.self, forKey: .country)
                code = try values.decode(String.self, forKey: .code)
                name = try values.decode(String.self, forKey: .name)
                disabled = try values.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
                manual = try values.decodeIfPresent(Bool.self, forKey: .manual) ?? false
            }
        }

        struct Town: Codable, Sendable, Hashable, ExifDatabase.Item {
            /// GeoNames' own number; none for a town a user added.
            var id: Int?
            var name: String
            var latitude: Double
            var longitude: Double
            var country: String
            var region: String
            var disabled = false
            var manual = false

            var key: String? { id.map(String.init) }

            init(id: Int?, name: String, latitude: Double, longitude: Double,
                 country: String, region: String) {
                self.id = id
                self.name = name
                self.latitude = latitude
                self.longitude = longitude
                self.country = country
                self.region = region
            }

            /// A town added by hand needs only its name and place.
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = try values.decodeIfPresent(Int.self, forKey: .id)
                name = try values.decode(String.self, forKey: .name)
                latitude = try values.decode(Double.self, forKey: .latitude)
                longitude = try values.decode(Double.self, forKey: .longitude)
                country = try values.decodeIfPresent(String.self, forKey: .country) ?? ""
                region = try values.decodeIfPresent(String.self, forKey: .region) ?? ""
                disabled = try values.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
                manual = try values.decodeIfPresent(Bool.self, forKey: .manual) ?? false
            }
        }

        init(countries: [Country] = [], regions: [Region] = [], towns: [Town] = []) {
            self.countries = countries
            self.regions = regions
            self.towns = towns
        }

        /// `Places.tsv`'s lines: `C` a country, `R` a region, `P` a town.
        init(tsv text: String) {
            var countries: [Country] = []
            var regions: [Region] = []
            var towns: [Town] = []
            text.enumerateLines { line, _ in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                    .map(String.init)
                switch fields.first {
                case "C" where fields.count >= 3:
                    countries.append(Country(code: fields[1], name: fields[2]))
                case "R" where fields.count >= 4:
                    regions.append(Region(country: fields[1], code: fields[2], name: fields[3]))
                case "P" where fields.count >= 7:
                    guard let latitude = Double(fields[2]), let longitude = Double(fields[3]) else {
                        return
                    }
                    towns.append(Town(id: Int(fields[1]), name: fields[6], latitude: latitude,
                                      longitude: longitude, country: fields[4],
                                      region: fields[5]))
                default:
                    break
                }
            }
            self.init(countries: countries, regions: regions, towns: towns)
        }
    }
}

nonisolated enum Geo {

    static let earthRadius = 6_371_008.8

    /// Metres between two places, along the ground.
    static func distance(_ latitude1: Double, _ longitude1: Double,
                         _ latitude2: Double, _ longitude2: Double) -> Double {
        let radians = Double.pi / 180
        let dLatitude = (latitude2 - latitude1) * radians
        let dLongitude = (longitude2 - longitude1) * radians
        let a = sin(dLatitude / 2) * sin(dLatitude / 2)
            + cos(latitude1 * radians) * cos(latitude2 * radians)
            * sin(dLongitude / 2) * sin(dLongitude / 2)
        return 2 * earthRadius * atan2(sqrt(a), sqrt(1 - a))
    }
}
