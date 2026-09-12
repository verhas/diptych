import SwiftUI

/// What a script printed, while it is printing it.
///
/// The command line is at the top because it is the one moment the user sees
/// exactly what ran -- a safeguard as much as a courtesy. Stop is there while
/// it runs, since a script that never finishes must not leave a window that
/// can only wait.
struct ScriptOutputView: View {

    let run: ScriptRun
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(run.script.name).font(.headline)
                // Said at the moment it matters. Diptych would normally refuse
                // a script that can still be written to, because one that can
                // change after being agreed to has not really been agreed to.
                // Developer mode allows it -- and allowing it quietly would
                // make a working rule look like a broken one.
                if run.script.isWritable {
                    Label("Developer mode: this script can still be written to, so what it "
                          + "does can change after you have agreed to it.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(run.commandLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollViewReader { scroller in
                ScrollView {
                    Text(run.output.isEmpty ? " " : run.output)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("output")
                }
                // Follows the tail while it runs, as a terminal does.
                .onChange(of: run.output) { _, _ in
                    guard run.isRunning else { return }
                    scroller.scrollTo("output", anchor: .bottom)
                }
            }
            .frame(minHeight: 220)

            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 340)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            status
            Spacer()
            if run.isRunning {
                Button("Stop") { run.stop() }
            } else {
                Button("Copy") {
                    let board = NSPasteboard.general
                    board.clearContents()
                    board.setString(run.output, forType: .string)
                    onClose()
                }
                Button("OK") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var status: some View {
        if run.isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Running\u{2026}").font(.subheadline).foregroundStyle(.secondary)
            }
        } else if let trouble = run.trouble {
            Label(trouble, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.red)
        } else if let code = run.status {
            // The number either way, because an expert wants it -- but
            // anything other than zero says so in a way nobody can miss. A
            // script that fails while printing plausible output is otherwise
            // indistinguishable from one that worked.
            Label(code == 0 ? "Finished \u{2014} 0" : "Failed \u{2014} exit status \(code)",
                  systemImage: code == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.subheadline)
                .foregroundStyle(code == 0 ? Color.secondary : Color.red)
                .labelStyle(.titleAndIcon)
        }
    }
}

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

            Text("These are ignored for now. Fix them and start Diptych again \u{2014} or "
                 + "switch on developer mode in Settings, which adds a command to read them "
                 + "again without restarting.")
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
