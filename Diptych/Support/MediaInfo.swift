import AVFoundation
import Foundation
import ImageIO

/// What a picture or a video says about itself -- read from its header,
/// never its pixels -- for the flat view's tests and the panes' columns.
/// Every field the file does not have is nil, and a test on it is false.
nonisolated struct MediaInfo: Sendable, Hashable {

    enum Kind: String, Sendable, Hashable {
        case image, video
    }

    let kind: Kind
    /// What the bytes are, whatever the name says: `jpeg`, `heic`, `mov` --
    /// one of `MediaFormat.all`.
    var format: String
    /// The picture carries EXIF at all.
    var hasExif = false
    var taken: Date?
    var digitized: Date?
    var camera: String?
    var lens: String?
    var software: String?
    var artist: String?
    var copyright: String?
    var description: String?
    var iso: Double?
    /// The f-number.
    var aperture: Double?
    /// Exposure time, in seconds.
    var shutter: Double?
    /// Focal length in millimetres, and its 35mm equivalent.
    var focal: Double?
    var focal35: Double?
    var flash: Bool?
    /// As the picture is shown: after its orientation is applied.
    var width: Int?
    var height: Int?
    /// EXIF orientation, 1 to 8; nil when the file has none.
    var orientation: Int?
    var transparent: Bool?
    var animated = false
    var latitude: Double?
    var longitude: Double?
    /// Metres above the sea; below it, negative.
    var altitude: Double?
    /// Place names written into the file, by photo software or by hand.
    var writtenCity: String?
    var writtenState: String?
    var writtenCountry: String?
    var writtenCountryCode: String?
    /// 0 to 5 stars, as Lightroom and Bridge write them.
    var rating: Int?
    /// A video's length, in seconds.
    var duration: Double?
    /// The nearest town, found when the file was read -- on the thread
    /// reading it, not the one drawing a column.
    var placed: Places.Place?

    init(kind: Kind, format: String) {
        self.kind = kind
        self.format = format
    }

    var located: Bool { latitude != nil && longitude != nil }

    var megapixels: Double? {
        guard let width, let height else { return nil }
        return Double(width) * Double(height) / 1_000_000
    }

    /// Turned by its orientation tag rather than by its pixels.
    var rotated: Bool { (orientation ?? 1) != 1 }

    // MARK: Places

    /// The town nearest to where it was taken, for the names the file does
    /// not have.
    var nearest: Places.Place? {
        if let placed { return placed }
        guard let latitude, let longitude else { return nil }
        return Places.shared.nearest(latitude: latitude, longitude: longitude)
    }

    /// Written into the file, or else the nearest town's.
    var city: String? { writtenCity ?? nearest?.city }
    var state: String? { writtenState ?? (writtenCity == nil ? nearest?.state : nil) }
    var country: String? { writtenCountry ?? nearest?.country }
    var countryCode: String? { writtenCountryCode ?? nearest?.countryCode }
}

// MARK: - Formats

/// The names `format` compares with, and what each is.
nonisolated struct MediaFormat: Sendable {
    let name: String
    /// Other names it answers to: `jpg` for `jpeg`.
    let aliases: [String]
    let kind: MediaInfo.Kind
    let title: String
    /// A camera's raw format: `format = "raw"` is any of them.
    var isRaw = false

    static let all: [MediaFormat] = [
        MediaFormat(name: "jpeg", aliases: ["jpg"], kind: .image, title: "JPEG"),
        MediaFormat(name: "heic", aliases: ["heif"], kind: .image, title: "HEIC, as an iPhone takes it"),
        MediaFormat(name: "heif", aliases: [], kind: .image, title: "HEIF that is not HEIC"),
        MediaFormat(name: "avif", aliases: [], kind: .image, title: "AVIF"),
        MediaFormat(name: "png", aliases: [], kind: .image, title: "PNG"),
        MediaFormat(name: "gif", aliases: [], kind: .image, title: "GIF"),
        MediaFormat(name: "tiff", aliases: ["tif"], kind: .image, title: "TIFF"),
        MediaFormat(name: "webp", aliases: [], kind: .image, title: "WebP"),
        MediaFormat(name: "bmp", aliases: [], kind: .image, title: "Windows bitmap"),
        MediaFormat(name: "ico", aliases: [], kind: .image, title: "Windows icon"),
        MediaFormat(name: "icns", aliases: [], kind: .image, title: "Mac icon"),
        MediaFormat(name: "svg", aliases: [], kind: .image, title: "SVG drawing"),
        MediaFormat(name: "psd", aliases: [], kind: .image, title: "Photoshop"),
        MediaFormat(name: "jp2", aliases: [], kind: .image, title: "JPEG 2000"),
        MediaFormat(name: "jxl", aliases: [], kind: .image, title: "JPEG XL"),
        MediaFormat(name: "exr", aliases: [], kind: .image, title: "OpenEXR"),
        MediaFormat(name: "hdr", aliases: [], kind: .image, title: "Radiance HDR"),
        MediaFormat(name: "tga", aliases: [], kind: .image, title: "Targa"),
        MediaFormat(name: "pbm", aliases: ["pgm", "ppm"], kind: .image, title: "Netpbm"),
        MediaFormat(name: "dng", aliases: [], kind: .image, title: "Adobe raw", isRaw: true),
        MediaFormat(name: "cr2", aliases: [], kind: .image, title: "Canon raw", isRaw: true),
        MediaFormat(name: "cr3", aliases: [], kind: .image, title: "Canon raw", isRaw: true),
        MediaFormat(name: "crw", aliases: [], kind: .image, title: "Canon raw, older", isRaw: true),
        MediaFormat(name: "nef", aliases: ["nrw"], kind: .image, title: "Nikon raw", isRaw: true),
        MediaFormat(name: "arw", aliases: ["srf", "sr2"], kind: .image, title: "Sony raw", isRaw: true),
        MediaFormat(name: "raf", aliases: [], kind: .image, title: "Fujifilm raw", isRaw: true),
        MediaFormat(name: "orf", aliases: [], kind: .image, title: "Olympus raw", isRaw: true),
        MediaFormat(name: "rw2", aliases: [], kind: .image, title: "Panasonic raw", isRaw: true),
        MediaFormat(name: "pef", aliases: [], kind: .image, title: "Pentax raw", isRaw: true),
        MediaFormat(name: "srw", aliases: [], kind: .image, title: "Samsung raw", isRaw: true),
        MediaFormat(name: "raw", aliases: [], kind: .image, title: "another camera's raw", isRaw: true),
        MediaFormat(name: "mov", aliases: ["quicktime"], kind: .video, title: "QuickTime"),
        MediaFormat(name: "mp4", aliases: [], kind: .video, title: "MPEG-4"),
        MediaFormat(name: "m4v", aliases: [], kind: .video, title: "MPEG-4, as iTunes writes it"),
        MediaFormat(name: "3gp", aliases: ["3g2"], kind: .video, title: "3GPP, from older phones"),
        MediaFormat(name: "avi", aliases: [], kind: .video, title: "AVI"),
        MediaFormat(name: "mkv", aliases: [], kind: .video, title: "Matroska"),
        MediaFormat(name: "webm", aliases: [], kind: .video, title: "WebM"),
        MediaFormat(name: "mpeg", aliases: ["mpg", "ts"], kind: .video, title: "MPEG program or transport stream"),
        MediaFormat(name: "flv", aliases: [], kind: .video, title: "Flash video"),
        MediaFormat(name: "wmv", aliases: ["asf"], kind: .video, title: "Windows Media"),
    ]

    static func named(_ name: String) -> MediaFormat? {
        let lower = name.lowercased()
        return all.first { $0.name == lower }
    }

    /// The format's own name for one of its names: `jpg` → `jpeg`, `raw`
    /// stays `raw`. Nil for no format at all.
    static func canonical(_ name: String) -> String? {
        let lower = name.lowercased()
        return all.first { $0.name == lower || $0.aliases.contains(lower) }?.name
    }

    /// Every name a file of `format` answers to.
    static func names(of format: String) -> [String] {
        guard let found = named(format) else { return [format] }
        return [found.name] + found.aliases + (found.isRaw && found.name != "raw" ? ["raw"] : [])
    }

    /// ImageIO's type for a picture, as a format's name.
    static func name(ofImageType type: String) -> String {
        let known: [String: String] = [
            "public.jpeg": "jpeg", "public.heic": "heic", "public.heics": "heic",
            "public.heif": "heif", "public.avif": "avif", "public.avis": "avif",
            "public.avci": "avif", "public.png": "png", "com.compuserve.gif": "gif",
            "public.tiff": "tiff", "org.webmproject.webp": "webp", "com.microsoft.bmp": "bmp",
            "com.microsoft.ico": "ico", "com.microsoft.cur": "ico", "com.apple.icns": "icns",
            "com.adobe.photoshop-image": "psd", "public.jpeg-2000": "jp2",
            "public.jpeg-xl": "jxl", "com.ilm.openexr-image": "exr", "public.radiance": "hdr",
            "com.truevision.tga-image": "tga", "public.pbm": "pbm", "public.pgm": "pbm",
            "public.ppm": "pbm", "public.pnm": "pbm", "public.svg-image": "svg",
            "com.adobe.raw-image": "dng", "com.canon.cr2-raw-image": "cr2",
            "com.canon.cr3-raw-image": "cr3", "com.canon.crw-raw-image": "crw",
            "com.nikon.raw-image": "nef", "com.nikon.nrw-raw-image": "nef",
            "com.sony.arw-raw-image": "arw", "com.sony.raw-image": "arw",
            "com.sony.sr2-raw-image": "arw", "com.fuji.raw-image": "raf",
            "com.olympus.raw-image": "orf", "com.olympus.or-raw-image": "orf",
            "com.panasonic.rw2-raw-image": "rw2", "com.panasonic.raw-image": "rw2",
            "com.pentax.raw-image": "pef", "com.samsung.raw-image": "srw",
        ]
        if let name = known[type] { return name }
        return type.contains("raw-image") ? "raw" : (type.split(separator: ".").last.map {
            String($0).lowercased()
        } ?? type)
    }
}

// MARK: - Reading

nonisolated enum MediaReader {

    /// What the file is, by its first bytes; nil for anything that is not a
    /// picture or a video -- or not a plain file.
    static func read(_ url: URL) -> MediaInfo? {
        guard let (kind, format) = sniff(url) else { return nil }
        var info: MediaInfo?
        switch kind {
        case .image:
            info = format == "svg" ? svg(url) : image(url)
        case .video:
            info = video(url, format: format)
        }
        let place = info?.nearest
        info?.placed = place
        return info
    }

    // MARK: Sniffing

    /// The kind and format of the file, by its first bytes.
    static func sniff(_ url: URL) -> (MediaInfo.Kind, String)? {
        guard let head = try? FileHandle(forReadingFrom: url) else { return nil }
        let start = (try? head.read(upToCount: 1024)) ?? Data()
        try? head.close()
        return sniff(start, name: url.lastPathComponent)
    }

    /// The kind and format the bytes say. A picture's exact format is left
    /// to ImageIO, which also tells a camera's raw file from a TIFF.
    static func sniff(_ data: Data, name: String) -> (MediaInfo.Kind, String)? {
        let bytes = [UInt8](data.prefix(1024))
        func at(_ offset: Int, _ pattern: [UInt8]) -> Bool {
            bytes.count >= offset + pattern.count
                && Array(bytes[offset..<(offset + pattern.count)]) == pattern
        }
        func text(_ offset: Int, _ length: Int) -> String {
            guard bytes.count >= offset + length else { return "" }
            return String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
        }
        if at(0, [0xFF, 0xD8, 0xFF]) { return (.image, "jpeg") }
        if at(0, [0x89, 0x50, 0x4E, 0x47]) { return (.image, "png") }
        if at(0, Array("GIF8".utf8)) { return (.image, "gif") }
        if at(0, [0x49, 0x49, 0x2A, 0x00]) || at(0, [0x4D, 0x4D, 0x00, 0x2A])
            || at(0, Array("IIRO".utf8)) || at(0, Array("IIRS".utf8))
            || at(0, [0x49, 0x49, 0x55, 0x00]) { return (.image, "tiff") }
        if at(0, Array("FUJIFILMCCD-RAW".utf8)) { return (.image, "raf") }
        if at(0, Array("RIFF".utf8)) {
            if text(8, 4) == "WEBP" { return (.image, "webp") }
            if text(8, 4) == "AVI " { return (.video, "avi") }
            return nil
        }
        if at(0, Array("BM".utf8)), bytes.count > 14 { return (.image, "bmp") }
        if at(0, Array("8BPS".utf8)) { return (.image, "psd") }
        if at(0, [0x00, 0x00, 0x01, 0x00]) || at(0, [0x00, 0x00, 0x02, 0x00]) {
            return (.image, "ico")
        }
        if at(0, Array("icns".utf8)) { return (.image, "icns") }
        if at(0, [0xFF, 0x0A]) || at(4, Array("JXL ".utf8)) { return (.image, "jxl") }
        if at(4, Array("jP  ".utf8)) || at(0, [0xFF, 0x4F, 0xFF, 0x51]) { return (.image, "jp2") }
        if at(0, [0x76, 0x2F, 0x31, 0x01]) { return (.image, "exr") }
        if at(0, Array("#?RADIANCE".utf8)) || at(0, Array("#?RGBE".utf8)) { return (.image, "hdr") }
        if at(4, Array("ftyp".utf8)) {
            return isoMedia(major: text(8, 4), compatible: bytes)
        }
        // QuickTime before ftyp: a movie atom first.
        if ["moov", "mdat", "wide", "free", "skip", "pnot"].contains(text(4, 4)) {
            return (.video, "mov")
        }
        if at(0, [0x1A, 0x45, 0xDF, 0xA3]) {
            return (.video, String(decoding: bytes, as: UTF8.self).contains("webm") ? "webm" : "mkv")
        }
        if at(0, Array("FLV".utf8)) { return (.video, "flv") }
        if at(0, [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) { return (.video, "wmv") }
        if at(0, [0x00, 0x00, 0x01, 0xBA]) || at(0, [0x00, 0x00, 0x01, 0xB3])
            || (bytes.count > 376 && bytes[0] == 0x47 && bytes[188] == 0x47 && bytes[376] == 0x47) {
            return (.video, "mpeg")
        }
        // Netpbm and Targa have no reliable mark: by the name.
        let lower = (name as NSString).pathExtension.lowercased()
        if ["pbm", "pgm", "ppm", "pnm"].contains(lower), bytes.first == 0x50 { return (.image, "pbm") }
        if lower == "tga" { return (.image, "tga") }
        // SVG: XML whose first element is <svg>, or svgz by its name.
        if lower == "svgz" { return (.image, "svg") }
        let start = String(decoding: bytes, as: UTF8.self)
        if start.contains("<svg"), start.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("<") { return (.image, "svg") }
        return nil
    }

    /// The ISO media family -- MP4, QuickTime, HEIC, AVIF, CR3 -- by its brands.
    private static func isoMedia(major: String, compatible bytes: [UInt8])
        -> (MediaInfo.Kind, String)? {
        let brands = Set(stride(from: 16, to: min(bytes.count, 64) - 3, by: 4).map {
            String(decoding: bytes[$0..<($0 + 4)], as: UTF8.self)
        } + [major])
        switch major {
        case "heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs":
            return (.image, "heic")
        case "avif", "avis":
            return (.image, "avif")
        case "mif1", "msf1":
            if brands.contains("avif") || brands.contains("avis") { return (.image, "avif") }
            if brands.contains("heic") || brands.contains("hevc") { return (.image, "heic") }
            return (.image, "heif")
        case "crx ":
            return (.image, "cr3")
        case "qt  ":
            return (.video, "mov")
        case "M4V ", "M4VH", "M4VP":
            return (.video, "m4v")
        case "M4A ", "M4B ", "M4P ", "F4A ", "F4B ":
            return nil      // sound, not video
        default:
            if major.hasPrefix("3g") { return (.video, "3gp") }
            return (.video, "mp4")
        }
    }

    // MARK: Pictures

    private static func image(_ url: URL) -> MediaInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) > 0 else { return nil }
        var info = MediaInfo(kind: .image, format: MediaFormat.name(ofImageType: type))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            ?? [:]
        let count = CGImageSourceGetCount(source)
        info.animated = count > 1 && ["gif", "png", "webp", "heic", "avif"].contains(info.format)

        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        info.orientation = orientation
        // 5 to 8 are turned a quarter: what is shown is the other way round.
        if let orientation, (5...8).contains(orientation) {
            info.width = height
            info.height = width
        } else {
            info.width = width
            info.height = height
        }
        info.transparent = (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        info.hasExif = exif != nil
        let exifFields = exif ?? [:]

        info.taken = exifDate(exifFields[kCGImagePropertyExifDateTimeOriginal],
                              offset: exifFields[kCGImagePropertyExifOffsetTimeOriginal])
        info.digitized = exifDate(exifFields[kCGImagePropertyExifDateTimeDigitized],
                                  offset: exifFields[kCGImagePropertyExifOffsetTimeDigitized])
        info.camera = camera(make: text(tiff[kCGImagePropertyTIFFMake]),
                             model: text(tiff[kCGImagePropertyTIFFModel]))
        info.lens = text(exifFields[kCGImagePropertyExifLensModel])
            ?? text(aux[kCGImagePropertyExifAuxLensModel])
        info.software = text(tiff[kCGImagePropertyTIFFSoftware])
        info.artist = text(tiff[kCGImagePropertyTIFFArtist])
            ?? text(iptc[kCGImagePropertyIPTCByline])
        info.copyright = text(tiff[kCGImagePropertyTIFFCopyright])
            ?? text(iptc[kCGImagePropertyIPTCCopyrightNotice])
        info.description = text(tiff[kCGImagePropertyTIFFImageDescription])
            ?? text(iptc[kCGImagePropertyIPTCCaptionAbstract])
        info.iso = number(exifFields[kCGImagePropertyExifISOSpeedRatings])
        info.aperture = number(exifFields[kCGImagePropertyExifFNumber])
        info.shutter = number(exifFields[kCGImagePropertyExifExposureTime])
        info.focal = number(exifFields[kCGImagePropertyExifFocalLength])
        info.focal35 = number(exifFields[kCGImagePropertyExifFocalLenIn35mmFilm])
        if let flash = number(exifFields[kCGImagePropertyExifFlash]) {
            info.flash = Int(flash) & 1 == 1
        }

        if var latitude = number(gps[kCGImagePropertyGPSLatitude]),
           var longitude = number(gps[kCGImagePropertyGPSLongitude]) {
            if text(gps[kCGImagePropertyGPSLatitudeRef])?.uppercased() == "S" { latitude = -latitude }
            if text(gps[kCGImagePropertyGPSLongitudeRef])?.uppercased() == "W" {
                longitude = -longitude
            }
            if abs(latitude) <= 90, abs(longitude) <= 180 {
                info.latitude = latitude
                info.longitude = longitude
            }
        }
        if var altitude = number(gps[kCGImagePropertyGPSAltitude]) {
            if number(gps[kCGImagePropertyGPSAltitudeRef]) == 1 { altitude = -altitude }
            info.altitude = altitude
        }

        info.writtenCity = text(iptc[kCGImagePropertyIPTCCity])
        info.writtenState = text(iptc[kCGImagePropertyIPTCProvinceState])
        info.writtenCountry = text(iptc[kCGImagePropertyIPTCCountryPrimaryLocationName])
        info.writtenCountryCode = text(iptc[kCGImagePropertyIPTCCountryPrimaryLocationCode])

        // XMP: the stars, and place names that are only there.
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            func xmp(_ path: String) -> String? {
                (CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString)
                    as String?).flatMap { text($0) }
            }
            if let stars = xmp("xmp:Rating").flatMap(Double.init) {
                info.rating = max(0, min(5, Int(stars.rounded())))
            }
            info.writtenCity = info.writtenCity ?? xmp("photoshop:City")
            info.writtenState = info.writtenState ?? xmp("photoshop:State")
            info.writtenCountry = info.writtenCountry ?? xmp("photoshop:Country")
            info.writtenCountryCode = info.writtenCountryCode
                ?? xmp("Iptc4xmpCore:CountryCode")
        }
        return info
    }

    /// "Canon" and "Canon EOS R5" are one camera, not "Canon Canon EOS R5".
    static func camera(make: String?, model: String?) -> String? {
        guard let model else { return make }
        guard let make else { return model }
        let first = make.split(separator: " ").first.map(String.init) ?? make
        if model.lowercased().hasPrefix(first.lowercased()) { return model }
        return "\(make) \(model)"
    }

    /// EXIF's `2024:07:14 15:30:12`, in the zone written beside it -- or,
    /// with none, this Mac's.
    static func exifDate(_ value: Any?, offset: Any?) -> Date? {
        guard let written = text(value) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = zone(text(offset)) ?? .current
        return formatter.date(from: String(written.prefix(19)))
    }

    /// `+02:00`, `-0530`, `Z`.
    static func zone(_ written: String?) -> TimeZone? {
        guard let written = written?.trimmingCharacters(in: .whitespaces), !written.isEmpty else {
            return nil
        }
        if written.uppercased() == "Z" { return TimeZone(secondsFromGMT: 0) }
        let sign = written.hasPrefix("-") ? -1 : 1
        let digits = written.filter(\.isNumber)
        guard digits.count == 4 || digits.count == 2,
              let hours = Int(digits.prefix(2)),
              let minutes = Int(digits.count == 4 ? String(digits.suffix(2)) : "0"),
              hours < 24, minutes < 60 else { return nil }
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }

    private static func text(_ value: Any?) -> String? {
        let raw: String?
        switch value {
        case let string as String: raw = string
        case let strings as [String]: raw = strings.joined(separator: ", ")
        default: raw = nil
        }
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let numbers as [NSNumber]: numbers.first?.doubleValue
        case let string as String: Double(string)
        default: nil
        }
    }

    // MARK: SVG

    /// A drawing: its size from the `<svg>` element's width and height,
    /// or else its viewBox.
    private static func svg(_ url: URL) -> MediaInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        let data = (try? handle.read(upToCount: 65_536)) ?? Data()
        try? handle.close()
        var info = MediaInfo(kind: .image, format: "svg")
        let text = String(decoding: data, as: UTF8.self)
        guard let open = text.range(of: "<svg") else { return info }
        let rest = text[open.upperBound...]
        let tag = rest.prefix { $0 != ">" }
        func attribute(_ name: String) -> String? {
            let pattern = "(?:^|\\s)\(name)\\s*=\\s*[\"']([^\"']*)[\"']"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: String(tag),
                                               range: NSRange(tag.startIndex..., in: tag)),
                  let range = Range(match.range(at: 1), in: tag) else { return nil }
            return String(tag[range])
        }
        let box = attribute("viewBox")?.split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { Double($0) }
        info.width = attribute("width").flatMap(pixels) ?? box.flatMap { $0.count == 4 ? Int($0[2].rounded()) : nil }
        info.height = attribute("height").flatMap(pixels) ?? box.flatMap { $0.count == 4 ? Int($0[3].rounded()) : nil }
        info.transparent = true
        return info
    }

    /// CSS lengths as pixels, at 96 to the inch; a percentage is no size.
    private static func pixels(_ written: String) -> Int? {
        let trimmed = written.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits) else { return nil }
        let unit = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let scale: Double? = switch unit {
        case "", "px": 1
        case "pt": 96.0 / 72
        case "pc": 16
        case "in": 96
        case "cm": 96 / 2.54
        case "mm": 96 / 25.4
        default: nil
        }
        return scale.map { Int((value * $0).rounded()) }
    }

    // MARK: Videos

    private final class Box: @unchecked Sendable {
        var value: MediaInfo?
    }

    /// Read by AVFoundation -- asynchronous, waited for here: the callers
    /// walk a tree on a thread of their own.
    private static func video(_ url: URL, format: String) -> MediaInfo? {
        var info = MediaInfo(kind: .video, format: format)
        // AVFoundation reads the MPEG-4 family; the rest are videos with
        // nothing more to say.
        guard ["mov", "mp4", "m4v", "3gp"].contains(format) else { return info }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await loadVideo(url, format: format)
            done.signal()
        }
        if done.wait(timeout: .now() + 10) == .success, let loaded = box.value {
            info = loaded
        }
        return info
    }

    private static func loadVideo(_ url: URL, format: String) async -> MediaInfo {
        var info = MediaInfo(kind: .video, format: format)
        // By what the bytes are, not the name: AVFoundation goes by the
        // extension, and opens nothing of a video named `.txt`.
        let types = ["mov": "video/quicktime", "mp4": "video/mp4", "m4v": "video/x-m4v",
                     "3gp": "video/3gpp"]
        let named = MediaFormat.canonical(url.pathExtension).map { types[$0] != nil } ?? false
        let options: [String: Any] = named ? [:]
            : [AVURLAssetOverrideMIMETypeKey: types[format] ?? "video/mp4"]
        let asset = AVURLAsset(url: url, options: options)
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            info.duration = duration.seconds
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let shown = size.applying(transform)
            info.width = Int(abs(shown.width).rounded())
            info.height = Int(abs(shown.height).rounded())
            info.orientation = transform.b != 0 ? 6 : 1
            info.transparent = false
        }
        let items = (try? await asset.load(.metadata)) ?? []
        var byKey: [AVMetadataIdentifier: AVMetadataItem] = [:]
        for item in items {
            if let identifier = item.identifier, byKey[identifier] == nil { byKey[identifier] = item }
        }
        // By the same tags the metadata editor reads and writes, so what it
        // saves -- in an MP4 as ISO user data -- is what the columns show.
        func item(_ field: VideoMetadata.Field) -> [AVMetadataItem] {
            field.identifiers.compactMap { byKey[$0] }
                + items.filter { $0.commonKey != nil && $0.commonKey == field.commonKey }
        }
        func string(_ field: VideoMetadata.Field) async -> String? {
            for item in item(field) {
                if let value = try? await item.load(.stringValue) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }
        for item in item(.taken) {
            if let value = try? await item.load(.dateValue) { info.taken = value; break }
            if let text = try? await item.load(.stringValue), let parsed = isoDate(text) {
                info.taken = parsed
                break
            }
        }
        if info.taken == nil, let item = try? await asset.load(.creationDate) {
            info.taken = try? await item.load(.dateValue)
        }
        info.camera = camera(make: await string(.make), model: await string(.model))
        info.software = await string(.software)
        info.artist = await string(.artist)
        info.copyright = await string(.copyright)
        info.description = await string(.description)
        if let place = await string(.location), let (latitude, longitude, altitude) = iso6709(place) {
            info.latitude = latitude
            info.longitude = longitude
            info.altitude = altitude
        }
        return info
    }

    /// `2024-07-14T15:30:12+0200`, and the other ways a video writes a date.
    static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds],
            [.withFullDate, .withTime, .withColonSeparatorInTime, .withTimeZone],
        ] {
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// `+47.4979+019.0402+120.000/`: latitude, longitude and, if there,
    /// altitude.
    static func iso6709(_ text: String) -> (Double, Double, Double?)? {
        let pattern = #"^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        func part(_ index: Int) -> Double? {
            Range(match.range(at: index), in: text).flatMap { Double(text[$0]) }
        }
        guard let latitude = part(1), let longitude = part(2), abs(latitude) <= 90,
              abs(longitude) <= 180 else { return nil }
        return (latitude, longitude, part(3))
    }
}

// MARK: - Remembered

/// What was read, by the file's path, as long as the file is not changed:
/// a flat view's tests, run again, and the panes' columns read each file
/// once.
nonisolated final class MediaCache: @unchecked Sendable {

    static let shared = MediaCache()

    private struct Stamp: Hashable {
        let modified: timespec_compat
        let size: off_t
        let inode: ino_t
    }

    /// `timespec` is not Hashable.
    private struct timespec_compat: Hashable {
        let seconds: Int
        let nanoseconds: Int
    }

    private let lock = NSLock()
    private var entries: [String: (Stamp, MediaInfo?)] = [:]
    private static let limit = 50_000

    /// The file's media facts; nil for a folder, a file that is neither a
    /// picture nor a video, or one that cannot be read. Through a link, to
    /// what it points at.
    func info(for url: URL) -> MediaInfo? {
        var status = stat()
        guard stat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        let stamp = Stamp(modified: timespec_compat(seconds: status.st_mtimespec.tv_sec,
                                                    nanoseconds: status.st_mtimespec.tv_nsec),
                          size: status.st_size, inode: status.st_ino)
        let path = url.path
        lock.lock()
        if let (known, info) = entries[path], known == stamp {
            lock.unlock()
            return info
        }
        lock.unlock()
        let info = status.st_size == 0 ? nil : MediaReader.read(url)
        lock.lock()
        if entries.count >= Self.limit { entries.removeAll(keepingCapacity: true) }
        entries[path] = (stamp, info)
        lock.unlock()
        return info
    }

    func forget() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

// MARK: - As columns

nonisolated extension MediaInfo {

    /// The date a column sorts by.
    func taken(_ column: FileColumn) -> Date? {
        column == .digitized ? digitized : taken
    }

    /// The number a column sorts by.
    func number(_ column: FileColumn) -> Double? {
        switch column {
        case .iso: iso
        case .aperture: aperture
        case .shutter: shutter
        case .focal: focal
        case .focal35: focal35
        case .dimensions, .megapixels: megapixels
        case .duration: duration
        case .altitude: altitude
        case .rating: rating.map(Double.init)
        default: nil
        }
    }

    /// What a column shows; empty for what the file does not say.
    func text(for column: FileColumn) -> String {
        switch column {
        case .format: return format.uppercased()
        case .taken: return taken.map(Self.dateText) ?? ""
        case .digitized: return digitized.map(Self.dateText) ?? ""
        case .camera: return camera ?? ""
        case .lens: return lens ?? ""
        case .software: return software ?? ""
        case .artist: return artist ?? ""
        case .copyright: return copyright ?? ""
        case .imageDescription: return description ?? ""
        case .iso: return iso.map { String(Int($0.rounded())) } ?? ""
        case .aperture: return aperture.map { "f/" + Self.short($0) } ?? ""
        case .shutter: return shutter.map(Self.exposure) ?? ""
        case .focal: return focal.map { Self.short($0) + " mm" } ?? ""
        case .focal35: return focal35.map { Self.short($0) + " mm" } ?? ""
        case .dimensions:
            guard let width, let height else { return "" }
            return "\(width) \u{00D7} \(height)"
        case .megapixels: return megapixels.map { String(format: "%.1f MP", $0) } ?? ""
        case .duration: return duration.map(Self.clock) ?? ""
        case .location:
            guard let latitude, let longitude else { return "" }
            return String(format: "%.4f, %.4f", latitude, longitude)
        case .altitude: return altitude.map(Self.height) ?? ""
        case .city: return city ?? ""
        case .state: return state ?? ""
        case .country: return country ?? countryCode ?? ""
        case .rating: return rating.map { $0 == 0 ? "0" : String(repeating: "\u{2605}", count: $0) } ?? ""
        default: return ""
        }
    }

    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static func dateText(_ date: Date) -> String { dateFormat.string(from: date) }

    /// 2.8, 50, 4.5: no trailing zeros.
    static func short(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", (value * 10).rounded() / 10)
    }

    /// 1/250 s, 0.5 s, 2 s, as cameras show it.
    static func exposure(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        if seconds < 0.4 {
            return "1/\(Int((1 / seconds).rounded())) s"
        }
        return short(seconds) + " s"
    }

    /// 0:42, 12:03, 1:02:03.
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest)
                         : String(format: "%d:%02d", minutes, rest)
    }

    /// In metres or in feet, as this Mac's region measures.
    static func height(_ metres: Double) -> String {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .short
        formatter.numberFormatter.maximumFractionDigits = 0
        let measured = Measurement(value: metres, unit: UnitLength.meters)
        let usesMetric = Locale.current.measurementSystem == .metric
        return formatter.string(from: usesMetric ? measured : measured.converted(to: .feet))
    }
}

// MARK: - Values found, for Control-Space

nonisolated extension MediaInfo {

    /// The text a test of `field` compares with.
    func value(of field: FlatQuery.MediaText) -> String? {
        switch field {
        case .format: format
        case .camera: camera
        case .lens: lens
        case .software: software
        case .artist: artist
        case .copyright: copyright
        case .description: description
        case .city: city
        case .state: state
        case .country: country
        }
    }

    /// What `field` is among these files -- the cameras of a flat view's
    /// rows -- the commonest first. Only files named as pictures or videos
    /// are opened, and not more than `limit` of them.
    static func values(of field: FlatQuery.MediaText, in urls: [URL],
                       limit: Int = 3000) -> [String] {
        var counts: [String: Int] = [:]
        var opened = 0
        for url in urls where opened < limit && looksLikeMedia(url) {
            opened += 1
            guard let value = MediaCache.shared.info(for: url)?.value(of: field) else { continue }
            counts[value, default: 0] += 1
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value
                                                    : $0.key.localizedStandardCompare($1.key)
                                                        == .orderedAscending }
            .prefix(100).map(\.key)
    }

    /// By the name alone: what is worth opening to ask.
    static func looksLikeMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if MediaFormat.canonical(ext) != nil { return true }
        return ["jpe", "jfif", "tif", "heics", "mp4v", "mpe", "m2ts", "mts", "svgz", "nrw",
                "orf", "dcr", "kdc", "mrw", "3fr", "iiq", "rwl", "x3f"].contains(ext)
    }
}
