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
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "textformat.size") }
            GitSettingsView()
                .tabItem { Label("Version Tracking",
                                 systemImage: "point.3.filled.connected.trianglepath.dotted") }
            SoundSettingsView()
                .tabItem { Label("Sounds", systemImage: "speaker.wave.2") }
        }
        .frame(width: 500, height: 470)
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
                .foregroundStyle(.secondary)

            Toggle("List folders before files", isOn: $store.configuration.foldersFirst)
                .toggleStyle(.checkbox)
            Text("Off, everything is in one sequence in whatever order the column "
                 + "header says \u{2014} which is what you want when sorting by size or "
                 + "date. \u{201C}..\u{201D} stays on top either way.")
                .font(.caption)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Show version tracking (Git)", isOn: $store.configuration.gitEnabled)
                .toggleStyle(.checkbox)

            Text("Diptych uses the \u{201C}git\u{201D} program already on your Mac. "
                 + "It does not include one.")
                .font(.subheadline).foregroundStyle(.secondary)

            found

            warning

            HStack {
                Text("Use a different program\u{2026}")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Choose\u{2026}") { choose() }
                if !store.configuration.gitPath.isEmpty {
                    Button("Use the one found automatically") {
                        store.configuration.gitPath = ""
                        git.locate()
                    }
                }
                Spacer()
            }

            Text("The program must be named \u{201C}git\u{201D}. That stops you picking "
                 + "the wrong file by accident. It is not a security check \u{2014} a "
                 + "harmful program can be named \u{201C}git\u{201D} too.")
                .font(.caption).foregroundStyle(.secondary)

            Spacer()

            HStack {
                Button(copied ? "Copied" : "Copy Details") { copyDetails() }
                    .help("Everything about this setup in one paste, to send to whoever "
                          + "set up your repository")
                Spacer()
            }
        }
        .padding(20)
        .onAppear { if git.tool == nil { git.locate() } }
        .onChange(of: store.configuration.gitEnabled) { _, on in if on { git.locate() } }
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
            Text("Git is normally installed by developers. If you need it, ask whoever set "
                 + "up your repository.")
                .font(.caption).foregroundStyle(.secondary)
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
                    Text("It confirms the file is named \u{201C}git\u{201D} and that it "
                         + "answers the way Git does, but a harmful program could do both "
                         + "of those things.\n\nWhatever this program is, it will be able "
                         + "to read, change and delete files in your folders, and send them "
                         + "over the internet \u{2014} because that is what Git itself does."
                         + "\n\nOnly switch this on if you know where this program came "
                         + "from. If you did not install it yourself, ask whoever set up "
                         + "your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
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
        git.locate()
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
