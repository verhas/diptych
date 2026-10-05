import AppKit
import SwiftUI

/// The Runs window: one window, a tab per run, with Diptych's own tab strip.
///
/// Not macOS window tabs. Those put a + on every tab bar that opens another,
/// empty window of the same kind -- a dead tab -- and SwiftUI shows the window
/// it creates when it likes, so a new run kept opening on its own and only
/// joined the others once it had finished. A tab strip of its own has neither
/// problem, and the tab in front is unambiguously "this run".
struct RunsView: View {

    @Bindable private var runs = CommandRuns.shared
    @State private var guard_ = CloseGuard()
    @State private var window: NSWindow?

    private var selected: CommandRun? {
        runs.focused.flatMap { id in runs.tabs.first { $0.id == id } } ?? runs.tabs.last
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            if let run = selected {
                RunPanel(run: run, close: { closeTab(run) })
                    .id(run.id)
            } else {
                Text("No runs. Right-click a script or command-line tool \u{25B8} Run.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 320)
        .background(WindowAccessor { found in
            guard let found else { return }
            window = found
            AppWindows.shared.register(found)
            WindowSubjects.shared.register(found, kind: "runs", description: "Runs")
            guard found.delegate !== guard_ else { return }
            guard_.shouldClose = { closeWindowIsAllowed() }
            guard_.willClose = {
                for run in runs.tabs { run.stop(); runs.closeTab(run.id) }
                runs.focused = nil
            }
            found.delegate = guard_
        })
        .onChange(of: runs.tabs.isEmpty) { _, empty in
            if empty { window?.close() }
        }
    }

    /// The tabs share the width, as in Safari, down to a width a command can
    /// still be read at. Past that the strip scrolls -- and then says so: ‹ and
    /// › step through the tabs, ⌄ lists all of them, and the tab shown is
    /// always scrolled into view. A strip that only scrolled hid every tab
    /// past the third from anyone without a horizontal scroll wheel, with
    /// nothing to say they were there.
    private var tabStrip: some View {
        GeometryReader { geometry in
            let tabs = runs.tabs
            let available = geometry.size.width - 12
            let fits = CGFloat(tabs.count) * Self.narrowestTab + CGFloat(max(0, tabs.count - 1)) * 2
                <= available
            let width = fits
                ? min(Self.widestTab, max(Self.narrowestTab,
                      (available - CGFloat(max(0, tabs.count - 1)) * 2) / CGFloat(max(1, tabs.count))))
                : Self.narrowestTab
            HStack(spacing: 4) {
                if !fits { stepButton(by: -1, systemImage: "chevron.left") }
                ScrollViewReader { scroller in
                    ScrollView(.horizontal, showsIndicators: !fits) {
                        HStack(spacing: 2) {
                            ForEach(tabs) { run in
                                RunTab(run: run, isSelected: run.id == selected?.id, width: width,
                                       select: { runs.focused = run.id },
                                       close: { closeTab(run) })
                                .id(run.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selected?.id) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(id) }
                    }
                    .onAppear { if let id = selected?.id { scroller.scrollTo(id) } }
                }
                if !fits {
                    stepButton(by: 1, systemImage: "chevron.right")
                    allTabsMenu
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 34)
        .background(.bar)
    }

    static let narrowestTab: CGFloat = 130
    static let widestTab: CGFloat = 240

    /// The tab before or after the one shown.
    private func stepButton(by step: Int, systemImage: String) -> some View {
        let tabs = runs.tabs
        let index = tabs.firstIndex { $0.id == selected?.id } ?? 0
        let target = index + step
        return Button {
            if tabs.indices.contains(target) { runs.focused = tabs[target].id }
        } label: {
            Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .disabled(!tabs.indices.contains(target))
        .help(step < 0 ? "The tab before" : "The tab after")
    }

    /// Every tab by name, the shown one ticked.
    private var allTabsMenu: some View {
        Menu {
            ForEach(runs.tabs) { run in
                Toggle(isOn: Binding(get: { run.id == selected?.id },
                                     set: { if $0 { runs.focused = run.id } })) {
                    Text(run.commandLine)
                }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("All \(runs.tabs.count) tabs")
    }

    /// Closing a tab whose program still runs stops it -- asked first.
    private func closeTab(_ run: CommandRun) {
        if run.isRunning {
            guard confirm("Stop \u{201C}\(run.program.lastPathComponent)\u{201D} and close its tab?",
                          "It is still running. Closing the tab stops it.") else { return }
            run.stop()
        }
        runs.closeTab(run.id)
    }

    private func closeWindowIsAllowed() -> Bool {
        let running = runs.tabs.filter(\.isRunning).count
        guard running > 0 else { return true }
        return confirm(running == 1 ? "Stop the run that is still going and close?"
                                    : "Stop the \(running) runs still going and close?",
                       "Closing the Runs window stops what is running in it. Every run is "
                       + "kept for a day, output included, either way.")
    }

    private func confirm(_ title: String, _ detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Stop and Close")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// One tab: how it stands, what it runs, and its ×.
private struct RunTab: View {
    let run: CommandRun
    let isSelected: Bool
    let width: CGFloat
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(colour).frame(width: 8, height: 8)
            Text(run.commandLine)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(hovering || isSelected ? 1 : 0.35)
            .help("Close this tab")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(run.commandLine)
    }

    private var colour: Color {
        switch run.state {
        case "running":  .blue
        case "finished": .green
        case "failed":   .red
        default:         .orange
        }
    }
}

/// A run's own part of the window: the command, its terminal, what came of it.
private struct RunPanel: View {

    let run: CommandRun
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            RunTerminal(view: run.view)
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(run.commandLine)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Text("in " + NamingTemplate.tilde(run.directory.path))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            status
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .trailing, spacing: 2) {
            switch run.state {
            case "running":
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    // Ticking, so a long build shows it is alive.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("Running \(CommandRun.formatted(run.realTime))")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            case "finished":
                Label("Finished", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case "failed":
                Label("Failed \u{2014} exit \(run.exitCode ?? -1)", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            default:
                Label("Stopped", systemImage: "stop.circle.fill").foregroundStyle(.orange)
            }
            if !run.isRunning {
                // As `time` reports it.
                Text(run.timingLine)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(copied ? "Copied" : "Copy Output") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(run.outputText, forType: .string)
                copied = true
            }
            Spacer()
            if run.isRunning {
                Button("Stop") { run.stop() }
            } else {
                Button("Run Again") {
                    RunLauncher.run(program: run.program, arguments: run.arguments,
                                    in: run.directory)
                }
                Button("Close Tab") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// The run's terminal view, put in the window -- and given the keyboard, so
/// a program that asks a question can be answered at once.
private struct RunTerminal: NSViewRepresentable {
    let view: DiptychTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {}
}

/// Starting a run: the downloaded-program question, the history, the log, the
/// tab.
@MainActor
enum RunLauncher {

    /// Brings up the Runs window; set by the first browser window, like the
    /// other window openers.
    static var openWindow: (() -> Void)?

    static func run(program: URL, arguments: String, in directory: URL) {
        guard confirmIfDownloaded(program) else { return }
        RunHistory.shared.record(arguments, for: program)
        let run = CommandRun(program: program, arguments: arguments, directory: directory)
        CommandRuns.shared.add(run)
        RunLog.shared.started(run)
        run.onFinish = { finished in
            RunLog.shared.finished(finished)
            CommandRuns.shared.finished(finished)
        }
        openWindow?()
    }

    /// macOS checks a downloaded app before it first runs; nothing checks a
    /// downloaded script. So Diptych asks.
    private static func confirmIfDownloaded(_ program: URL) -> Bool {
        guard ExtendedAttributes.data(of: program.path, name: "com.apple.quarantine") != nil
        else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\u{201C}\(program.lastPathComponent)\u{201D} was downloaded from "
            + "the internet."
        alert.informativeText = "Run it only if you trust where it came from. macOS does not "
            + "check scripts the way it checks apps."
        alert.addButton(withTitle: "Run Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }
}
