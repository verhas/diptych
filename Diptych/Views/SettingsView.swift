import SwiftUI

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
