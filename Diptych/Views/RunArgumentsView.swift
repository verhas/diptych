import AppKit
import SwiftUI

/// Run ▸ Run with Arguments…: one line for the arguments, the program's
/// earlier ones a ↑ away, and the exact command shown before it runs.
struct RunArgumentsView: View {

    @Bindable var model: AppModel
    let request: AppModel.RunRequest

    @State private var text = ""
    @State private var history: [String] = []
    /// Which history line the field shows; -1 is a new, empty line.
    @State private var position = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run \u{201C}\(request.program.lastPathComponent)\u{201D}").font(.headline)

            ArgumentField(text: $text,
                          onOlder: older, onNewer: newer,
                          onCommit: run, onCancel: { model.dialog = nil })
                .frame(height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2).truncationMode(.middle)
                Text("in " + NamingTemplate.tilde(request.directory.path))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Text(history.isEmpty
                 ? "Passed to your shell as typed: quotes, ~, $VARIABLES and wildcards work as at a prompt."
                 : "\u{2191} \u{2193} for earlier arguments. Passed to your shell as typed, as at a prompt.")
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
            }
        }
        .onAppear {
            history = model.runHistory(for: request.program)
            if let latest = history.first {
                text = latest
                position = 0
            }
        }
    }

    private var preview: String {
        let name = "./" + request.program.lastPathComponent
        let inPlace = request.program.deletingLastPathComponent().standardizedFileURL
            == request.directory.standardizedFileURL
        let program = inPlace ? name : request.program.path
        let arguments = text.trimmingCharacters(in: .whitespaces)
        return Shell.argument(program) + (arguments.isEmpty ? "" : " " + arguments)
    }

    private func older() {
        guard position + 1 < history.count else { return }
        position += 1
        text = history[position]
    }

    private func newer() {
        guard position > -1 else { return }
        position -= 1
        text = position == -1 ? "" : history[position]
    }

    private func run() {
        model.dialog = nil
        model.run(request.program, arguments: text, in: request.directory)
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
