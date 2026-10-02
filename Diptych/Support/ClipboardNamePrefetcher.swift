import AppKit

/// New from Clipboard's name, worked out before anyone asks for it.
///
/// Thinking of a name takes the model one to three seconds, and New from
/// Clipboard used to start only when chosen -- so the wait was always all of
/// it. Three moments say the command is likely to come, and each starts the
/// guess early:
///
/// 1. A menu opens: the menu bar, or a right-click on a pane. Both offer the
///    command, and the person is one click away from it.
/// 2. Diptych comes to the front with something new on the clipboard -- copy
///    elsewhere, switch here, paste is the way the command gets used.
/// 3. The clipboard changes while Diptych is in front.
///
/// One guess at a time, for one clipboard, folder and naming style. When the
/// command comes and all three still match, it takes the guess -- finished, or
/// still under way -- instead of asking again. When they do not, the guess is
/// thrown away and the command asks as it always did; only Vision's reading of
/// a picture is kept, since that does not depend on the folder and is the
/// slower half.
///
/// Never while Diptych is in the background, never unless Apple Intelligence
/// is switched on and ready, and not at all with Settings ▸ Apple Intelligence
/// ▸ "Start naming what is copied before it is pasted" unticked. Like every
/// other question to the model, it does not leave this Mac.
@MainActor
final class ClipboardNamePrefetcher {

    static let shared = ClipboardNamePrefetcher()
    private init() {}

    /// What a guess was made for. A different clipboard, folder or style is a
    /// different question.
    private struct Key: Equatable {
        let changeCount: Int
        let folder: String
        let style: NameSuggester.Style
    }

    private var key: Key?
    private var guess: Task<NameSuggester.Outcome, Never>?

    /// What Vision said about the picture on the clipboard, by change count.
    private var words: (changeCount: Int, length: Int, task: Task<String?, Never>)?

    private var observers: [NSObjectProtocol] = []

    var isEnabled: Bool {
        let configuration = ConfigStore.shared.configuration
        return configuration.prefetchClipboardNames
            && configuration.useAppleIntelligence
            && configuration.clipboardImageFormat != .off
            && NameSuggester.status == .ready
    }

    /// Signals 1 (the menu bar) and 2. The right-click half of 1 comes from
    /// `ClickRouter`, which knows which pane was clicked; signal 3 from
    /// `ClipboardWatcher`, which already notices every change.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            // The key window is settled a turn later than the app's activation.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ClipboardNamePrefetcher.shared.anticipateInKeyWindow() }
            }
        })
        observers.append(center.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { note in
            // Only the menu bar. A context menu posts this too, but for the
            // active pane, which need not be the one right-clicked.
            // Only the menu's identity crosses; a Notification is not Sendable.
            let menu = (note.object as? NSMenu).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard menu != nil, menu == NSApp.mainMenu.map(ObjectIdentifier.init) else { return }
                ClipboardNamePrefetcher.shared.anticipateInKeyWindow()
            }
        })
    }

    /// For the frontmost Diptych window's active pane, if there is one.
    func anticipateInKeyWindow() {
        guard NSApp.isActive, let window = NSApp.keyWindow,
              let model = KeyRouter.shared.allModels.first(where: { $0.window === window })
        else { return }
        anticipate(in: model.active.directory)
    }

    /// Start the guess for what is on the clipboard now, as a file in `folder`,
    /// unless that exact guess is already made or under way.
    func anticipate(in folder: URL) {
        guard isEnabled, NSApp.isActive else { return }
        let key = Key(changeCount: NSPasteboard.general.changeCount,
                      folder: folder.standardizedFileURL.path,
                      style: AppModel.nameStyle)
        guard key != self.key else { return }
        cancel()
        // Files on the clipboard -- Command-C in a pane, or in Finder -- are
        // there to be pasted as files, not made into a new one.
        guard Clipboard.fileURLs().isEmpty else { return }

        switch Clipboard.contents() {
        case .nothing:
            return

        case .text(let text):
            let details = NameSuggester.details(
                name: AppModel.numberedName("untitled.txt", in: folder),
                folder: folder, bytes: Int64(text.utf8.count), kind: "text")
            guess = Task {
                var style = key.style
                style.template = await Self.template(for: folder)
                return await NameSuggester.suggest(forText: text, details: details, style: style)
            }

        case .image(let image, let pdf):
            guard let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return }
            let sendable = NameSuggester.SendableImage(picture)
            // Still to be asked, "ask" is guessed as PNG: the format changes
            // the file's extension and size, which barely move a name.
            let chosen = ConfigStore.shared.configuration.clipboardImageFormat
            let format: Configuration.ClipboardImageFormat = chosen == .ask ? .png : chosen
            let name = AppModel.numberedName("untitled.\(format.fileExtension)", in: folder)
            guess = Task {
                var style = key.style
                style.template = await Self.template(for: folder)
                let said = style.template.usesContent
                    ? await pictureWords(for: sendable, changeCount: key.changeCount,
                                         length: style.excerptLength).value
                    : ""
                let bytes = await BlockingWork.run {
                    Self.estimatedBytes(of: sendable, pdf: pdf, as: format)
                }
                let details = NameSuggester.details(name: name, folder: folder,
                                                    bytes: bytes, kind: "picture")
                return await NameSuggester.suggest(forPictureDescribedAs: said,
                                                   details: details, style: style)
            }
        }
        self.key = key
    }

    /// The guess for exactly this clipboard, folder and style, if one was made.
    /// Taken, not shared: a second New from Clipboard asks afresh. A guess for
    /// anything else is stale, and stopped.
    func take(in folder: URL, changeCount: Int) -> Task<NameSuggester.Outcome, Never>? {
        let wanted = Key(changeCount: changeCount, folder: folder.standardizedFileURL.path,
                         style: AppModel.nameStyle)
        guard let guess, key == wanted else {
            cancel()
            return nil
        }
        self.guess = nil
        key = nil
        return guess
    }

    /// Something else wants the model -- Rename with Suggested Name -- and is
    /// the one the person is waiting for.
    func cancel() {
        guess?.cancel()
        guess = nil
        key = nil
    }

    /// Vision's words for a picture that came off the clipboard at
    /// `changeCount`: read once, whichever of the guess and the command
    /// needs them first.
    func pictureWords(for picture: NameSuggester.SendableImage, changeCount: Int,
                      length: Int) -> Task<String?, Never> {
        if let words, words.changeCount == changeCount, words.length == length {
            return words.task
        }
        let task = Task {
            await BlockingWork.run { NameSuggester.describe(picture, length: length) }
        }
        words = (changeCount, length, task)
        return task
    }

    /// Waits for a taken guess, and stops it if the wait is stopped -- Escape.
    nonisolated static func wait(
        for guess: Task<NameSuggester.Outcome, Never>
    ) async -> NameSuggester.Outcome {
        await withTaskCancellationHandler { await guess.value } onCancel: { guess.cancel() }
    }

    private static func template(for folder: URL) async -> NamingTemplate.Template {
        await BlockingWork.run { NamingTemplate.read().template(for: folder) }
    }

    /// Near enough to what `Clipboard.data` will write, for the size a
    /// template can mention.
    nonisolated private static func estimatedBytes(
        of picture: NameSuggester.SendableImage, pdf: Data?,
        as format: Configuration.ClipboardImageFormat
    ) -> Int64 {
        if format == .pdf, let pdf { return Int64(pdf.count) }
        let bitmap = NSBitmapImageRep(cgImage: picture.image)
        let data = bitmap.representation(using: format == .jpeg ? .jpeg : .png,
                                         properties: format == .jpeg
                                             ? [.compressionFactor: 0.9] : [:])
        return Int64(data?.count ?? 0)
    }
}
