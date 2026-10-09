import Foundation
import ImageIO

/// The ways of writing a coordinate, which the Location heading's button
/// goes round.
enum CoordinateFormat: CaseIterable, Sendable {
    /// 47.4979
    case decimal
    /// 47° 29.874′
    case degreesMinutes
    /// 47° 29′ 52.44″
    case degreesMinutesSeconds

    var next: CoordinateFormat {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    var title: String {
        switch self {
        case .decimal:               "Decimal Degrees"
        case .degreesMinutes:        "Degrees and Minutes"
        case .degreesMinutesSeconds: "Degrees, Minutes and Seconds"
        }
    }

    var example: String {
        switch self {
        case .decimal:               "47.4979"
        case .degreesMinutes:        "47\u{00B0} 29.874\u{2032}"
        case .degreesMinutesSeconds: "47\u{00B0} 29\u{2032} 52.44\u{2033}"
        }
    }
}

/// Whether a value is one a camera would write.
enum ExifVerdict: Equatable, Sendable {
    case fine
    /// Can be written, but is not what a photo would have: shown in orange.
    case unusual(String)
    /// Cannot be written as it is: shown in red, and Save waits for it.
    case wrong(String)

    var message: String? {
        switch self {
        case .fine:                 nil
        case .unusual(let message): message
        case .wrong(let message):   message
        }
    }
}

extension ExifFields {

    // MARK: - Coordinates

    struct Coordinate: Equatable {
        /// Degrees, never negative: the hemisphere is separate in EXIF.
        let degrees: Double
        /// N, S, E or W, when the text said so -- a letter, or a minus sign.
        let hemisphere: String?
    }

    /// Any of `47.4979`, `-47.4979`, `47° 29.874′`, `47 29 52.44 N`,
    /// `S 33° 51′ 54″`. Nil when it is not a coordinate; the range is checked
    /// separately, so a wrong one can say why.
    nonisolated static func coordinate(from text: String, latitude: Bool) -> Coordinate? {
        var rest = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard !rest.isEmpty else { return nil }
        var hemisphere: String?
        let letters: Set<Character> = latitude ? ["N", "S"] : ["E", "W"]
        if let last = rest.last, letters.contains(last) {
            hemisphere = String(last)
            rest.removeLast()
        } else if let first = rest.first, letters.contains(first) {
            hemisphere = String(first)
            rest.removeFirst()
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("-") {
            guard hemisphere == nil else { return nil }
            hemisphere = latitude ? "S" : "W"
            rest.removeFirst()
        }
        // Degrees, minutes and seconds, whatever marks separate them.
        let parts = rest.split(whereSeparator: { !"0123456789.".contains($0) }).map(String.init)
        let numbers = parts.compactMap(Double.init)
        guard (1...3).contains(parts.count), numbers.count == parts.count,
              rest.allSatisfy({ "0123456789. \u{00B0}'\u{2032}\u{2019}\"\u{2033}".contains($0) })
        else { return nil }
        // Minutes and seconds under 60, and whole where something follows.
        if numbers.count > 1 {
            guard numbers[1] < 60, numbers[0] == numbers[0].rounded() else { return nil }
        }
        if numbers.count > 2 {
            guard numbers[2] < 60, numbers[1] == numbers[1].rounded() else { return nil }
        }
        let degrees = numbers[0] + (numbers.count > 1 ? numbers[1] / 60 : 0)
            + (numbers.count > 2 ? numbers[2] / 3600 : 0)
        return Coordinate(degrees: degrees, hemisphere: hemisphere)
    }

    /// Degrees written one of the three ways.
    nonisolated static func format(degrees: Double, as format: CoordinateFormat) -> String {
        func trimmed(_ value: Double, places: Int) -> String {
            var text = String(format: "%.\(places)f", value)
            while text.contains("."), text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            return text
        }
        switch format {
        case .decimal:
            return trimmed(degrees, places: 6)
        case .degreesMinutes:
            var whole = degrees.rounded(.down)
            var minutes = ((degrees - whole) * 60 * 1000).rounded() / 1000
            if minutes >= 60 { whole += 1; minutes = 0 }
            return "\(Int(whole))\u{00B0} \(trimmed(minutes, places: 3))\u{2032}"
        case .degreesMinutesSeconds:
            var whole = degrees.rounded(.down)
            var minutes = ((degrees - whole) * 60).rounded(.down)
            var seconds = ((degrees - whole - minutes / 60) * 3600 * 100).rounded() / 100
            if seconds >= 60 { minutes += 1; seconds = 0 }
            if minutes >= 60 { whole += 1; minutes = 0 }
            return "\(Int(whole))\u{00B0} \(Int(minutes))\u{2032} "
                + "\(trimmed(seconds, places: 2))\u{2033}"
        }
    }

    // MARK: - Dates

    /// EXIF writes a date and time as `2024:06:30 18:45:00`, with no zone:
    /// the clock on the wall where the photo was taken. Read and written in
    /// UTC here only so that nothing shifts it.
    nonisolated static func exifDate(_ text: String, format: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else {
            return nil
        }
        return date
    }

    nonisolated static func exifText(_ date: Date, format: String,
                                     in zone: TimeZone = TimeZone(secondsFromGMT: 0)!) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    nonisolated static let dateTimeFormat = "yyyy:MM:dd HH:mm:ss"
    nonisolated static let dateFormat = "yyyy:MM:dd"
    nonisolated static let timeFormat = "HH:mm:ss"

    /// The first digital camera was built in 1975; a photo dated before it
    /// is a scan, or a mistake.
    nonisolated static let firstDigitalCamera = 1975

    /// GPS counts its time from midnight UTC, 6 January 1980: no receiver
    /// can have stamped a date before it.
    nonisolated static let gpsEpoch = exifDate("1980:01:06", format: dateFormat)!

    // MARK: - Time zones

    /// `+02:00`, the offset `zone` had at the wall-clock `dateTime` -- summer
    /// time or not, as it was on that day. Today's, without a date.
    nonisolated static func offset(of zone: TimeZone, at dateTime: String?) -> String {
        var moment = Date()
        if let dateTime {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            formatter.dateFormat = dateTimeFormat
            moment = formatter.date(from: dateTime) ?? moment
        }
        return offsetText(seconds: zone.secondsFromGMT(for: moment))
    }

    nonisolated static func offsetText(seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let minutes = abs(seconds) / 60
        return String(format: "%@%02d:%02d", sign, minutes / 60, minutes % 60)
    }

    /// The zones by region -- Africa, America, Europe... -- and the cities in
    /// each, for the time zone menu.
    nonisolated static let zonesByRegion: [(region: String, zones: [(id: String, city: String)])] = {
        var regions: [String: [(String, String)]] = [:]
        for id in TimeZone.knownTimeZoneIdentifiers where id.contains("/") {
            let parts = id.split(separator: "/")
            let region = String(parts[0])
            guard !["Etc", "SystemV", "US", "Canada", "Brazil", "Chile", "Mexico"]
                .contains(region) else { continue }
            let city = parts.dropFirst().joined(separator: " \u{2013} ")
                .replacingOccurrences(of: "_", with: " ")
            regions[region, default: []].append((id, city))
        }
        return regions.keys.sorted().map { region in
            (region, regions[region]!.sorted { $0.1 < $1.1 }.map { (id: $0.0, city: $0.1) })
        }
    }()

    // MARK: - Is it a value a camera would write?

    nonisolated static func verdict(of text: String, for field: ExifField,
                                    now: Date = Date()) -> ExifVerdict {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .fine }

        switch field.input {
        case .dateTime, .date:
            let format = field.input == .date ? dateFormat : dateTimeFormat
            guard let date = exifDate(trimmed, format: format) else {
                return .unusual("Not a date as EXIF writes it: "
                                + (field.input == .date ? "2024:06:30" : "2024:06:30 18:45:00"))
            }
            return dateVerdict(date, now: now, gps: field.key.group == .gps)

        case .time:
            return exifDate(trimmed, format: timeFormat) == nil
                ? .wrong("A time is written 16:45:00, under 24 hours") : .fine

        case .offset:
            let parts = trimmed.dropFirst().split(separator: ":")
            guard let sign = trimmed.first, sign == "+" || sign == "-", parts.count == 2,
                  parts.allSatisfy({ $0.count == 2 }),
                  let hours = Int(parts[0]), let minutes = Int(parts[1]), minutes < 60 else {
                return .unusual("A time zone is written +02:00")
            }
            let total = (hours * 60 + minutes) * (sign == "-" ? -1 : 1)
            return (-12 * 60 ... 14 * 60).contains(total)
                ? .fine : .unusual("No time zone is that far from UTC")

        case .choice(let choices):
            if field.kind == .integer, Int(trimmed) == nil {
                return .wrong("Not a whole number")
            }
            return choices.contains { $0.value == trimmed }
                ? .fine : .unusual("Not one of the values EXIF defines for it")

        case .coordinate(let latitude, _):
            guard let coordinate = coordinate(from: trimmed, latitude: latitude) else {
                return .wrong("Not a coordinate: write it " + CoordinateFormat.allCases
                    .map(\.example).joined(separator: ", or "))
            }
            let limit: Double = latitude ? 90 : 180
            return coordinate.degrees <= limit
                ? .fine
                : .wrong("A \(latitude ? "latitude" : "longitude") is at most "
                         + "\(Int(limit))\u{00B0}")

        case .computed:
            return .fine

        case .text:
            break
        }

        if field.kind != .text {
            do {
                _ = try value(of: trimmed, as: field.kind)
            } catch {
                return .wrong(error.message)
            }
        }
        if positive.contains(field.key.name),
           let number = (try? value(of: trimmed, as: field.kind)).flatMap(firstNumber),
           number <= 0 {
            return .unusual("A camera writes more than 0 here")
        }
        if field.key.name == kCGImagePropertyGPSImgDirection as String,
           let number = Double(trimmed), !(0..<360).contains(number) {
            return .unusual("A direction is from 0 to under 360\u{00B0}")
        }
        return .fine
    }

    private nonisolated static func dateVerdict(_ date: Date, now: Date, gps: Bool) -> ExifVerdict {
        if gps, date < gpsEpoch {
            return .unusual("Before 6 January 1980, when GPS time began")
        }
        let year = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(secondsFromGMT: 0)!, from: date).year ?? 0
        if year < firstDigitalCamera {
            return .unusual("Before \(firstDigitalCamera), when the first digital camera "
                            + "was made")
        }
        // A day's grace: the wall clock of a photo taken east of here is
        // ahead of ours.
        if date.timeIntervalSince(now) > 24 * 3600 + 14 * 3600 {
            return .unusual("In the future")
        }
        return .fine
    }

    private nonisolated static let positive: Set<String> = [
        kCGImagePropertyExifExposureTime as String, kCGImagePropertyExifFNumber as String,
        kCGImagePropertyExifISOSpeedRatings as String, kCGImagePropertyExifFocalLength as String,
        kCGImagePropertyExifFocalLenIn35mmFilm as String,
    ]

    private nonisolated static func firstNumber(_ value: Any) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? [NSNumber])?.first?.doubleValue
    }
}
