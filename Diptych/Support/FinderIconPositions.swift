import Foundation

/// Where Finder put the icons of a folder, and how big it draws them -- read
/// from the folder's `.DS_Store`, and written back there when icons are
/// placed by hand in Diptych, so Finder shows them where they were put.
///
/// Two records matter: `Iloc` on each item, the centre of its icon in points
/// from the top left of the window's content, as two 32-bit numbers followed
/// by eight bytes Finder always writes as `ffffffff ffff0000`; and `icvp` on
/// the folder itself (the entry ".") -- a property list of the icon view's
/// settings, among them `iconSize`, `gridSpacing` and `arrangeBy`. Finder
/// only honours the positions while `arrangeBy` is "none"; sorted, it lays
/// the icons out itself.
enum FinderIconPositions {

    struct Layout: Equatable {
        /// By file name.
        var positions: [String: CGPoint] = [:]
        var iconSize: Double?
        var gridSpacing: Double?
        /// "none" when icons stay where they were put.
        var arrangeBy: String?
    }

    enum Failure: Error, Equatable, LocalizedError {
        /// A `.DS_Store` that could not be read in full: writing it back
        /// would lose what was not read.
        case unreadable
        case notWritten(String)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "Finder's .DS_Store in this folder could not be read in full, so it was left alone."
            case .notWritten(let reason):
                "Finder's .DS_Store could not be written: \(reason)"
            }
        }
    }

    static func storeURL(in folder: URL) -> URL {
        folder.appendingPathComponent(".DS_Store")
    }

    /// What the folder's `.DS_Store` says; empty when there is none, or it is
    /// not one that can be read.
    static func read(_ folder: URL) -> Layout {
        guard let data = try? Data(contentsOf: storeURL(in: folder)),
              let store = try? DSStore(data: data) else { return Layout() }
        return layout(of: store.records)
    }

    static func layout(of records: [DSStore.Record]) -> Layout {
        var layout = Layout()
        for record in records {
            switch (record.key, record.value) {
            case ("Iloc", .blob(let data)):
                if let point = position(from: data) { layout.positions[record.entry] = point }
            case ("icvp", .blob(let data)) where record.entry == ".":
                guard let options = try? PropertyListSerialization.propertyList(
                    from: data, format: nil) as? [String: Any] else { continue }
                layout.iconSize = (options["iconSize"] as? NSNumber)?.doubleValue
                layout.gridSpacing = (options["gridSpacing"] as? NSNumber)?.doubleValue
                layout.arrangeBy = options["arrangeBy"] as? String
            default:
                continue
            }
        }
        return layout
    }

    /// `Iloc`'s first eight bytes: x then y, signed.
    static func position(from data: Data) -> CGPoint? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return nil }
        func int(_ at: Int) -> Int32 {
            Int32(bitPattern: bytes[at ..< at + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        }
        return CGPoint(x: Double(int(0)), y: Double(int(4)))
    }

    static func iloc(_ point: CGPoint) -> Data {
        func bytes(_ value: Double) -> [UInt8] {
            let raw = UInt32(bitPattern: Int32(clamping: Int(value.rounded())))
            return [UInt8(raw >> 24), UInt8(raw >> 16 & 0xFF), UInt8(raw >> 8 & 0xFF), UInt8(raw & 0xFF)]
        }
        return Data(bytes(point.x) + bytes(point.y) + [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0])
    }

    /// The records with these icons placed: their `Iloc` replaced or added,
    /// and the folder's icon view set to keep icons where they are put -- a
    /// view options list made in Finder's own shape when there was none.
    /// Every other record is kept as it was.
    /// With `settingSize`, the folder's icon size becomes `iconSize` too --
    /// when the positions were worked out for that size and not Finder's.
    static func placing(_ positions: [String: CGPoint], iconSize: Double, settingSize: Bool = false,
                        in records: [DSStore.Record]) -> [DSStore.Record] {
        var kept = records.filter { !($0.key == "Iloc" && positions[$0.entry] != nil) }
        for (name, point) in positions {
            kept.append(DSStore.Record(entry: name, key: "Iloc", value: .blob(iloc(point))))
        }

        var options: [String: Any] = defaultViewOptions(iconSize: iconSize)
        if let index = kept.firstIndex(where: { $0.entry == "." && $0.key == "icvp" }) {
            if case .blob(let data) = kept[index].value,
               let existing = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any] {
                options = existing
            }
            kept.remove(at: index)
        }
        options["arrangeBy"] = "none"
        if settingSize { options["iconSize"] = iconSize }
        if let data = try? PropertyListSerialization.data(fromPropertyList: options,
                                                          format: .binary, options: 0) {
            kept.append(DSStore.Record(entry: ".", key: "icvp", value: .blob(data)))
        }
        return kept
    }

    /// Writes the positions into the folder's `.DS_Store`, making one if
    /// there is none. A file that cannot be read in full is not touched.
    static func write(_ positions: [String: CGPoint], iconSize: Double, settingSize: Bool = false,
                      in folder: URL) throws {
        let url = storeURL(in: folder)
        var records: [DSStore.Record] = []
        var tail: [UInt8]?
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let store = try? DSStore(data: data), store.isComplete
            else { throw Failure.unreadable }
            records = store.records
            tail = DSStoreWriter.headerTail(of: data)
        }
        let data: Data
        do {
            data = try DSStoreWriter.encode(placing(positions, iconSize: iconSize,
                                                    settingSize: settingSize, in: records),
                                            headerTail: tail)
        } catch {
            throw Failure.unreadable
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw Failure.notWritten(error.localizedDescription)
        }
    }

    /// What Finder writes for a folder whose icon view was never adjusted.
    static func defaultViewOptions(iconSize: Double) -> [String: Any] {
        ["arrangeBy": "none", "backgroundColorBlue": 1.0, "backgroundColorGreen": 1.0,
         "backgroundColorRed": 1.0, "backgroundType": 0, "gridOffsetX": 0.0,
         "gridOffsetY": 0.0, "gridSpacing": 54.0, "iconSize": iconSize,
         "labelOnBottom": true, "scrollPositionX": 0.0, "scrollPositionY": 0.0,
         "showIconPreview": true, "showItemInfo": false, "textSize": 12.0,
         "viewOptionsVersion": 1]
    }
}
