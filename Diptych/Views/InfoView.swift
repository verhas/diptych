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
            }
            .padding(14)

            Divider()
            statusBar
        }
        .frame(minWidth: 520, minHeight: 460)
        .navigationTitle(model.name)
        .onAppear(perform: seedDrafts)
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
                                Text("\(attribute.data.count) bytes")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Remove") { model.removeAttribute(named: attribute.name) }
                            }
                            if attribute.text != nil {
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
