import SwiftUI
import AppKit
import FoundationModels

/// Everything Diptych does with Apple Intelligence.
///
/// A tab of its own although it holds one feature today: what a person is
/// deciding here is whether a language model reads their files at all, which
/// is a different kind of decision from how a list is sorted -- and it is the
/// place any later use of the model will be switched on too.
struct IntelligenceSettingsView: View {

    @Bindable private var store = ConfigStore.shared

    /// Where the model runs. Only one answer exists today; the other is shown
    /// so that nobody discovers later that it was being chosen for them.
    enum Location: Hashable { case thisMac, cloud }

    static let presetLengths = [100, 500, 1000, 3000]

    /// Chose "Other" while the number was still one of the presets. Without
    /// this the choice would snap straight back to that preset.
    @State private var typingOwnLength = false

    /// Read when the pane appears and on request -- not watched, since the
    /// files are edited elsewhere and a pane is not the place to poll a disk.
    @State private var instructions: NamingInstructions.Catalogue?

    var body: some View {
        // Scrolls, and every explanation may grow downwards, like the other
        // panes: the Settings window cannot be resized.
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            let status = NameSuggester.status
            let configuration = store.configuration

            Toggle("Use Apple Intelligence", isOn: $store.configuration.useAppleIntelligence)
                .toggleStyle(.checkbox)
                // Can be switched on only where it can work -- but always off,
                // so a Mac that has lost Apple Intelligence since is not left
                // with a setting nobody can change.
                .disabled(!configuration.useAppleIntelligence && status != .ready)
            explanation("Used for Rename with Suggested Name (\u{2303}\u{2318}R, or \u{2318}F2), "
                        + "and to name what New from Clipboard makes from what is in it. A "
                        + "name always lands in the rename field for you to accept, change or "
                        + "throw away.")
            Label(status.explanation,
                  systemImage: status == .ready ? "checkmark.circle" : "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(status == .ready ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Picker("Where it runs", selection: .constant(Location.thisMac)) {
                Text("On this Mac").tag(Location.thisMac)
                Text("Apple's Private Cloud Compute \u{2014} not available yet").tag(Location.cloud)
            }
            .pickerStyle(.radioGroup)
            // The whole choice, not only the second answer: there is nothing to
            // choose between yet.
            .disabled(true)
            explanation("On this Mac, nothing is sent anywhere. Apple's cloud model would send "
                        + "the start of your files to Apple's servers. Diptych does not use it; "
                        + "if it ever does, it will be a choice you make here.")

            Divider()

            Text("Suggested names").font(.headline)

            separatorRow(configuration)

            Toggle("Use UTF-8 in file names", isOn: $store.configuration.nameUnicode)
                .toggleStyle(.checkbox)
            explanation("Unticked, a name keeps to plain ASCII letters: \u{00F6}, \u{0151} and "
                        + "\u{00F3} become o, letters from other alphabets are spelt in Latin "
                        + "ones, and anything with no such spelling is left out.")

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Use ae, oe, ue for \u{00E4}, \u{00F6}, \u{00FC}",
                       isOn: $store.configuration.nameGermanSpelling)
                    .toggleStyle(.checkbox)
                explanation("The German way of writing without them: \u{00DC}bersicht becomes "
                            + "Uebersicht rather than Ubersicht. Only with UTF-8 unticked "
                            + "\u{2014} with it ticked, the letters are kept as they are.")
            }
            .padding(.leading, 20)
            .disabled(configuration.nameUnicode)

            lengthRow(configuration)

            Divider()

            instructionsSection
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func separatorRow(_ configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            Toggle("Use", isOn: $store.configuration.nameSeparatorEnabled)
                .toggleStyle(.checkbox)
            SingleCharacterField(text: $store.configuration.nameSeparator)
                .frame(width: 26)
                .disabled(!configuration.nameSeparatorEnabled)
            Text("instead of space in file names")
        }
        if configuration.nameSeparatorEnabled {
            if let character = configuration.nameSeparator.first {
                if !NameSuggester.isUsableSeparator(character, unicode: configuration.nameUnicode) {
                    warning(configuration.nameUnicode || character.isASCII
                            ? "\u{201C}\(configuration.nameSeparator)\u{201D} cannot be used in a "
                              + "name, so spaces are kept."
                            : "With UTF-8 unticked, this has to be a plain ASCII character, so "
                              + "spaces are kept.")
                }
            } else {
                warning("Type the character to use. Until then, spaces are kept.")
            }
        }
    }

    @ViewBuilder
    private func lengthRow(_ configuration: Configuration) -> some View {
        let length = configuration.nameExcerptLength
        let isOwn = typingOwnLength || !Self.presetLengths.contains(length)

        Text("Characters read from the start of a file")

        Picker("Characters read from the start of a file", selection: Binding(
            get: { isOwn ? 0 : length },
            set: { choice in
                if choice == 0 {
                    typingOwnLength = true
                } else {
                    typingOwnLength = false
                    store.configuration.nameExcerptLength = choice
                }
            })) {
            ForEach(Self.presetLengths, id: \.self) { Text("\($0)").tag($0) }
            Text("Other").tag(0)
        }
        .pickerStyle(.radioGroup)
        .horizontalRadioGroupLayout()
        // Said above instead: beside five buttons it is wider than the window.
        .labelsHidden()

        HStack(spacing: 6) {
            TextField("", value: Binding(
                get: { store.configuration.nameExcerptLength },
                // A positive number, whatever is typed: nothing can be named
                // from none of a file.
                set: { store.configuration.nameExcerptLength = max(1, $0) }),
                      format: .number.grouping(.never))
                .frame(width: 90)
                .disabled(!isOwn)
            Text("characters")
        }

        explanation(contextExplanation)
    }

    @ViewBuilder
    private var instructionsSection: some View {
        Text("Instructions").font(.headline)

        explanation("What the model is told is plain text in files you can edit, in "
                    + "\(NamingInstructions.tilde(PromptTemplate.directory.path)). "
                    + "\(NamingInstructions.generalName) is used everywhere. A file in the "
                    + "\u{201C}\(NamingInstructions.folderDirectoryName)\u{201D} folder beside "
                    + "it that starts with a line such as \u{201C}# under: ~/Documents/"
                    + "Scans\u{201D} is used in that folder and every folder inside it instead; "
                    + "when several match, the nearest folder wins. An edit applies to the next "
                    + "name, without restarting.")

        if let instructions {
            VStack(alignment: .leading, spacing: 4) {
                instructionLine(folder: "Everywhere else",
                                file: instructions.general.file ?? "Diptych's own")
                ForEach(instructions.rules, id: \.folder) { rule in
                    instructionLine(folder: NamingInstructions.tilde(rule.folder), file: rule.file)
                }
            }
            ForEach(Array(instructions.problems.enumerated()), id: \.offset) { _, problem in
                warning("\(problem.file): \(problem.message)")
            }
        }

        Button("Read the Instructions Again") { readInstructions() }
            .onAppear { readInstructions() }
    }

    private func instructionLine(folder: String, file: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(folder)
                .fixedSize(horizontal: false, vertical: true)
            Text("\u{2192}").foregroundStyle(.secondary)
            Text(file).foregroundStyle(.secondary)
        }
        .font(.caption)
        .textSelection(.enabled)
    }

    private func readInstructions() {
        instructions = NamingInstructions.read()
    }

    /// The model's limit, as the model reports it rather than as remembered.
    private var contextExplanation: String {
        var tokens: Int?
        if #available(macOS 26, *), NameSuggester.status == .ready {
            tokens = SystemLanguageModel.default.contextSize
        }
        let limit = tokens.map {
            "The model reads at most \($0.formatted()) tokens at once, its instructions and "
            + "its answer included"
        } ?? "The model can read only so much at once, its instructions and its answer included"
        return limit + ". A token is a few characters of English, and fewer in many other "
            + "languages. Set more than it can read and no name comes back \u{2014} Diptych "
            + "says so when that happens. Fewer characters is quicker, but gives it less to "
            + "go on. Text, the text of a PDF, and what is seen in a picture all count."
    }

    // MARK: - Pieces

    private func explanation(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(Color.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A text field that holds one character: typing replaces it.
///
/// AppKit rather than a SwiftUI TextField, because a SwiftUI field on macOS
/// does not reliably show a value changed while it is being typed into -- the
/// binding would hold one character and the field would go on showing two.
/// Here the field editor is corrected directly, as each key arrives.
struct SingleCharacterField: NSViewRepresentable {

    @Binding var text: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.alignment = .center
        field.delegate = context.coordinator
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {

        var parent: SingleCharacterField

        init(_ parent: SingleCharacterField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // The character that was not there before is the one just typed,
            // wherever the caret was when it went in. Typed again as itself,
            // there is nothing new, and it stays.
            let previous = parent.text
            let typed = field.stringValue
            let kept = (typed.first { String($0) != previous } ?? typed.last)
                .map(String.init) ?? ""
            if field.stringValue != kept { field.stringValue = kept }
            parent.text = kept
        }
    }
}
