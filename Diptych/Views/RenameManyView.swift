import SwiftUI
import AppKit

/// Renaming a folder's worth of files with one regular expression, in a window
/// of its own -- like Text Edit and Bin Edit.
///
/// The list is the point: every file is shown with the name it would get,
/// before anything happens. Files that do not match are dimmed, exactly as the
/// pane filter dims them, and can be hidden instead.
struct RenameManyView: View {

    let folder: URL

    @State private var model: RenameManyModel

    init(folder: URL) {
        self.folder = folder
        _model = State(initialValue: RenameManyModel(folder: folder))
    }

    var body: some View {
        VStack(spacing: 0) {
            top
            Divider()
            list
            Divider()
            bottom
        }
        .navigationTitle("Rename Many \u{2014} \(NamingTemplate.tilde(model.folder.path))")
        .onAppear { model.load() }
    }

    // MARK: - Above the list

    private var top: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                    .help("The folder above")
                    .disabled(!model.canGoUp)
                Text(NamingTemplate.tilde(model.folder.path))
                    .lineLimit(1).truncationMode(.head)
                    .textSelection(.enabled)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Search")
                    TextField("regular expression, matching the whole name",
                              text: $model.search)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        // Red as the pane filter goes red, for the same reason.
                        .foregroundStyle(model.searchIsValid ? Color.primary : Color.red)
                }
                GridRow {
                    Text("Replace")
                    TextField("the new name, with $1 for the first group",
                              text: $model.replacement)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }

            HStack(spacing: 12) {
                Toggle("Hide the files that do not match", isOn: $model.hidesOthers)
                    .toggleStyle(.checkbox)
                Spacer()
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(model.searchIsValid ? .secondary : Color.red)
            }
        }
        .padding(12)
    }

    private var summary: String {
        guard model.hasSearch else { return "Every file is listed." }
        guard model.searchIsValid else { return "That is not a regular expression yet." }
        let matched = model.matching.count
        if model.replacement.isEmpty {
            return "\(matched) matched. Type a replacement to see the new names."
        }
        return "\(matched) matched, \(model.plan.renames) would be renamed."
    }

    // MARK: - The list

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.listed) { entry in
                    row(entry)
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ entry: RenameManyModel.Entry) -> some View {
        let matches = model.matches(entry)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
            Text(entry.name)
                .lineLimit(1).truncationMode(.middle)
            if let new = model.newNames[entry.name] {
                Text("\u{2192}").foregroundStyle(.secondary)
                Text(new)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        // Dimmed, not hidden, unless asked -- the same as the pane filter.
        .opacity(matches ? 1 : 0.35)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard entry.isDirectory else { return }
            model.navigate(to: model.folder.appendingPathComponent(entry.name))
        }
        .help(entry.isDirectory ? "Double-click to go into this folder" : "")
    }

    // MARK: - Below the list

    private var bottom: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.plan.problems.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.plan.problems.enumerated()), id: \.offset) { _, problem in
                        Label(problem, systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let outcome = model.outcome {
                Text(outcome)
                    .font(.caption)
                    .foregroundStyle(model.wentWrong ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack {
                Text(model.plan.steps.contains { $0.isTemporary }
                     ? "Two files swap names, so one steps aside under a temporary name and "
                       + "comes back."
                     : "")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if model.isRenaming { ProgressView().controlSize(.small) }
                Button(model.plan.renames > 1 ? "Rename \(model.plan.renames) Items"
                                              : "Rename") {
                    Task { await model.rename() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canRename)
            }
        }
        .padding(12)
    }
}
