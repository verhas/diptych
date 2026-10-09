import SwiftUI
import AppKit

/// Renaming a folder's worth of files with one regular expression, in a window
/// of its own -- like Text Edit and Bin Edit.
///
/// The list is the point: every file is shown with the name it would get,
/// before anything happens. Files that do not match are dimmed, exactly as the
/// pane filter dims them, and can be hidden instead.
struct RenameManyView: View {

    let request: RenameManyRequest

    @State private var model: RenameManyModel

    init(request: RenameManyRequest) {
        self.request = request
        _model = State(initialValue: RenameManyModel(request))
    }

    private var title: String {
        "Rename Many \u{2014} \(NamingTemplate.tilde(model.folder.path))"
            + (model.isFlat ? " (flat view)" : "")
    }

    var body: some View {
        VStack(spacing: 0) {
            top
            Divider()
            list
            Divider()
            bottom
        }
        .navigationTitle(title)
        .onAppear { model.load() }
        .background(WindowAccessor { window in
            if let window {
                AppWindows.shared.register(window)
                WindowSubjects.shared.register(window, kind: "renameMany",
                                               description: request.folder.path)
            }
        })
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
                if let expression = model.flatExpression {
                    // The rows as the pane lists them -- stale or not -- not
                    // what the expression would find now.
                    Text(expression.isEmpty ? "flat view, everything"
                                            : "flat view: \(expression)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .help("The flat view's rows, as the pane lists them")
                }
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
                Toggle("Selection only", isOn: $model.selectionOnly)
                    .toggleStyle(.checkbox)
                    .disabled(!model.hasSelection)
                    .help(model.hasSelection
                          ? "Match and rename only what was selected in the pane"
                          : "Nothing was selected in the pane")
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
        guard model.hasSearch else {
            return model.selectionOnly ? "Only the \(model.selected.count) selected."
                                       : "Every file is listed."
        }
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
            (Text(entry.prefix).foregroundStyle(.secondary) + Text(entry.name))
                .lineLimit(1).truncationMode(.middle)
            if let new = model.newNames[entry.id] {
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
            guard entry.isDirectory, !model.isFlat else { return }
            model.navigate(to: entry.url)
        }
        .help(entry.isDirectory && !model.isFlat ? "Double-click to go into this folder" : "")
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
