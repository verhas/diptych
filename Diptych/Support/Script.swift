import Foundation

/// A script -- a text file that starts with `#!` -- or a text file marked
/// executable without one: what runs it, whether that is on this Mac, and the
/// mistakes in the `#!` line that make "command not found" so puzzling.
nonisolated struct Script {

    /// Where interpreters are looked for when the line goes through `env`:
    /// the places a login shell's PATH has on a Mac, as the app's own PATH is
    /// only the system's.
    struct Environment: Sendable {
        var exists: @Sendable (String) -> Bool
        var search: [String]

        static let mac = Environment(
            exists: { FileManager.default.isExecutableFile(atPath: $0) },
            search: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                     "/opt/local/bin", "/Library/Apple/usr/bin"])
    }

    let text: String
    /// The line after `#!`, as written; nil for a file without one.
    let line: String?
    let interpreter: String?
    let arguments: [String]
    /// What `env` is asked to find, when the line goes through it.
    let program: String?
    /// Where `program` is on this Mac, when it is.
    let found: String?
    let language: String?
    let executable: Bool
    /// What happens when it is started.
    enum Outcome: Equatable {
        /// It runs, with this program.
        case runs(String)
        /// It does not, for this reason.
        case fails(String)
        /// It runs only in some way or place.
        case depends(String)
    }

    /// Started on this Mac.
    let here: Outcome?
    /// Started on Linux, when that differs.
    let onLinux: Outcome?
    /// Mistakes that stop the system from running it as the line says.
    let problems: [String]
    /// Things worth knowing that do not stop it.
    let notes: [String]

    static func startsLikeScript(_ data: Data) -> Bool {
        data.starts(with: [0x23, 0x21]) || data.starts(with: [0xEF, 0xBB, 0xBF, 0x23, 0x21])
    }

    init(data: Data, text: String, executable: Bool, environment: Environment = .mac) {
        self.text = text
        self.executable = executable
        var problems: [String] = [], notes: [String] = []
        let marked = data.starts(with: [0xEF, 0xBB, 0xBF])
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text

        guard body.hasPrefix("#!") else {
            line = nil; interpreter = nil; arguments = []; program = nil; found = nil; language = nil
            onLinux = nil
            here = executable ? .depends("as a shell script, when a shell starts it; any other way it fails") : nil
            if executable {
                notes.append("It is marked executable but has no #! line. A shell asked to run it runs it "
                             + "as a shell script; started any other way it fails with “exec format error”.")
            }
            self.problems = problems
            self.notes = notes
            return
        }
        if marked {
            problems.append("A byte-order mark comes before #!, so the system does not see the line: "
                            + "it is run by the shell that starts it, whatever the line says.")
        }

        // By scalars: "\r\n" is one Character, which is not "\n".
        let scalars = body.unicodeScalars
        let end = scalars.firstIndex(of: "\n") ?? scalars.endIndex
        var first = scalars[scalars.index(scalars.startIndex, offsetBy: 2)..<end]
        let length = String(String.UnicodeScalarView(first)).utf8.count + 2
        if first.last == "\r" {
            first = first.dropLast()
            problems.append("The #! line ends in a Windows line ending (CR LF): the system looks for an "
                            + "interpreter whose name ends in a carriage return, and reports “no such file "
                            + "or directory”. Save it with Unix line endings.")
        }
        line = String(String.UnicodeScalarView(first)).trimmingCharacters(in: .whitespaces)
        let words = line!.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        interpreter = words.first
        arguments = Array(words.dropFirst())
        if length > 512 {
            problems.append("The #! line is \(length) bytes long; macOS reads only the first 512.")
        }

        var program: String?
        var here: Outcome?
        let crlf = problems.contains { $0.contains("Windows line ending") }
        if let interpreter {
            if !interpreter.hasPrefix("/") {
                problems.append("The interpreter, \(interpreter), is not a full path: it is looked for in the "
                                + "folder the script is started from, not in PATH.")
                here = .depends("only when started from a folder that has \(interpreter) in it")
            } else if !environment.exists(interpreter) {
                problems.append("\(interpreter) is not on this Mac.")
                here = .fails("\(interpreter) is not on this Mac")
            }
            if (interpreter as NSString).lastPathComponent == "env" {
                program = Self.envProgram(arguments)
                if program == nil {
                    problems.append("env is not given a program to run.")
                    here = here ?? .fails("env is given no program to run")
                }
            }
        } else {
            problems.append("The #! line names no interpreter.")
            here = .fails("the line names no interpreter")
        }
        self.program = program
        var onLinux: Outcome?
        if let program {
            found = program.hasPrefix("/") ? (environment.exists(program) ? program : nil)
                : environment.search.lazy.map { $0 + "/" + program }.first(where: environment.exists)
            if here == nil {
                here = found.map { .runs($0) }
                    ?? .depends("only if \(program) is in your PATH: it is not in the usual places on this Mac")
            }
            // Linux hands env everything after it as one word.
            if arguments.count > 1, !arguments[0].hasPrefix("-S") {
                let whole = arguments.joined(separator: " ")
                onLinux = .fails("env looks for a program named “\(whole)”, which there is not; "
                                 + "#!/usr/bin/env -S \(whole) splits it there too")
            }
        } else {
            found = nil
        }
        if let interpreter, here == nil { here = .runs(interpreter) }
        // What stops it outranks everything above.
        if marked {
            here = .fails("the system does not see the #! line: the shell that starts it runs it as a "
                          + "shell script, not with \(interpreter ?? "the interpreter it names")")
        } else if crlf {
            here = .fails("the system looks for “\(interpreter ?? "")” followed by a carriage return, "
                          + "which does not exist")
        }
        let name = (program ?? interpreter.map { ($0 as NSString).lastPathComponent }) ?? "sh"
        language = Self.language(of: name)
        if !executable, case .runs(let with)? = here {
            here = .depends("as “\(name) file”, with \(with); not as a command of its own, "
                            + "as it is not marked executable")
        }
        if !executable {
            notes.append("It is not marked executable: start it as “\(name) file”, or mark it with chmod +x first.")
        }
        self.here = here
        self.onLinux = onLinux
        self.problems = problems
        self.notes = notes
    }

    /// The program `env` runs: its first argument that is not an option or a
    /// NAME=value setting. `-S` splits the rest into words.
    static func envProgram(_ arguments: [String]) -> String? {
        var words = arguments[...]
        while let word = words.first {
            if word == "-S" || word == "--split-string" {
                words = words.dropFirst()
                continue
            }
            if word.hasPrefix("-S") {
                // "-Spython3 -u": the rest of the word is the first one split.
                return String(word.dropFirst(2))
            }
            if word == "-u" || word == "-P" || word == "--unset" {
                words = words.dropFirst(2)
                continue
            }
            if word.hasPrefix("-") || word.contains("=") {
                words = words.dropFirst()
                continue
            }
            return word
        }
        return nil
    }

    /// "python3.12" is Python, "bash" is Bash.
    static func language(of program: String?) -> String? {
        guard var name = program?.lowercased() else { return nil }
        while let last = name.last, last.isNumber || last == "." || last == "-" { name.removeLast() }
        let names: [String: String] = [
            "sh": "Shell", "bash": "Bash", "zsh": "Zsh", "ksh": "Korn shell", "dash": "Dash", "fish": "Fish",
            "csh": "C shell", "tcsh": "C shell", "python": "Python", "pypy": "Python", "perl": "Perl",
            "ruby": "Ruby", "node": "JavaScript (Node.js)", "deno": "TypeScript or JavaScript (Deno)",
            "bun": "TypeScript or JavaScript (Bun)", "osascript": "AppleScript", "swift": "Swift", "php": "PHP",
            "rscript": "R", "awk": "awk", "gawk": "awk", "lua": "Lua", "tclsh": "Tcl", "wish": "Tcl/Tk",
            "pwsh": "PowerShell", "make": "Makefile", "expect": "Expect", "julia": "Julia", "groovy": "Groovy",
            "java": "Java", "kotlin": "Kotlin", "jshell": "Java", "sed": "sed", "elixir": "Elixir",
            "escript": "Erlang", "guile": "Scheme", "racket": "Racket", "sbcl": "Lisp", "uv": "Python (uv)",
        ]
        return names[name]
    }
}

/// A Windows batch file, `.bat` or `.cmd`: run by cmd.exe, which macOS does
/// not have, and fussy in ways that are invisible in an editor.
nonisolated struct BatchFile {

    static let extensions: Set<String> = ["bat", "cmd"]

    let text: String
    let problems: [String]
    let notes: [String]
    /// Labels, `:name` lines, that GOTO and CALL jump to.
    let labels: Int

    init(data: Data, text: String) {
        self.text = text
        var problems: [String] = [], notes: [String] = []
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            problems.append("A byte-order mark starts it. cmd.exe reads those three bytes as part of the first "
                            + "command, and reports it as “not recognized as an internal or external command”.")
        } else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            problems.append("It is saved as UTF-16; cmd.exe reads batch files one byte per character, and "
                            + "cannot run it.")
        }
        let bytes = [UInt8](data.prefix(4 * 1024 * 1024))
        var crlf = 0, bare = 0
        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            if index > 0, bytes[index - 1] == 0x0D { crlf += 1 } else { bare += 1 }
        }
        let lines = text.components(separatedBy: .newlines)
        labels = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix(":") && !trimmed.hasPrefix("::")
        }.count
        if bare > 0 {
            let which = crlf == 0 ? "Its lines end in LF only" : "\(bare.formatted()) of its lines end in LF only"
            let message = which + ": cmd.exe can miss the labels GOTO and CALL jump to, and run the wrong lines. "
                + "Save it with Windows (CR LF) line endings."
            if labels > 0 { problems.append(message) } else { notes.append(message) }
        }
        let marked = data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        if bytes.dropFirst(marked).contains(where: { $0 >= 0x80 }), !text.lowercased().contains("chcp 65001") {
            notes.append("It has characters beyond ASCII. cmd.exe reads them in the console's code page "
                         + "(often 437 or 850), not as UTF-8, unless the file first runs chcp 65001.")
        }
        self.problems = problems
        self.notes = notes
    }
}
