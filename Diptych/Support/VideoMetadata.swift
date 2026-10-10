import AVFoundation
import Foundation

/// What a video says about itself that can be changed: when and where it was
/// taken, the camera, and the words about it -- read and written by
/// AVFoundation, the picture and sound copied as they are, not encoded again.
///
/// A QuickTime movie keeps all of it, as an iPhone writes it. An MP4 keeps
/// what the ISO user data has room for -- the date, the place, the artist,
/// the copyright, the description, the title, the software -- and no camera:
/// AVFoundation writes no make or model into one.
nonisolated enum VideoMetadata {

    enum Field: String, CaseIterable, Sendable, Identifiable {
        case taken, location, altitude, make, model, software, artist, copyright, description, title

        var id: String { rawValue }

        var label: String {
            switch self {
            case .taken:       "Date Taken"
            case .location:    "Latitude, Longitude"
            case .altitude:    "Altitude (m)"
            case .make:        "Camera Make"
            case .model:       "Camera Model"
            case .software:    "Software"
            case .artist:      "Artist"
            case .copyright:   "Copyright"
            case .description: "Description"
            case .title:       "Title"
            }
        }

        var example: String {
            switch self {
            case .taken:       "2024-07-14 18:30:00 +02:00"
            case .location:    "47.4979, 19.0402"
            case .altitude:    "105"
            case .make:        "Apple"
            case .model:       "iPhone 15 Pro"
            case .software:    "18.5"
            case .artist:      "Jane Doe"
            case .copyright:   "© 2024 Jane Doe"
            case .description: "Fireworks over the Danube"
            case .title:       "Summer evening"
            }
        }

        /// Every identifier that holds it, in any of the formats, the one a
        /// reader looks at first first. Altitude is part of the location.
        var identifiers: [AVMetadataIdentifier] {
            switch self {
            case .taken:
                [.quickTimeMetadataCreationDate, .quickTimeUserDataCreationDate, .isoUserDataDate,
                 .commonIdentifierCreationDate]
            case .location, .altitude:
                [.quickTimeMetadataLocationISO6709, .quickTimeUserDataLocationISO6709,
                 VideoMetadata.isoPlace, .commonIdentifierLocation]
            case .make:
                [.quickTimeMetadataMake, .quickTimeUserDataMake, .commonIdentifierMake]
            case .model:
                [.quickTimeMetadataModel, .quickTimeUserDataModel, .commonIdentifierModel]
            case .software:
                [.quickTimeMetadataSoftware, .quickTimeUserDataSoftware, .commonIdentifierSoftware,
                 AVMetadataIdentifier(rawValue: "uiso/swre")]
            case .artist:
                [.quickTimeMetadataArtist, .quickTimeMetadataAuthor, .quickTimeUserDataArtist,
                 .commonIdentifierArtist, .commonIdentifierAuthor, .iTunesMetadataArtist,
                 AVMetadataIdentifier(rawValue: "uiso/perf"), AVMetadataIdentifier(rawValue: "uiso/auth")]
            case .copyright:
                [.quickTimeMetadataCopyright, .quickTimeUserDataCopyright, .isoUserDataCopyright,
                 .commonIdentifierCopyrights, .iTunesMetadataCopyright]
            case .description:
                [.quickTimeMetadataDescription, .quickTimeUserDataDescription,
                 .commonIdentifierDescription, .iTunesMetadataDescription,
                 AVMetadataIdentifier(rawValue: "uiso/dscp")]
            case .title:
                [.quickTimeMetadataTitle, .quickTimeUserDataFullName, .commonIdentifierTitle,
                 .iTunesMetadataSongName, AVMetadataIdentifier(rawValue: "uiso/titl")]
            }
        }

        /// The common key AVFoundation gives an item of it in any format.
        var commonKey: AVMetadataKey? {
            switch self {
            case .taken:       .commonKeyCreationDate
            case .location, .altitude: .commonKeyLocation
            case .make:        .commonKeyMake
            case .model:       .commonKeyModel
            case .software:    .commonKeySoftware
            case .artist:      .commonKeyArtist
            case .copyright:   .commonKeyCopyrights
            case .description: .commonKeyDescription
            case .title:       .commonKeyTitle
            }
        }

        /// What it is written as: QuickTime metadata, which AVFoundation
        /// turns into ISO user data in an MP4 -- all but the software, which
        /// it takes only by its common name there.
        func writtenIdentifier(in format: String) -> AVMetadataIdentifier {
            if self == .software, format != "mov" { return .commonIdentifierSoftware }
            return identifiers[0]
        }

        func fits(_ format: String) -> Bool {
            (self != .make && self != .model) || format == "mov"
        }
    }

    static let isoPlace = AVMetadataIdentifier(rawValue: "uiso/loci")

    /// The formats it can write: the MPEG-4 family, which AVFoundation both
    /// reads and writes.
    static let editableFormats: Set<String> = ["mov", "mp4", "m4v"]

    /// The format, by the file's bytes, when its metadata can be changed.
    static func format(of url: URL) -> String? {
        guard let (kind, format) = MediaReader.sniff(url), kind == .video,
              editableFormats.contains(format) else {
            return nil
        }
        return format
    }

    static func canEdit(_ url: URL) -> Bool { format(of: url) != nil }

    struct Failure: Error, Sendable {
        let message: String
    }

    // MARK: - Reading

    /// The fields the video has, as text to show and type over.
    static func values(of url: URL) async -> [Field: String] {
        let asset = AVURLAsset(url: url, options: assetOptions(for: url))
        let items = await allItems(of: asset)
        var values: [Field: String] = [:]
        for field in Field.allCases where field != .altitude {
            guard let item = first(of: field, in: items),
                  let text = try? await item.load(.stringValue) else { continue }
            // No control characters: a NUL some writers leave at the end
            // is not part of the value, and a text field drops it.
            let trimmed = String(String.UnicodeScalarView(text.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0)
            })).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            switch field {
            case .taken:
                values[.taken] = shown(date: trimmed)
            case .location:
                guard let (latitude, longitude, altitude) = MediaReader.iso6709(trimmed) else {
                    continue
                }
                values[.location] = number(latitude) + ", " + number(longitude)
                if let altitude {
                    values[.altitude] = number(altitude)
                }
            default:
                values[field] = trimmed
            }
        }
        return values
    }

    /// To six places at most, no zeros after the last digit that counts.
    private static func number(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private static func allItems(of asset: AVURLAsset) async -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            items += (try? await asset.loadMetadata(for: format)) ?? []
        }
        return items
    }

    private static func holds(_ item: AVMetadataItem, _ field: Field) -> Bool {
        if let identifier = item.identifier, field.identifiers.contains(identifier) { return true }
        return item.commonKey != nil && item.commonKey == field.commonKey
    }

    private static func first(of field: Field, in items: [AVMetadataItem]) -> AVMetadataItem? {
        for identifier in field.identifiers {
            if let item = items.first(where: { $0.identifier == identifier }) { return item }
        }
        return items.first { $0.commonKey != nil && $0.commonKey == field.commonKey }
    }

    /// AVFoundation goes by the name; a video named otherwise is opened by
    /// what its bytes are.
    private static func assetOptions(for url: URL) -> [String: Any] {
        let types = ["mov": "video/quicktime", "mp4": "video/mp4", "m4v": "video/x-m4v"]
        let named = MediaFormat.canonical(url.pathExtension).map { types[$0] != nil } ?? false
        guard !named, let format = format(of: url), let type = types[format] else { return [:] }
        return [AVURLAssetOverrideMIMETypeKey: type]
    }

    // MARK: - Dates and places as typed

    /// `2024-07-14T18:30:00+0200` as `2024-07-14 18:30:00 +02:00`.
    static func shown(date text: String) -> String {
        guard let match = text.wholeMatch(of: dateForm) else { return text }
        var shown = "\(match.output.1) \(match.output.2)"
        if let seconds = match.output.3 { shown += ":\(seconds)" } else { shown += ":00" }
        if let zone = match.output.4 {
            let digits = zone.filter(\.isNumber)
            if zone == "Z" { shown += " +00:00" }
            else if digits.count == 4 {
                shown += " \(zone.first!)\(digits.prefix(2)):\(digits.suffix(2))"
            }
        }
        return shown
    }

    /// `2024-07-14 18:30`, with seconds and an offset or without, as the
    /// QuickTime creation date: `2024-07-14T18:30:00+0200`. Without an
    /// offset, the Mac's own on that day. Nil for anything else.
    static func stored(date text: String, zone: TimeZone = .current) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.wholeMatch(of: dateForm) else { return nil }
        let day = String(match.output.1), time = String(match.output.2)
        let seconds = match.output.3.map(String.init) ?? "00"
        let parts = (day + "-" + time + "-" + seconds)
            .split(whereSeparator: { $0 == "-" || $0 == ":" }).compactMap { Int($0) }
        guard parts.count == 6, (1...12).contains(parts[1]), (1...31).contains(parts[2]),
              parts[3] < 24, parts[4] < 60, parts[5] < 60 else { return nil }
        let offset: String
        if let zoneText = match.output.4 {
            if zoneText == "Z" {
                offset = "+0000"
            } else {
                let digits = zoneText.filter(\.isNumber)
                guard digits.count == 4 else { return nil }
                offset = "\(zoneText.first!)\(digits)"
            }
        } else {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let components = DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                            hour: parts[3], minute: parts[4], second: parts[5])
            let date = calendar.date(from: components) ?? Date()
            let seconds = zone.secondsFromGMT(for: date)
            offset = String(format: "%@%02d%02d", seconds < 0 ? "-" : "+",
                            abs(seconds) / 3600, abs(seconds) % 3600 / 60)
        }
        return "\(day)T\(time):\(seconds)\(offset)"
    }

    private nonisolated(unsafe) static let dateForm = try! Regex(
        #"(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})(?::(\d{2}))?(?:\.\d+)?\s*(Z|[+-]\d{2}:?\d{2})?"#,
        as: (Substring, Substring, Substring, Substring?, Substring?).self)

    /// `47.4979, 19.0402` and an altitude in metres, as ISO 6709:
    /// `+47.4979+019.0402+105.000/`. Nil when the place cannot be read.
    static func stored(location text: String, altitude: String?) -> String? {
        guard let place = PastedPlace.pair(text) else { return nil }
        var stored = String(format: "%+08.4f%+09.4f", place.latitude, place.longitude)
        if let altitude = altitude?.trimmingCharacters(in: .whitespaces), !altitude.isEmpty {
            guard let metres = Double(altitude.replacingOccurrences(of: "m", with: "")
                .trimmingCharacters(in: .whitespaces)) else { return nil }
            stored += String(format: "%+08.3f", metres)
        }
        return stored + "/"
    }

    // MARK: - Writing

    /// The changes, by field: a value to write, or nil to take it out.
    /// Altitude goes with the location, and is written only with one.
    typealias Changes = [Field: String?]

    /// What each field becomes in the file, checked: the date and the place
    /// in their stored forms. The first problem, said, when there is one.
    static func checked(_ changes: Changes) throws(Failure) -> [Field: String?] {
        var stored: [Field: String?] = [:]
        for (field, value) in changes where field != .altitude {
            guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                stored[field] = .some(nil)
                continue
            }
            switch field {
            case .taken:
                guard let date = Self.stored(date: value) else {
                    throw Failure(message: "\u{201C}\(value)\u{201D} is not a date: write it as "
                                  + Field.taken.example)
                }
                stored[.taken] = date
            case .location:
                let altitude = changes[.altitude] ?? nil
                guard let place = Self.stored(location: value, altitude: altitude) else {
                    throw Failure(message: "\u{201C}\(value)\u{201D} is not a place: write it as "
                                  + Field.location.example + ", and the altitude in metres")
                }
                stored[.location] = place
            default:
                stored[field] = value.trimmingCharacters(in: .whitespaces)
            }
        }
        return stored
    }

    /// `url` written again with its metadata changed, in place -- the same
    /// file, its name, links and permissions kept -- a copy of it as it was
    /// kept for Undo first. That copy is returned.
    static func rewrite(_ url: URL, changes: Changes) async throws(Failure) -> URL {
        let name = url.lastPathComponent
        guard let format = format(of: url) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} is not a QuickTime or MP4 video.")
        }
        // The altitude is part of the place: changed alone, it is written
        // with the place there is.
        var changes = changes
        if changes[.altitude] != nil, changes[.location] == nil,
           let place = await values(of: url)[.location] {
            changes[.location] = place
        }
        let stored = try checked(changes)
        let asset = AVURLAsset(url: url, options: assetOptions(for: url))
        var items = await allItems(of: asset).filter { item in
            !stored.keys.contains { holds(item, $0) }
        }
        for case let (field, value?) in stored where field.fits(format) {
            let item = AVMutableMetadataItem()
            item.identifier = field.writtenIdentifier(in: format)
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            items.append(item)
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("Diptych-video-\(UUID().uuidString)")
        let out = work.appendingPathComponent("video." + format)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            guard let export = AVAssetExportSession(asset: asset,
                                                    presetName: AVAssetExportPresetPassthrough) else {
                throw Failure(message: "\u{201C}\(name)\u{201D} cannot be written again.")
            }
            export.metadata = items
            try await export.export(to: out, as: format == "mov" ? .mov : format == "m4v" ? .m4v : .mp4)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be written: "
                          + error.localizedDescription)
        }
        do {
            let before = try UndoSnapshots.keep(url)
            do {
                try UndoSnapshots.putBack(out, into: url)
            } catch {
                try? UndoSnapshots.putBack(before, into: url)
                try? FileManager.default.removeItem(at: before)
                throw error
            }
            return before
        } catch {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be written: "
                          + error.localizedDescription)
        }
    }

    /// Each video rewritten with the same changes: the ones done, with their
    /// copies for Undo, and what went wrong with the others.
    static func rewrite(_ urls: [URL], changes: Changes) async
        -> (done: [(url: URL, before: URL)], failures: [String]) {
        var done: [(url: URL, before: URL)] = []
        var failures: [String] = []
        for url in urls {
            do {
                done.append((url, try await rewrite(url, changes: changes)))
            } catch {
                failures.append(error.message)
            }
        }
        return (done, failures)
    }
}
