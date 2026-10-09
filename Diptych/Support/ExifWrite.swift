import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Reading an image's EXIF, and writing it back changed -- without decoding
/// and re-encoding the picture, so not a pixel of it changes.
///
/// ImageIO's lossless route: the metadata is edited as `CGImageMetadata` and
/// `CGImageDestinationCopyImageSource` copies the image data across as it is.
/// What comes out is read back before anything is written to disk, and a file
/// where a change did not take is left alone: ImageIO accepts some changes it
/// then quietly drops.
enum ExifWrite {

    enum Change: @unchecked Sendable {
        case set(Any)
        case remove
        /// The offset of a time zone, `+02:00`, on the date in `date` as each
        /// image has it -- or as it is being set -- so summer time comes out
        /// right for every image on its own day.
        case zone(String, date: ExifKey?)
        /// Taken from each image itself: its width or height.
        case computed(ExifComputed)
    }

    struct Failure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    /// Every TIFF, Exif and GPS value the image holds.
    nonisolated static func values(of url: URL) -> [ExifKey: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return values(in: source)
    }

    nonisolated static func values(in source: CGImageSource) -> [ExifKey: Any]? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [String: Any] else { return nil }
        var values: [ExifKey: Any] = [:]
        for group in ExifGroup.allCases {
            guard let dictionary = properties[group.rawValue] as? [String: Any] else { continue }
            for (name, value) in dictionary {
                values[ExifKey(group: group, name: name)] = value
            }
        }
        return values
    }

    /// The image in `data` with every EXIF, TIFF and GPS field taken out,
    /// checked; nil when it has none. Orientation stays: without it the
    /// picture would show turned.
    nonisolated static func eraseAll(_ data: Data, name: String) throws(Failure) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let values = values(in: source) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be read as an image.")
        }
        let orientation = ExifKey(group: .tiff, name: kCGImagePropertyTIFFOrientation as String)
        var changes: [ExifKey: Change] = [:]
        for key in values.keys where key != orientation {
            changes[key] = .remove
        }
        // Adobe's XMP copy of camera details EXIF has no field for -- the
        // lens and its serial number -- and what is left of the newer EXIF.
        let stripped: Set<String> = ["aux", "exifEX"]
        let hasStripped = (CGImageSourceCopyMetadataAtIndex(source, 0, nil)
            .flatMap { CGImageMetadataCopyTags($0) as? [CGImageMetadataTag] } ?? [])
            .contains { (CGImageMetadataTagCopyPrefix($0) as String?).map(stripped.contains) == true }
        guard !changes.isEmpty || hasStripped else { return nil }
        return try rewrite(data, name: name, changes: changes, stripping: stripped)
    }

    /// The image in `data` without where it was taken: every GPS field, and
    /// the place names photo software writes beside them; checked. Nil when
    /// it has none.
    nonisolated static func removeLocation(_ data: Data, name: String) throws(Failure) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let values = values(in: source) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be read as an image.")
        }
        var changes: [ExifKey: Change] = [:]
        for key in values.keys where key.group == .gps {
            changes[key] = .remove
        }
        let places = (CGImageSourceCopyMetadataAtIndex(source, 0, nil)
            .flatMap { CGImageMetadataCopyTags($0) as? [CGImageMetadataTag] } ?? [])
            .contains { tag in
                guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                      let tagName = CGImageMetadataTagCopyName(tag) as String? else { return false }
                return placeTags.contains("\(prefix):\(tagName)")
            }
        guard !changes.isEmpty || places else { return nil }
        return try rewrite(data, name: name, changes: changes, removingPaths: placeTags)
    }

    /// Where IPTC and Photoshop keep a place by its name.
    nonisolated static let placeTags: Set<String> = [
        "photoshop:City", "photoshop:State", "photoshop:Country",
        "Iptc4xmpCore:Location", "Iptc4xmpCore:CountryCode",
    ]

    /// Turning or mirroring a picture as it is shown, by its Orientation
    /// alone: the pixels are not decoded, so nothing of the quality is lost.
    enum Turn: Sendable, CaseIterable {
        case left, right, flipHorizontal, flipVertical

        /// The Orientation after the turn, for each of the eight before it.
        func applied(to orientation: Int) -> Int {
            let table: [Int: Int] = switch self {
            case .right:          [1: 6, 6: 3, 3: 8, 8: 1, 2: 7, 7: 4, 4: 5, 5: 2]
            case .left:           [1: 8, 8: 3, 3: 6, 6: 1, 2: 5, 5: 4, 4: 7, 7: 2]
            case .flipHorizontal: [1: 2, 2: 1, 3: 4, 4: 3, 5: 6, 6: 5, 7: 8, 8: 7]
            case .flipVertical:   [1: 4, 4: 1, 2: 3, 3: 2, 5: 8, 8: 5, 6: 7, 7: 6]
            }
            return table[orientation] ?? table[1]!
        }
    }

    nonisolated static let orientationKey = ExifKey(group: .tiff,
                                                    name: kCGImagePropertyTIFFOrientation as String)

    /// The image in `data` turned; checked. JPEG and HEIC by their
    /// Orientation, other formats by their pixels -- PNG and TIFF lose
    /// nothing by it either.
    nonisolated static func turn(_ data: Data, name: String, _ turn: Turn) throws(Failure) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be read as an image.")
        }
        let now = orientation(of: source)
        let next = turn.applied(to: (1...8).contains(now) ? now : 1)
        guard let type = CGImageSourceGetType(source) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be read as an image.")
        }
        let byOrientation = [UTType.jpeg, .heic, .heif].map(\.identifier).contains(type as String)
        guard byOrientation else {
            return try turnPixels(source, type: type, to: next, name: name)
        }
        // The orientation option alone, not new metadata: HEIC keeps its
        // turn in the container rather than in EXIF, and only this option
        // writes it there. The rest of the metadata is copied as it is.
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} cannot be written in its format.")
        }
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(
            destination, source, [kCGImageDestinationOrientation: next] as CFDictionary, &error)
        else {
            let reason = (error?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String }
            throw Failure(message: "\u{201C}\(name)\u{201D} cannot be turned"
                          + (reason.map { ": \($0)" } ?? "."))
        }
        let result = output as Data
        guard let written = CGImageSourceCreateWithData(result as CFData, nil),
              orientation(of: written) == next else {
            throw Failure(message: "\u{201C}\(name)\u{201D} would not keep its new "
                          + "orientation, so it was left as it was.")
        }
        return result
    }

    /// A format that keeps no turn of its own, or that viewers ignore:
    /// the pixels drawn as `orientation` says, and the image upright.
    private nonisolated static func turnPixels(_ source: CGImageSource, type: CFString,
                                               to orientation: Int,
                                               name: String) throws(Failure) -> Data {
        guard CGImageSourceGetCount(source) == 1 else {
            throw Failure(message: "\u{201C}\(name)\u{201D} has several frames, which are not "
                          + "turned.")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let exif = CGImagePropertyOrientation(rawValue: UInt32(orientation)) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be decoded.")
        }
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let turned = CIImage(cgImage: image).oriented(exif)
        let format: CIFormat = image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8
        guard let pixels = CIContext().createCGImage(turned, from: turned.extent, format: format,
                                                     colorSpace: space) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be turned.")
        }
        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            ?? [:]
        properties[kCGImagePropertyOrientation] = 1
        properties.removeValue(forKey: kCGImagePropertyPixelWidth)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight)
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} cannot be written in its format, so "
                          + "it cannot be turned.")
        }
        CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be written turned.")
        }
        return output as Data
    }

    /// How the picture is to be turned to be shown: 1 to 8, 1 upright.
    nonisolated static func orientation(of source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }

    /// The image in `data` with `changes` made, checked.
    nonisolated static func rewrite(_ data: Data, name: String, changes: [ExifKey: Change],
                                    stripping prefixes: Set<String> = [],
                                    removingPaths paths: Set<String> = []) throws(Failure) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be read as an image.")
        }
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
            .flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
        var changes = resolved(changes, in: source)

        // Artist on its own, in an image with no other TIFF field, is
        // accepted and then dropped on the way out; with Orientation beside
        // it, it is kept. An image without an Orientation is upright, which
        // is what 1 says, so writing it changes nothing about the picture.
        let settingTIFF = changes.contains {
            if case .set = $0.value { return $0.key.group == .tiff }
            return false
        }
        if settingTIFF,
           CGImageMetadataCopyTagMatchingImageProperty(
               metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation) == nil {
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation,
                NSNumber(value: 1))
        }

        // GPS date and time are one value in XMP, so they are written as one:
        // set one at a time, the date came out as 1916:01:00.
        let date = changes.removeValue(forKey: gpsDate)
        let time = changes.removeValue(forKey: gpsTime)
        if date != nil || time != nil {
            try setGPSTime(date: date, time: time, in: metadata, existing: values(in: source),
                           name: name)
        }

        for (key, change) in changes {
            let dictionary = key.group.dictionary
            let property = key.name as CFString
            switch change {
            case .set(let value):
                guard CGImageMetadataSetValueMatchingImageProperty(
                    metadata, dictionary, property, stored(value, for: key)) else {
                    throw Failure(message: "\(key.path) cannot be set in \u{201C}\(name)\u{201D}.")
                }
            case .zone, .computed:
                continue   // resolved above
            case .remove:
                // Removed by its path, which is what the tag is called in
                // the metadata -- "exif:DateTimeOriginal" and the like.
                guard let tag = CGImageMetadataCopyTagMatchingImageProperty(
                    metadata, dictionary, property),
                      let prefix = CGImageMetadataTagCopyPrefix(tag),
                      let tagName = CGImageMetadataTagCopyName(tag) else { continue }
                CGImageMetadataRemoveTagWithPath(metadata, nil,
                                                 "\(prefix):\(tagName)" as CFString)
                // ImageIO makes the ISO up again from the newer EXIF's
                // sensitivity, which a camera writes beside it.
                if key.name == kCGImagePropertyExifISOSpeedRatings as String {
                    CGImageMetadataRemoveTagWithPath(metadata, nil,
                                                     "exifEX:PhotographicSensitivity" as CFString)
                }
            }
        }

        for path in paths {
            CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
        }

        if !prefixes.isEmpty, let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] {
            for tag in tags {
                guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                      prefixes.contains(prefix),
                      let tagName = CGImageMetadataTagCopyName(tag) else { continue }
                CGImageMetadataRemoveTagWithPath(metadata, nil, "\(prefix):\(tagName)" as CFString)
            }
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} cannot be written in its format.")
        }
        let options = [kCGImageDestinationMetadata: metadata,
                       kCGImageDestinationMergeMetadata: false] as CFDictionary
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options, &error) else {
            let reason = (error?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String }
            throw Failure(message: "The EXIF of \u{201C}\(name)\u{201D} cannot be changed"
                          + (reason.map { ": \($0)" } ?? "."))
        }
        let result = output as Data
        var all = changes
        if let date { all[gpsDate] = date }
        if let time { all[gpsTime] = time }
        try check(result, name: name, against: all)
        return result
    }

    /// Time zones and image sizes worked out for this image, so every change
    /// left is a value to set or a field to remove.
    nonisolated static func resolved(_ changes: [ExifKey: Change],
                                     in source: CGImageSource) -> [ExifKey: Change] {
        let existing = values(in: source) ?? [:]
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        var result: [ExifKey: Change] = [:]
        for (key, change) in changes {
            switch change {
            case .zone(let identifier, let dateKey):
                guard let zone = TimeZone(identifier: identifier) else { continue }
                var date: String?
                if let dateKey {
                    if case .set(let typed as String)? = changes[dateKey] {
                        date = typed
                    } else {
                        date = existing[dateKey] as? String
                    }
                }
                result[key] = .set(ExifFields.offset(of: zone, at: date))
            case .computed(let what):
                let property = what == .pixelWidth ? kCGImagePropertyPixelWidth
                                                   : kCGImagePropertyPixelHeight
                if let size = properties?[property as String] as? NSNumber {
                    result[key] = .set(size)
                }
            case .set, .remove:
                result[key] = change
            }
        }
        return result
    }

    nonisolated static let gpsDate = ExifKey(group: .gps,
                                             name: kCGImagePropertyGPSDateStamp as String)
    nonisolated static let gpsTime = ExifKey(group: .gps,
                                             name: kCGImagePropertyGPSTimeStamp as String)

    /// XMP's one GPS time stamp, `2024-06-30T16:45:00Z`, from a date of
    /// `2024:06:30` and a time of `16:45:00` -- each the one typed, or the one
    /// the image already has. Removing either removes both.
    private nonisolated static func setGPSTime(date: Change?, time: Change?,
                                               in metadata: CGMutableImageMetadata,
                                               existing: [ExifKey: Any]?,
                                               name: String) throws(Failure) {
        if case .remove = date { return removeGPSTime(from: metadata) }
        if case .remove = time { return removeGPSTime(from: metadata) }
        let typedDate: String? = if case .set(let value) = date { value as? String } else { nil }
        let typedTime: String? = if case .set(let value) = time { value as? String } else { nil }
        guard let day = (typedDate ?? existing?[gpsDate] as? String)
            .flatMap({ isoDate($0) }) else {
            throw Failure(message: typedDate == nil
                          ? "A GPS time needs a GPS date to go with it."
                          : "The GPS date is written 2024:06:30.")
        }
        guard let clock = isoTime(typedTime ?? existing?[gpsTime] as? String ?? "00:00:00") else {
            throw Failure(message: "The GPS time is written 16:45:00.")
        }
        CGImageMetadataRegisterNamespaceForPrefix(metadata, kCGImageMetadataNamespaceExif,
                                                  kCGImageMetadataPrefixExif, nil)
        guard CGImageMetadataSetValueWithPath(metadata, nil, "exif:GPSTimeStamp" as CFString,
                                              "\(day)T\(clock)Z" as CFString) else {
            throw Failure(message: "The GPS date and time cannot be set in \u{201C}\(name)\u{201D}.")
        }
    }

    private nonisolated static func removeGPSTime(from metadata: CGMutableImageMetadata) {
        guard let tag = CGImageMetadataCopyTagMatchingImageProperty(
            metadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSDateStamp),
              let prefix = CGImageMetadataTagCopyPrefix(tag),
              let tagName = CGImageMetadataTagCopyName(tag) else { return }
        CGImageMetadataRemoveTagWithPath(metadata, nil, "\(prefix):\(tagName)" as CFString)
    }

    /// `2024:06:30` as `2024-06-30`.
    nonisolated static func isoDate(_ text: String) -> String? {
        let parts = text.split(separator: ":")
        guard parts.count == 3, parts.allSatisfy({ Int($0) != nil }),
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return nil }
        return parts.joined(separator: "-")
    }

    /// `16:45:00`, as it is if it is one.
    nonisolated static func isoTime(_ text: String) -> String? {
        let parts = text.split(separator: ":")
        guard parts.count == 3, parts.allSatisfy({ Double($0) != nil }) else { return nil }
        return parts.map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":")
    }

    /// Latitude and longitude, which go in as plain numbers: XMP writes them
    /// as degrees and minutes, and a fraction there is read as something else.
    nonisolated static let coordinates: Set<String> = [
        kCGImagePropertyGPSLatitude as String, kCGImagePropertyGPSLongitude as String,
        kCGImagePropertyGPSDestLatitude as String, kCGImagePropertyGPSDestLongitude as String,
    ]

    /// A value as the metadata takes it. A number that is not whole goes in
    /// as a fraction, which is how EXIF stores it: handed over as a number,
    /// 2.8 is written as 2. Coordinates are the exception.
    nonisolated static func stored(_ value: Any, for key: ExifKey) -> CFTypeRef {
        if key.group == .gps && coordinates.contains(key.name) { return value as CFTypeRef }
        // Artist is XMP's list of creators: a HEIC image keeps it only as a
        // list, of one name.
        if key.group == .tiff, key.name == kCGImagePropertyTIFFArtist as String,
           let name = value as? String {
            return [name] as CFArray
        }
        switch value {
        // A list of one, ISO above all, goes in as the one: a HEIC image
        // drops it as a list.
        case let numbers as [NSNumber] where numbers.count == 1:
            return stored(numbers[0], for: key)
        case let number as NSNumber where !isWhole(number):
            return fraction(number.doubleValue) as CFString
        case let numbers as [NSNumber] where numbers.contains(where: { !isWhole($0) }):
            return numbers.map { isWhole($0) ? "\($0.int64Value)" : fraction($0.doubleValue) }
                as CFArray
        default:
            return value as CFTypeRef
        }
    }

    private nonisolated static func isWhole(_ number: NSNumber) -> Bool {
        let value = number.doubleValue
        return value == value.rounded() && abs(value) < 1e15
    }

    /// 2.8 as "28/10", 0.008 as "1/125": a power of ten under it, reduced.
    nonisolated static func fraction(_ value: Double) -> String {
        var denominator: Int64 = 1
        while denominator < 1_000_000_000,
              abs(value * Double(denominator) - (value * Double(denominator)).rounded()) > 1e-9 {
            denominator *= 10
        }
        var numerator = Int64((value * Double(denominator)).rounded())
        var divisor = gcd(abs(numerator), denominator)
        if divisor == 0 { divisor = 1 }
        numerator /= divisor
        return "\(numerator)/\(denominator / divisor)"
    }

    private nonisolated static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        b == 0 ? a : gcd(b, a % b)
    }

    /// Every change is in the result, or the result is not used.
    private nonisolated static func check(_ data: Data, name: String,
                                          against changes: [ExifKey: Change]) throws(Failure) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let found = values(in: source) else {
            throw Failure(message: "\u{201C}\(name)\u{201D} could not be read back after the "
                          + "change, so it was left as it was.")
        }
        var lost: [String] = []
        for (key, change) in changes.sorted(by: { $0.key < $1.key }) {
            switch change {
            case .set(let wanted):
                if let value = found[key], ExifFields.same(value, wanted) { continue }
                lost.append(key.name)
            case .remove:
                if found[key] != nil { lost.append(key.name) }
            case .zone, .computed:
                continue
            }
        }
        guard lost.isEmpty else {
            // A HEIC image drops altitude, direction and the rest of the
            // location when it has no position to go with them.
            let noPosition = found[ExifKey(group: .gps,
                                           name: kCGImagePropertyGPSLatitude as String)] == nil
            let lostLocation = changes.keys.contains { $0.group == .gps && lost.contains($0.name) }
            throw Failure(message: "\u{201C}\(name)\u{201D} would not keep "
                          + lost.joined(separator: ", ")
                          + ", so it was left as it was."
                          + (noPosition && lostLocation
                             ? " Location details are kept only with a latitude and longitude."
                             : ""))
        }
    }
}
