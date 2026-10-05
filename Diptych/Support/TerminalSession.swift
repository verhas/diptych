import AppKit
import Darwin
@preconcurrency import SwiftTerm

/// The agent terminal: a shell under a browser window's panes, started in
/// `~/.diptych/agentic` with the configured agent -- `claude`, `codex`,
/// whatever the person uses -- already running in it, and Diptych's MCP
/// server in its `.mcp.json`. It is there to talk to an agent that works
/// through Diptych; that it is also a perfectly ordinary shell, once the
/// agent is left, is a side effect nobody needs to be stopped from using.
///
/// A real terminal, not a lookalike: SwiftTerm runs the shell in a
/// pseudo-terminal and draws what it writes, so `vim`, `htop`, colours and the
/// mouse work as they do in Terminal.app. Diptych is not sandboxed, so the
/// shell sees what a shell in Terminal.app sees -- with one difference worth
/// knowing: macOS counts what it runs as Diptych's doing, so a privacy prompt
/// names Diptych, and Diptych's Full Disk Access covers it.
///
/// One per window, made the first time the panel is shown. Hiding the panel
/// keeps it -- and whatever is running in it -- alive; the shell ends when it
/// exits by itself or when its window closes.
@MainActor
final class TerminalSession: NSObject {

    let view: DiptychTerminalView

    /// Called once the shell has ended, by `exit` or by being stopped.
    var onExit: (() -> Void)?

    /// The next time the terminal is put on screen, give it the keyboard.
    /// Set when it is opened or unfolded -- and only then.
    var focusRequested = true

    /// The window the panel belongs to. Closing it ends the shell, whether or
    /// not the panel was showing at the time.
    weak var hostWindow: NSWindow? {
        didSet { observeClosing() }
    }

    private var closeObserver: NSObjectProtocol?

    init(startingIn folder: URL, running command: String) {
        let options = TerminalOptions(scrollback: 10_000)
        let style = TerminalStyle.current
        view = DiptychTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 240),
                                   font: style.font, options: options)
        super.init()
        view.processDelegate = self
        view.apply(style)
        start(in: folder, running: command)
    }

    /// A login shell, the way Terminal.app starts one -- `-zsh` as its
    /// argv[0] -- so `.zprofile` runs and `PATH` is what the person is used
    /// to, rather than the bare one an app launched from the Dock inherits.
    /// Without that the agent's command would mostly not be found.
    ///
    /// The command is typed into the shell, as if by the person: the shell
    /// starts once, reads its startup files once, and is the same shell the
    /// prompt returns to when the agent ends. Running it with `-c` and
    /// starting a second shell after it ran `.zshrc` twice, and anything that
    /// prints at start-up printed twice.
    private func start(in folder: URL, running command: String) {
        let shell = Self.loginShell
        let name = "-" + (shell as NSString).lastPathComponent
        view.startProcess(executable: shell, args: [], environment: Self.environment,
                          execName: name, currentDirectory: folder.path)
        // Waits in the terminal's input until the shell is ready to read it.
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { view.send(txt: trimmed + "\r") }
    }

    /// What a shell started by Diptych is given: a terminal that does colour,
    /// and `TERM_PROGRAM`, so a program can tell where it runs.
    static var environment: [String] {
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        environment.append("SHELL=\(loginShell)")
        environment.append("TERM_PROGRAM=Diptych")
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            environment.append("TERM_PROGRAM_VERSION=\(version)")
        }
        // The person's own language, where SwiftTerm would otherwise say en_US.
        if let lang = ProcessInfo.processInfo.environment["LANG"] {
            environment.removeAll { $0.hasPrefix("LANG=") }
            environment.append("LANG=\(lang)")
        }
        return environment
    }

    /// The shell in the account's own record, not `$SHELL`: an app started
    /// from the Dock may not have that variable at all.
    static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    /// Something other than the shell itself is in charge of the terminal --
    /// a build, `vim`, `ssh` -- as opposed to the shell waiting at its prompt.
    var hasRunningCommand: Bool {
        let fd = view.process.childfd
        guard view.process.running, fd >= 0 else { return false }
        let foreground = tcgetpgrp(fd)
        return foreground > 0 && foreground != view.process.shellPid
    }

    /// What is running at the moment, by name -- "claude", "vim" -- when it
    /// is something other than the shell at its prompt.
    var runningCommandName: String? {
        guard hasRunningCommand else { return nil }
        let foreground = tcgetpgrp(view.process.childfd)
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(foreground, &buffer, UInt32(buffer.count)) > 0 else { return "a command" }
        let name = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: name, as: UTF8.self)
    }

    func terminate() {
        guard view.process.running else { return }
        view.terminate()
    }

    private func observeClosing() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        guard let hostWindow else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: hostWindow, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminate() }
        }
    }
}

extension TerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onExit?()
    }
}

/// How the agent terminal looks, from Settings ▸ Appearance -- its own font
/// and colours, apart from the panes'.
struct TerminalStyle: Equatable {
    var optionAsMeta = false
    var fontName: String
    var fontSize: Double
    var colours: Configuration.TerminalColours
    var foreground: String
    var background: String

    @MainActor
    static var current: TerminalStyle {
        let configuration = ConfigStore.shared.configuration
        return TerminalStyle(optionAsMeta: configuration.terminalOptionAsMeta,
                             fontName: configuration.terminalFontName,
                             fontSize: configuration.terminalFontSize,
                             colours: configuration.terminalColours,
                             foreground: configuration.terminalForeground,
                             background: configuration.terminalBackground)
    }

    /// By family, so "SF Mono" works as the name people know it by. A family
    /// that is gone falls back to the system's monospaced font.
    var font: NSFont {
        let size = CGFloat(fontSize)
        if !fontName.isEmpty,
           let font = NSFontManager.shared.font(withFamily: fontName, traits: [],
                                                weight: 5, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Text and background. `.system` resolves for the appearance in effect
    /// when called, which is why the view calls this again on a switch to or
    /// from dark mode.
    var textColours: (foreground: NSColor, background: NSColor) {
        switch colours {
        case .system: (.textColor, .textBackgroundColor)
        case .light:  (NSColor(white: 0.1, alpha: 1), .white)
        case .dark:   (NSColor(white: 0.9, alpha: 1), NSColor(white: 0.12, alpha: 1))
        case .custom: (NSColor(hex: foreground) ?? .textColor,
                       NSColor(hex: background) ?? .textBackgroundColor)
        }
    }

    /// The available monospaced families, for the Settings picker. A terminal
    /// is a grid; a proportional font breaks every table and box drawn in it.
    @MainActor
    static var monospacedFamilies: [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
        return families.filter { !$0.hasPrefix(".") }.sorted()
    }
}

/// SwiftTerm's view, drawn in the style Settings gives it.
final class DiptychTerminalView: LocalProcessTerminalView {

    private var style = TerminalStyle(fontName: "", fontSize: 12, colours: .system,
                                      foreground: "", background: "")

    /// Told when this view is clicked into, so the window stops counting
    /// either pane as focused. Called by `ClickRouter`: SwiftTerm does not let
    /// `becomeFirstResponder` be overridden.
    var onFocus: (() -> Void)?

    func apply(_ newStyle: TerminalStyle) {
        let fontChanged = newStyle.fontName != style.fontName || newStyle.fontSize != style.fontSize
        style = newStyle
        if fontChanged || font != style.font { font = style.font }
        // SwiftTerm's default is Meta, which sent Escape X for Option+X and so
        // made a layout's # @ \ and the rest impossible to type.
        optionAsMetaKey = style.optionAsMeta
        applyColours()
    }

    /// SwiftTerm takes a colour's value once, when it is set, so a dynamic
    /// system colour has to be resolved -- and set again on every switch
    /// between light and dark.
    private func applyColours() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let colours = style.textColours
            nativeForegroundColor = colours.foreground
            nativeBackgroundColor = colours.background
            caretColor = .controlAccentColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColours()
    }

    // MARK: - Keys a terminal emulator gives meaning to

    /// ⌘⌫, as Ghostty and iTerm have it: Control-U, which a shell and Claude
    /// both read as "delete back to the start of the line". It arrives here
    /// as the standard text command, from the menu shortcut ⌘⌫ already has.
    override func deleteToBeginningOfLine(_ sender: Any?) { send(txt: "\u{15}") }

    /// ⌘← and ⌘→: Control-A and Control-E, the start and end of the line.
    override func moveToLeftEndOfLine(_ sender: Any?) { send(txt: "\u{1}") }
    override func moveToBeginningOfLine(_ sender: Any?) { send(txt: "\u{1}") }
    override func moveToRightEndOfLine(_ sender: Any?) { send(txt: "\u{5}") }
    override func moveToEndOfLine(_ sender: Any?) { send(txt: "\u{5}") }

    // MARK: - Copying

    /// Told what was copied, for a word of feedback.
    var onCopied: ((String) -> Void)?

    /// "Copied “npm run build”", or "Copied 3 lines".
    static func copiedMessage(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").count
        if lines > 1 { return "Copied \(lines) lines" }
        let shown = text.count > 40 ? String(text.prefix(40)) + "\u{2026}" : text
        return "Copied \u{201C}\(shown)\u{201D}"
    }

    /// What is selected, without the blanks the screen pads every line with.
    /// Any NUL -- an empty cell, should one come through -- becomes a space:
    /// many programs stop reading pasted text at one.
    private var selectedText: String? {
        getSelection().flatMap(Self.cleanedForPasting)
    }

    static func cleanedForPasting(_ raw: String) -> String? {
        let lines = raw.replacingOccurrences(of: "\u{0}", with: " ")
            .components(separatedBy: "\n")
            .map { line in
                var line = line
                while line.last == " " || line.last == "\t" { line.removeLast() }
                return line
            }
        var text = lines.joined(separator: "\n")
        while text.hasSuffix("\n") { text.removeLast() }
        return text.isEmpty ? nil : text
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        onCopied?(text)
    }

    /// ⌘C copies nothing here. Selecting already copied; a ⌘C pressed from
    /// habit -- or by accident -- must not replace what was copied with
    /// whatever happens to be selected, or with nothing.
    override func copy(_ sender: Any) {}

    /// Selecting is copying: there is nothing else to select terminal text
    /// for. When the mouse is let go on a selection -- dragged, or a double-
    /// or triple-click -- the text goes to the clipboard and the selection is
    /// cleared, so it is plain that it has been taken.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        // Cleared whether or not there was text to copy: a selection of only
        // blanks, or one barely started, was left on screen when the clearing
        // waited for something to copy.
        guard getSelection() != nil else { return }
        if let text = selectedText { copyToPasteboard(text) }
        clearSelection()
        // Once more a moment later: a double-click's word selection can be
        // put back by the click handling that follows the release.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.clearSelection()
        }
    }

    /// SwiftTerm's `selectNone` only marks the selection inactive -- it does
    /// not say so, nor redraw -- so the highlight stayed on screen after the
    /// text had been copied. Said and redrawn here.
    private func clearSelection() {
        selectNone()
        selectionChanged(source: getTerminal())
        needsDisplay = true
    }

    // MARK: - Dropping files

    /// Files dragged in from a pane or from Finder are typed in as their
    /// paths, quoted for the shell and separated by spaces -- what
    /// Terminal.app does, and what lets "look at this file" be said by
    /// dragging the file onto the agent.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
    }

    private func droppedPaths(_ info: NSDraggingInfo) -> [String] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: options) as? [URL] ?? []
        return urls.map(\.path)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedPaths(sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedPaths(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = droppedPaths(sender)
        guard !paths.isEmpty else { return false }
        // A space after it, ready for whatever is typed next.
        send(txt: Shell.arguments(paths) + " ")
        window?.makeFirstResponder(self)
        onFocus?()
        return true
    }
}

extension NSColor {
    /// `#RRGGBB`, the form colours are kept in config.json.
    convenience init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        func byte(_ component: CGFloat) -> Int { Int((component * 255).rounded()) }
        return String(format: "#%02X%02X%02X",
                      byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}
