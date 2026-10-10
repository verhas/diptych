import AppKit
import ImageIO
import SwiftUI

/// Image ▸ Edit EXIF: the images at the top, their fields below, each with
/// the box that says it will be written. Video ▸ Edit Metadata is the same
/// window on videos: their date, place, camera and words as the same fields.
struct ExifEditorView: View {

    @State private var model: ExifEditorModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: ExifKey?
    @State private var calendarFor: ExifKey?
    /// The image picked in the list at the top.
    @State private var chosenFile: URL?

    /// F3, as AppKit's key events spell it.
    private static let f3 = KeyEquivalent(Character(UnicodeScalar(NSF3FunctionKey)!))

    init(urls: [URL], kind: ExifEditorModel.Kind = .images) {
        _model = State(initialValue: ExifEditorModel(files: urls, kind: kind))
    }

    private var isVideo: Bool { model.kind == .videos }

    /// "image", "video".
    private func things(_ count: Int) -> String {
        let one = isVideo ? "video" : "image"
        return count == 1 ? "1 \(one)" : "\(count) \(one)s"
    }

    private func title(of group: ExifGroup) -> String {
        guard isVideo else { return group.title }
        switch group {
        case .tiff: return "Video and Camera"
        case .exif: return "Date Taken"
        case .gps:  return group.title
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
            Divider()
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fields
            }
            Divider()
            footer
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(minWidth: 620, minHeight: 460)
        .onChange(of: focused) { _, id in
            if let id { model.touch(id) }
        }
        .navigationTitle((isVideo ? "Metadata of " : "EXIF of ")
                         + (model.files.count == 1 ? model.files[0].lastPathComponent
                            : (isVideo ? "\(model.files.count) Videos"
                                       : "\(model.files.count) Images")))
        .background(WindowAccessor { window in
            guard let window else { return }
            AppWindows.shared.register(window)
            WindowSubjects.shared.register(window, kind: isVideo ? "video" : "exif",
                                           description: model.files.map(\.path)
                                               .joined(separator: "\n"))
        })
    }

    // MARK: - The images

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(things(model.files.count))
                .font(.headline)
            // One image at a time: Space shows it in Quick Look, Return or
            // F3 opens it, as in a pane.
            List(selection: $chosenFile) {
                ForEach(model.files, id: \.self) { url in
                    HStack(spacing: 6) {
                        // The whole path: the window outlives the pane it
                        // was opened from, and an agent can open it on
                        // images from any folders.
                        (Text(url.deletingLastPathComponent().path
                              .replacingOccurrences(of: "/+$", with: "",
                                                    options: .regularExpression) + "/")
                            .foregroundStyle(.secondary)
                         + Text(url.lastPathComponent))
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                        if model.unreadable.contains(url) {
                            Text(isVideo ? "not a QuickTime or MP4 video; left out"
                                         : "cannot be read as an image; left out")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                    .help(url.path)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 18)
            .contextMenu(forSelectionType: URL.self) { urls in
                if let url = urls.first {
                    Button("Open") { NSWorkspaceOpener.open(url) }
                    Button("Quick Look") { QuickLookController.shared.toggle([url], owner: nil) }
                    Divider()
                    Button("Copy Path") { Clipboard.copyText(url.path) }
                }
            } primaryAction: { urls in
                urls.first.map(NSWorkspaceOpener.open)
            }
            .onKeyPress(.space) {
                guard let chosenFile else { return .ignored }
                QuickLookController.shared.toggle([chosenFile], owner: nil)
                return .handled
            }
            .onKeyPress(keys: [.return, Self.f3]) { _ in
                guard let chosenFile else { return .ignored }
                NSWorkspaceOpener.open(chosenFile)
                return .handled
            }
            .onChange(of: chosenFile) { _, url in
                // The preview follows the selection, as in a pane.
                if let url { QuickLookController.shared.update([url]) }
            }
            .frame(height: model.files.count > 4 ? 90 : CGFloat(model.files.count) * 20 + 6)
        }
    }

    // MARK: - The fields

    private var fields: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(ExifGroup.allCases, id: \.self) { group in
                    let rows = model.rows(in: group)
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            groupHeading(group)
                            Grid(alignment: .leadingFirstTextBaseline,
                                 horizontalSpacing: 8, verticalSpacing: 6) {
                                ForEach(rows) { row in gridRow(row) }
                                if group == .gps, let location = model.location {
                                    // Under the values, in their column.
                                    GridRow {
                                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                        LocationMap(location: location)
                                            .padding(.top, 4)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func groupHeading(_ group: ExifGroup) -> some View {
        HStack {
            Text(title(of: group)).font(.subheadline).bold()
            Spacer()
            // One button for the whole section: every coordinate is written
            // the same way, and going round rewrites them all.
            if group == .gps {
                Button {
                    model.rotateCoordinateFormat()
                } label: {
                    Label(model.coordinateFormat.title,
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .controlSize(.small)
                .help("Write latitude and longitude as "
                      + model.coordinateFormat.next.title.lowercased()
                      + " \u{2014} " + model.coordinateFormat.next.example)
            }
        }
    }

    private func gridRow(_ row: ExifEditorModel.Row) -> some View {
        let verdict = model.verdict(for: row)
        return GridRow {
            Toggle("", isOn: Binding(get: { row.checked },
                                     set: { model.setChecked($0, for: row.id) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                // Nothing to write until something is typed or removed.
                .disabled(!row.edited && !row.removing)
                .help(row.checked ? "Will be written on Save" : "Not written on Save")

            Text(row.field.label)
                .foregroundStyle(row.isParked ? .secondary : .primary)
                .frame(width: 190, alignment: .leading)
                .help(row.field.key.path)

            VStack(alignment: .leading, spacing: 2) {
                value(row, verdict: verdict)
                if let error = row.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if model.lookingUp == row.id {
                    Text("Looking up the place\u{2026}").font(.caption).foregroundStyle(.secondary)
                } else if row.suggested {
                    Text(row.checked ? "Suggested by Apple Intelligence"
                         : "Suggested by Apple Intelligence \u{2014} tick the box to keep it")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let message = verdict.message, !row.isParked {
                    Text(message).font(.caption).foregroundStyle(colour(of: verdict))
                }
            }
            .gridColumnAlignment(.leading)

            Button {
                model.toggleRemoval(of: row.id)
            } label: {
                Image(systemName: row.removing ? "arrow.uturn.backward" : "minus.circle")
            }
            .buttonStyle(.borderless)
            .opacity(row.canRemove || row.added ? 1 : 0)
            .disabled(!row.canRemove && !row.added)
            .help(row.removing ? "Keep this field"
                  : row.canRemove ? "Remove this field from every image" : "Take this field away")
        }
    }

    /// Orange for a value a camera would not write but EXIF can hold; red
    /// for one it cannot.
    private func colour(of verdict: ExifVerdict) -> Color {
        switch verdict {
        case .fine:    .secondary
        case .unusual: .orange
        case .wrong:   .red
        }
    }

    @ViewBuilder
    private func value(_ row: ExifEditorModel.Row, verdict: ExifVerdict) -> some View {
        if row.removing {
            Text(shown(row.current).isEmpty ? "Removed on Save" : shown(row.current))
                .strikethrough()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .help("Removed from every image on Save")
        } else if case .computed = row.field.input {
            Text(row.added ? "Taken from each image\u{2019}s own size on Save"
                           : shown(row.current))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .help("The image\u{2019}s own size; it cannot be typed")
        } else if row.field.kind == .readOnly {
            Text(shown(row.current))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .help("Set by the image itself; it can be removed, not typed into")
        } else if row.field.hasHelper && !row.typing && helperFits(row) {
            HStack(spacing: 6) {
                helper(row)
                Spacer(minLength: 0)
                Button { model.setTyping(true, in: row.id) } label: {
                    Image(systemName: "keyboard")
                }
                .buttonStyle(.borderless)
                .help("Type it instead")
            }
        } else {
            HStack(spacing: 6) {
                textField(row, verdict: verdict)
                if row.field.hasHelper {
                    Button { model.setTyping(false, in: row.id) } label: {
                        Image(systemName: helperSymbol(row.field.input))
                    }
                    .buttonStyle(.borderless)
                    .disabled(!helperFits(row))
                    .help(helperFits(row) ? "Pick it instead"
                                          : "This value cannot be picked; type it")
                }
            }
        }
    }

    private func textField(_ row: ExifEditorModel.Row, verdict: ExifVerdict) -> some View {
        Group {
            if case .coordinate = row.field.input {
                CoordinateField(text: row.text, prompt: prompt(for: row), dimmed: row.isParked,
                                onChange: { model.type($0, in: row.id) },
                                onFocus: { model.touch(row.id) },
                                onPaste: { model.paste($0, into: row.id) })
            } else if ExifDatabase.offers(row.field.key) {
                SuggestingField(text: row.text, prompt: prompt(for: row), dimmed: row.isParked,
                                onChange: { model.type($0, in: row.id) },
                                onFocus: { model.touch(row.id) },
                                values: { model.suggestions(for: row.id) })
            } else {
                TextField("", text: Binding(get: { row.text },
                                            set: { model.type($0, in: row.id) }),
                          prompt: Text(prompt(for: row)))
                    .textFieldStyle(.plain)
            }
        }
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(row.isGrey ? Color.secondary.opacity(0.22)
                                 : Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(row.error != nil ? .red
                        : verdict == .fine || row.isParked ? Color.secondary.opacity(0.35)
                        : colour(of: verdict)))
            .foregroundStyle(row.isParked ? .secondary : .primary)
            // Not disabled while unticked: clicking back into it ticks it
            // again, and the editing carries on.
            .focused($focused, equals: row.id)
            .frame(maxWidth: .infinity)
    }

    private func prompt(for row: ExifEditorModel.Row) -> String {
        if model.isSuggesting, row.field.key.name == kCGImagePropertyTIFFImageDescription as String {
            return "Asking Apple Intelligence\u{2026}"
        }
        if case .coordinate = row.field.input, row.current != .different {
            return "Not set \u{2014} e.g. \(model.coordinateFormat.example)"
        }
        return row.placeholder
    }

    private func helperSymbol(_ input: ExifInput) -> String {
        switch input {
        case .dateTime, .date: "calendar"
        case .time:            "clock"
        case .offset:          "globe"
        default:               "list.bullet"
        }
    }

    /// A date picker can only show a date: a value from a file that is not
    /// one is shown as text.
    private func helperFits(_ row: ExifEditorModel.Row) -> Bool {
        guard let format = dateFormat(row.field.input) else { return true }
        return row.isEmpty || ExifFields.exifDate(row.text, format: format) != nil
    }

    private func dateFormat(_ input: ExifInput) -> String? {
        switch input {
        case .dateTime: ExifFields.dateTimeFormat
        case .date:     ExifFields.dateFormat
        case .time:     ExifFields.timeFormat
        default:        nil
        }
    }

    private static let utc = TimeZone(secondsFromGMT: 0)!

    @ViewBuilder
    private func helper(_ row: ExifEditorModel.Row) -> some View {
        switch row.field.input {
        case .dateTime, .date, .time:
            dateHelper(row)
        case .choice(let choices):
            Menu {
                ForEach(choices, id: \.self) { choice in
                    Button("\(choice.label) (\(choice.value))") {
                        model.choose(choice.value, in: row.id)
                    }
                }
                Divider()
                Button("Type a Value\u{2026}") { model.setTyping(true, in: row.id) }
            } label: {
                Text(choiceLabel(row, choices))
            }
            .fixedSize()
        case .offset:
            zoneMenu(row)
        default:
            EmptyView()
        }
    }

    private func choiceLabel(_ row: ExifEditorModel.Row, _ choices: [ExifChoice]) -> String {
        if row.isEmpty { return row.placeholder }
        let value = row.text.trimmingCharacters(in: .whitespaces)
        if let choice = choices.first(where: { $0.value == value }) {
            return "\(choice.label) (\(choice.value))"
        }
        return value
    }

    @ViewBuilder
    private func dateHelper(_ row: ExifEditorModel.Row) -> some View {
        let format = dateFormat(row.field.input)!
        if row.isEmpty {
            HStack(spacing: 6) {
                Text(row.placeholder)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(row.isGrey ? Color.secondary.opacity(0.22) : .clear))
                Button("Set") {
                    // The wall clock here, for a photo's own dates; GPS
                    // dates and times are UTC.
                    let zone = row.field.input == .dateTime ? TimeZone.current : Self.utc
                    model.choose(ExifFields.exifText(Date(), format: format, in: zone),
                                 in: row.id)
                }
                .controlSize(.small)
            }
        } else {
            HStack(spacing: 6) {
                ExifDatePicker(text: row.text, parts: parts(row.field.input),
                               dimmed: row.isParked,
                               onChange: { model.choose($0, in: row.id) },
                               onFocus: { model.touch(row.id) })
                .fixedSize()
                if row.field.input != .time { calendar(row, format: format) }
            }
        }
    }

    /// The month on a calendar, for picking a day by looking: the time of
    /// day, if the field has one, is left as it was.
    private func calendar(_ row: ExifEditorModel.Row, format: String) -> some View {
        Button {
            calendarFor = row.id
            model.touch(row.id)
        } label: {
            Image(systemName: "calendar")
        }
        .buttonStyle(.borderless)
        .help("Pick the day on a calendar")
        .popover(isPresented: Binding(get: { calendarFor == row.id },
                                      set: { if !$0 { calendarFor = nil } }),
                 arrowEdge: .bottom) {
            DatePicker("", selection: Binding(
                get: {
                    ExifFields.exifDate(String(row.text.prefix(10)),
                                        format: ExifFields.dateFormat) ?? Date()
                },
                set: { day in
                    let date = ExifFields.exifText(day, format: ExifFields.dateFormat)
                    model.choose(date + row.text.dropFirst(10), in: row.id)
                }), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                // The digits are the wall clock's, not a moment: read and
                // written in UTC so that none of them moves.
                .environment(\.timeZone, Self.utc)
                .environment(\.calendar, Self.gregorian)
                .padding(10)
        }
    }

    private static let gregorian: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }()

    private func parts(_ input: ExifInput) -> ExifDatePicker.Parts {
        switch input {
        case .date: .date
        case .time: .time
        default:    .dateTime
        }
    }

    private func zoneMenu(_ row: ExifEditorModel.Row) -> some View {
        // Offsets on the date beside it, worked out once for the menu:
        // close enough for a label, and Save works each image's out exactly.
        let moment = model.referenceDate(for: row)
            .flatMap { ExifFields.exifDate($0, format: ExifFields.dateTimeFormat) } ?? Date()
        func offset(_ id: String) -> String {
            TimeZone(identifier: id).map {
                ExifFields.offsetText(seconds: $0.secondsFromGMT(for: moment))
            } ?? ""
        }
        return Menu {
            Button("UTC (+00:00)") { model.chooseZone("UTC", in: row.id) }
            ForEach(ExifFields.zonesByRegion, id: \.region) { region in
                Menu(region.region) {
                    ForEach(region.zones, id: \.id) { zone in
                        Button("\(zone.city) (\(offset(zone.id)))") {
                            model.chooseZone(zone.id, in: row.id)
                        }
                    }
                }
            }
            Divider()
            Button("Type an Offset\u{2026}") { model.setTyping(true, in: row.id) }
        } label: {
            if let zone = row.zone {
                Text("\(zone.replacingOccurrences(of: "_", with: " ")) (\(row.text))")
            } else {
                Text(row.isEmpty ? row.placeholder : row.text)
            }
        }
        .fixedSize()
        .help(row.zone == nil ? "Pick the time zone the photos were taken in"
              : "Written as each image\u{2019}s own offset on its own date, summer time "
                + "included")
    }

    private func shown(_ current: ExifEditorModel.Current) -> String {
        switch current {
        case .same(let text): text
        case .different:      "Different in each file"
        case .unshowable:     "(not text)"
        case .unset:          ""
        }
    }

    // MARK: - Save and Cancel

    private var footer: some View {
        HStack(alignment: .top, spacing: 10) {
            Menu("Add Field") {
                ForEach(model.addable) { field in
                    Button("\(field.label) \u{2014} \(field.key.group.title)") { model.add(field) }
                }
            }
            .fixedSize()
            .disabled(model.addable.isEmpty || model.isLoading)
            .help("Show a field none of the \(isVideo ? "videos" : "images") has yet")

            // The fields through the clipboard, as JSON: to keep what was
            // typed when it cannot be saved here, or to give one file's
            // values to another.
            Button {
                model.copyJSON()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(model.isLoading)
            .help("Copy the fields as JSON")
            Button {
                if let text = NSPasteboard.general.string(forType: .string) {
                    model.pasteJSON(text)
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .disabled(model.isLoading)
            .help("Paste fields from JSON on the clipboard \u{2014} as Copy writes them")

            VStack(alignment: .leading, spacing: 2) {
                if let notice = model.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.problems, id: \.self) { problem in
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.isSaving { ProgressView().controlSize(.small) }
            // Not on Escape: an editor full of typing is not to be lost to
            // one key. It closes as other windows do, with ⌘W or its button.
            Button("Cancel") { dismiss() }
            // ⌘S, not Return: Return in a field saved half-finished typing.
            Button("Save") {
                Task { if await model.save() { dismiss() } }
            }
            .keyboardShortcut("s")
            .disabled(!model.hasChanges || model.isSaving || model.readable.isEmpty)
        }
    }
}
