import AppKit
import SwiftUI

/// Settings ▸ Agents: the MCP server an agent talks to Diptych through, and
/// the agent terminal that starts one with that server already configured.
struct AgentSettingsView: View {

    @Bindable private var store = ConfigStore.shared

    var body: some View {
        // Scrolls, like the other long panes: the Settings window cannot be
        // resized, and text that does not fit is otherwise simply cut off.
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text("Agent Access (MCP)").font(.headline)

            Toggle("Allow a local AI agent to query Diptych", isOn: Binding(
                get: { store.configuration.mcpServerEnabled },
                set: { store.setMCPServerEnabled($0) }))
                .toggleStyle(.checkbox)
            explanation("Listens on 127.0.0.1 only, and only while Diptych is running. An agent "
                        + "needs the token below to ask it anything -- what's selected, what a "
                        + "comparison window is showing -- nothing it can already do through the "
                        + "shell.")

            if store.configuration.mcpServerEnabled {
                LabeledContent("Port") {
                    TextField("", value: $store.configuration.mcpServerPort, format: .number)
                        .frame(width: 80)
                }
                LabeledContent("Token") {
                    HStack {
                        Text(MCPTokenStore.shared.token)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Regenerate") { MCPTokenStore.shared.regenerate() }
                    }
                }
                explanation("Regenerating stops the old token working immediately. Any agent "
                            + "already connected, and the .mcp.json entry it was given, needs the "
                            + "new one -- run \u{201c}Add Diptych to Agent Config\u{201d} again to "
                            + "update it. The agent terminal updates its own each time it starts.")
            }

            Divider()

            Text("Agent Terminal").font(.headline)
            explanation("View \u{25B8} Show Agent Terminal (\u{2303}`) opens a terminal under the "
                        + "window with your agent already running in it, and Diptych already in "
                        + "its .mcp.json. Opening it switches agent access on.")

            LabeledContent("Start with") {
                TextField("claude", text: $store.configuration.agentCommand)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 260)
            }
            explanation("claude, codex, copilot, or whatever you use, with any options. Run by "
                        + "your login shell; when it ends, the shell stays. Empty: just a shell.")

            LabeledContent("Start in") {
                HStack {
                    TextField(Configuration.defaultAgentDirectory,
                              text: $store.configuration.agentDirectory)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 260)
                    Button("Choose\u{2026}") { chooseDirectory() }
                    Button("Default") {
                        store.configuration.agentDirectory = Configuration.defaultAgentDirectory
                    }
                    .disabled(store.configuration.agentDirectory
                              == Configuration.defaultAgentDirectory)
                }
            }
            explanation("Made if it does not exist, and given a .mcp.json pointing at Diptych. "
                        + "Where the agent stands hardly matters -- it reaches files through "
                        + "Diptych -- so a folder of its own keeps that file out of your projects. "
                        + "Applies to the next agent terminal opened.")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func explanation(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = AgentWorkspace.directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.configuration.agentDirectory = NamingTemplate.tilde(url.path)
    }
}
