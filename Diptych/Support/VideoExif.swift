import Foundation
import ImageIO

/// A video's metadata as the EXIF editor's fields, so videos are edited in
/// the same window, the same way: the date with its picker and time zone,
/// the place in four fields that go round the three ways of writing it, the
/// camera with Control-Space -- and back again into the video on Save.
nonisolated enum VideoExif {

    private static func key(_ group: ExifGroup, _ name: CFString) -> ExifKey {
        ExifKey(group: group, name: name as String)
    }

    static let taken = key(.exif, kCGImagePropertyExifDateTimeOriginal)
    static let zone = key(.exif, kCGImagePropertyExifOffsetTimeOriginal)
    static let latitude = key(.gps, kCGImagePropertyGPSLatitude)
    static let latitudeRef = key(.gps, kCGImagePropertyGPSLatitudeRef)
    static let longitude = key(.gps, kCGImagePropertyGPSLongitude)
    static let longitudeRef = key(.gps, kCGImagePropertyGPSLongitudeRef)
    static let altitude = key(.gps, kCGImagePropertyGPSAltitude)
    static let altitudeRef = key(.gps, kCGImagePropertyGPSAltitudeRef)
    /// A video's title has no EXIF field: TIFF's document name stands in.
    static let title = key(.tiff, kCGImagePropertyTIFFDocumentName)

    /// The text fields, each one of the video's.
    static let texts: [ExifKey: VideoMetadata.Field] = [
        key(.tiff, kCGImagePropertyTIFFImageDescription): .description,
        key(.tiff, kCGImagePropertyTIFFArtist): .artist,
        key(.tiff, kCGImagePropertyTIFFCopyright): .copyright,
        key(.tiff, kCGImagePropertyTIFFMake): .make,
        key(.tiff, kCGImagePropertyTIFFModel): .model,
        key(.tiff, kCGImagePropertyTIFFSoftware): .software,
        title: .title,
    ]

    private static let gpsKeys: Set<ExifKey> = [latitude, latitudeRef, longitude, longitudeRef,
                                                altitude, altitudeRef]

    /// The fields a video has, all shown: as the EXIF editor has them, but
    /// without a camera when none of the videos can hold one -- an MP4 has
    /// no place for it -- or has one.
    static func catalogue(withCamera: Bool) -> [ExifField] {
        let wanted: [ExifKey] = [
            key(.tiff, kCGImagePropertyTIFFImageDescription),
            key(.tiff, kCGImagePropertyTIFFArtist), key(.tiff, kCGImagePropertyTIFFCopyright),
            key(.tiff, kCGImagePropertyTIFFMake), key(.tiff, kCGImagePropertyTIFFModel),
            key(.tiff, kCGImagePropertyTIFFSoftware),
            taken, zone, latitude, latitudeRef, longitude, longitudeRef, altitude, altitudeRef,
        ]
        let camera: Set<String> = ["Make", "Model"]
        var fields = ExifFields.catalogue.filter { field in
            wanted.contains(field.key) && (withCamera || !camera.contains(field.key.name))
        }.map { field in
            ExifField(key: field.key, label: field.label, kind: field.kind, common: true,
                      example: field.example, input: field.input)
        }
        fields.insert(ExifField(key: title, label: "Title", kind: .text, common: true), at: 1)
        return fields
    }

    // MARK: - Reading

    /// The video's metadata as EXIF values, or nil for a file that is not
    /// a QuickTime or MP4 video.
    static func values(of url: URL) async -> [ExifKey: Any]? {
        guard VideoMetadata.canEdit(url) else { return nil }
        let video = await VideoMetadata.values(of: url)
        var values: [ExifKey: Any] = [:]
        for (exif, field) in texts {
            if let text = video[field] { values[exif] = text }
        }
        if let shown = video[.taken] {
            // 2024-07-14 18:30:00 +02:00
            let parts = shown.split(separator: " ")
            if parts.count >= 2 {
                values[taken] = parts[0].replacingOccurrences(of: "-", with: ":") + " " + parts[1]
            }
            if parts.count >= 3 { values[zone] = String(parts[2]) }
        }
        if let place = video[.location], let pair = PastedPlace.pair(place) {
            values[latitude] = NSNumber(value: abs(pair.latitude))
            values[latitudeRef] = pair.latitude < 0 ? "S" : "N"
            values[longitude] = NSNumber(value: abs(pair.longitude))
            values[longitudeRef] = pair.longitude < 0 ? "W" : "E"
            if let metres = video[.altitude].flatMap(Double.init) {
                values[altitude] = NSNumber(value: abs(metres))
                values[altitudeRef] = NSNumber(value: metres < 0 ? 1 : 0)
            }
        }
        return values
    }

    // MARK: - Writing

    /// The EXIF editor's changes as the video's, for one video whose values
    /// are `existing`: the date and its zone made one, the place's fields
    /// made one place.
    static func changes(_ changes: [ExifKey: ExifWrite.Change],
                        existing: [ExifKey: Any]) -> VideoMetadata.Changes {
        var video: VideoMetadata.Changes = [:]
        func text(_ change: ExifWrite.Change?) -> String?? {
            switch change {
            case .set(let value)?: return .some(ExifFields.text(of: value) ?? "\(value)")
            case .remove?:         return .some(nil)
            default:               return nil
            }
        }
        for (exif, field) in texts {
            if let value = text(changes[exif]) { video[field] = value }
        }

        // The date and its zone.
        if changes[taken] != nil || changes[zone] != nil {
            let date: String?
            switch text(changes[taken]) {
            case .some(let value): date = value
            case .none:            date = existing[taken] as? String
            }
            var offset: String? = existing[zone] as? String
            switch changes[zone] {
            case .set(let value as String)?: offset = value
            case .zone(let identifier, _)?:
                offset = TimeZone(identifier: identifier).map {
                    ExifFields.offset(of: $0, at: date)
                }
            case .remove?: offset = nil
            default: break
            }
            if let date, !date.isEmpty {
                let day = date.prefix(10).replacingOccurrences(of: ":", with: "-")
                video[.taken] = day + date.dropFirst(10) + (offset.map { " " + $0 } ?? "")
            } else {
                video[.taken] = .some(nil)
            }
        }

        // The place.
        if changes.keys.contains(where: gpsKeys.contains) {
            func value(_ key: ExifKey) -> Any? {
                switch changes[key] {
                case .set(let value)?: return value
                case .remove?:         return nil
                default:               return existing[key]
                }
            }
            func degrees(_ key: ExifKey, _ reference: ExifKey, negative: String) -> Double? {
                guard let number = value(key) as? NSNumber
                        ?? (value(key) as? String).flatMap(Double.init).map(NSNumber.init)
                else { return nil }
                let ref = (value(reference) as? String)?.uppercased()
                return ref == negative ? -abs(number.doubleValue) : abs(number.doubleValue)
            }
            if let lat = degrees(latitude, latitudeRef, negative: "S"),
               let lon = degrees(longitude, longitudeRef, negative: "W") {
                video[.location] = "\(lat), \(lon)"
                if let metres = (value(altitude) as? NSNumber)?.doubleValue {
                    let below = (value(altitudeRef) as? NSNumber)?.intValue == 1
                    video[.altitude] = String(below ? -metres : metres)
                }
            } else {
                video[.location] = .some(nil)
            }
        }
        return video
    }
}
