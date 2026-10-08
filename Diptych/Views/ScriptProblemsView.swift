import SwiftUI

/// Everything wrong in the scripts folder, said once at startup.
struct ScriptProblemsView: View {

    let problems: [ScriptProblem]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(problems.count == 1
                 ? "One script could not be read"
                 : "\(problems.count) problems in your scripts")
                .font(.headline)

            Text("These scripts are left out of the Scripts menu for now. Fix them and start "
                 + "Diptych again \u{2014} or switch on developer mode in Settings \u{25B8} "
                 + "Behaviour, and use the menu item \u{201C}File \u{25B8} Read the Scripts "
                 + "Folder Again\u{201D}.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(problems) { problem in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(problem.line.map { "\(problem.file), line \($0)" }
                                 ?? problem.file)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                            Text(problem.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 260)

            HStack {
                Spacer()
                Button("OK") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
    }
}
