import Foundation
import ImageIO

/// The `$…` placeholders the Rename Many replacement understands, on top of the
/// regular expression's own `$1`, `$2` backreferences.
///
///     $n                   a serial number, 1, 2, 3 … in listed order
///     $cdate{YYYY-MM-DD}    when it was created, in a format you give
///     $mdate{YYYY-MM-DD}    when it was last changed
///     $owner               the owning user
///     $group               the owning group
///     $exif{DateTimeOriginal}  an EXIF value, by its name
///
/// Each is filled from the file it is for -- so the same replacement gives a
/// different result per file -- and then handed to the regex engine as a
/// literal: the text put in is escaped, so a value that happens to contain a
/// `$` or a `\` cannot turn into a backreference by accident, while the `$1`
/// the user wrote still works.
enum RenamePlaceholders {

    /// For the window's legend and the completion menu, in the order shown.
    static let legend: [(token: String, meaning: String)] = [
        ("$n", "a serial number, 1, 2, 3 \u{2026} in listed order"),
        ("$cdate{YYYY-MM-DD}", "the date it was created, in your format"),
        ("$mdate{YYYY-MM-DD}", "the date it was last changed"),
        ("$owner", "the owning user"),
        ("$group", "the owning group"),
        ("$exif{DateTimeOriginal}", "an EXIF value, by its name"),
    ]

    /// Everything the placeholders of one file draw on, gathered once.
    struct Values: Sendable {
        var serial: Int = 1
        var created: Date?
        var modified: Date?
        var owner: String = ""
        var group: String = ""
        var exif: [String: String] = [:]
    }

    // MARK: - Expanding

    /// Expand the `$…` placeholders in `template`, leaving `$1` backreferences
    /// and anything unrecognised exactly as written.
    static func expand(_ template: String, with values: Values) -> String {
        var out = ""
        var rest = Substring(template)
        while let dollar = rest.firstIndex(of: "$") {
            out += rest[rest.startIndex ..< dollar]
            let after = rest.index(after: dollar)
            guard after < rest.endIndex else { out += "$"; rest = rest[after...]; break }

            if let (token, consumed) = token(in: rest[after...]) {
                out += escaped(value(of: token, with: values))
                rest = rest[consumed...]
            } else {
                // A backreference ($1) or just a stray $ -- copy it through for
                // the regex engine, which owns everything but our placeholders.
                out += "$"
                rest = rest[after...]
            }
        }
        out += rest
        return out
    }

    /// Our placeholders. `$exif{…}` first so the longer names win over a bare
    /// prefix, though none here is a prefix of another.
    private enum Token {
        case serial
        case created(String)
        case modified(String)
        case owner
        case group
        case exif(String)
    }

    /// Read one placeholder at the start of `text` (which begins just after the
    /// `$`). Returns it and the index in the *whole* string just past it.
    private static func token(in text: Substring) -> (Token, String.Index)? {
        func argument(after keyword: Substring) -> (String, String.Index)? {
            guard keyword.first == "{", let close = keyword.firstIndex(of: "}") else { return nil }
            let arg = String(keyword[keyword.index(after: keyword.startIndex) ..< close])
            return (arg, keyword.index(after: close))
        }

        if text.hasPrefix("cdate"), let (arg, end) = argument(after: text.dropFirst(5)) {
            return (.created(arg), end)
        }
        if text.hasPrefix("mdate"), let (arg, end) = argument(after: text.dropFirst(5)) {
            return (.modified(arg), end)
        }
        if text.hasPrefix("exif"), let (arg, end) = argument(after: text.dropFirst(4)) {
            return (.exif(arg), end)
        }
        if text.hasPrefix("owner"), !isNameChar(text.dropFirst(5).first) {
            return (.owner, text.index(text.startIndex, offsetBy: 5))
        }
        if text.hasPrefix("group"), !isNameChar(text.dropFirst(5).first) {
            return (.group, text.index(text.startIndex, offsetBy: 5))
        }
        if text.hasPrefix("n"), !isNameChar(text.dropFirst(1).first) {
            return (.serial, text.index(after: text.startIndex))
        }
        return nil
    }

    /// Lets `$owner` be recognised but not `$ownership`, and `$n` but not a
    /// `$name` somebody wrote meaning nothing of ours.
    private static func isNameChar(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber
    }

    private static func value(of token: Token, with values: Values) -> String {
        switch token {
        case .serial:            return String(values.serial)
        case .created(let fmt):  return values.created.map { format($0, fmt) } ?? ""
        case .modified(let fmt): return values.modified.map { format($0, fmt) } ?? ""
        case .owner:             return values.owner
        case .group:             return values.group
        case .exif(let key):     return values.exif[key] ?? ""
        }
    }

    /// The format is written the everyday way -- `YYYY-MM-DD`, `HH-mm-ss` --
    /// so the calendar-year `Y` and day-of-month `D` people mean are turned
    /// into the `y` and `d` the formatter wants. Numeric throughout, so a fixed
    /// POSIX locale keeps it from depending on the Mac's region.
    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
            .replacingOccurrences(of: "Y", with: "y")
            .replacingOccurrences(of: "D", with: "d")
        return formatter.string(from: date)
    }

    /// A value going into a regex-template replacement must have its `\` and
    /// `$` escaped, or the engine reads them as its own.
    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "$", with: "\\$")
    }

    // MARK: - Gathering a file's values

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "heic", "heif", "tiff", "tif", "gif", "bmp",
        "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2", "pef", "sr2", "webp",
    ]

    /// Everything but the serial number, read from the file at `url`. The serial
    /// is set by the caller, which alone knows the order the files are listed in.
    static func gather(for url: URL) -> Values {
        var values = Values()

        var info = stat()
        if lstat(url.path, &info) == 0 {
            values.owner = userName(info.st_uid)
            values.group = groupName(info.st_gid)
            values.modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            values.created = Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec))
        }

        if imageExtensions.contains(url.pathExtension.lowercased()) {
            values.exif = exif(of: url)
        }
        return values
    }

    private static func userName(_ uid: uid_t) -> String {
        guard let entry = getpwuid(uid) else { return String(uid) }
        return String(cString: entry.pointee.pw_name)
    }

    private static func groupName(_ gid: gid_t) -> String {
        guard let entry = getgrgid(gid) else { return String(gid) }
        return String(cString: entry.pointee.gr_name)
    }

    /// The EXIF and TIFF values of an image, flattened to `[name: text]` with
    /// the names ImageIO uses -- `DateTimeOriginal`, `Make`, `Model`, `ISOSpeedRatings`.
    static func exif(of url: URL) -> [String: String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any] else { return [:] }
        var out: [String: String] = [:]
        for dictionary in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary,
                           kCGImagePropertyGPSDictionary] {
            guard let values = properties[dictionary] as? [CFString: Any] else { continue }
            for (key, value) in values {
                out[key as String] = string(from: value)
            }
        }
        return out
    }

    /// A single scalar as text; an array (ISOSpeedRatings is one) as its first.
    private static func string(from value: Any) -> String {
        if let array = value as? [Any], let first = array.first { return "\(first)" }
        return "\(value)"
    }
}
