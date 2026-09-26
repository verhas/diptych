import Foundation

/// The bundled `ReleaseNotes.txt` -- every release's notes concatenated by
/// `build.sh` at build time, newest first. Generated, not written by hand:
/// see `generate_release_notes` in `build.sh`.
enum ReleaseNotesText {
    static let all: String = {
        guard let url = Bundle.main.url(forResource: "ReleaseNotes", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "No release notes were bundled with this build." }
        return text
    }()
}
