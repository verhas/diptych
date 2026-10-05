import AppKit
import SwiftUI

/// The agent terminal under the window: a handle, and the terminal under it.
///
/// The handle is always there, a thin strip along the bottom of the window,
/// so the terminal starts out looking closed and is opened from where it
/// will appear. Its chevron does what \u{2303}` and View \u{25B8} Show Agent
/// Terminal do: the first click starts the agent, later ones fold the
/// terminal down to the strip -- the agent carrying on -- and open it again.
/// Dragging the handle of an open terminal makes it taller or shorter, and
/// the height is remembered.
struct TerminalArea: View {

    let session: TerminalSession?
    let isOpen: Bool
    let style: TerminalStyle
    /// The tallest the terminal may be and still leave the panes usable.
    let maxHeight: CGFloat
    /// Open or fold it -- the model's toggle, the same one the menu uses.
    let toggle: () -> Void
    /// The terminal took the keyboard.
    let tookFocus: () -> Void
    /// Something was copied from it.
    let copied: (String) -> Void

    @Bindable private var store = ConfigStore.shared
    /// The height while a drag is under way: written to Settings once, when
    /// the drag ends, not on every mouse movement.
    @State private var dragHeight: CGFloat?
    @State private var dragStart: CGFloat?

    static let handleHeight: CGFloat = 14

    private var height: CGFloat {
        let stored = dragHeight ?? CGFloat(store.configuration.terminalHeight)
        return max(100, min(stored, maxHeight))
    }

    var body: some View {
        VStack(spacing: 0) {
            handle
            if isOpen, let session {
                TerminalPanel(session: session, style: style, tookFocus: tookFocus,
                              copied: copied)
                    .frame(height: height)
            }
        }
    }

    private var handle: some View {
        ZStack {
            Rectangle().fill(.bar)
            Image(systemName: isOpen ? "chevron.compact.down" : "chevron.compact.up")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 90, height: Self.handleHeight)
        }
        .frame(height: Self.handleHeight)
        .overlay(alignment: .top) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .gesture(resize)
        .onHover { inside in
            guard isOpen else { return }
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .help(isOpen ? "Fold the agent terminal away (\u{2303}`); drag to resize"
                     : session == nil ? "Start the agent terminal (\u{2303}`)"
                                      : "Show the agent terminal (\u{2303}`)")
    }

    private var resize: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { drag in
                guard isOpen else { return }
                let start = dragStart ?? height
                dragStart = start
                // Up is taller: the handle is the terminal's top edge.
                dragHeight = max(100, min(start - drag.translation.height, maxHeight))
            }
            .onEnded { _ in
                if let dragHeight { store.configuration.terminalHeight = Double(dragHeight) }
                dragHeight = nil
                dragStart = nil
            }
    }
}

/// The window's `TerminalSession`, shown.
///
/// The session's view is handed in, not made here, so folding or hiding the
/// terminal only takes the view off screen -- the shell, and anything running
/// in it, carry on, and showing it again finds them as they were.
///
/// It takes the keyboard only when asked to, once: when the terminal has just
/// been opened. Taking it every time SwiftUI happens to rebuild this view
/// pulled the keyboard back from a pane that had just been clicked.
struct TerminalPanel: NSViewRepresentable {

    let session: TerminalSession
    let style: TerminalStyle
    let tookFocus: () -> Void
    let copied: (String) -> Void

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let terminal = session.view
        terminal.removeFromSuperview()
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
        terminal.onFocus = tookFocus
        terminal.onCopied = copied
        terminal.apply(style)
        if session.focusRequested {
            session.focusRequested = false
            DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
        }
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        session.view.onFocus = tookFocus
        session.view.onCopied = copied
        session.view.apply(style)
    }
}
