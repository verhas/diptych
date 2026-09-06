import Foundation

/// Rendering file names as shell arguments.
enum Shell {

    /// Characters a shell passes through untouched.
    private static let safe = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-+=/:@%,")

    /// Quoted only when it has to be, which is what makes a pasted list read
    /// naturally in a terminal: `notes.txt 'my file.txt'` rather than
    /// `'notes.txt' 'my file.txt'`.
    static func argument(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return quoted(value)
    }

    /// Always quoted, for building a command string programmatically.
    ///
    /// A single-quoted shell string cannot contain a single quote, so each one
    /// closes the string, adds an escaped quote, and reopens it.
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func arguments(_ values: [String]) -> String {
        values.map(argument).joined(separator: " ")
    }
}
