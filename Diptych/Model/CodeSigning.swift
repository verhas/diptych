import Foundation

/// Reading a file's code signature and what Gatekeeper makes of it -- what
/// `codesign`, `spctl` and `stapler` report, gathered into one answer for the
/// Info window. Read-only: it asks the tools, it does not sign anything.
///
/// Nothing here touches the main actor; it runs the command-line tools off the
/// main thread and returns a value.
enum CodeSigning {

    struct Report: Sendable, Equatable {
        /// The file carries a signature at all.
        var signed = false
        /// `codesign --verify` was happy with it -- nil when unsigned.
        var valid: Bool?
        var identifier: String?
        var teamIdentifier: String?
        /// The certificate chain, leaf first.
        var authorities: [String] = []
        /// Signed ad-hoc -- a bare signature with no identity behind it.
        var adhoc = false
        var timestamp: String?
        /// Gatekeeper accepted it -- nil when it could not be assessed.
        var accepted: Bool?
        /// What Gatekeeper said it is: `Notarized Developer ID`, `Developer
        /// ID`, `rejected`, …
        var source: String?
        /// A notarization ticket is stapled to the file -- nil when that does
        /// not apply (only apps, disk images and installers are stapled).
        var stapled: Bool?
        /// The one-line headline for the top of the tab.
        var summary = "Not read yet."
        /// The tools' own words, for the disclosure at the bottom.
        var raw = ""

        var notarized: Bool { source?.localizedCaseInsensitiveContains("notarized") ?? false }
    }

    // MARK: - Gathering

    nonisolated static func report(for url: URL) -> Report {
        var report = Report()
        let display = run("/usr/bin/codesign", ["-dvvv", url.path])
        report.raw = "$ codesign -dvvv\n" + display.out

        if display.out.localizedCaseInsensitiveContains("not signed at all")
            || display.out.localizedCaseInsensitiveContains("is not signed") {
            report.signed = false
            report.summary = "This file is not code-signed."
            return report
        }
        report.signed = true
        parse(display.out, into: &report)

        // Valid signature?
        let verify = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path])
        report.valid = verify.status == 0
        report.raw += "\n\n$ codesign --verify --deep --strict (exit \(verify.status))\n"
            + (verify.out.isEmpty ? "(no output -- signature is valid)" : verify.out)

        // What Gatekeeper makes of it.
        let type = assessmentType(for: url)
        let assess = run("/usr/sbin/spctl", ["--assess", "--type", type, "-vv", url.path])
        report.accepted = assess.status == 0
        report.source = source(in: assess.out)
        report.raw += "\n\n$ spctl --assess --type \(type) -vv (exit \(assess.status))\n" + assess.out

        // A stapled ticket, where one would be.
        if ["app", "dmg", "pkg", "mpkg"].contains(url.pathExtension.lowercased()) {
            let staple = run("/usr/bin/xcrun", ["stapler", "validate", url.path])
            report.stapled = staple.status == 0
            report.raw += "\n\n$ xcrun stapler validate (exit \(staple.status))\n" + staple.out
        }

        report.summary = summarise(report)
        return report
    }

    // MARK: - Parsing

    /// Parse a `codesign -dvvv` display into a report -- the signed fields set,
    /// the rest left as given. Exposed for testing against canned output.
    nonisolated static func parsed(_ text: String) -> Report {
        var report = Report(signed: true)
        parse(text, into: &report)
        return report
    }

    nonisolated static func parse(_ text: String, into report: inout Report) {
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if let value = value(line, after: "Identifier=") { report.identifier = value }
            else if let value = value(line, after: "TeamIdentifier=") {
                report.teamIdentifier = value == "not set" ? nil : value
            } else if let value = value(line, after: "Authority=") {
                report.authorities.append(value)
            } else if let value = value(line, after: "Timestamp=") {
                report.timestamp = value
            } else if let value = value(line, after: "Signature=") {
                report.adhoc = value.localizedCaseInsensitiveContains("adhoc")
            }
        }
    }

    private nonisolated static func value(_ line: String, after prefix: String) -> String? {
        line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
    }

    /// The `source=…` line of spctl's output -- what it decided the file is.
    nonisolated static func source(in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("source=") { return String(line.dropFirst("source=".count)) }
        }
        // A rejection has no source line; the verb is the answer.
        if text.localizedCaseInsensitiveContains("rejected") { return "rejected" }
        return nil
    }

    private nonisolated static func assessmentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pkg", "mpkg": "install"
        case "dmg":         "open"
        default:            "execute"
        }
    }

    private nonisolated static func summarise(_ report: Report) -> String {
        if report.notarized, report.valid == true {
            return "Signed and notarized by Apple\u{2014}"
                + (report.teamIdentifier.map { "team \($0)." } ?? "a known developer.")
        }
        if report.adhoc { return "Ad-hoc signed: a bare signature with no developer identity." }
        if report.valid == false { return "Signed, but the signature does not verify." }
        if report.accepted == false {
            return "Signed, but Gatekeeper would not accept it (not notarized)."
        }
        if report.valid == true {
            return "Signed by " + (report.authorities.first ?? "an unknown authority") + "."
        }
        return "Signed."
    }

    // MARK: - Running a tool

    private nonisolated static func run(_ launch: String, _ arguments: [String])
        -> (status: Int32, out: String) {
        guard FileManager.default.isExecutableFile(atPath: launch) else { return (-1, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = arguments
        // codesign writes its display to standard error; one pipe keeps the
        // order and lets a single read drain both.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
