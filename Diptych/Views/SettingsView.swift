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
