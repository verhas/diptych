import Foundation

/// A diagnostic report as macOS writes it, `.ips`: one line of JSON saying
/// what kind of report it is, then the report -- since macOS 12 a crash is
/// JSON too, before that text, as other kinds still are.
nonisolated struct CrashLog: Sendable {

    static let extensions: Set<String> = ["ips"]
    static let maximumSize = 32 * 1024 * 1024

    enum Problem: Error, CustomStringConvertible {
        case notAReport
        var description: String { "Its first line is not a diagnostic report's header." }
    }

    struct Frame: Sendable {
        var image: String
        var symbol: String?
        var offset: Int?
        var address: UInt64?
        var file: String?
        var line: Int?
        var inline = false
        /// In the program itself, rather than in the system's libraries.
        var own = false
    }

    struct Thread: Sendable {
        var number: Int
        var name: String?
        var queue: String?
        var crashed: Bool
        var frames: [Frame]
    }

    struct Image: Sendable {
        var name: String
        var path: String?
        var identifier: String?
        var version: String?
        var architecture: String?
        var uuid: String?
        var base: UInt64
        var size: UInt64
        var own: Bool
    }

    /// The header's `bug_type`: 309 a crash, 109 a crash in the old text form.
    var kind: String
    var header: [(key: String, value: String)] = []
    var process: String?
    var version: String?
    var build: String?
    var identifier: String?
    var path: String?
    var parent: String?
    var responsible: String?
    var captureTime: String?
    var launchTime: String?
    var system: String?
    var hardware: String?
    var processor: String?
    var translated = false
    var uptime: Int?
    var team: String?
    var exceptionType: String?
    var signal: String?
    var subtype: String?
    var codes: String?
    var exceptionMessage: String?
    var termination: String?
    var terminationNamespace: String?
    var terminationReasons: [String] = []
    var terminatedBy: String?
    /// "Application Specific Information": what a library said as it gave up.
    var applicationNotes: [String] = []
    var threads: [Thread] = []
    var lastException: [Frame] = []
    var images: [Image] = []
    var crashedThread: Int?
    /// A text report, or a JSON one that is not a crash, as it is.
    var text: String?

    var isCrash: Bool { !threads.isEmpty || exceptionType != nil }

    static func looksLikeReport(_ data: Data) -> Bool {
        guard let first = data.prefix(64 * 1024).split(separator: 0x0A, maxSplits: 1).first,
              let header = try? JSONSerialization.jsonObject(with: first) as? [String: Any] else { return false }
        return header["bug_type"] != nil || header["timestamp"] != nil
    }

    init(data: Data) throws {
        let lines = data.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = lines.first,
              let header = try? JSONSerialization.jsonObject(with: Data(first)) as? [String: Any] else {
            throw Problem.notAReport
        }
        kind = Self.string(header["bug_type"]) ?? ""
        for key in ["app_name", "name", "app_version", "build_version", "bundleID", "os_version", "timestamp",
                    "incident_id", "platform", "slice_uuid"] {
            if let value = Self.string(header[key]), !value.isEmpty { self.header.append((key, value)) }
        }
        process = Self.string(header["app_name"]) ?? Self.string(header["name"])
        version = Self.string(header["app_version"])
        build = Self.string(header["build_version"])
        identifier = Self.string(header["bundleID"])
        system = Self.string(header["os_version"])
        captureTime = Self.string(header["timestamp"])

        let rest = lines.count > 1 ? Data(lines[1]) : Data()
        if let body = try? JSONSerialization.jsonObject(with: rest) as? [String: Any], body["threads"] != nil || body["exception"] != nil {
            read(body)
        } else {
            text = String(decoding: rest, as: UTF8.self)
            if let object = try? JSONSerialization.jsonObject(with: rest),
               let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                text = String(decoding: pretty, as: UTF8.self)
            }
        }
    }

    // MARK: - The JSON crash report

    private mutating func read(_ body: [String: Any]) {
        process = Self.string(body["procName"]) ?? process
        path = Self.string(body["procPath"])
        if let bundle = body["bundleInfo"] as? [String: Any] {
            version = Self.string(bundle["CFBundleShortVersionString"]) ?? version
            build = Self.string(bundle["CFBundleVersion"]) ?? build
            identifier = Self.string(bundle["CFBundleIdentifier"]) ?? identifier
        }
        parent = Self.process(body["parentProc"], body["parentPid"])
        responsible = Self.process(body["responsibleProc"], body["responsiblePid"])
        if responsible?.hasPrefix(process ?? "\u{0}") == true { responsible = nil }
        captureTime = Self.string(body["captureTime"]) ?? captureTime
        launchTime = Self.string(body["procLaunch"])
        if let os = body["osVersion"] as? [String: Any], let train = Self.string(os["train"]) {
            system = train + (Self.string(os["build"]).map { " (\($0))" } ?? "")
        }
        hardware = Self.string(body["modelCode"])
        processor = Self.string(body["cpuType"])
        translated = body["translated"] as? Bool ?? false
        uptime = Self.int(body["uptime"])
        team = Self.string(body["codeSigningTeamID"]).flatMap { $0.isEmpty ? nil : $0 }

        if let exception = body["exception"] as? [String: Any] {
            exceptionType = Self.string(exception["type"])
            signal = Self.string(exception["signal"])
            subtype = Self.string(exception["subtype"])
            codes = Self.string(exception["codes"])
            exceptionMessage = Self.string(exception["message"])
        }
        if let ending = body["termination"] as? [String: Any] {
            termination = Self.string(ending["indicator"])
            terminationNamespace = Self.string(ending["namespace"])
            terminationReasons = (ending["reasons"] as? [Any])?.compactMap(Self.string) ?? []
            if let by = Self.string(ending["byProc"]), by != "exc handler" {
                terminatedBy = Self.process(by, ending["byPid"])
            }
        }
        if let notes = body["asi"] as? [String: Any] {
            for (library, lines) in notes.sorted(by: { $0.key < $1.key }) {
                for line in (lines as? [Any])?.compactMap(Self.string) ?? [Self.string(lines)].compactMap({ $0 }) {
                    applicationNotes.append("\(library): \(line)")
                }
            }
        }

        let ownFolder = path.map { Self.bundleFolder(of: $0) }
        for (index, entry) in ((body["usedImages"] as? [Any]) ?? []).prefix(20_000).enumerated() {
            guard let image = entry as? [String: Any] else {
                images.append(Image(name: "image \(index)", base: 0, size: 0, own: false))
                continue
            }
            let imagePath = Self.string(image["path"])
            let name = Self.string(image["name"]) ?? imagePath.map { ($0 as NSString).lastPathComponent } ?? "???"
            let own = imagePath.map { candidate in
                candidate == path || ownFolder.map { !$0.isEmpty && candidate.hasPrefix($0) } == true
            } ?? false
            images.append(Image(name: name, path: imagePath, identifier: Self.string(image["CFBundleIdentifier"]),
                                version: Self.string(image["CFBundleShortVersionString"]),
                                architecture: Self.string(image["arch"]), uuid: Self.string(image["uuid"]),
                                base: Self.unsigned(image["base"]) ?? 0, size: Self.unsigned(image["size"]) ?? 0, own: own))
        }
        for (number, entry) in ((body["threads"] as? [Any]) ?? []).prefix(5_000).enumerated() {
            guard let thread = entry as? [String: Any] else { continue }
            threads.append(Thread(number: number, name: Self.string(thread["name"]), queue: Self.string(thread["queue"]),
                                  crashed: thread["triggered"] as? Bool ?? false, frames: frames(thread["frames"])))
        }
        crashedThread = Self.int(body["faultingThread"]).flatMap { index in threads.indices.contains(index) ? index : nil }
            ?? threads.firstIndex(where: \.crashed)
        lastException = frames(body["lastExceptionBacktrace"])
    }

    private func frames(_ value: Any?) -> [Frame] {
        ((value as? [Any]) ?? []).prefix(2_000).compactMap { entry in
            guard let frame = entry as? [String: Any] else { return nil }
            let index = Self.int(frame["imageIndex"])
            let image = index.flatMap { images.indices.contains($0) ? images[$0] : nil }
            let offset = Self.unsigned(frame["imageOffset"])
            var address: UInt64?
            if let image, let offset {
                let (sum, overflow) = image.base.addingReportingOverflow(offset)
                address = overflow ? nil : sum
            }
            return Frame(image: image?.name ?? "???", symbol: Self.string(frame["symbol"]),
                         offset: Self.int(frame["symbolLocation"]), address: address,
                         file: Self.string(frame["sourceFile"]), line: Self.int(frame["sourceLine"]),
                         inline: frame["inline"] as? Bool ?? false, own: image?.own ?? false)
        }
    }

    /// What the crash means, in words, where the report's codes say enough.
    var explanation: String? {
        let top = crashedThread.map { threads[$0].frames.first?.symbol ?? "" } ?? ""
        if let failure = (crashedThread.map { threads[$0].frames.prefix(3).compactMap(\.symbol) } ?? [])
            .first(where: { $0.hasPrefix("Swift runtime failure: ") }) {
            let what = failure.dropFirst("Swift runtime failure: ".count)
            return "Swift stopped the program on purpose: \(what). The frame below it is the line that did it."
        }
        if top.contains("_assertionFailure") || top.contains("_fatalErrorMessage") {
            return "Swift stopped the program on purpose: a precondition, a fatalError, an index out of range or an unwrapped nil."
        }
        if top.contains("_dispatch_assert_queue_fail") {
            return "Code that must run on one thread, usually the main one, was called on another."
        }
        switch exceptionType {
        case "EXC_BAD_ACCESS":
            return "The program used memory it may not touch: a dangling pointer, a nil one, or a stack that ran out."
        case "EXC_BREAKPOINT":
            return "The program stopped itself on a trap: in Swift, a failed check such as an overflow or an unwrapped nil."
        case "EXC_BAD_INSTRUCTION":
            return "The processor met an instruction it could not run: on Intel, Swift's failed checks end this way."
        case "EXC_CRASH" where signal == "SIGABRT":
            return lastException.isEmpty ? "The program called abort(): a library or the program itself gave up."
                : "An Objective-C exception was not caught: its backtrace is below."
        case "EXC_CRASH" where signal == "SIGKILL":
            return "The system ended the program: \(terminationNamespace.map(Self.namespaceText) ?? "see the reason below")."
        case "EXC_GUARD":
            return "The program broke a rule guarding a resource, such as closing a file descriptor it does not own."
        case "EXC_RESOURCE":
            return "The program used more of a resource -- memory, processor time, disk writes -- than allowed."
        case "EXC_ARITHMETIC":
            return "An arithmetic fault, such as an integer divided by zero."
        default:
            return nil
        }
    }

    static func namespaceText(_ namespace: String) -> String {
        switch namespace {
        case "CODESIGNING": "its code signature is not valid"
        case "WATCHDOG": "it did not answer in time"
        case "JETSAM", "MEMORY": "the Mac ran short of memory"
        case "RUNNINGBOARD": "the system manages its lifetime and ended it"
        case "DYLD": "a library it needs could not be loaded"
        case "SPRINGBOARD", "FRONTBOARD": "the system's app manager ended it"
        default: namespace.lowercased()
        }
    }

    // MARK: - Reading loosely typed JSON

    static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    /// A JSON number -- not true or false, which bridge to NSNumber too, and
    /// not "is Bool", which a plain 0 or 1 also answers yes to.
    private static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }

    static func int(_ value: Any?) -> Int? {
        guard let number = number(value) else { return nil }
        let double = number.doubleValue
        guard double.isFinite, abs(double) < 9e15 else { return nil }
        return number.intValue
    }

    static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = number(value), number.doubleValue >= 0, number.doubleValue.isFinite else { return nil }
        return number.uint64Value
    }

    private static func process(_ name: Any?, _ pid: Any?) -> String? {
        guard let name = string(name) else { return nil }
        return int(pid).map { "\(name) [\($0)]" } ?? name
    }

    /// The `.app` (or other bundle) a program lies in: its own frameworks
    /// and plug-ins are the program's code too.
    private static func bundleFolder(of path: String) -> String {
        guard let range = path.range(of: ".app/Contents/") else { return "" }
        return String(path[..<range.upperBound])
    }
}
