import Foundation

/// A diagnostic report as a page: which program, what stopped it and why in
/// words, then the stack of the thread that crashed -- the program's own
/// frames picked out -- with the other threads and the libraries folded.
nonisolated enum CrashReport {

    typealias R = ExecutableReport

    static let kinds: [String: String] = [
        "309": "Crash report", "109": "Crash report", "298": "Low-memory report",
        "288": "Stackshot", "211": "Analytics data",
    ]

    static func html(for log: CrashLog, url: URL, size: Int) -> String {
        let name = url.lastPathComponent
        let kind = kinds[log.kind] ?? (log.kind.isEmpty ? "Diagnostic report" : "Diagnostic report, type \(log.kind)")
        var body = "<h1>\(R.escape(log.process ?? name))"
        if let version = log.version, !version.isEmpty {
            body += " <span class=version>\(R.escape(version))\(log.build.map { $0 == version || $0.isEmpty ? "" : " (\($0))" }.map(R.escape) ?? "")</span>"
        }
        body += "</h1><p class=lead>\(R.escape(kind + ", " + R.bytes(size)))</p>"
        body += "<p class=meta>\(R.escape(url.path))</p>"

        guard log.isCrash else {
            body += aboutCard(log)
            if let text = log.text, !text.isEmpty {
                let shown = String(text.prefix(R.shownText))
                body += "<pre class=source>\(R.source(shown))</pre>"
                if shown.count < text.count { body += "<p class=dim>The first \(R.bytes(R.shownText)) are shown.</p>" }
            }
            return KeyStoreReport.page(title: name, body: R.style + style + body)
        }

        // Why.
        body += "<div class=card><div class=head><b>What Happened</b></div><div class=cert>"
        if let explanation = log.explanation { body += "<p class=why>\(R.escape(explanation))</p>" }
        if let type = log.exceptionType {
            var text = R.escape(type)
            if let signal = log.signal { text += " <span class=dim>(\(R.escape(signal)))</span>" }
            body += R.row("Exception", text)
        }
        if let subtype = log.subtype { body += R.row("Subtype", R.escape(subtype)) }
        if let codes = log.codes, !codes.isEmpty { body += R.row("Codes", "<code>\(R.escape(codes))</code>") }
        if let message = log.exceptionMessage { body += R.row("Message", R.escape(message)) }
        if let termination = log.termination {
            var text = R.escape(termination)
            if let namespace = log.terminationNamespace { text += " <span class=dim>— \(R.escape(namespace))</span>" }
            body += R.row("Ended", text)
        }
        for reason in log.terminationReasons.prefix(20) { body += R.row("Reason", R.escape(reason)) }
        if let by = log.terminatedBy { body += R.row("Ended by", R.escape(by)) }
        for note in log.applicationNotes.prefix(40) { body += R.row("Said", "<code>\(R.escape(String(note.prefix(4000))))</code>") }
        if let crashed = log.crashedThread {
            body += R.row("Thread", R.escape(threadTitle(log.threads[crashed])))
        }
        body += "</div></div>"

        if let crashed = log.crashedThread {
            body += "<h2>Crashed Thread <span class=count>\(R.escape(threadTitle(log.threads[crashed])))</span></h2>"
            body += stack(log.threads[crashed].frames)
        }
        if !log.lastException.isEmpty {
            body += "<h2>Last Exception Backtrace <span class=count>\(log.lastException.count) frames</span></h2>"
            body += stack(log.lastException)
        }

        body += aboutCard(log)

        let others = log.threads.filter { $0.number != log.crashedThread }
        if !others.isEmpty {
            body += "<details><summary><h2>Other Threads <span class=count>\(others.count)</span></h2></summary>"
            for thread in others.prefix(500) {
                body += "<details class=thread><summary>\(R.escape(threadTitle(thread)))"
                body += " <span class=count>\(thread.frames.count) frames</span></summary>\(stack(thread.frames))</details>"
            }
            body += "</details>"
        }
        if !log.images.isEmpty {
            body += "<details><summary><h2>Libraries Loaded <span class=count>\(log.images.count)</span></h2></summary>"
            body += "<table class=summary><tr><th>Name</th><th>Version</th><th>Address</th><th>Path</th></tr>"
            for image in log.images.prefix(3000) {
                body += "<tr><td\(image.own ? " class=own" : "")>\(R.escape(image.name))"
                if let identifier = image.identifier { body += "<br><span class=dim>\(R.escape(identifier))</span>" }
                body += "</td><td>\(R.escape(image.version ?? ""))</td>"
                let end = image.base.addingReportingOverflow(image.size)
                body += "<td><code>\(image.base == 0 ? "" : hex(image.base) + (end.overflow ? "" : "–" + hex(end.partialValue)))</code></td>"
                body += "<td><code>\(R.escape(image.path ?? ""))</code></td></tr>"
            }
            body += "</table></details>"
        }
        return KeyStoreReport.page(title: name, body: R.style + style + body)
    }

    static func html(failure: Error, url: URL, size: Int) -> String {
        R.html(failure: failure, kind: "Diagnostic report", name: url.lastPathComponent,
               path: url.deletingLastPathComponent().path, size: size)
    }

    private static func aboutCard(_ log: CrashLog) -> String {
        var rows = ""
        if let identifier = log.identifier, !identifier.isEmpty { rows += R.row("Identifier", "<code>\(R.escape(identifier))</code>") }
        if let path = log.path { rows += R.row("Program", "<code>\(R.escape(path))</code>") }
        if let team = log.team { rows += R.row("Team", "<code>\(R.escape(team))</code>") }
        if let parent = log.parent { rows += R.row("Started by", R.escape(parent)) }
        if let responsible = log.responsible { rows += R.row("On behalf of", R.escape(responsible)) }
        if let time = log.captureTime { rows += R.row("When", R.escape(time)) }
        if let launch = log.launchTime { rows += R.row("Started", R.escape(launch)) }
        if let system = log.system { rows += R.row("System", R.escape(system)) }
        var machine = R.escape([log.hardware, log.processor].compactMap { $0 }.joined(separator: ", "))
        if log.translated { machine += " <span class=soon>— run translated by Rosetta</span>" }
        if !machine.isEmpty { rows += R.row("Mac", machine) }
        if let uptime = log.uptime, uptime >= 0 {
            rows += R.row("Mac up for", R.escape(Duration.seconds(uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide))))
        }
        if !log.isCrash {
            for (key, value) in log.header where !["app_name", "name", "app_version", "build_version", "timestamp", "os_version", "bundleID"].contains(key) {
                rows += R.row(key, R.escape(value))
            }
        }
        return rows.isEmpty ? "" : "<div class=card><div class=head><b>About</b></div><div class=cert>\(rows)</div></div>"
    }

    private static func threadTitle(_ thread: CrashLog.Thread) -> String {
        var title = "Thread \(thread.number)"
        if let name = thread.name, !name.isEmpty { title += ": \(name)" }
        if let queue = thread.queue, !queue.isEmpty { title += " — queue \(queue)" }
        return title
    }

    private static func stack(_ frames: [CrashLog.Frame]) -> String {
        guard !frames.isEmpty else { return "<p class=dim>No frames recorded.</p>" }
        var out = "<table class=\"summary stack\">"
        for (index, frame) in frames.prefix(512).enumerated() {
            out += "<tr\(frame.own ? " class=own" : "")><td class=n>\(index)</td><td class=image>\(R.escape(frame.image))</td><td>"
            if let symbol = frame.symbol {
                out += "<code>\(R.escape(String(symbol.prefix(2000))))</code>"
                if let offset = frame.offset, offset > 0 { out += " <span class=dim>+ \(offset)</span>" }
            } else if let address = frame.address {
                out += "<code class=dim>\(hex(address))</code>"
            }
            if frame.inline { out += " <span class=dim>(inlined)</span>" }
            if let file = frame.file {
                out += "<br><span class=dim>\(R.escape((file as NSString).lastPathComponent))"
                if let line = frame.line { out += ":\(line)" }
                out += "</span>"
            }
            out += "</td></tr>"
        }
        if frames.count > 512 { out += "<tr><td></td><td colspan=2 class=dim>and \(frames.count - 512) more</td></tr>" }
        return out + "</table>"
    }

    private static func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }

    static let style = """
        <style>
        .version { color: var(--dim); font-weight: 400; }
        .why { margin: 4px 10px 8px; }
        .stack td { vertical-align: top; }
        .stack .n { color: var(--dim); width: 2em; text-align: right; }
        .stack .image { width: 26%; color: var(--dim); }
        .stack tr.own td, td.own { font-weight: 600; }
        .stack tr.own .image { color: var(--kind); }
        details.thread { margin-left: 14px; }
        </style>
        """
}
