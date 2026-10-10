import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The EXIF fields Image ▸ Edit EXIF knows: where each lives in ImageIO's
/// properties, what to call it, and what kind of value it takes.
///
/// EXIF is three dictionaries as ImageIO reads it -- the TIFF one (camera
/// make, artist, copyright), the Exif one proper (dates, exposure, lens) and
/// the GPS one -- and a field is a key in one of them.
enum ExifGroup: String, CaseIterable, Sendable, Codable {
    case tiff = "{TIFF}"
    case exif = "{Exif}"
    case gps = "{GPS}"

    /// `TIFF`, `Exif`, `GPS`: as ImageIO names its dictionaries, without
    /// the braces -- the groups of the JSON a window copies.
    var name: String { String(rawValue.dropFirst().dropLast()) }

    init?(name: String) {
        guard let group = Self.allCases.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else { return nil }
        self = group
    }

    var title: String {
        switch self {
        case .tiff: "Image and Camera"
        case .exif: "Photo"
        case .gps:  "Location"
        }
    }

    var dictionary: CFString {
        switch self {
        case .tiff: kCGImagePropertyTIFFDictionary
        case .exif: kCGImagePropertyExifDictionary
        case .gps:  kCGImagePropertyGPSDictionary
        }
    }
}

struct ExifKey: Hashable, Sendable, Comparable {
    let group: ExifGroup
    let name: String

    /// `Exif › DateTimeOriginal`, for a tooltip.
    var path: String {
        "\(group.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))) \u{203A} \(name)"
    }

    static func < (a: ExifKey, b: ExifKey) -> Bool {
        let order = ExifGroup.allCases
        let (ga, gb) = (order.firstIndex(of: a.group)!, order.firstIndex(of: b.group)!)
        return ga != gb ? ga < gb : a.name < b.name
    }
}

enum ExifKind: Sendable, Equatable {
    case text
    case integer
    case number
    case integers
    case numbers
    /// Shown, and can be removed, but not typed into: a dictionary, raw
    /// bytes, or something ImageIO works out for itself.
    case readOnly
}

/// One of the values EXIF defines for a field: Metering Mode 3 is Spot.
struct ExifChoice: Sendable, Equatable, Hashable {
    let value: String
    let label: String
}

/// Something worked out for each image rather than typed: an image's own
/// width and height.
enum ExifComputed: Sendable, Equatable {
    case pixelWidth
    case pixelHeight
}

/// How a field is edited: the help it gets beyond a text field.
enum ExifInput: Sendable, Equatable {
    case text
    /// `2024:06:30 18:45:00`, with a date picker.
    case dateTime
    /// `2024:06:30`, the GPS date.
    case date
    /// `16:45:00`, the GPS time.
    case time
    /// `+02:00`, chosen as a time zone; the offset is the zone's on the date
    /// in `date`.
    case offset(date: ExifKey?)
    /// One of a list, or anything typed, which is then unusual.
    case choice([ExifChoice])
    /// Degrees, in any of three ways of writing them. The hemisphere is the
    /// field named in `reference`.
    case coordinate(latitude: Bool, reference: ExifKey)
    /// Not typed: taken from each image.
    case computed(ExifComputed)
}

struct ExifField: Sendable, Identifiable {
    let key: ExifKey
    let label: String
    let kind: ExifKind
    /// Offered on every image, set or not. The others appear where a file has
    /// them, or when added.
    let common: Bool
    /// What a value looks like, for the empty field.
    var example: String = ""
    var input: ExifInput = .text

    var id: ExifKey { key }

    /// Something to pick from, with typing as the way past it.
    var hasHelper: Bool {
        switch input {
        case .text, .coordinate, .computed: false
        default: true
        }
    }
}

enum ExifFields {

    // MARK: - Which files

    /// The kinds of image whose EXIF can be changed without re-encoding the
    /// picture. PNG and TIFF are written too, but ImageIO silently keeps some
    /// of their old EXIF values, and AVIF it refuses outright.
    nonisolated static let editableTypes: [UTType] = [.jpeg, .heic, .heif]

    nonisolated static func canEdit(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return editableTypes.contains { type.conforms(to: $0) }
    }

    // MARK: - The catalogue

    private static func key(_ group: ExifGroup, _ name: CFString) -> ExifKey {
        ExifKey(group: group, name: name as String)
    }

    private static func field(_ group: ExifGroup, _ name: CFString, _ label: String,
                              _ kind: ExifKind, common: Bool = false,
                              example: String = "", input: ExifInput = .text) -> ExifField {
        ExifField(key: key(group, name), label: label, kind: kind,
                  common: common, example: example, input: input)
    }

    private static func choices(_ pairs: [(Int, String)]) -> ExifInput {
        .choice(pairs.map { ExifChoice(value: String($0.0), label: $0.1) })
    }

    private static func letters(_ pairs: [(String, String)]) -> ExifInput {
        .choice(pairs.map { ExifChoice(value: $0.0, label: $0.1) })
    }

    nonisolated static let catalogue: [ExifField] = [
        field(.tiff, kCGImagePropertyTIFFImageDescription, "Description", .text, common: true),
        field(.tiff, kCGImagePropertyTIFFArtist, "Artist", .text, common: true),
        field(.tiff, kCGImagePropertyTIFFCopyright, "Copyright", .text, common: true),
        field(.tiff, kCGImagePropertyTIFFMake, "Camera Make", .text, common: true),
        field(.tiff, kCGImagePropertyTIFFModel, "Camera Model", .text, common: true),
        field(.tiff, kCGImagePropertyTIFFSoftware, "Software", .text, common: true),
        field(.tiff, kCGImagePropertyTIFFDateTime, "Date Modified", .text, common: true,
              example: "2024:06:30 18:45:00", input: .dateTime),
        field(.tiff, kCGImagePropertyTIFFOrientation, "Orientation", .integer,
              input: choices([(1, "Upright"), (2, "Mirrored left to right"),
                              (3, "Upside down"), (4, "Mirrored top to bottom"),
                              (5, "Mirrored, then turned 90\u{00B0} anticlockwise"),
                              (6, "Turned 90\u{00B0} clockwise"),
                              (7, "Mirrored, then turned 90\u{00B0} clockwise"),
                              (8, "Turned 90\u{00B0} anticlockwise")])),
        field(.tiff, kCGImagePropertyTIFFXResolution, "Horizontal Resolution", .number),
        field(.tiff, kCGImagePropertyTIFFYResolution, "Vertical Resolution", .number),
        field(.tiff, kCGImagePropertyTIFFResolutionUnit, "Resolution Unit", .integer,
              input: choices([(1, "None"), (2, "Inch"), (3, "Centimetre")])),
        field(.tiff, kCGImagePropertyTIFFHostComputer, "Host Computer", .text),

        field(.exif, kCGImagePropertyExifDateTimeOriginal, "Date Taken", .text, common: true,
              example: "2024:06:30 18:45:00", input: .dateTime),
        field(.exif, kCGImagePropertyExifOffsetTimeOriginal, "Time Zone Taken", .text,
              common: true, example: "+02:00",
              input: .offset(date: key(.exif, kCGImagePropertyExifDateTimeOriginal))),
        field(.exif, kCGImagePropertyExifDateTimeDigitized, "Date Digitised", .text,
              common: true, example: "2024:06:30 18:45:00", input: .dateTime),
        field(.exif, kCGImagePropertyExifOffsetTimeDigitized, "Time Zone Digitised", .text,
              example: "+02:00",
              input: .offset(date: key(.exif, kCGImagePropertyExifDateTimeDigitized))),
        field(.exif, kCGImagePropertyExifOffsetTime, "Time Zone Modified", .text,
              example: "+02:00",
              input: .offset(date: key(.tiff, kCGImagePropertyTIFFDateTime))),
        field(.exif, kCGImagePropertyExifUserComment, "Comment", .text, common: true),
        field(.exif, kCGImagePropertyExifCameraOwnerName, "Camera Owner", .text, common: true),
        field(.exif, kCGImagePropertyExifBodySerialNumber, "Camera Serial Number", .text),
        field(.exif, kCGImagePropertyExifLensMake, "Lens Make", .text, common: true),
        field(.exif, kCGImagePropertyExifLensModel, "Lens Model", .text, common: true),
        field(.exif, kCGImagePropertyExifLensSerialNumber, "Lens Serial Number", .text),
        field(.exif, kCGImagePropertyExifExposureTime, "Exposure Time (s)", .number,
              common: true, example: "1/125"),
        field(.exif, kCGImagePropertyExifFNumber, "F-Number", .number, common: true,
              example: "2.8"),
        field(.exif, kCGImagePropertyExifISOSpeedRatings, "ISO", .integers, common: true,
              example: "400"),
        field(.exif, kCGImagePropertyExifFocalLength, "Focal Length (mm)", .number,
              common: true),
        field(.exif, kCGImagePropertyExifFocalLenIn35mmFilm, "Focal Length, 35 mm (mm)",
              .integer),
        field(.exif, kCGImagePropertyExifExposureBiasValue, "Exposure Bias (EV)", .number),
        field(.exif, kCGImagePropertyExifExposureProgram, "Exposure Program", .integer,
              input: choices([(0, "Not defined"), (1, "Manual"), (2, "Normal program"),
                              (3, "Aperture priority"), (4, "Shutter priority"),
                              (5, "Creative (depth of field)"), (6, "Action (fast shutter)"),
                              (7, "Portrait"), (8, "Landscape")])),
        field(.exif, kCGImagePropertyExifExposureMode, "Exposure Mode", .integer,
              input: choices([(0, "Auto"), (1, "Manual"), (2, "Auto bracket")])),
        field(.exif, kCGImagePropertyExifMeteringMode, "Metering Mode", .integer,
              input: choices([(0, "Unknown"), (1, "Average"), (2, "Centre-weighted average"),
                              (3, "Spot"), (4, "Multi-spot"), (5, "Pattern"), (6, "Partial"),
                              (255, "Other")])),
        field(.exif, kCGImagePropertyExifLightSource, "Light Source", .integer,
              input: choices([(0, "Unknown"), (1, "Daylight"), (2, "Fluorescent"),
                              (3, "Tungsten"), (4, "Flash"), (9, "Fine weather"),
                              (10, "Cloudy"), (11, "Shade"), (12, "Daylight fluorescent"),
                              (13, "Day white fluorescent"), (14, "Cool white fluorescent"),
                              (15, "White fluorescent"), (17, "Standard light A"),
                              (18, "Standard light B"), (19, "Standard light C"),
                              (20, "D55"), (21, "D65"), (22, "D75"), (23, "D50"),
                              (24, "ISO studio tungsten"), (255, "Other")])),
        field(.exif, kCGImagePropertyExifWhiteBalance, "White Balance", .integer,
              input: choices([(0, "Auto"), (1, "Manual")])),
        field(.exif, kCGImagePropertyExifSceneCaptureType, "Scene Type", .integer,
              input: choices([(0, "Standard"), (1, "Landscape"), (2, "Portrait"),
                              (3, "Night")])),
        field(.exif, kCGImagePropertyExifContrast, "Contrast", .integer,
              input: choices([(0, "Normal"), (1, "Low"), (2, "High")])),
        field(.exif, kCGImagePropertyExifSaturation, "Saturation", .integer,
              input: choices([(0, "Normal"), (1, "Low"), (2, "High")])),
        field(.exif, kCGImagePropertyExifSharpness, "Sharpness", .integer,
              input: choices([(0, "Normal"), (1, "Soft"), (2, "Hard")])),
        field(.exif, kCGImagePropertyExifSubjectDistRange, "Subject Distance", .integer,
              input: choices([(0, "Unknown"), (1, "Macro"), (2, "Close"), (3, "Distant")])),
        field(.exif, kCGImagePropertyExifCustomRendered, "Processing", .integer,
              input: choices([(0, "Normal"), (1, "Custom")])),
        field(.exif, kCGImagePropertyExifColorSpace, "Colour Space", .integer,
              input: choices([(1, "sRGB"), (65535, "Uncalibrated")])),
        field(.exif, kCGImagePropertyExifPixelXDimension, "Image Width (pixels)", .readOnly,
              input: .computed(.pixelWidth)),
        field(.exif, kCGImagePropertyExifPixelYDimension, "Image Height (pixels)", .readOnly,
              input: .computed(.pixelHeight)),

        field(.gps, kCGImagePropertyGPSLatitude, "Latitude", .number, common: true,
              example: "47.4979",
              input: .coordinate(latitude: true,
                                 reference: key(.gps, kCGImagePropertyGPSLatitudeRef))),
        field(.gps, kCGImagePropertyGPSLatitudeRef, "Latitude N/S", .text, common: true,
              input: letters([("N", "North"), ("S", "South")])),
        field(.gps, kCGImagePropertyGPSLongitude, "Longitude", .number, common: true,
              example: "19.0402",
              input: .coordinate(latitude: false,
                                 reference: key(.gps, kCGImagePropertyGPSLongitudeRef))),
        field(.gps, kCGImagePropertyGPSLongitudeRef, "Longitude E/W", .text, common: true,
              input: letters([("E", "East"), ("W", "West")])),
        field(.gps, kCGImagePropertyGPSAltitude, "Altitude (m)", .number, common: true),
        field(.gps, kCGImagePropertyGPSAltitudeRef, "Altitude Below Sea Level", .integer,
              input: choices([(0, "Above sea level"), (1, "Below sea level")])),
        field(.gps, kCGImagePropertyGPSDateStamp, "GPS Date", .text, example: "2024:06:30",
              input: .date),
        field(.gps, kCGImagePropertyGPSTimeStamp, "GPS Time (UTC)", .text,
              example: "16:45:00", input: .time),
        field(.gps, kCGImagePropertyGPSImgDirection, "Direction (degrees)", .number),
        field(.gps, kCGImagePropertyGPSImgDirectionRef, "Direction Reference", .text,
              input: letters([("T", "True north"), ("M", "Magnetic north")])),
        field(.gps, kCGImagePropertyGPSSpeed, "Speed", .number),
        field(.gps, kCGImagePropertyGPSSpeedRef, "Speed Unit", .text,
              input: letters([("K", "km/h"), ("M", "mph"), ("N", "Knots")])),
    ]

    /// What ImageIO keeps for its own bookkeeping, or cannot write: written
    /// over, it keeps its own value. Flash is a structure in XMP, and a number
    /// written to it comes out 0.
    nonisolated static let computed: Set<String> = [
        kCGImagePropertyExifFlash as String,
        kCGImagePropertyExifVersion as String,
        kCGImagePropertyExifFlashPixVersion as String,
        kCGImagePropertyExifComponentsConfiguration as String,
        kCGImagePropertyGPSVersion as String,
    ]

    /// The catalogue's field, or one made up for a key a file has that the
    /// catalogue does not know, its kind read from the value.
    nonisolated static func field(for key: ExifKey, sample: Any?) -> ExifField {
        if let known = catalogue.first(where: { $0.key == key }) { return known }
        return ExifField(key: key, label: label(for: key.name),
                         kind: computed.contains(key.name) ? .readOnly : kind(of: sample),
                         common: false)
    }

    /// `ShutterSpeedValue` as "Shutter Speed Value".
    nonisolated static func label(for name: String) -> String {
        var words = ""
        let characters = Array(name)
        for (index, character) in characters.enumerated() {
            if index > 0, character.isUppercase,
               characters[index - 1].isLowercase
                || (index + 1 < characters.count && characters[index + 1].isLowercase
                    && characters[index - 1].isUppercase) {
                words.append(" ")
            }
            words.append(character)
        }
        return words
    }

    nonisolated static func kind(of value: Any?) -> ExifKind {
        switch value {
        case is String:
            return .text
        case let number as NSNumber:
            return isInteger(number) ? .integer : .number
        case let array as [Any] where !array.isEmpty && array.allSatisfy({ $0 is NSNumber }):
            return array.allSatisfy { isInteger($0 as! NSNumber) } ? .integers : .numbers
        default:
            return .readOnly
        }
    }

    private nonisolated static func isInteger(_ number: NSNumber) -> Bool {
        let type = String(cString: number.objCType)
        return !["f", "d"].contains(type)
    }

    // MARK: - Values as text

    /// How a value is shown and compared: the same text means the same value.
    nonisolated static func text(of value: Any) -> String? {
        switch value {
        case let text as String:
            return text
        case let number as NSNumber:
            return format(number.doubleValue)
        case let array as [Any]:
            let parts = array.compactMap { $0 as? NSNumber }.map { format($0.doubleValue) }
            if parts.count == array.count { return parts.joined(separator: ", ") }
            let words = array.compactMap { $0 as? String }
            return words.count == array.count ? words.joined(separator: ", ") : nil
        default:
            return nil
        }
    }

    /// Whole numbers without a decimal point, others as short as they are
    /// exact: 2.8, not 2.7999999999999998.
    nonisolated static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.10g", value)
    }

    enum ParseError: Error, Equatable {
        case notANumber(String)
        case notAWholeNumber(String)
        case readOnly

        var message: String {
            switch self {
            case .notANumber(let text):      "\u{201C}\(text)\u{201D} is not a number"
            case .notAWholeNumber(let text): "\u{201C}\(text)\u{201D} is not a whole number"
            case .readOnly:                  "This field cannot be typed into"
            }
        }
    }

    /// What is typed, as the value to write. A fraction is a number too --
    /// an exposure time is written 1/125 everywhere else.
    nonisolated static func value(of text: String, as kind: ExifKind) throws(ParseError) -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .text:
            return text
        case .number:
            return NSNumber(value: try number(trimmed))
        case .integer:
            return NSNumber(value: try integer(trimmed))
        case .numbers:
            var values: [NSNumber] = []
            for part in parts(trimmed) { values.append(NSNumber(value: try number(part))) }
            return values
        case .integers:
            var values: [NSNumber] = []
            for part in parts(trimmed) { values.append(NSNumber(value: try integer(part))) }
            return values
        case .readOnly:
            throw .readOnly
        }
    }

    private nonisolated static func parts(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
    }

    private nonisolated static func number(_ text: String) throws(ParseError) -> Double {
        let halves = text.split(separator: "/", omittingEmptySubsequences: false)
        if halves.count == 2, let top = Double(halves[0]), let bottom = Double(halves[1]),
           bottom != 0 {
            return top / bottom
        }
        guard let value = Double(text), value.isFinite else { throw .notANumber(text) }
        return value
    }

    private nonisolated static func integer(_ text: String) throws(ParseError) -> Int {
        guard let value = Int(text) else { throw .notAWholeNumber(text) }
        return value
    }

    /// Whether what a file now holds is what was written. Numbers are stored
    /// as fractions, so 2.8 may come back a hair away from 2.8.
    nonisolated static func same(_ found: Any, _ wanted: Any) -> Bool {
        if let a = found as? NSNumber, let b = wanted as? NSNumber {
            return close(a.doubleValue, b.doubleValue)
        }
        if let a = found as? [NSNumber], let b = wanted as? [NSNumber] {
            return a.count == b.count && zip(a, b).allSatisfy { close($0.doubleValue, $1.doubleValue) }
        }
        // ISO written as a single number comes back as a list of one.
        if let a = found as? [NSNumber], let b = wanted as? NSNumber, a.count == 1 {
            return close(a[0].doubleValue, b.doubleValue)
        }
        if let a = found as? String, let b = wanted as? String {
            return a.trimmingCharacters(in: .whitespacesAndNewlines)
                == b.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text(of: found) == text(of: wanted)
    }

    private nonisolated static func close(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= max(abs(a), abs(b)) * 1e-4 + 1e-9
    }
}
