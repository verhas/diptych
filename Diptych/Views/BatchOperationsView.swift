import SwiftUI
import AppKit

/// The review window `propose_file_operations` opens: every proposed
/// operation, checked by default, individually editable, cancel or execute.
///
/// Reuses the checkbox-row-with-shift-click pattern from "Undo or Redo Many"
/// (`ContentView.historyList`/`choose`) and the same inline `PermissionField`
/// `CellView` embeds for the pane's own permission column -- both already the
/// project's established answer to "a list the person ticks rows in" and "an
/// in-place rwx editor," so neither is reinvented here.
struct BatchOperationsView: View {

    @State private var model: BatchOperationsModel?
    @State private var shiftAnchor: Int?
    @State private var confirmingLargeBatch = false
    @State private var largeBatchAcknowledged = false
    @State private var endEditing = EndEditingOnClick()
    @Environment(\.dismiss) private var dismiss
    let batchId: UUID

    /// A batch big enough that ticking through it row by row stops being a
    /// real review -- asked about once per window, separately from the
    /// overwrite/delete-permanent gate.
    private static let confirmationThreshold = 10

    init(batchId: UUID) {
        self.batchId = batchId
        _model = State(initialValue: BatchOperationsStore.shared.model(for: batchId))
    }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                Text("This batch is no longer available.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(WindowAccessor { window in
            if let window {
                AppWindows.shared.register(window)
                WindowSubjects.shared.register(window, kind: "batchOperations",
                                               description: "\(model?.rows.count ?? 0) operation(s)",
                                               model: model)
                endEditing.install(on: window)
            }
        })
        .onDisappear { endEditing.remove() }
    }

    @ViewBuilder
    private func content(_ model: BatchOperationsModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(model)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, index: index, model: model)
                        Divider()
                    }
                }
                .padding(.vertical, 4)
            }
            if !model.batchProblems.isEmpty {
                Divider()
                batchProblemsView(model)
            }
            Divider()
            footer(model)
        }
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle("File Operations")
        .confirmationDialog("Run \(model.rows.filter(\.included).count) operations?",
                            isPresented: $confirmingLargeBatch, titleVisibility: .visible) {
            Button("Continue") {
                largeBatchAcknowledged = true
                attemptExecute(model)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This batch has more than \(Self.confirmationThreshold) operations. Worth "
                 + "one more look at the list before running it.")
        }
    }

    /// Execute, gated in order: freshly revalidated first, since a text
    /// field only commits its edit to `problems`/`canExecute` on Return --
    /// without this, a button that looked enabled from before an edit could
    /// silently do nothing when pressed. Then a large batch is confirmed
    /// once per window, then it actually runs. Overwrites and permanent
    /// deletes are not asked about here: each such row has its own tick,
    /// and Execute stays disabled until every one is ticked or deselected.
    private func attemptExecute(_ model: BatchOperationsModel) {
        model.revalidate()
        guard model.canExecute else { return }
        if model.rows.filter(\.included).count > Self.confirmationThreshold, !largeBatchAcknowledged {
            confirmingLargeBatch = true
            return
        }
        Task { await model.execute() }
    }

    private func header(_ model: BatchOperationsModel) -> some View {
        HStack {
            Text("\(model.rows.count) proposed operation\(model.rows.count == 1 ? "" : "s")")
                .font(.headline)
            Spacer()
            Button("Select All") { model.toggleAll(true) }
            Button("Select None") { model.toggleAll(false) }
        }
        .padding(12)
    }

    @ViewBuilder
    private func batchProblemsView(_ model: BatchOperationsModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.batchProblems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func footer(_ model: BatchOperationsModel) -> some View {
        HStack {
            statusText(model)
            Spacer()
            // Cancel's whole point is to leave the review -- a window still
            // sitting there afterwards left closing it to the red button,
            // which defeats having a Cancel button at all. Once the batch
            // has actually run there is nothing left to cancel, so the same
            // button becomes Close instead of doing nothing useful.
            Button(model.status == .reviewing ? "Cancel" : "Close") {
                if model.status == .reviewing { model.cancel() }
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(model.status == .executing)
            Button("Execute") { attemptExecute(model) }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canExecute)
        }
        .padding(12)
    }

    @ViewBuilder
    private func statusText(_ model: BatchOperationsModel) -> some View {
        switch model.status {
        case .reviewing:
            let unconfirmed = model.rowsNeedingOverwriteConfirmation.count
            if unconfirmed > 0 {
                Text("\(unconfirmed) operation\(unconfirmed == 1 ? "" : "s") would overwrite or "
                     + "permanently delete: tick it to allow, or deselect it.")
                    .font(.caption).foregroundStyle(.orange)
            }
        case .executing:
            Text("Working\u{2026}").font(.caption).foregroundStyle(.secondary)
        case .cancelled:
            Text("Cancelled.").font(.caption).foregroundStyle(.secondary)
        case .finished:
            let ran = model.rows.filter { model.rowResults[$0.id] != nil }.count
            let failed = model.failedRows.count
            if failed == 0 {
                Text("Done: all \(ran) succeeded.").font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Done: \(ran - failed) succeeded, \(failed) failed.",
                      systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: BatchOperationRow, index: Int, model: BatchOperationsModel) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                choose(index, in: model.rows, model: model)
            } label: {
                Image(systemName: row.included ? "checkmark.square.fill" : "square")
                    .foregroundStyle(row.included ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(model.status != .reviewing)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.kind.displayName).font(.system(size: 12, weight: .semibold))
                    if let reason = row.reason, !reason.isEmpty {
                        Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if row.isNoOp {
                        Text("No change").font(.caption2).foregroundStyle(.secondary)
                    }
                    if row.included, row.needsDestructiveConfirmation {
                        Toggle(row.kind == .deletePermanent ? "Delete permanently"
                                                            : "Overwrite existing item",
                               isOn: Binding(get: { row.destructiveConfirmed },
                                             set: { row.destructiveConfirmed = $0 }))
                            .toggleStyle(.checkbox)
                            .font(.caption2)
                            .foregroundStyle(row.kind == .deletePermanent ? .red : .orange)
                            .disabled(model.status != .reviewing)
                    }
                }
                editor(row, model: model)
                if let result = model.rowResults[row.id] {
                    if model.failedRows.contains(row.id) {
                        Label(result, systemImage: "xmark.octagon.fill")
                            .font(.caption).foregroundStyle(.red)
                    } else {
                        Label(result, systemImage: "checkmark.circle")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(row.problems, id: \.self) { problem in
                    Text(problem).font(.caption2).foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        // A no-op still reads as ticked -- its checkbox is untouched -- but
        // is dimmed like an excluded row, since running it changes nothing.
        .opacity(row.included && !row.isNoOp ? 1 : 0.5)
    }

    @ViewBuilder
    private func editor(_ row: BatchOperationRow, model: BatchOperationsModel) -> some View {
        let disabled = model.status != .reviewing
        switch row.kind {
        case .move, .copy:
            HStack(spacing: 6) {
                Text(row.source?.path ?? "?").font(.caption).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                EditableTextField("Destination path", initial: row.targetPath?.path ?? "",
                                  disabled: disabled) {
                    row.targetPath = $0.isEmpty ? nil : URL(fileURLWithPath: $0)
                }
                .onSubmit { model.revalidate() }
            }
        case .rename:
            HStack(spacing: 6) {
                Text(row.source?.lastPathComponent ?? "?").font(.caption).lineLimit(1)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                EditableTextField("New name", initial: row.newName ?? "", disabled: disabled) {
                    row.newName = $0.isEmpty ? nil : $0
                }
                .onSubmit { model.revalidate() }
            }
        case .trash, .deletePermanent:
            Text(row.source?.path ?? "?").font(.caption).lineLimit(1).truncationMode(.middle)
        case .setPermissions:
            HStack(spacing: 10) {
                Text(row.source?.path ?? "?").font(.caption).lineLimit(1).truncationMode(.middle)
                Text(row.currentMode.map(FileOperations.rwxString) ?? "?????????")
                    .font(PaneFont.monospacedSwiftUI).foregroundStyle(.secondary)
                    .help("The permissions it has now")
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                PermissionField(mode: row.mode ?? 0,
                                onCursor: { _ in },
                                onCommit: { row.mode = $0; model.revalidate() },
                                onCancel: {},
                                autoFocus: false,
                                onEdit: { row.mode = $0 })
                    .frame(width: 90, height: 16)
                    .disabled(disabled)
            }
        case .setOwner:
            HStack(spacing: 8) {
                Text(row.source?.path ?? "?").font(.caption).lineLimit(1).truncationMode(.middle)
                Picker("", selection: Binding(
                    get: { row.owner ?? "" },
                    set: { row.owner = $0.isEmpty ? nil : $0; model.revalidate() })) {
                    Text("(unchanged)").tag("")
                    ForEach(AccountLookup.users(), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 130).disabled(disabled)
                Picker("", selection: Binding(
                    get: { row.group ?? "" },
                    set: { row.group = $0.isEmpty ? nil : $0; model.revalidate() })) {
                    Text("(unchanged)").tag("")
                    ForEach(AccountLookup.groups(), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 130).disabled(disabled)
            }
        case .createSymlink:
            HStack(spacing: 6) {
                EditableTextField("New link path", initial: row.targetPath?.path ?? "",
                                  disabled: disabled) {
                    row.targetPath = $0.isEmpty ? nil : URL(fileURLWithPath: $0)
                }
                .onSubmit { model.revalidate() }
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                EditableTextField("Points to", initial: row.linkTarget?.path ?? "",
                                  disabled: disabled) {
                    row.linkTarget = $0.isEmpty ? nil : URL(fileURLWithPath: $0)
                }
                .onSubmit { model.revalidate() }
            }
        case .createDirectory:
            EditableTextField("New folder path", initial: row.targetPath?.path ?? "",
                              disabled: disabled) {
                row.targetPath = $0.isEmpty ? nil : URL(fileURLWithPath: $0)
            }
            .onSubmit { model.revalidate() }
        case .setXattr, .removeXattr:
            attributeEditor(row, model: model, disabled: disabled)
        case .addTags, .removeTags, .setTags:
            tagEditor(row, model: model, disabled: disabled)
        }
    }

    /// The attribute, what it holds now, and -- for set -- what it will hold,
    /// in the encoding the value was given in.
    @ViewBuilder
    private func attributeEditor(_ row: BatchOperationRow, model: BatchOperationsModel,
                                 disabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(row.source?.path ?? "?").font(.caption).lineLimit(1).truncationMode(.middle)
                EditableTextField("Attribute name", initial: row.xattrName ?? "",
                                  disabled: disabled) {
                    row.xattrName = $0.isEmpty ? nil : $0
                }
                .onSubmit { model.revalidate() }
                .frame(maxWidth: 260)
            }
            HStack(spacing: 6) {
                Text(XattrDisplay.describe(row.currentXattr, name: row.xattrName))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .help("What it holds now")
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                if row.kind == .setXattr {
                    Picker("", selection: Binding(
                        get: { row.xattrEncoding },
                        set: { row.xattrEncoding = $0; row.unknownEncoding = nil
                               model.revalidate() })) {
                        ForEach(XattrEncoding.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(width: 80).disabled(disabled)
                    EditableTextField("Value", initial: row.xattrText ?? "", disabled: disabled) {
                        row.xattrText = $0
                    }
                    .onSubmit { model.revalidate() }
                } else {
                    Text("(removed)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let name = row.xattrName, let meaning = XattrDisplay.meaning(of: name) {
                Text(meaning).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The tags the item has now, and the tags it will have, as chips. The
    /// row's own list is edited in place: a chip's \u{00D7} drops it, the field
    /// adds one.
    @ViewBuilder
    private func tagEditor(_ row: BatchOperationRow, model: BatchOperationsModel,
                           disabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.source?.path ?? "?").font(.caption).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 6) {
                TagChips(tags: row.currentTags ?? [], removable: false) { _ in }
                    .help("The tags it has now")
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                TagChips(tags: row.resultingTags(from: row.currentTags ?? []), removable: false) { _ in }
                    .help("The tags it will have")
            }
            HStack(spacing: 6) {
                Text(row.kind == .addTags ? "Add:" : row.kind == .removeTags ? "Remove:" : "Set to:")
                    .font(.caption).foregroundStyle(.secondary)
                TagChips(tags: row.tags, removable: !disabled) { tag in
                    row.tags.removeAll { $0 == tag }
                    model.revalidate()
                }
                if !disabled {
                    NewTagField { tag in
                        if !row.tags.contains(where: {
                            $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                            row.tags.append(tag)
                        }
                        model.revalidate()
                    }
                }
            }
        }
    }

    /// Same shift-click-range gesture `ContentView.choose` gives "Undo or
    /// Redo Many" -- read from the event since a plain Button gives no
    /// modifiers.
    private func choose(_ index: Int, in rows: [BatchOperationRow], model: BatchOperationsModel) {
        let shift = NSEvent.modifierFlags.contains(.shift)
        if shift, let from = shiftAnchor, rows.indices.contains(from) {
            let included = !rows[index].included
            for step in min(from, index) ... max(from, index) { rows[step].included = included }
            model.revalidate()
            return
        }
        rows[index].included.toggle()
        shiftAnchor = index
        model.revalidate()
    }
}

/// Tags as Finder draws them: a coloured dot for the seven colours, the name
/// beside it -- and, where the list is being edited, a \u{00D7} to drop one.
private struct TagChips: View {
    let tags: [String]
    let removable: Bool
    let remove: (String) -> Void

    var body: some View {
        if tags.isEmpty {
            Text("(none)").font(.caption).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 3) {
                        if FinderTag.colourIndex(of: tag) != 0 {
                            Circle().fill(InfoView.colour(of: tag)).frame(width: 8, height: 8)
                        }
                        Text(tag).font(.caption)
                        if removable {
                            Button { remove(tag) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .help("Leave \u{201C}\(tag)\u{201D} out")
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
        }
    }
}

/// Type a tag and press Return to add it.
private struct NewTagField: View {
    @State private var text = ""
    let add: (String) -> Void

    var body: some View {
        TextField("Add a tag", text: $text)
            .textFieldStyle(.roundedBorder).font(.caption).frame(width: 110)
            .onSubmit {
                let tag = text.trimmingCharacters(in: .whitespaces)
                guard !tag.isEmpty else { return }
                add(tag)
                text = ""
            }
    }
}

/// A text field that owns its text while it is being typed in, pushing each
/// change into the row rather than reading it back out of an `@Observable`
/// model on every render.
private struct EditableTextField: View {
    @State private var text: String
    let placeholder: String
    let disabled: Bool
    let commit: (String) -> Void

    init(_ placeholder: String, initial: String, disabled: Bool,
         commit: @escaping (String) -> Void) {
        self.placeholder = placeholder
        _text = State(initialValue: initial)
        self.disabled = disabled
        self.commit = commit
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder).font(.caption).disabled(disabled)
            .onChange(of: text) { _, newValue in commit(newValue) }
    }
}

/// Ends text editing when the person clicks anything in the window that is
/// not itself an editor.
///
/// AppKit only moves first responder to something that asks for it: clicking
/// a label, empty space or a button leaves a text field editing, still
/// receiving every keystroke. With one field that is the familiar macOS
/// behaviour; with a list of editable rows it means typing lands in a row
/// the person has visibly moved away from.
@MainActor
final class EndEditingOnClick {
    private var monitor: Any?
    private weak var window: NSWindow?

    func install(on window: NSWindow) {
        guard monitor == nil else { return }
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let location = event.locationInWindow
            let number = event.windowNumber
            MainActor.assumeIsolated { self?.mouseDown(at: location, windowNumber: number) }
            return event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Decided after the click has been handled rather than before: hit
    /// testing from the window's content view stops at SwiftUI's own
    /// containers and never reaches the text fields and grids inside them.
    /// Whatever the click was on has had its chance to take focus by then;
    /// if it didn't, and it landed outside the editor that still has focus,
    /// that editor is let go.
    private func mouseDown(at location: NSPoint, windowNumber: Int) {
        guard let window, window.windowNumber == windowNumber else { return }
        let before = window.firstResponder
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window,
                  window.firstResponder === before,
                  let editor = Self.editorView(of: before) else { return }
            if !editor.convert(editor.bounds, to: nil).contains(location) {
                window.makeFirstResponder(nil)
            }
        }
    }

    /// The view an editing responder belongs to: the text field a field
    /// editor is editing, or the permission grid itself.
    private static func editorView(of responder: NSResponder?) -> NSView? {
        if let grid = responder as? PermissionEditorView { return grid }
        if let fieldEditor = responder as? NSTextView, fieldEditor.isFieldEditor {
            return fieldEditor.delegate as? NSView
        }
        return nil
    }
}
