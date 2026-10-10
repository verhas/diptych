import Foundation
import ImageIO
import Observation

/// Image ▸ Edit EXIF: the EXIF of one or more images, field by field, and
/// which fields are to be written.
///
/// A field is written only when its box is ticked. Typing in a field ticks
/// it; unticking it greys the field and keeps what was typed, so ticking it
/// again picks up where it was left. A field whose files disagree is shown
/// grey and empty, and what is typed there replaces every file's value.
@MainActor
@Observable
final class ExifEditorModel {

    /// Posted when files have been written, for the panes to read them again:
    /// a change inside a file is not a change to its folder, so they would
    /// not notice.
    static let saved = Notification.Name("dev.verhas.Diptych.exifSaved")

    /// Pictures' EXIF, or videos' metadata shown as the same fields.
    enum Kind: Sendable { case images, videos }

    let files: [URL]
    let kind: Kind
    /// The fields there are: EXIF's, or the ones a video has.
    private(set) var catalogue: [ExifField] = ExifFields.catalogue
    /// Each video's values as read, for what Save leaves as it was.
    @ObservationIgnored private var videoValues: [URL: [ExifKey: Any]] = [:]
    private(set) var rows: [Row] = []
    /// How latitude and longitude are written, for the Location heading's
    /// button to go round.
    private(set) var coordinateFormat = CoordinateFormat.decimal
    /// Apple Intelligence is working out a description.
    private(set) var isSuggesting = false
    /// The coordinate field a pasted link or plus code is being looked up
    /// for, while it is.
    private(set) var lookingUp: ExifKey?
    @ObservationIgnored private var suggestionAsked = false
    private(set) var isLoading = true
    private(set) var isSaving = false
    /// Files that are not readable as images; they are left out.
    private(set) var unreadable: [URL] = []
    /// What went wrong in the last save, for the window to show.
    private(set) var problems: [String] = []

    /// What the files hold in one field.
    enum Current: Equatable {
        /// In none of them.
        case unset
        /// The same in all of them.
        case same(String)
        /// Not the same in all -- or there in some and not in others.
        case different
        /// There, but not as anything that can be shown as text.
        case unshowable
    }

    struct Row: Identifiable {
        let field: ExifField
        let current: Current
        var text: String
        /// Typed into since the window opened.
        var edited = false
        /// To be written on Save.
        var checked = false
        /// To be taken out of every file on Save.
        var removing = false
        /// Added from Add Field, not read from any file.
        var added = false
        var error: String?
        /// Typed rather than picked: a date, a time zone or a listed value
        /// written by hand, which may then be one a camera would not write.
        var typing = false
        /// The time zone picked, whose offset is worked out on Save from each
        /// image's own date.
        var zone: String?
        /// Filled in by Apple Intelligence, not by the user.
        var suggested = false

        var id: ExifKey { field.key }

        /// Typed into, then unticked: kept, but not to be written.
        var isParked: Bool { edited && !checked && !removing }

        /// Something to remove: some file has it.
        var canRemove: Bool { current != .unset }

        var isGrey: Bool { isParked || (current == .different && !edited) }

        /// Nothing in it yet: no value shared by all, and nothing typed.
        var isEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

        var placeholder: String {
            switch current {
            case .different: "Different in each file"
            case .unset:     field.example.isEmpty ? "Not set" : "Not set \u{2014} e.g. \(field.example)"
            case .same, .unshowable: ""
            }
        }
    }

    init(files: [URL], kind: Kind = .images) {
        self.files = files
        self.kind = kind
        Task { await load() }
    }

    var readable: [URL] { files.filter { !unreadable.contains($0) } }

    var hasChanges: Bool { rows.contains { $0.checked } }

    /// The catalogue's fields not on show yet, for Add Field.
    var addable: [ExifField] {
        let shown = Set(rows.map(\.id))
        return catalogue.filter { !shown.contains($0.key) }
    }

    func rows(in group: ExifGroup) -> [Row] { rows.filter { $0.field.key.group == group } }

    /// What Control-Space offers in a make or model field, from
    /// ~/.diptych/exif: for a model, those of the make written beside it.
    func suggestions(for key: ExifKey) -> [String] {
        let makeName = key.name == "Model" ? "Make" : key.name == "LensModel" ? "LensMake" : nil
        let make = makeName.flatMap { name in rows.first { $0.field.key.name == name }?.text }
        return ExifDatabase.values(for: key, make: make)
    }

    // MARK: - Reading

    private final class Read: @unchecked Sendable {
        var values: [[ExifKey: Any]?] = []
    }

    func load() async {
        if kind == .videos { return await loadVideos() }
        isLoading = true
        let files = files
        let read = await BlockingWork.run { () -> Read in
            let read = Read()
            read.values = files.map { ExifWrite.values(of: $0) }
            return read
        }
        unreadable = zip(files, read.values).filter { $0.1 == nil }.map(\.0)
        rows = Self.rows(from: read.values.compactMap { $0 })
        reformatCoordinates()
        isLoading = false
        suggestDescription()
    }

    /// Videos: their metadata as the fields a video has. A camera only
    /// where one of them is a QuickTime movie, which can hold it, or has
    /// one.
    private func loadVideos() async {
        isLoading = true
        var values: [URL: [ExifKey: Any]] = [:]
        for url in files {
            if let found = await VideoExif.values(of: url) { values[url] = found }
        }
        videoValues = values
        unreadable = files.filter { values[$0] == nil }
        let withCamera = readable.contains { VideoMetadata.format(of: $0) == "mov" }
            || values.values.contains { $0.keys.contains { $0.name == "Make" || $0.name == "Model" } }
        catalogue = VideoExif.catalogue(withCamera: withCamera)
        rows = Self.rows(from: readable.compactMap { values[$0] }, catalogue: catalogue)
        reformatCoordinates()
        isLoading = false
    }

    /// A row for every common field, and for every other field any file has.
    static func rows(from values: [[ExifKey: Any]],
                     catalogue: [ExifField] = ExifFields.catalogue) -> [Row] {
        var keys = Set(catalogue.filter(\.common).map(\.key))
        for file in values { keys.formUnion(file.keys) }
        return keys.map { key in
            let found = values.map { $0[key] }
            let field = catalogue.first { $0.key == key }
                ?? ExifFields.field(for: key, sample: found.compactMap { $0 }.first)
            let current = current(of: found)
            if case .same(let text) = current {
                return Row(field: field, current: current, text: text)
            }
            return Row(field: field, current: current, text: "")
        }
        .sorted(by: order)
    }

    static func current(of found: [Any?]) -> Current {
        guard found.contains(where: { $0 != nil }) else { return .unset }
        guard found.allSatisfy({ $0 != nil }) else { return .different }
        let texts = found.map { ExifFields.text(of: $0!) }
        guard let first = texts[0] else {
            return texts.allSatisfy { $0 == nil } ? .unshowable : .different
        }
        return texts.allSatisfy { $0 == first } ? .same(first) : .different
    }

    /// The catalogue's order within a group, then the rest by name.
    private static func order(_ a: Row, _ b: Row) -> Bool {
        if a.field.key.group != b.field.key.group { return a.field.key < b.field.key }
        let place = { (row: Row) in
            ExifFields.catalogue.firstIndex { $0.key == row.field.key } ?? Int.max
        }
        let (pa, pb) = (place(a), place(b))
        return pa != pb ? pa < pb : a.field.label < b.field.label
    }

    // MARK: - Editing

    func type(_ text: String, in id: ExifKey) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        var text = text
        // An o, which no coordinate has, is the degree sign: there is no key
        // for it.
        if case .coordinate = rows[index].field.input {
            text = text.replacingOccurrences(of: "o", with: "\u{00B0}")
                .replacingOccurrences(of: "O", with: "\u{00B0}")
        }
        guard rows[index].text != text else { return }
        rows[index].text = text
        rows[index].zone = nil
        rows[index].suggested = false
        markEdited(index)
        // A minus sign or a letter says the hemisphere, which is a field of
        // its own in EXIF: it is set to match.
        if case .coordinate(let latitude, let reference) = rows[index].field.input,
           let hemisphere = ExifFields.coordinate(from: text, latitude: latitude)?.hemisphere,
           let at = rows.firstIndex(where: { $0.id == reference }),
           rows[at].text != hemisphere {
            rows[at].text = hemisphere
            rows[at].typing = false
            markEdited(at)
        }
    }

    /// Clicked or tabbed into. A field unticked after typing is ticked again:
    /// going back into it is going back to editing it, and having to tick the
    /// box first was a click for nothing.
    func touch(_ id: ExifKey) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        if rows[index].isParked {
            rows[index].checked = true
            rows[index].error = nil
        }
    }

    private func markEdited(_ index: Int) {
        rows[index].edited = true
        rows[index].checked = true
        rows[index].removing = false
        rows[index].error = nil
    }

    /// A value from a field's list, or a date from its picker.
    func choose(_ value: String, in id: ExifKey) {
        type(value, in: id)
        if let index = rows.firstIndex(where: { $0.id == id }) { rows[index].typing = false }
    }

    /// Typing instead of picking, or back to picking.
    func setTyping(_ typing: Bool, in id: ExifKey) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].typing = typing
    }

    /// A time zone from the menu: shown as its offset on the date beside it,
    /// written as each image's own.
    func chooseZone(_ identifier: String, in id: ExifKey) {
        guard let index = rows.firstIndex(where: { $0.id == id }),
              let zone = TimeZone(identifier: identifier) else { return }
        rows[index].text = ExifFields.offset(of: zone, at: referenceDate(for: rows[index]))
        rows[index].zone = identifier
        rows[index].typing = false
        markEdited(index)
    }

    /// The date a time zone row goes with, as it reads now: typed, or shared
    /// by all the images.
    func referenceDate(for row: Row) -> String? {
        guard case .offset(let dateKey?) = row.field.input,
              let date = rows.first(where: { $0.id == dateKey }),
              ExifFields.exifDate(date.text, format: ExifFields.dateTimeFormat) != nil
        else { return nil }
        return date.text
    }

    /// A place on the globe, in signed degrees: south and west negative.
    nonisolated struct Location: Equatable, Sendable {
        let latitude: Double
        let longitude: Double
    }

    /// Where the images were taken, as the location reads now: both
    /// coordinates there, valid, and the same in every image -- or typed.
    /// The hemisphere is the text's own letter or sign, else its N/S or E/W
    /// field. Nil when either is missing, different, or being removed.
    var location: Location? {
        /// What Save leaves in the files: typed if ticked, else as it was.
        func value(_ key: ExifKey) -> String? {
            guard let row = rows.first(where: { $0.id == key }), !row.removing else { return nil }
            if row.checked { return row.text }
            if case .same(let text) = row.current { return text }
            return nil
        }
        func degrees(_ name: CFString, latitude: Bool) -> Double? {
            let key = ExifKey(group: .gps, name: name as String)
            guard let row = rows.first(where: { $0.id == key }),
                  case .coordinate(_, let reference) = row.field.input,
                  let text = value(key),
                  let coordinate = ExifFields.coordinate(from: text, latitude: latitude),
                  coordinate.degrees <= (latitude ? 90 : 180) else { return nil }
            let hemisphere = coordinate.hemisphere
                ?? value(reference)?.trimmingCharacters(in: .whitespaces).uppercased()
            return hemisphere == "S" || hemisphere == "W" ? -coordinate.degrees : coordinate.degrees
        }
        guard let latitude = degrees(kCGImagePropertyGPSLatitude, latitude: true),
              let longitude = degrees(kCGImagePropertyGPSLongitude, latitude: false)
        else { return nil }
        return Location(latitude: latitude, longitude: longitude)
    }

    /// Text pasted into Latitude or Longitude: a place as a map app copies
    /// it -- a coordinate pair, a link, a plus code -- fills all four
    /// location fields. False for anything else, which is pasted as it is.
    @discardableResult
    func paste(_ text: String, into id: ExifKey) -> Bool {
        guard let place = PastedPlace.recognize(text) else { return false }
        if case .coordinates(let location) = place {
            setLocation(location)
            return true
        }
        lookingUp = id
        Task { [weak self] in
            do {
                let location = try await place.resolve()
                guard let self, self.lookingUp == id else { return }
                self.lookingUp = nil
                self.setLocation(location)
            } catch {
                guard let self, self.lookingUp == id else { return }
                self.lookingUp = nil
                if let index = self.rows.firstIndex(where: { $0.id == id }) {
                    self.rows[index].error = error.localizedDescription
                }
            }
        }
        return true
    }

    /// Latitude, longitude and their N/S and E/W, all four ticked, the
    /// coordinates written the way the Location heading says.
    func setLocation(_ location: Location) {
        func set(_ name: CFString, _ text: String) {
            let key = ExifKey(group: .gps, name: name as String)
            if !rows.contains(where: { $0.id == key }),
               let field = catalogue.first(where: { $0.key == key }) {
                add(field)
            }
            choose(text, in: key)
        }
        set(kCGImagePropertyGPSLatitude,
            ExifFields.format(degrees: abs(location.latitude), as: coordinateFormat))
        set(kCGImagePropertyGPSLatitudeRef, location.latitude < 0 ? "S" : "N")
        set(kCGImagePropertyGPSLongitude,
            ExifFields.format(degrees: abs(location.longitude), as: coordinateFormat))
        set(kCGImagePropertyGPSLongitudeRef, location.longitude < 0 ? "W" : "E")
    }

    /// The next way of writing coordinates, with every one on show rewritten.
    func rotateCoordinateFormat() {
        coordinateFormat = coordinateFormat.next
        reformatCoordinates()
    }

    /// Rewritten, not edited: the value is the same, so nothing is ticked.
    private func reformatCoordinates() {
        for index in rows.indices {
            guard case .coordinate(let latitude, _) = rows[index].field.input,
                  let coordinate = ExifFields.coordinate(from: rows[index].text,
                                                         latitude: latitude) else { continue }
            var text = ExifFields.format(degrees: coordinate.degrees, as: coordinateFormat)
            if let hemisphere = coordinate.hemisphere, rows[index].text.contains(where: \.isLetter) {
                text += " " + hemisphere
            }
            rows[index].text = text
        }
    }

    /// Whether what a row holds is a value a camera would write. A row is
    /// judged on what it shows: what was typed, or the value all the images
    /// share -- a date in the future is worth knowing about either way.
    func verdict(for row: Row) -> ExifVerdict {
        guard !row.removing, row.zone == nil else { return .fine }
        if case .computed = row.field.input { return .fine }
        guard row.field.kind != .readOnly || row.edited else { return .fine }
        return ExifFields.verdict(of: row.text, for: row.field)
    }

    func setChecked(_ checked: Bool, for id: ExifKey) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].checked = checked
        if !checked { rows[index].removing = false }
        rows[index].error = nil
    }

    /// The bin button: marks a field for removal, or takes the mark off. A
    /// field added here and never in any file simply goes again.
    func toggleRemoval(of id: ExifKey) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        if rows[index].added && !rows[index].canRemove {
            rows.remove(at: index)
            return
        }
        rows[index].removing.toggle()
        rows[index].checked = rows[index].removing || rows[index].edited
        rows[index].error = nil
    }

    func add(_ field: ExifField) {
        guard !rows.contains(where: { $0.id == field.key }) else { return }
        var row = Row(field: field, current: .unset, text: "", added: true)
        // Taken from each image: there is nothing to type, so it is to be
        // written as soon as it is added.
        if case .computed = field.input {
            row.edited = true
            row.checked = true
        }
        rows.append(row)
        rows.sort(by: Self.order)
    }

    // MARK: - As JSON, through the clipboard

    /// Said under the fields after a copy or a paste: what it did.
    private(set) var notice: String?

    /// Every field with a value, as the window shows it -- typed, or shared
    /// by all the files -- by group and name: `{"Exif": {"DateTimeOriginal":
    /// "1978:01:01 00:00:00"}, "GPS": {...}, "TIFF": {...}}`. Fields the files
    /// disagree on, and ones being removed, are left out.
    func json() -> String {
        var groups: [String: [String: String]] = [:]
        for row in rows where !row.removing && !row.isEmpty {
            if case .computed = row.field.input { continue }
            groups[row.field.key.group.name, default: [:]][row.field.key.name] = row.text
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: groups, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    func copyJSON() {
        Clipboard.copyText(json())
        let count = rows.filter { !$0.removing && !$0.isEmpty }.count
        notice = count == 1 ? "1 field copied as JSON" : "\(count) fields copied as JSON"
    }

    /// Fields from JSON as `json()` writes it -- or with the names alone,
    /// not grouped -- typed into the window, to be checked and saved as any
    /// typing is. Names that are no field here are said.
    func pasteJSON(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let top = object as? [String: Any] else {
            notice = nil
            problems = ["The clipboard holds no JSON object of fields."]
            return
        }
        var values: [(ExifGroup?, String, Any)] = []
        for (name, value) in top {
            if let fields = value as? [String: Any], let group = ExifGroup(name: name) {
                values += fields.map { (group, $0.key, $0.value) }
            } else {
                values.append((nil, name, value))
            }
        }
        var set = 0
        var unknown: [String] = []
        for (group, name, value) in values.sorted(by: { $0.1 < $1.1 }) {
            guard let field = catalogue.first(where: {
                $0.key.name == name && (group == nil || $0.key.group == group)
            }) ?? rows.first(where: {
                $0.field.key.name == name && (group == nil || $0.field.key.group == group)
            })?.field else {
                unknown.append(name)
                continue
            }
            if case .computed = field.input { continue }
            let text = (value as? String) ?? (value as? NSNumber)?.stringValue ?? "\(value)"
            if !rows.contains(where: { $0.id == field.key }) { add(field) }
            choose(text, in: field.key)
            set += 1
        }
        problems = unknown.isEmpty ? []
            : ["Not fields here, so left out: " + unknown.joined(separator: ", ") + "."]
        notice = set == 1 ? "1 field pasted from JSON \u{2014} Save writes it"
            : "\(set) fields pasted from JSON \u{2014} Save writes them"
    }

    // MARK: - A description from Apple Intelligence

    /// One image with no description: Apple Intelligence is asked for one in
    /// the background. It arrives as if typed and then unticked -- grey, not
    /// to be written unless the box is ticked -- and only into a field still
    /// untouched: whatever the user typed or picked there in the meantime
    /// wins. Being focused is not touching it: the window may well open with
    /// the description field focused.
    private func suggestDescription() {
        let key = ExifKey(group: .tiff, name: kCGImagePropertyTIFFImageDescription as String)
        guard kind == .images, !suggestionAsked, readable.count == 1, let url = readable.first,
              ConfigStore.shared.configuration.useAppleIntelligence,
              NameSuggester.status == .ready,
              let row = rows.first(where: { $0.id == key }),
              row.current == .unset, !row.edited else { return }
        suggestionAsked = true
        isSuggesting = true
        Task { [weak self] in
            let caption = await NameSuggester.caption(forImageAt: url)
            guard let self else { return }
            self.isSuggesting = false
            guard let caption, let index = self.rows.firstIndex(where: { $0.id == key }),
                  !self.rows[index].edited, !self.rows[index].removing,
                  self.rows[index].isEmpty else { return }
            self.rows[index].text = caption
            self.rows[index].edited = true
            self.rows[index].checked = false
            self.rows[index].suggested = true
        }
    }

    // MARK: - Saving

    /// What Save would write, or the rows that are wrong.
    func changes() -> [ExifKey: ExifWrite.Change]? {
        var changes: [ExifKey: ExifWrite.Change] = [:]
        var valid = true
        for index in rows.indices where rows[index].checked {
            let row = rows[index]
            if row.removing {
                changes[row.id] = .remove
                continue
            }
            if case .computed(let what) = row.field.input {
                changes[row.id] = .computed(what)
                continue
            }
            if row.text.trimmingCharacters(in: .whitespaces).isEmpty {
                // An emptied field is removed: EXIF has no empty value that
                // means anything else.
                changes[row.id] = .remove
                continue
            }
            if let zone = row.zone, case .offset(let dateKey) = row.field.input {
                changes[row.id] = .zone(zone, date: dateKey)
                continue
            }
            if case .wrong(let message) = verdict(for: row) {
                rows[index].error = message
                valid = false
                continue
            }
            if case .coordinate(let latitude, _) = row.field.input,
               let coordinate = ExifFields.coordinate(from: row.text, latitude: latitude) {
                changes[row.id] = .set(NSNumber(value: coordinate.degrees))
                continue
            }
            do {
                let text = row.field.hasHelper
                    ? row.text.trimmingCharacters(in: .whitespaces) : row.text
                changes[row.id] = .set(try ExifFields.value(of: text, as: row.field.kind))
            } catch {
                rows[index].error = error.message
                valid = false
            }
        }
        return valid ? changes : nil
    }

    final class Saved: @unchecked Sendable {
        var done: [(url: URL, before: URL)] = []
        var failures: [String] = []
    }

    /// Each image read, changed by `change`, and written back in place, a
    /// snapshot of it kept first for Undo. `change` gives nil for an image
    /// it leaves as it is.
    nonisolated static func rewriteInPlace(
        _ files: [URL],
        change: @escaping @Sendable (Data, String) throws(ExifWrite.Failure) -> Data?
    ) async -> Saved {
        await BlockingWork.run { () -> Saved in
            let saved = Saved()
            for url in files {
                let name = url.lastPathComponent
                do {
                    let data = try Data(contentsOf: url)
                    let changed: Data
                    do {
                        guard let result = try change(data, name) else { continue }
                        changed = result
                    } catch let failure as ExifWrite.Failure {
                        saved.failures.append(failure.message)
                        continue
                    }
                    let before = try UndoSnapshots.keep(url)
                    do {
                        // In place, so it stays the same file -- its hard
                        // links, permissions and attributes with it.
                        try changed.write(to: url)
                    } catch {
                        try? UndoSnapshots.putBack(before, into: url)
                        try? FileManager.default.removeItem(at: before)
                        throw error
                    }
                    saved.done.append((url, before))
                } catch {
                    saved.failures.append("\u{201C}\(name)\u{201D} could not be written: "
                                          + error.localizedDescription)
                }
            }
            return saved
        }
    }

    /// True when every file was written, and the window can close.
    func save() async -> Bool {
        problems = []
        guard let changes = changes(), !changes.isEmpty else { return false }
        isSaving = true
        defer { isSaving = false }
        if kind == .videos { return await saveVideos(changes) }

        let boxed = ChangesBox(changes)
        let saved = await Self.rewriteInPlace(readable) { data, name throws(ExifWrite.Failure) in
            try ExifWrite.rewrite(data, name: name, changes: boxed.changes)
        }

        FileHistory.shared.recordContents(saved.done, name: "EXIF Change",
                                          told: told(saved.done.map { $0.url }, changes: changes))
        if !saved.done.isEmpty {
            NotificationCenter.default.post(name: Self.saved, object: nil)
        }
        guard saved.failures.isEmpty else {
            // What was typed stays, to be mended and saved again -- read
            // afresh, the files would have taken it all away.
            problems = saved.failures
                + (saved.done.isEmpty ? [] : ["The others were changed; Undo puts them back."])
            return false
        }
        return true
    }

    /// Each video written with the changes as its own: a time zone's offset
    /// on its own date, the place from its own fields and the ones changed.
    private func saveVideos(_ changes: [ExifKey: ExifWrite.Change]) async -> Bool {
        var done: [(url: URL, before: URL)] = []
        var failures: [String] = []
        for url in readable {
            let video = VideoExif.changes(changes, existing: videoValues[url] ?? [:])
            do {
                done.append((url, try await VideoMetadata.rewrite(url, changes: video)))
            } catch {
                failures.append(error.message)
            }
        }
        if let first = done.first {
            let labels = rows.filter { changes[$0.id] != nil }.map { row -> String in
                if case .remove? = changes[row.id] { return "\(row.field.label) (removed)" }
                return row.field.label
            }.joined(separator: ", ")
            let urls = done.map(\.url)
            let folder = FileHistory.folder(of: first.url)
            FileHistory.shared.recordContents(
                done, name: "Video Metadata Change",
                told: urls.count == 1
                    ? "The metadata of \(FileHistory.quoted(first.url.lastPathComponent)) in "
                      + "\(folder) was changed: \(labels)."
                    : "The metadata of \(urls.count) videos in \(folder) was changed: "
                      + "\(labels). The videos: \(FileHistory.Plan.names(urls)).")
            NotificationCenter.default.post(name: Self.saved, object: nil)
        }
        guard failures.isEmpty else {
            problems = failures
                + (done.isEmpty ? [] : ["The others were changed; Undo puts them back."])
            return false
        }
        return true
    }

    private final class ChangesBox: @unchecked Sendable {
        let changes: [ExifKey: ExifWrite.Change]
        init(_ changes: [ExifKey: ExifWrite.Change]) { self.changes = changes }
    }

    /// The history's sentence: which files, and which fields.
    func told(_ urls: [URL], changes: [ExifKey: ExifWrite.Change]) -> String {
        guard let first = urls.first else { return "" }
        let labels = rows.filter { changes[$0.id] != nil }.map { row -> String in
            if case .remove? = changes[row.id] { return "\(row.field.label) (removed)" }
            return row.field.label
        }
        let fields = labels.joined(separator: ", ")
        let folder = FileHistory.folder(of: first)
        return urls.count == 1
            ? "The EXIF of \(FileHistory.quoted(first.lastPathComponent)) in \(folder) was "
              + "changed: \(fields)."
            : "The EXIF of \(urls.count) images in \(folder) was changed: \(fields). "
              + "The images: \(FileHistory.Plan.names(urls))."
    }
}
