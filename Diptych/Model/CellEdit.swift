import Foundation
import ImageIO

/// A value edited where it is shown, in its cell, as a name and permissions
/// are: a file's created and modified dates, a JPEG's or HEIC's EXIF, a
/// QuickTime or MP4 video's metadata. Click the cell of a selected row,
/// type, Return; it is set for every selected item it can be set for, and
/// is one step of Undo.
enum CellEdit {

    /// Which cell is being edited.
    struct Spot: Equatable, Sendable {
        let id: FileItem.ID
        let column: FileColumn
    }

    /// What a cell's value is, in the file.
    enum Target: Equatable, Sendable {
        case fileDate(FileHistory.DateChange.Which)
        case exif(ExifKey)
        case video(VideoMetadata.Field)

        var isDate: Bool {
            switch self {
            case .fileDate: true
            case .exif(let key): key == CellEdit.taken || key == CellEdit.digitized
            case .video(let field): field == .taken
            }
        }
    }

    nonisolated static let taken = ExifKey(group: .exif,
                                           name: kCGImagePropertyExifDateTimeOriginal as String)
    nonisolated static let digitized = ExifKey(group: .exif,
                                               name: kCGImagePropertyExifDateTimeDigitized as String)
    nonisolated static let takenZone = ExifKey(group: .exif,
                                               name: kCGImagePropertyExifOffsetTimeOriginal as String)
    nonisolated static let digitizedZone = ExifKey(
        group: .exif, name: kCGImagePropertyExifOffsetTimeDigitized as String)

    /// The EXIF field each picture column is, where it is one field.
    private static let exifKeys: [FileColumn: ExifKey] = [
        .taken: taken,
        .digitized: digitized,
        .lens: ExifKey(group: .exif, name: kCGImagePropertyExifLensModel as String),
        .software: ExifKey(group: .tiff, name: kCGImagePropertyTIFFSoftware as String),
        .artist: ExifKey(group: .tiff, name: kCGImagePropertyTIFFArtist as String),
        .copyright: ExifKey(group: .tiff, name: kCGImagePropertyTIFFCopyright as String),
        .imageDescription: ExifKey(group: .tiff, name: kCGImagePropertyTIFFImageDescription as String),
        .iso: ExifKey(group: .exif, name: kCGImagePropertyExifISOSpeedRatings as String),
        .aperture: ExifKey(group: .exif, name: kCGImagePropertyExifFNumber as String),
        .shutter: ExifKey(group: .exif, name: kCGImagePropertyExifExposureTime as String),
        .focal: ExifKey(group: .exif, name: kCGImagePropertyExifFocalLength as String),
        .focal35: ExifKey(group: .exif, name: kCGImagePropertyExifFocalLenIn35mmFilm as String),
    ]

    private static let videoFields: [FileColumn: VideoMetadata.Field] = [
        .taken: .taken, .software: .software, .artist: .artist, .copyright: .copyright,
        .imageDescription: .description,
    ]

    /// What the cell is for this item, or nil when it cannot be edited there.
    static func target(_ column: FileColumn, for item: FileItem) -> Target? {
        guard !item.isParent, !item.isSymlink else { return nil }
        switch column {
        case .modified: return .fileDate(.modified)
        case .created:  return .fileDate(.created)
        default: break
        }
        guard !item.isDirectory else { return nil }
        if let key = exifKeys[column], ExifFields.canEdit(item.url) { return .exif(key) }
        if let field = videoFields[column], VideoMetadata.canEdit(item.url) { return .video(field) }
        return nil
    }

    // MARK: - The text to edit

    private static let dayAndTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let dayTimeAndZone: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss xxx"
        return formatter
    }()

    /// The value as it is typed: a date as `2024-07-14 18:30:00`, an
    /// aperture as `1.8`, a shutter speed as `1/250`.
    static func text(of target: Target, for item: FileItem) -> String {
        switch target {
        case .fileDate(let which):
            return FileHistory.date(which, of: item.url).map { dayAndTime.string(from: $0) } ?? ""
        case .video(let field):
            guard let media = item.media ?? MediaCache.shared.info(for: item.url) else { return "" }
            switch field {
            case .taken:       return media.taken.map { dayTimeAndZone.string(from: $0) } ?? ""
            case .software:    return media.software ?? ""
            case .artist:      return media.artist ?? ""
            case .copyright:   return media.copyright ?? ""
            case .description: return media.description ?? ""
            default:           return ""
            }
        case .exif(let key):
            guard let value = ExifWrite.values(of: item.url)?[key] else { return "" }
            if let text = value as? String {
                guard target.isDate else { return text }
                // 2024:07:14 18:30:00 → 2024-07-14 18:30:00
                return text.count >= 10
                    ? String(text.prefix(10)).replacingOccurrences(of: ":", with: "-")
                      + text.dropFirst(10)
                    : text
            }
            let number = (value as? NSNumber) ?? (value as? [NSNumber])?.first
            guard let number else { return "" }
            if key.name == kCGImagePropertyExifExposureTime as String, number.doubleValue < 1 {
                return ExifWrite.fraction(number.doubleValue)
            }
            let double = number.doubleValue
            return double == double.rounded() ? String(Int(double)) : String(double)
        }
    }

    // MARK: - Reading what is typed

    struct Problem: Error {
        let message: String
    }

    /// A date as typed -- `2024-07-14 18:30`, seconds and an offset as one
    /// likes, `:` between the date's parts as EXIF has them too -- as its
    /// day and time, and its offset if one was typed.
    static func date(_ text: String) -> (day: String, time: String, offset: String?)? {
        let pattern = #/^\s*(\d{4})[-:](\d{2})[-:](\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?\s*(Z|[+-]\d{2}:?\d{2})?\s*$/#
        guard let match = text.wholeMatch(of: pattern),
              let month = Int(match.output.2), (1...12).contains(month),
              let day = Int(match.output.3), (1...31).contains(day),
              let hour = Int(match.output.4), hour < 24,
              let minute = Int(match.output.5), minute < 60 else { return nil }
        let seconds = match.output.6.map(String.init) ?? "00"
        guard let second = Int(seconds), second < 60 else { return nil }
        var offset: String?
        if let zone = match.output.7 {
            if zone == "Z" {
                offset = "+00:00"
            } else {
                let digits = zone.filter(\.isNumber)
                offset = "\(zone.first!)\(digits.prefix(2)):\(digits.suffix(2))"
            }
        }
        return ("\(match.output.1)-\(match.output.2)-\(match.output.3)",
                "\(match.output.4):\(match.output.5):\(seconds)", offset)
    }

    /// A date typed, as a moment: its own offset, or this Mac's.
    static func moment(_ text: String) -> Date? {
        guard let (day, time, offset) = date(text) else { return nil }
        if let offset { return dayTimeAndZone.date(from: "\(day) \(time) \(offset)") }
        return dayAndTime.date(from: "\(day) \(time)")
    }

    /// The EXIF changes a value typed into a picture's cell makes: nil
    /// removes the field. A date with an offset sets the time zone beside it.
    static func exifChanges(_ text: String, key: ExifKey) throws(Problem)
        -> [ExifKey: ExifWrite.Change] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [key: .remove] }
        if key == taken || key == digitized {
            guard let (day, time, offset) = date(trimmed) else {
                throw Problem(message: "\u{201C}\(trimmed)\u{201D} is not a date: "
                              + "write it as 2024-07-14 18:30:00")
            }
            var changes: [ExifKey: ExifWrite.Change] = [
                key: .set(day.replacingOccurrences(of: "-", with: ":") + " " + time),
            ]
            if let offset { changes[key == taken ? takenZone : digitizedZone] = .set(offset) }
            return changes
        }
        guard let field = ExifFields.catalogue.first(where: { $0.key == key }) else {
            return [key: .set(trimmed)]
        }
        // As the column shows it: f/1.8, 1/250 s, 24 mm.
        let bare = field.kind == .text ? text
            : trimmed.replacingOccurrences(of: #"^[fF]/|\s*(s|mm)$"#, with: "",
                                          options: .regularExpression)
        do {
            return [key: .set(try ExifFields.value(of: bare, as: field.kind))]
        } catch {
            throw Problem(message: error.message)
        }
    }
}
