import SwiftUI

/// A small dot in the toolbar, present only while the MCP server is switched
/// on: dim when idle, a brief bright pulse -- green for a call, red for a
/// rejected (unauthorized) request -- on every request the server handles.
/// Clicking it opens the activity console.
struct MCPStatusIndicator: View {

    @Bindable private var config = ConfigStore.shared
    @Bindable private var log = MCPActivityLog.shared
    @State private var pulsing = false
    @State private var pulseIsError = false
    @State private var lastSeenToken = 0
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if config.configuration.mcpServerEnabled {
            Button {
                openWindow(id: DiptychApp.mcpConsoleWindowID)
            } label: {
                Circle()
                    .fill(pulsing ? (pulseIsError ? Color.red : Color.green)
                                 : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulsing ? 1.5 : 1.0)
                    .animation(.easeOut(duration: 0.2), value: pulsing)
            }
            .buttonStyle(.plain)
            .help("Local agent access (MCP) is on \u{2014} click for the activity log")
            .onChange(of: log.activityToken) { _, newToken in
                guard newToken != lastSeenToken else { return }
                lastSeenToken = newToken
                pulseIsError = log.entries.last?.kind == .rejected
                pulsing = true
                Task {
                    try? await Task.sleep(for: .milliseconds(220))
                    pulsing = false
                }
            }
        }
    }
}
