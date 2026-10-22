import SwiftUI
import AppKit

/// Find text A in the selected names and change it to B, in a window of its
/// own. The list is the point: every selected file is shown with the name it
/// would get, so a replacement can be seen before it happens.
struct RenameReplaceView: View {

    let request: RenameReplaceRequest

    @State private var model: RenameReplaceModel

    init(request: RenameReplaceRequest) {
        self.request = request
        _model = State(initialValue: RenameReplaceModel(request))
    }

    private var title: String {
        "Replace in Names \u{2014} \(model.items.count) item\(model.items.count == 1 ? "" : "s")"
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
                WindowSubjects.shared.register(window, kind: "renameReplace",
                                               description: "\(model.items.count) items")
            }
        })
    }

    // MARK: - Above the list

    private var top: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("Find")
                TextField(model.useRegex ? "regular expression" : "text to find",
                          text: $model.find)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(model.searchIsValid ? Color.primary : Color.red)
            }
            GridRow {
                Text("Replace")
                TextField(model.useRegex ? "replacement, with $1 for a group" : "replacement text",
                          text: $model.replaceWith)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            GridRow {
                Color.clear.frame(width: 0, height: 0)
                Toggle("Regular expression", isOn: $model.useRegex)
                    .help("Off: find and replace plain text. On: A is a regular expression and "
                          + "B its replacement, matched anywhere in each name, every occurrence.")
            }
        }
        .padding(12)
    }

    // MARK: - The list

    private var list: some View {
        ScrollViewReader { _ in
            List(model.items) { item in
                HStack(spacing: 8) {
                    Text(item.name)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(model.newNames[item.url] == nil ? .secondary : .primary)
                    if let new = model.newNames[item.url] {
                        Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.caption)
                        Text(new)
                            .lineLimit(1).truncationMode(.middle)
                            .fontWeight(.medium)
                    }
                    Spacer()
                }
                .font(.system(.body, design: .monospaced))
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Below the list

    private var bottom: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.problems.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.problems.prefix(20), id: \.self) { problem in
                            Text(problem).foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 96)
            } else if let outcome = model.outcome {
                Text(outcome).foregroundStyle(model.wentWrong ? .red : .secondary)
            }

            HStack {
                if model.hasFind, model.problems.isEmpty {
                    Text(model.renames == 0 ? "No names would change"
                         : "\(model.renames) name\(model.renames == 1 ? "" : "s") would change")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                if model.isRenaming { ProgressView().controlSize(.small) }
                Spacer()
                Button("Replace") { Task { await model.apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canApply)
            }
        }
        .padding(12)
    }
}
