import Foundation

/// The lists in `~/.diptych/exif`, for a user to correct and add to:
///
///     cameras.json   makes and models, offered in the EXIF editor
///     lenses.json    lens makes and models, the same
///     places.json    the countries, regions and towns a picture's
///                    location is named after
///
/// Each is written the first time Diptych starts, from the lists it comes
/// with, and on the first start of each later version merged with them:
///
/// - What a user added stays, and so does every `"disabled": true` -- an
///   item found wrong is never enabled again by a merge.
/// - A camera or lens already there is left as it is.
/// - A country, region or town already there takes this version's values,
///   which may have corrected it -- unless it is `"manual": true`, which a
///   user sets on one corrected by hand.
///
/// Each file says which version last wrote it, and while that is the
/// version running, it is only read.
nonisolated enum ExifDatabase {

    static let cameraFile = "cameras.json"
    static let lensFile = "lenses.json"
    static let placeFile = "places.json"

    /// One of the lists' items: the same one in the file and in the version
    /// when their keys are equal. One with no key -- a town added by hand --
    /// is only the user's.
    protocol Item: Codable {
        var key: String? { get }
        var disabled: Bool { get set }
        var manual: Bool { get }
    }

    /// A camera or a lens, as it writes itself into a picture.
    struct Gear: Item, Hashable, Sendable {
        var make: String
        var model: String
        var disabled = false

        var key: String? { make + "\u{0}" + model }
        var manual: Bool { false }

        init(make: String, model: String, disabled: Bool = false) {
            self.make = make
            self.model = model
            self.disabled = disabled
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            make = try values.decodeIfPresent(String.self, forKey: .make) ?? ""
            model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
            disabled = try values.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        }

        private enum CodingKeys: String, CodingKey { case make, model, disabled }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(make, forKey: .make)
            try values.encode(model, forKey: .model)
            try values.encode(disabled, forKey: .disabled)
        }
    }

    /// A file that could not be read: the lists Diptych comes with are used
    /// in its place, and it is left as it is, to be mended.
    struct Problem: Sendable, Equatable {
        let path: String
        let message: String
    }

    /// The lists in use, and what was wrong with the files.
    struct Lists: Sendable {
        var cameras: [Gear]
        var lenses: [Gear]
        var gazetteer: Places.Gazetteer
        var problems: [Problem] = []
    }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".diptych/exif")
    }

    /// Prepared once, on first use -- the app starts it as it launches. A
    /// test run gets the lists Diptych comes with and leaves ~/.diptych be.
    static let shared: Lists = {
        let builtIn = Lists(cameras: ExifGearList.cameras, lenses: ExifGearList.lenses,
                            gazetteer: Places.builtIn)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return builtIn
        }
        return prepare(in: directory, version: version, builtIn: builtIn)
    }()

    /// The fields Control-Space offers values for.
    static func offers(_ field: ExifKey) -> Bool {
        ["Make", "Model", "LensMake", "LensModel"].contains(field.name)
    }

    /// The enabled items' values for `field`, in the lists' order; for a
    /// model, those of `make` when one is given and has any.
    static func values(for field: ExifKey, make: String? = nil,
                       in lists: Lists = shared) -> [String] {
        let enabled: [Gear]
        let byModel: Bool
        switch field.name {
        case "Make":      (enabled, byModel) = (lists.cameras, false)
        case "Model":     (enabled, byModel) = (lists.cameras, true)
        case "LensMake":  (enabled, byModel) = (lists.lenses, false)
        case "LensModel": (enabled, byModel) = (lists.lenses, true)
        default:          return []
        }
        let make = make?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var usable = enabled.filter { !$0.disabled }
        // The models of the make already written, when it is one listed.
        if byModel, usable.contains(where: { $0.make.lowercased() == make }) {
            usable = usable.filter { $0.make.lowercased() == make }
        }
        var seen: Set<String> = []
        return usable.compactMap { gear in
            let value = byModel ? gear.model : gear.make
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
    }

    // MARK: - Writing and merging

    /// Each file written or merged as needed, then read.
    static func prepare(in directory: URL, version: String, builtIn: Lists) -> Lists {
        var lists = builtIn
        var problems: [Problem] = []
        func note(_ problem: Problem?) { if let problem { problems.append(problem) } }

        var cameras = GearFile(version: version, items: builtIn.cameras)
        note(sync(&cameras, at: directory.appendingPathComponent(cameraFile), version: version,
                  merge: { file, ours in file.items = merge(file.items, ours.items, renew: false) }))
        lists.cameras = cameras.items

        var lenses = GearFile(version: version, items: builtIn.lenses)
        note(sync(&lenses, at: directory.appendingPathComponent(lensFile), version: version,
                  merge: { file, ours in file.items = merge(file.items, ours.items, renew: false) }))
        lists.lenses = lenses.items

        var places = PlaceFile(version: version, gazetteer: builtIn.gazetteer)
        note(sync(&places, at: directory.appendingPathComponent(placeFile), version: version,
                  merge: { file, ours in
                      file.countries = merge(file.countries, ours.countries, renew: true)
                      file.regions = merge(file.regions, ours.regions, renew: true)
                      file.towns = merge(file.towns, ours.towns, renew: true)
                  }))
        lists.gazetteer = places.gazetteer

        lists.problems = problems
        return lists
    }

    /// `ours` in, the file's merged with it out. Written when there was no
    /// file, or one another version wrote; left alone when it cannot be
    /// read, and then `ours` is what is used.
    private static func sync<File: ListFile>(_ ours: inout File, at url: URL, version: String,
                                             merge: (inout File, File) -> Void) -> Problem? {
        let manager = FileManager.default
        if let data = try? Data(contentsOf: url) {
            let file: File
            do {
                file = try JSONDecoder().decode(File.self, from: data)
            } catch {
                return Problem(path: url.path, message: describe(error))
            }
            if file.version == version {
                ours = file
                return nil
            }
            var merged = file
            merge(&merged, ours)
            merged.version = version
            ours = merged
        } else if manager.fileExists(atPath: url.path) {
            return Problem(path: url.path, message: "it cannot be read")
        }
        do {
            try manager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            try ours.data().write(to: url, options: .atomic)
        } catch {
            return Problem(path: url.path, message: "it cannot be written: "
                           + error.localizedDescription)
        }
        return nil
    }

    /// The file's items in their order, each now as this version has it if
    /// `renew` and not `manual`, disabled where it was; then the version's
    /// new ones.
    static func merge<T: Item>(_ file: [T], _ ours: [T], renew: Bool) -> [T] {
        var mine: [String: T] = [:]
        for item in ours {
            if let key = item.key, mine[key] == nil { mine[key] = item }
        }
        var seen: Set<String> = []
        var merged: [T] = file.map { item in
            guard let key = item.key else { return item }
            seen.insert(key)
            guard renew, !item.manual, var renewed = mine[key] else { return item }
            renewed.disabled = item.disabled
            return renewed
        }
        for item in ours {
            if let key = item.key, seen.insert(key).inserted { merged.append(item) }
        }
        return merged
    }

    /// Where in the file, as a person editing it would look.
    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let context):
            let underlying = (context.underlyingError as NSError?)?
                .userInfo[NSDebugDescriptionErrorKey] as? String
            return "it is not JSON: " + (underlying ?? context.debugDescription)
        case DecodingError.keyNotFound(let key, let context):
            return "\u{201C}\(key.stringValue)\u{201D} is missing at " + path(context)
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return context.debugDescription + " at " + path(context)
        default:
            return error.localizedDescription
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let path = context.codingPath.map { key in
            key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)"
        }.joined()
        return path.isEmpty ? "the top" : path
    }

    // MARK: - The files

    fileprivate protocol ListFile: Codable {
        var version: String? { get set }
        func data() throws -> Data
    }

    /// `cameras.json` and `lenses.json`.
    fileprivate struct GearFile: ListFile {
        var version: String?
        var items: [Gear]

        init(version: String, items: [Gear]) {
            self.version = version
            self.items = items
        }

        func data() throws -> Data {
            try ExifDatabase.data(version: version, about: [
                "Offered by Control-Space in the EXIF editor's make and model fields.",
                "Add an item, or set \"disabled\": true on a wrong one: a new version of Diptych "
                    + "adds its new items and never enables one again.",
            ], lists: [("items", try lines(items))])
        }
    }

    /// `places.json`.
    fileprivate struct PlaceFile: ListFile {
        var version: String?
        var countries: [Places.Gazetteer.Country]
        var regions: [Places.Gazetteer.Region]
        var towns: [Places.Gazetteer.Town]

        init(version: String, gazetteer: Places.Gazetteer) {
            self.version = version
            countries = gazetteer.countries
            regions = gazetteer.regions
            towns = gazetteer.towns
        }

        var gazetteer: Places.Gazetteer {
            Places.Gazetteer(countries: countries, regions: regions, towns: towns)
        }

        func data() throws -> Data {
            try ExifDatabase.data(version: version, about: [
                "The towns of 15,000 people or more, with their regions and countries, from "
                    + "GeoNames (https://www.geonames.org), CC BY 4.0: what a picture's city, "
                    + "state and country are when it has a location but no names.",
                "Set \"disabled\": true on a wrong one; a new version of Diptych never enables "
                    + "it again.",
                "A new version of Diptych writes its own values over the ones here -- it may "
                    + "have corrected them -- except where \"manual\" is true: set it on one you "
                    + "corrected by hand. A town you add needs no id.",
            ], lists: [("countries", try lines(countries)), ("regions", try lines(regions)),
                       ("towns", try lines(towns))])
        }
    }

    /// One item a line, so a file of thirty thousand towns can be read,
    /// searched and edited as text.
    private static func lines<T: Encodable>(_ items: [T]) throws -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try items.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
    }

    private static func data(version: String?, about: [String],
                             lists: [(String, [String])]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func json<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        var text = "{\n"
        text += "  \"version\": \(try json(version ?? "")),\n"
        text += "  \"about\": [\n" + (try about.map { "    " + (try json($0)) })
            .joined(separator: ",\n") + "\n  ]"
        for (name, items) in lists {
            text += ",\n  \(try json(name)): ["
            text += items.isEmpty ? "]" : "\n    " + items.joined(separator: ",\n    ") + "\n  ]"
        }
        text += "\n}\n"
        return Data(text.utf8)
    }
}
