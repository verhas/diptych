import SwiftUI

/// The Info window: everything about one file, editable.
struct InfoView: View {

    @State private var model: FileInfoModel
    /// Working copies of the text-valued extended attributes, so typing does
    /// not write to disk on every keystroke.
    @State private var attributeDrafts: [String: String] = [:]
    /// Filters the symbol picker. View state: it is not part of the file.
    @State private var symbolQuery = ""

    init(url: URL) {
        _model = State(initialValue: FileInfoModel(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                general.tabItem { Label("General", systemImage: "doc") }
                ownership.tabItem { Label("Ownership", systemImage: "person.crop.circle") }
                tags.tabItem { Label("Tags", systemImage: "tag") }
                attributes.tabItem { Label("Attributes", systemImage: "list.bullet.rectangle") }
                access.tabItem { Label("Access", systemImage: "lock.shield") }
                details.tabItem { Label("Details", systemImage: "text.magnifyingglass") }
                openBy.tabItem { Label("Open By", systemImage: "bolt.horizontal.circle") }
            }
            .padding(14)

            Divider()
            statusBar
        }
        // Wide enough for seven tabs in the bar. One too many for the width
        // and macOS folds the *whole* bar into a "more toolbar items" pop-up
        // where no tab can be chosen at all -- which is what 620 did to six
        // tabs, and what happened to Settings when it gained one. Measured
        // through accessibility rather than guessed at.
        .frame(minWidth: 880, minHeight: 460)
        .navigationTitle(model.name)
        .onAppear(perform: seedDrafts)
        .background(WindowAccessor { window in if let window { AppWindows.shared.register(window) } })
    }

    private var statusBar: some View {
        HStack {
            if let status = model.status {
                Image(systemName: model.statusIsError
                      ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(model.statusIsError ? .orange : .green)
                Text(status).lineLimit(2)
            }
            Spacer()
            Text(model.url.deletingLastPathComponent().path)
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - General

    /// Plain stacks rather than Form. A grouped Form on macOS puts controls
    /// inside rows whose hit testing is unreliable for buttons sitting next to
    /// text fields, which left Remove and Add doing nothing.
    private func panel<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        } label: {
            Text(title).font(.headline)
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 90, alignment: .trailing).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
            Spacer()
        }
    }

    private var general: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                panel("File") {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Location").frame(width: 90, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        Text(model.location)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.head)
                        Spacer()
                    }
                    HStack {
                        Text("Name").frame(width: 90, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        TextField("Name", text: $model.name)
                            .onSubmit { model.applyRename() }
                        Button("Rename") { model.applyRename() }
                    }
                    field("Kind", model.kind.isEmpty ? "--" : model.kind)
                    field("Size", model.sizeText)
                }

                if model.isSymlink { linkPanel }

                panel("Dates") {
                    DatePicker("Created", selection: $model.created)
                    DatePicker("Modified", selection: $model.modified)
                    // Neither of these is settable: "added" belongs to the
                    // folder's index, "accessed" to the kernel.
                    field("Added", model.added.map(Self.format) ?? "--")
                    field("Accessed", model.accessed.map(Self.format) ?? "--")
                    Button("Apply Dates") { model.applyDates() }
                }
            }
            .padding(4)
        }
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Ownership

    private var ownership: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                panel("Owner and group") {
                Picker("Owner", selection: $model.owner) {
                    ForEach(AccountLookup.users(), id: \.self) { Text($0).tag($0) }
                }
                Picker("Group", selection: $model.group) {
                    Section("Yours") {
                        ForEach(AccountLookup.ownGroups(), id: \.self) { Text($0).tag($0) }
                    }
                    Section("All") {
                        let own = Set(AccountLookup.ownGroups())
                        ForEach(AccountLookup.groups().filter { !own.contains($0) }, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                }
                    Button("Apply Owner and Group") { model.applyOwnership() }
                    Text("Giving a file to another user needs an administrator "
                         + "password; macOS will ask.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                panel("Permissions (\(model.modeText))") {
                    if model.isSymlink {
                        Text("This is a symbolic link: these are the linked "
                             + "item\u{2019}s permissions, and changing them changes it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    permissionRow("User", read: S_IRUSR, write: S_IWUSR, execute: S_IXUSR)
                    permissionRow("Group", read: S_IRGRP, write: S_IWGRP, execute: S_IXGRP)
                    permissionRow("Others", read: S_IROTH, write: S_IWOTH, execute: S_IXOTH)

                    if model.isDirectory {
                        Text("For a folder, Read lists the names inside it and "
                             + "Search allows reaching what is in it. Read without "
                             + "Search lists names you cannot then open.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    LabeledContent("Special") {
                        HStack(spacing: 14) {
                            bitToggle("setuid", S_ISUID)
                                .help("Run as the file\u{2019}s owner rather than as whoever "
                                      + "started it. This is how /usr/bin/sudo becomes root.")
                            bitToggle("setgid", S_ISGID)
                                .help(model.isDirectory
                                      ? "New items in this folder inherit its group."
                                      : "Run as the file\u{2019}s group.")
                            bitToggle("sticky", S_ISVTX)
                                .help("In a folder, only an item\u{2019}s owner may delete it "
                                      + "\u{2014} what makes /tmp safe to share.")
                        }
                    }
                    Text("These three share the execute column: they show as "
                         + "s, s and t in place of x.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(4)
        }
    }

    private func permissionRow(_ title: String,
                               read: mode_t, write: mode_t, execute: mode_t) -> some View {
        LabeledContent(title) {
            HStack(spacing: 14) {
                bitToggle("Read", read)
                bitToggle("Write", write)
                // For a directory it is Read that lists names; execute permits
                // traversal. Labelling this one "List" invited exactly the
                // wrong change.
                bitToggle(model.isDirectory ? "Search" : "Execute", execute)
            }
        }
    }

    private func bitToggle(_ title: String, _ bit: mode_t) -> some View {
        Toggle(title, isOn: Binding(get: { model.isSet(bit) },
                                    set: { _ in model.toggle(bit) }))
    }

    /// Folders only, and deliberately inside the Tags tab: the colour of a
    /// tinted folder *is* the tag, so the two controls belong side by side.
    private var folderIcon: some View {
        panel("Folder icon") {
            Text("macOS tints a folder with its tag colour only when the folder "
                 + "is marked as having a custom icon. Pick a symbol to draw on top of it.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Tint this folder with its tag colour",
                   isOn: Binding(get: { model.folderIsCustomised },
                                 set: { model.applyFolderIcon(customised: $0,
                                                              symbol: model.folderSymbol) }))

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search symbols", text: $symbolQuery)
                    .textFieldStyle(.plain)
                if !model.folderSymbol.isEmpty {
                    Button("No symbol") {
                        model.applyFolderIcon(customised: true, symbol: "")
                    }
                }
            }

            let matches = SymbolCatalog.matches(symbolQuery)
            if matches.isEmpty {
                Text("No symbol of that name.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 4)], spacing: 4) {
                    ForEach(matches, id: \.self) { symbol in
                        Button {
                            model.applyFolderIcon(customised: true, symbol: symbol)
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 15))
                                .frame(width: 30, height: 28)
                                .background {
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(model.folderSymbol == symbol
                                              ? Color.accentColor.opacity(0.30)
                                              : Color.secondary.opacity(0.10))
                                }
                        }
                        .buttonStyle(.plain)
                        .help(symbol)
                    }
                }
                .padding(2)
            }
            .frame(height: 132)
            .disabled(!model.folderIsCustomised)
            .opacity(model.folderIsCustomised ? 1 : 0.4)

            Text(model.folderSymbol.isEmpty
                 ? "No symbol -- the folder is tinted only."
                 : "Symbol: \(model.folderSymbol)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Symbolic links only. The target is text, and editing it is the only way
    /// to repoint a link short of deleting and recreating it by hand.
    private var linkPanel: some View {
        panel("Symbolic link") {
            Text("Where the link points. A relative target is kept relative -- "
                 + "rewriting it as an absolute path would change what the link means "
                 + "if the folder moves.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(alignment: .top) {
                Text("Target").frame(width: 90, alignment: .trailing)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    TextEditor(text: $model.linkTarget)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 46)
                        .border(.quaternary)
                    // Follows the text as it is typed, not the link on disk.
                    let note = model.linkTargetNote
                    HStack(spacing: 6) {
                        Image(systemName: note.ok
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(note.ok ? .green : .orange)
                        // A broken link is legal and sometimes deliberate, so
                        // this reports rather than refuses.
                        Text(note.text)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Revert") { model.revertLinkTarget() }
                    .disabled(!model.linkTargetHasChanges)
                Button("Apply Target") { model.applyLinkTarget() }
                    .disabled(!model.linkTargetHasChanges)
            }
        }
    }

    // MARK: - Tags

    private var tags: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                panel("Colours") {
                    Text("Click a colour to add or remove that tag.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        ForEach(FinderTag.coloured, id: \.self) { tag in
                            Button {
                                model.toggleTag(tag)
                            } label: {
                                Circle()
                                    .fill(Self.colour(of: tag))
                                    .frame(width: 22, height: 22)
                                    .overlay {
                                        if model.tags.contains(tag) {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .overlay { Circle().strokeBorder(.secondary.opacity(0.35)) }
                            }
                            .buttonStyle(.plain)
                            .help(tag)
                        }
                    }
                }

                panel("Tags on this file") {
                    if model.tags.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(model.tags, id: \.self) { tag in
                        HStack {
                            Circle().fill(Self.colour(of: tag))
                                .frame(width: 10, height: 10)
                                .overlay { Circle().strokeBorder(.secondary.opacity(0.3)) }
                            Text(tag)
                            Spacer()
                            Button("Remove") { model.toggleTag(tag) }
                        }
                    }
                }

                if model.isDirectory { folderIcon }

                panel("Add a tag of your own") {
                    Text("Type a name and press Return, or click Add. "
                         + "Tags named after the seven colours get that colour.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("Tag name", text: $model.newTag)
                            .onSubmit { model.addTag() }
                        Button("Add") { model.addTag() }
                            .disabled(model.newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .padding(4)
        }
    }

    private static func colour(of tag: String) -> Color {
        switch tag {
        case "Red":    .red
        case "Orange": .orange
        case "Yellow": .yellow
        case "Green":  .green
        case "Blue":   .blue
        case "Purple": .purple
        case "Gray":   .gray
        default:       .clear
        }
    }

    // MARK: - Extended attributes

    private var attributes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                panel("Extended attributes") {
                    if model.attributes.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(model.attributes) { attribute in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(attribute.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .textSelection(.enabled)
                                Spacer()
                                Text(attribute.isReadable
                                     ? "\(attribute.data?.count ?? 0) bytes"
                                     : "protected")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Remove") { model.removeAttribute(named: attribute.name) }
                                    // Removing it would fail for the same
                                    // reason reading it does.
                                    .disabled(!attribute.isReadable)
                            }
                            if !attribute.isReadable {
                                // Listed rather than hidden. The file has this
                                // attribute; what is in it is simply not ours
                                // to see, and an inspector that quietly left it
                                // out would be disagreeing with the file.
                                Text("macOS keeps this one to itself \u{2014} it can be listed "
                                     + "but not read, by anybody, including an administrator. "
                                     + "Left by a program that was granted access to this file.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if attribute.text != nil {
                                HStack {
                                    TextField("Value", text: draft(for: attribute))
                                        .font(.system(size: 11, design: .monospaced))
                                    Button("Save") {
                                        model.saveAttribute(named: attribute.name,
                                                            text: attributeDrafts[attribute.name] ?? "")
                                    }
                                }
                            } else {
                                // Binary values -- a plist, a bookmark. Editing
                                // them as text would corrupt them.
                                Text(attribute.hexPreview)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Divider()
                        }
                    }
                }

                panel("Add an attribute") {
                    TextField("Name, e.g. com.example.note", text: $model.newAttributeName)
                    TextField("Value", text: $model.newAttributeValue)
                    Button("Add Attribute") { model.addAttribute() }
                        .disabled(model.newAttributeName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(4)
        }
        .onChange(of: model.attributes) { _, _ in seedDrafts() }
    }

    private func draft(for attribute: ExtendedAttributes.Attribute) -> Binding<String> {
        Binding(get: { attributeDrafts[attribute.name] ?? attribute.text ?? "" },
                set: { attributeDrafts[attribute.name] = $0 })
    }

    private func seedDrafts() {
        for attribute in model.attributes where attribute.text != nil {
            attributeDrafts[attribute.name] = attribute.text
        }
    }

    // MARK: - Details

    /// What is written inside the file about itself. Read-only: every one of
    /// these formats keeps its metadata in the file, so writing a field means
    /// rewriting the file.
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("What this file says about itself").font(.headline)
                Spacer()
                if model.isReadingDetails { ProgressView().controlSize(.small) }
            }

            if let report = model.details {
                if let nothing = report.nothing {
                    Text(nothing)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !report.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(report.sections) { section in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(section.title).font(.subheadline).bold()
                                    ForEach(section.rows) { row in
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text(row.name)
                                                .frame(width: 210, alignment: .trailing)
                                                .foregroundStyle(.secondary)
                                            Text(row.value)
                                                .fixedSize(horizontal: false, vertical: true)
                                            Spacer(minLength: 0)
                                        }
                                        .font(.system(size: 11))
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                }
            } else if !model.isReadingDetails {
                Text("Nothing has been read yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            Text("Read only. These attributes live inside the file, so changing one means "
                 + "rewriting the file \u{2014} re-encoding a picture, or unzipping and "
                 + "rezipping a document \u{2014} which Diptych will not do behind a field.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.readDetails() }
    }

    // MARK: - Open by

    /// What has this file open, or this folder as its current one.
    ///
    /// A snapshot with the time on it, not a live list: a program can open or
    /// close a file between two blinks, so a list that looked live would be
    /// making a promise it cannot keep.
    private var openBy: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.isDirectory ? "Programs using this folder"
                                       : "Programs with this file open")
                    .font(.headline)
                Spacer()
                if model.isLookingForOpenBy { ProgressView().controlSize(.small) }
                Button("Look Again") { model.lookForOpenBy() }
                    .disabled(model.isLookingForOpenBy)
            }

            if let report = model.openBy {
                if let failure = report.failure {
                    Label(failure, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                } else if report.isEmpty {
                    Text(model.isDirectory
                         ? "No program of yours has this folder, or anything in it, open."
                         : "No program of yours has this file open.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !report.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(report.holders) { holder in
                                holderRow(holder)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                }

                Spacer(minLength: 0)
                Text(summary(of: report))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if !model.isLookingForOpenBy {
                Text("Nothing has been looked at yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Asked when the tab is first shown, not when the window opens: this
        // walks every process on the Mac, and most visits to this window are
        // not about that.
        .onAppear { if model.openBy == nil { model.lookForOpenBy() } }
    }

    private func holderRow(_ holder: OpenFiles.Holder) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: holder.isWriting ? "pencil.circle" : "eye.circle")
                .foregroundStyle(holder.isWriting ? Color.orange : .secondary)
                .help(holder.isWriting ? "Has it open for writing" : "Has it open for reading")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(holder.program).font(.system(size: 12, weight: .medium))
                    Text("\u{2014} \(holder.kind.describes)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // Which file, when this is something inside the folder asked
                // about; otherwise where the program itself came from.
                Text(holder.path.map { "process \(holder.pid) \u{2022} "
                                       + PromptBuilder.abbreviate($0) }
                     ?? "process \(holder.pid)\(holder.executable.isEmpty ? "" : " \u{2022} ")"
                        + PromptBuilder.abbreviate(holder.executable))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .textSelection(.enabled)
    }

    /// The three numbers that keep the answer honest, and the two things it
    /// does not mean.
    private func summary(of report: OpenFiles.Report) -> String {
        let when = report.at.formatted(date: .omitted, time: .standard)
        var lines = ["As of \(when). \(report.looked) of \(report.processes) programs could be "
                     + "looked inside."]
        if report.refused > 0 {
            lines.append("\(report.refused) belong to other users, and macOS does not let "
                         + "Diptych see what they have open \u{2014} so this is what your own "
                         + "programs are doing, not everything on this Mac.")
        }
        if report.incomplete {
            lines.append("The search was stopped before it had been through every program.")
        }
        if report.truncated {
            lines.append("Only the first \(OpenFiles.mostHolders) are listed.")
        }
        lines.append("Having a file open is not the same as locking it: most programs that "
                     + "hold one open are only reading it.")
        return lines.joined(separator: " ")
    }

    // MARK: - Access control

    private var access: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Access control list")
                .font(.headline)
            Text("The same text `ls -le` shows. Leave it empty to remove the list entirely.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $model.aclText)
                .font(.system(size: 11, design: .monospaced))
                .border(.separator)

            HStack {
                Text(model.aclOnDisk.isEmpty ? "This file has no access control list."
                                             : "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Revert") { model.revertACL() }
                    .disabled(!model.aclHasChanges)
                Button("Apply") { model.applyACL() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.aclHasChanges)
            }
        }
    }
}
