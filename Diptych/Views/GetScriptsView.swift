import SwiftUI

/// File ▸ Get Scripts…: the scripts that come with Diptych, each to tick or
/// leave, with its source a click away and, when something is already there
/// under its name, a comparison with that first.
struct GetScriptsView: View {

    let model: AppModel
    let onClose: () -> Void

    private let scripts = ScriptLibrary.bundledFolder.map(ScriptLibrary.scripts(in:)) ?? []
    @State private var chosen: Set<String> = []
    @State private var showing: ScriptLibrary.Script.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Get Scripts").font(.headline)

            Text("These come with Diptych and are installed into ~/.diptych/scripts, "
                 + "readable by you alone. Nothing is downloaded. A script is a program that "
                 + "can do anything you can, so read what one does before you tick it; each "
                 + "asks again before it first runs.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if scripts.isEmpty {
                Text("This copy of Diptych has no scripts with it.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(scripts) { script in
                            row(script)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 340)
            }

            if !ScriptCatalogue.shared.isEnabled {
                Text("Scripts are switched off in Settings \u{25B8} Behaviour. They can be "
                     + "installed now, and appear in the menus once switched on.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? "Install" : "Install \(chosen.count)") {
                    model.installScripts(scripts.filter { chosen.contains($0.id) })
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        // The sheet it is shown in gives the width and the margins.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ script: ScriptLibrary.Script) -> some View {
        let status = ScriptLibrary.status(of: script, in: ScriptCatalogue.folder)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: Binding(get: { chosen.contains(script.id) },
                                     set: { if $0 { chosen.insert(script.id) } else { chosen.remove(script.id) } })) {
                    Text(script.name).fontWeight(.medium)
                }
                .toggleStyle(.checkbox)
                .disabled(status == .installed)
                Spacer()
                Text(Self.describe(status, version: script.version))
                    .font(.caption)
                    .foregroundStyle(status == .different ? .orange : .secondary)
            }
            if !script.summary.isEmpty {
                Text(script.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
            HStack(spacing: 12) {
                Button(showing == script.id ? "Hide Source" : "Show Source") {
                    showing = showing == script.id ? nil : script.id
                }
                if status != .absent, status != .installed {
                    Button("Compare with Yours") { model.compareWithInstalled(script) }
                        .help("Your \(script.fileName) on the left, this one on the right")
                }
                Text(script.fileName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.link)
            .font(.caption)
            .padding(.leading, 20)

            if showing == script.id {
                ScrollView([.vertical, .horizontal]) {
                    Text(script.contents)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(.leading, 20)
            }
        }
    }

    static func describe(_ status: ScriptLibrary.Status, version: Int) -> String {
        switch status {
        case .absent: return "version \(version)"
        case .installed: return "installed, version \(version)"
        case .older(let installed):
            return "version \(installed.map(String.init) ?? "?") installed \u{2014} \(version) is newer"
        case .different: return "a different file of this name is installed"
        }
    }
}
