import AppKit
import SwiftUI

/// Run ▸ Run with Arguments…: one line for the arguments, the variables the
/// program is given, whether to keep this as a template -- and the exact
/// command shown before it runs. ↑ and ↓ step through earlier runs, arguments
/// and variables together, as a shell's history steps through lines: what
/// was being edited is left behind.
struct RunArgumentsView: View {

    @Bindable var model: AppModel
    let request: AppModel.RunRequest

    typealias Variable = RunHistory.File.Entry.Variable

    /// One row of the variables editor. Its own id, because two rows may for a
    /// moment have the same name, and typing must stay in the row typed in.
    struct VariableRow: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var value: String
    }

    @State private var text = ""
    @State private var variables: [VariableRow] = []
    @State private var showsVariables = false
    @State private var asTemplate = false
    @State private var history: [RunHistory.File.Entry] = []
    /// Which history entry the window shows; -1 is a new, empty one.
    @State private var position = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run \u{201C}\(request.program.lastPathComponent)\u{201D}").font(.headline)

            ArgumentField(text: $text,
                          onOlder: older, onNewer: newer,
                          onCommit: run, onCancel: { model.dialog = nil })
                .frame(height: 22)

            variablesEditor

            VStack(alignment: .leading, spacing: 2) {
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(3).truncationMode(.middle)
                Text("in " + NamingTemplate.tilde(request.directory.path))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Toggle("Save as a template", isOn: $asTemplate)
                .toggleStyle(.checkbox)
            Text("A template stays in the Run menu, marked \u{24C9}, and opens this window with "
                 + "these arguments and variables instead of running at once. It is never rolled "
                 + "off by the history limit.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(history.isEmpty
                 ? "Passed to your shell as typed: quotes, ~, $VARIABLES and wildcards work as at a prompt."
                 : "\u{2191} \u{2193} for earlier runs, variables included. Passed to your shell as typed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Edit History File\u{2026}") {
                    let file = RunHistory.shared.ensureFile(for: request.program)
                    model.dialog = nil
                    // A Text Edit window already open on it shows what the file
                    // held then -- before the runs since. Read it again first.
                    OpenTextDocuments.shared.refreshIfOpen(file)
                    model.openTextWindow?(file)
                }
                .help("This program's history, as the JSON it is kept in -- edit, reorder, "
                      + "or set \u{201C}fixed\u{201D} or \u{201C}limit\u{201D}")
                Spacer()
                Button("Cancel") { model.dialog = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Run") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!variablesAreValid)
            }
        }
        .onAppear {
            history = model.runHistory(for: request.program)
            if let prefill = request.prefill {
                show(prefill)
                position = history.firstIndex { $0.isSameRun(as: prefill) } ?? -1
            } else if let latest = history.first {
                show(latest)
                position = 0
            }
        }
    }

    // MARK: - Variables

    private var variablesEditor: some View {
        DisclosureGroup(isExpanded: $showsVariables) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach($variables) { $row in
                    HStack(spacing: 6) {
                        TextField("NAME", text: $row.name)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Self.isValidName(row.name) || row.name.isEmpty
                                             ? Color.primary : Color.red)
                            .frame(width: 170)
                        Text("=").foregroundStyle(.secondary)
                        TextField("value", text: $row.value)
                            .font(.system(.body, design: .monospaced))
                        Button {
                            variables.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this variable")
                    }
                }
                Button {
                    variables.append(VariableRow(name: "", value: ""))
                } label: {
                    Label("Add Variable", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                if !variablesAreValid {
                    Text("A name is letters, digits and _, not starting with a digit.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            .padding(.top, 4)
        } label: {
            Text(variables.isEmpty ? "Environment Variables"
                                   : "Environment Variables (\(variables.count))")
        }
    }

    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              CharacterSet.letters.contains(first) || first == "_" else { return false }
        return name.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_"
        }
    }

    /// Rows with a name must have a good one; a row left empty is ignored.
    private var variablesAreValid: Bool {
        variables.allSatisfy { $0.name.isEmpty || Self.isValidName($0.name) }
    }

    private var enteredVariables: [Variable] {
        variables.filter { !$0.name.isEmpty }.map { Variable(name: $0.name, value: $0.value) }
    }

    // MARK: - History

    /// An entry into the window: its arguments, its variables -- the editor
    /// opened when it has any. The template box always starts unticked.
    private func show(_ entry: RunHistory.File.Entry) {
        text = entry.arguments
        variables = entry.variables.map { VariableRow(name: $0.name, value: $0.value) }
        showsVariables = !variables.isEmpty
        asTemplate = false
    }

    private func clear() {
        text = ""
        variables = []
        asTemplate = false
    }

    private func older() {
        guard position + 1 < history.count else { return }
        position += 1
        show(history[position])
    }

    private func newer() {
        guard position > -1 else { return }
        position -= 1
        if position == -1 { clear() } else { show(history[position]) }
    }

    // MARK: - Running

    private var preview: String {
        let inPlace = request.program.deletingLastPathComponent().standardizedFileURL
            == request.directory.standardizedFileURL
        let program = inPlace ? "./" + request.program.lastPathComponent : request.program.path
        let arguments = text.trimmingCharacters(in: .whitespaces)
        return CommandRun.variablesPrefix(enteredVariables)
            + Shell.argument(program) + (arguments.isEmpty ? "" : " " + arguments)
    }

    private func run() {
        guard variablesAreValid else { return }
        model.dialog = nil
        model.run(request.program, arguments: text, environment: enteredVariables,
                  asTemplate: asTemplate, in: request.directory)
    }
}

/// The arguments line: AppKit, because ↑ and ↓ have to step through the
/// history, and a SwiftUI field gives those keys to its own cursor.
private struct ArgumentField: NSViewRepresentable {

    @Binding var text: String
    let onOlder: () -> Void
    let onNewer: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = "arguments"
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingHead
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            context.coordinator.caretToEnd(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            context.coordinator.caretToEnd(field)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ArgumentField
        init(parent: ArgumentField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):         parent.onOlder()
            case #selector(NSResponder.moveDown(_:)):       parent.onNewer()
            case #selector(NSResponder.insertNewline(_:)):  parent.onCommit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }

        func caretToEnd(_ field: NSTextField) {
            let length = (field.stringValue as NSString).length
            field.currentEditor()?.selectedRange = NSRange(location: length, length: 0)
        }
    }
}
