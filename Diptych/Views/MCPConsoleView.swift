import SwiftUI

/// What the MCP status indicator opens: a glance-at log of what a local agent
/// has been asking Diptych, newest first. Not a request/response inspector --
/// just enough to answer "what has it been doing" without leaving the app.
struct MCPConsoleView: View {

    @Bindable private var log = MCPActivityLog.shared

    var body: some View {
        VStack(spacing: 0) {
            if log.entries.isEmpty {
                ContentUnavailableView {
                    Label("No Activity Yet", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("Calls a connected agent makes over MCP will show up here.")
                }
            } else {
                List(log.entries.reversed()) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(color(for: entry.kind))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.summary).font(.system(.body, design: .monospaced))
                                Spacer()
                                Text(entry.date, format: .dateTime.hour().minute().second())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let detail = entry.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("\(log.entries.count) entr\(log.entries.count == 1 ? "y" : "ies") since Diptych started, or since last cleared.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { log.clear() }
                    .disabled(log.entries.isEmpty)
            }
            .padding(10)
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(WindowAccessor { window in
            if let window {
                AppWindows.shared.register(window)
                WindowSubjects.shared.register(window, kind: "mcpConsole", description: "MCP activity log")
            }
        })
    }

    private func color(for kind: MCPActivityLog.Kind) -> Color {
        switch kind {
        case .call: .green
        case .rejected: .red
        case .error: .orange
        }
    }
}
