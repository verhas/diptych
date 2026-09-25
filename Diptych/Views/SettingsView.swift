import SwiftUI
import AppKit

/// The configuration window, opened with Settings... (Cmd-,) in the app menu.
///
/// A `Settings` scene rather than a window we manage ourselves: macOS then puts
/// the item in the right place, gives it the standard shortcut, and remembers
/// its position. Tabs are here from the start because columns is only the first
/// of several things worth configuring.
struct SettingsView: View {
    var body: some View {
        TabView {
            ColumnSettingsView()
                .tabItem { Label("Columns", systemImage: "tablecells") }
            ToolbarSettingsView()
                .tabItem { Label("Toolbar", systemImage: "slider.horizontal.3") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "textformat.size") }
            BehaviourSettingsView()
                .tabItem { Label("Behaviour", systemImage: "switch.2") }
            IntelligenceSettingsView()
                .tabItem { Label("Apple Intelligence", systemImage: "apple.intelligence") }
            GitSettingsView()
                .tabItem { Label("Version Tracking",
                                 systemImage: "point.3.filled.connected.trianglepath.dotted") }
            SoundSettingsView()
                .tabItem { Label("Sounds", systemImage: "speaker.wave.2") }
        }
        // Wide enough for every tab in the toolbar. One too many for the width
        // and macOS moves the last ones into a ">>" overflow menu -- where a
        // Settings tab cannot be chosen at all: the items show, greyed out.
        // Seven tabs need about 530 points.
        .frame(width: 600, height: 470)
    }
}

/// What the application does, as opposed to how it looks.
struct BehaviourSettingsView: View {

    @Bindable private var store = ConfigStore.shared

    var body: some View {
        // Scrolls, because this pane keeps gaining sections and the Settings
        // window cannot be resized: text that does not fit is otherwise simply
        // cut off, which has already happened once here.
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text("New from Clipboard").font(.headline)

            Text("Makes a file in the current folder out of whatever has been copied. "
                 + "Text becomes a text file. A picture becomes the format chosen here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                // Without this the caption is given one line in a window nobody
                // can resize, and the rest of the sentence is simply not there.
                .fixedSize(horizontal: false, vertical: true)

            Picker("Save a picture as", selection: $store.configuration.clipboardImageFormat) {
                ForEach(Configuration.ClipboardImageFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.radioGroup)

            Text("PDF keeps a drawing as a drawing when it was copied as one, instead of "
                 + "flattening it into dots. PNG is the safe choice for a screenshot; "
                 + "JPEG is smaller but blurs sharp edges and text.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Switched off, the command is not in any menu at all.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("Run the scripts in ~/.diptych/scripts",
                   isOn: $store.configuration.scriptsEnabled)
                .toggleStyle(.checkbox)
            Text("A script is a program. Whatever is in that folder can do anything you can "
                 + "do \u{2014} change your files, delete them, send them somewhere. Diptych "
                 + "asks before running each one for the first time, and again whenever one "
                 + "changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("It will not run a script that came from outside this Mac, that belongs to "
                 + "somebody else, that can be written to, or that anybody else can read. A "
                 + "file has to be made yours alone before Diptych will run it, so that "
                 + "putting one there is something you did on purpose \u{2014} and so that "
                 + "what is in it stays yours. Nothing lifts those rules, so a script is "
                 + "written under the same conditions it will be run under.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Developer mode \u{2014} for writing scripts, not running them",
                   isOn: $store.configuration.scriptsDeveloperMode)
                .toggleStyle(.checkbox)
                .disabled(!store.configuration.scriptsEnabled)
            Text("Adds a command to read the folder again without restarting, for when you "
                 + "have just changed a script. It does not relax any of the rules above.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("Ask before quitting", isOn: $store.configuration.confirmQuit)
                .toggleStyle(.checkbox)
            Text("Quit sits one key away from Close Window and Select All.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Comparing Folders").font(.headline)

            Toggle("Compare permissions",
                   isOn: $store.configuration.directoryDiffComparePermissions)
                .toggleStyle(.checkbox)
            Toggle("Compare extended attributes",
                   isOn: $store.configuration.directoryDiffCompareAttributes)
                .toggleStyle(.checkbox)
            Toggle("Compare access control lists",
                   isOn: $store.configuration.directoryDiffCompareACL)
                .toggleStyle(.checkbox)
            Text("Content is always compared and has no setting of its own. A Compare "
                 + "Folders window carries its own checkbox for all four, so a single "
                 + "comparison can leave any of them out without changing what the next "
                 + "one starts with.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Compare modification dates",
                   isOn: $store.configuration.directoryDiffCompareModificationDate)
                .toggleStyle(.checkbox)
            Toggle("Compare creation dates",
                   isOn: $store.configuration.directoryDiffCompareCreationDate)
                .toggleStyle(.checkbox)
            Toggle("Compare owner and group",
                   isOn: $store.configuration.directoryDiffCompareOwnership)
                .toggleStyle(.checkbox)
            Text("All three off by default: a fresh copy commonly gets a new creation date, "
                 + "sometimes a new modification date, and often belongs to whoever made the "
                 + "copy rather than whoever made the original -- none of which is usually "
                 + "what \u{201C}the same\u{201D} is meant to ask about. Access time is left out "
                 + "altogether, since comparing a file is itself a read that would change it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Recurse into hidden folders (starting with a dot, like .git)",
                   isOn: $store.configuration.directoryDiffRecurseHiddenDirectories)
                .toggleStyle(.checkbox)
            Text("Off by default: a folder like .git is usually noise in a comparison, not "
                 + "something to compare. It still appears in the list either way -- this "
                 + "only decides whether its contents are looked at too.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ColumnSettingsView: View {

    @Bindable private var store = ConfigStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Columns apply to both panes, in every directory.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            List {
                ForEach(store.configuration.columnOrder) { column in
                    row(for: column)
                }
                .onMove { source, destination in
                    store.move(from: source, to: destination)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(maxHeight: .infinity)

            HStack {
                Text("Drag a row to change the column order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Defaults") { store.resetToDefaults() }
            }
        }
        .padding(20)
    }

    private func row(for column: FileColumn) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { store.configuration.enabledColumns.contains(column) },
                set: { store.setEnabled(column, $0) }))
                .labelsHidden()
                // Name identifies the row; without it there is nothing to read.
                .disabled(!column.isRemovable)

            Text(column.title)

            if !column.isRemovable {
                Text("always shown, always first")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.quaternary)
        }
        .padding(.vertical, 2)
    }
}


/// The pane font.
///
/// Only the panes follow it. Settings, the sidebar and the dialogs keep their
/// own sizes -- what is being configured is the file listing, not the chrome
/// around it, and scaling the chrome would make the window worse rather than
/// bigger.
struct AppearanceSettingsView: View {

    @Bindable private var store = ConfigStore.shared

    private var size: Binding<Double> {
        Binding(get: { store.configuration.fontSize }, set: { PaneFont.set($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The font the file listings are drawn with. Row heights and icons "
                 + "follow the size.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            Toggle("List folders before files", isOn: $store.configuration.foldersFirst)
                .toggleStyle(.checkbox)
            Text("Off, everything is in one sequence in whatever order the column "
                 + "header says \u{2014} which is what you want when sorting by size or "
                 + "date. \u{201C}..\u{201D} stays on top either way.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Picker("Font", selection: $store.configuration.fontName) {
                    Text("System").tag("")
                    Divider()
                    ForEach(PaneFont.availableNames, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 320)
                Spacer()
            }

            HStack(spacing: 10) {
                Text("Size")
                Slider(value: size,
                       in: Configuration.fontSizes,
                       step: 1)
                    .frame(maxWidth: 240)
                Text("\(Int(store.configuration.fontSize)) pt")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .leading)
                Stepper("", value: size,
                        in: Configuration.fontSizes, step: 1)
                    .labelsHidden()
            }

            Text("Also \u{2318}+ and \u{2318}\u{2212} from anywhere, and \u{2318}0 to "
                 + "return to \(Int(Configuration.defaultFontSize)) pt.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            sample

            Spacer()
            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    store.configuration.fontName = ""
                    PaneFont.reset()
                }
            }
        }
        .padding(20)
    }

    /// Shown at the chosen size, because a number of points means nothing until
    /// you see a filename drawn in it.
    private var sample: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Preview").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: PaneFont.iconSize * 0.8))
                    .foregroundStyle(.tint)
                Text("quote\u{2019}apostrophe.txt").font(PaneFont.swiftUI)
                Spacer()
                Text("1.8 MB").font(PaneFont.swiftUI).foregroundStyle(.secondary)
                Text("rwxr-xr-x").font(PaneFont.monospacedSwiftUI).foregroundStyle(.secondary)
            }
            .frame(height: PaneFont.rowHeight)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
        }
    }
}

/// Which buttons the toolbar shows, in what order, and on which side.
///
/// The same shape as the Columns pane -- one draggable list with a checkbox per
/// row -- because it is the same kind of decision, and a second arrangement to
/// learn would be a worse answer than a familiar one.
struct ToolbarSettingsView: View {

    @Bindable private var store = ConfigStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Drag to change the order. A button appears in the group you choose, "
                 + "in the order it has here.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            List {
                ForEach(store.configuration.toolbarSlots) { slot in
                    row(slot)
                }
                .onMove { source, destination in
                    store.moveToolbar(from: source, to: destination)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(maxHeight: .infinity)

            Text("Send My Work, Get the Latest and Check for Changes appear only in a "
                 + "folder that is tracked, and only while version tracking is "
                 + "switched on.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    store.configuration.toolbar = Configuration.defaultToolbar
                }
            }
        }
        .padding(20)
    }

    private func row(_ slot: ToolbarSlot) -> some View {
        HStack {
            Toggle(isOn: Binding(get: { slot.isShown },
                                 set: { store.setToolbar(slot.button, shown: $0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(slot.button.title)
                    Text(slot.button.explanation)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            Spacer()

            Picker("", selection: Binding(get: { slot.side },
                                          set: { store.setToolbar(slot.button, side: $0) })) {
                ForEach(ToolbarSide.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            .disabled(!slot.isShown)
        }
    }
}

/// Version tracking, off by default.
///
/// The disclosure is the point of this pane. Diptych runs a program it did not
/// install and cannot vouch for, and the honest thing is to say which one, what
/// it claims to be, who signed it, and what it will be able to do -- rather than
/// implying that a check has taken place.
struct GitSettingsView: View {

    @Bindable private var store = ConfigStore.shared
    @Bindable private var git = GitService.shared
    @State private var copied = false
    @State private var warnAboutTheServer = false

    static let talksToTheServer =
        "Everything else Diptych does with version tracking happens on this Mac, "
        + "but a check has to ask the shared copy \u{2014} so it needs a working "
        + "connection, and on a slow one or a very large folder it can take a while. "
        + "Without this, use Check for Changes when you want to know."

    var body: some View {
        // Scrolls, and every explanation may grow downwards: the Settings window
        // cannot be resized, and this pane holds more words than fit. Without
        // both, the text was clipped at the right edge instead of wrapping --
        // as the Behaviour pane's was before it got the same treatment.
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Show version tracking (Git)", isOn: $store.configuration.gitEnabled)
                .toggleStyle(.checkbox)

            Text("Diptych uses the \u{201C}git\u{201D} program already on your Mac. "
                 + "It does not include one.")
                .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            found

            warning

            Divider()

            Toggle("When sending, also bring in what other people have sent",
                   isOn: $store.configuration.gitUpdateWhenSending)
                .toggleStyle(.checkbox)
                .disabled(!store.configuration.gitEnabled)

            Text("The shared copy refuses your work whenever it has moved on at all, "
                 + "even when nobody touched the files you are sending. With this on, "
                 + "Diptych catches up by itself and your work goes \u{2014} which also "
                 + "means newer versions of other files arrive. With it off, the send "
                 + "stops and offers to update instead of doing it for you.")
                .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("Check for changes automatically when a folder is first opened",
                   isOn: $store.configuration.gitCheckOnOpen)
                .toggleStyle(.checkbox)
                .disabled(!store.configuration.gitEnabled)

            Text("Once per folder each time Diptych starts, and only where the folder "
                 + "is tracked and you have changes in it. Files that someone else has "
                 + "changed as well turn red, with no interruption.")
                .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            Text(Self.talksToTheServer)
                .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Use a different program\u{2026}")
                    .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                Button("Choose\u{2026}") { choose() }
                if !store.configuration.gitPath.isEmpty {
                    Button("Use the one found automatically") {
                        store.configuration.gitPath = ""
                        Task { await git.locate() }
                    }
                }
                Spacer()
            }

            Text("The program must be named \u{201C}git\u{201D}. That stops you picking "
                 + "the wrong file by accident. It is not a security check \u{2014} a "
                 + "harmful program can be named \u{201C}git\u{201D} too.")
                .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Button(copied ? "Copied" : "Copy Details") { copyDetails() }
                    .help("Everything about this setup in one paste, to send to whoever "
                          + "set up your repository")
                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await git.locateIfNeeded() }
        // Both directions: switching it off has to take the colours away, not
        // merely stop refreshing them.
        .onChange(of: store.configuration.gitEnabled) { _, _ in
            Task { await git.locate() }
        }
        // Said once, in front of the user, at the moment they switch it on.
        // Caption text beside a checkbox is read by nobody, and this is the
        // one setting that changes what Diptych does over the network.
        .onChange(of: store.configuration.gitCheckOnOpen) { _, on in
            if on { warnAboutTheServer = true }
        }
        .alert("This checks with the server", isPresented: $warnAboutTheServer) {
            Button("OK") { }
        } message: {
            Text(Self.talksToTheServer)
        }
    }

    @ViewBuilder
    private var found: some View {
        if let tool = git.tool {
            VStack(alignment: .leading, spacing: 3) {
                row("Found", tool.url.path)
                row("Reports itself as", tool.version)
                row("Digital signature", tool.signature)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        } else {
            Text(git.toolError
                 ?? "No Git program was found on this Mac, so version tracking stays off.")
                .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            Text("Git is normally installed by developers. If you need it, ask whoever set "
                 + "up your repository.")
                .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Names the consequence rather than saying "untrusted", which means
    /// nothing to someone who does not already know what to be afraid of.
    @ViewBuilder
    private var warning: some View {
        if git.tool != nil {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Diptych cannot check that this really is Git.")
                        .font(.subheadline).bold()
                            .fixedSize(horizontal: false, vertical: true)
                    Text("It confirms the file is named \u{201C}git\u{201D} and that it "
                         + "answers the way Git does, but a harmful program could do both "
                         + "of those things.\n\nWhatever this program is, it will be able "
                         + "to read, change and delete files in your folders, and send them "
                         + "over the internet \u{2014} because that is what Git itself does."
                         + "\n\nOnly switch this on if you know where this program came "
                         + "from. If you did not install it yourself, ask whoever set up "
                         + "your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 130, alignment: .trailing).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            Spacer()
        }
        .font(.system(size: 11))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/usr/bin")
        panel.message = "Choose the git program to use."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard url.lastPathComponent == "git" else {
            let alert = NSAlert()
            alert.messageText = "That file is not named \u{201C}git\u{201D}."
            alert.informativeText = "Diptych only accepts a program with that name. It stops "
                                  + "you picking the wrong file by accident."
            alert.runModal()
            return
        }
        store.configuration.gitPath = url.path
        Task { await git.locate() }
    }

    private func copyDetails() {
        Task {
            let text = await git.diagnostics(for: FileManager.default.homeDirectoryForCurrentUser)
            Clipboard.copyText(text)
            copied = true
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

struct SoundSettingsView: View {

    @Bindable private var store = ConfigStore.shared
    private let names = Sounds.available()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Play sounds", isOn: $store.configuration.soundsEnabled)
                .toggleStyle(.checkbox)

            Text("Played when an operation finishes. Choose \u{201C}None\u{201D} to silence "
                 + "one of them.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            Group {
                picker("Copy", \Configuration.copySound)
                picker("Move", \Configuration.moveSound)
                picker("Move to Trash", \Configuration.trashSound)
            }
            .disabled(!store.configuration.soundsEnabled)

            Spacer()
            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    store.configuration.copySound = "Pop"
                    store.configuration.moveSound = "Tink"
                    store.configuration.trashSound = "Glass"
                }
            }
        }
        .padding(20)
    }

    private func picker(_ title: String,
                        _ keyPath: WritableKeyPath<Configuration, String>) -> some View {
        let binding = Binding(
            get: { store.configuration[keyPath: keyPath] },
            set: { newValue in
                store.configuration[keyPath: keyPath] = newValue
                // Play it as it is chosen, so picking one does not mean
                // triggering a file operation to hear it.
                Sounds.play(newValue)
            })

        return HStack {
            Picker(title, selection: binding) {
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            .frame(maxWidth: 320)

            Button {
                Sounds.play(store.configuration[keyPath: keyPath])
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .help("Play")
        }
    }
}
