import AppKit

/// The short sounds played after a copy, move or trash.
@MainActor
enum Sounds {

    /// Stored in configuration as a name; this one means silence.
    static let silent = "None"

    /// The system sound set, which is what NSSound(named:) resolves.
    static func available() -> [String] {
        let directory = URL(fileURLWithPath: "/System/Library/Sounds")
        let names = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil))?
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted() ?? []
        return [silent] + names
    }

    /// Used by file operations, so the master switch turns everything off in
    /// one place. The Settings preview calls `play` directly -- picking a sound
    /// should be audible even while sounds are off.
    static func playIfEnabled(_ name: String) {
        guard ConfigStore.shared.configuration.soundsEnabled else { return }
        play(name)
    }

    static func play(_ name: String) {
        guard name != silent, !name.isEmpty else { return }
        NSSound(named: name)?.play()
    }
}
