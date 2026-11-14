import Foundation

/// Finder's "Unix executable file" is four things -- a Mach-O program, an ELF
/// one, a script, or text marked executable -- and Quick Look shows a name and
/// a size for all of them. This page says which, what it needs to run, and
/// whether it would.
nonisolated enum ExecutableReport {

    /// Extensions executables and libraries come with; the contents decide.
    static let extensions: Set<String> = ["dylib", "so", "o", "out", "elf", "axf", "bin", "ko", "node", "bundle",
                                          "command", "tool", "exe", "dll", "sys", "ocx", "efi", "scr", "cpl", "drv",
                                          "mui", "winmd", "lib", "a", "obj", "bat", "cmd"]
    /// Scripts are shown up to this size; longer ones are cut.
    static let shownText = 512 * 1024

    struct Host {
        var appleSilicon: Bool
        var macOS: OperatingSystemVersion

        static var current: Host {
            #if arch(arm64)
            Host(appleSilicon: true, macOS: ProcessInfo.processInfo.operatingSystemVersion)
            #else
            Host(appleSilicon: false, macOS: ProcessInfo.processInfo.operatingSystemVersion)
            #endif
        }
    }

    // MARK: - Mach-O

    static func html(for file: MachOFile, name: String, path: String, size: Int, host: Host = .current) -> String {
        let images = file.slices.compactMap(\.image)
        let first = images.first
        let kind = first.map { MachOFile.kind($0.fileType) } ?? "Mach-O file"
        let processors = unique(file.slices.map { slice in
            MachOFile.processor(slice.architecture, platform: slice.image?.platform)
        })
        var lead = file.universal ? "Mach-O universal \(kind.lowercased())" : "Mach-O \(kind.lowercased())"
        lead += " for " + list(processors)
        if let platform = first?.platform, platform != "macOS" { lead += ", built for \(platform)" }
        lead += ", " + bytes(size)

        var body = "<h1>\(escape(name))</h1><p class=lead>\(escape(lead))</p><p class=meta>\(escape(path))</p>"
        body += notes(for: file, host: host).joined()

        for slice in file.slices {
            body += card(slice, universal: file.universal)
        }

        // Libraries and entitlements are the same in every slice, nearly always:
        // shown once then, per slice when not.
        let libraryLists = images.map(\.libraries)
        if let list = libraryLists.first, !list.isEmpty || images.contains(where: { $0.identity != nil }) {
            if libraryLists.allSatisfy({ $0 == list }) {
                body += libraries(list, rpaths: first?.rpaths ?? [], title: "Linked Libraries")
            } else {
                for image in images where !image.libraries.isEmpty {
                    body += libraries(image.libraries, rpaths: image.rpaths,
                                      title: "Linked Libraries, \(image.architecture)")
                }
            }
        }
        let entitlementSets = images.compactMap { $0.signature?.entitlementsXML }
        if let firstSet = entitlementSets.first, let signature = first?.signature {
            if entitlementSets.allSatisfy({ $0 == firstSet }) {
                body += entitlements(signature.entitlements, title: "Entitlements")
            } else {
                for image in images {
                    if let signature = image.signature, !signature.entitlements.isEmpty {
                        body += entitlements(signature.entitlements, title: "Entitlements, \(image.architecture)")
                    }
                }
            }
        }
        for image in images where !image.segments.isEmpty {
            body += segments(image, universal: file.universal)
        }
        return KeyStoreReport.page(title: name, body: style + body)
    }

    static func notes(for file: MachOFile, host: Host) -> [String] {
        var out: [String] = []
        let images = file.slices.compactMap(\.image)
        let runnable = images.filter { [2, 6, 8].contains($0.fileType) }
        for slice in file.slices where slice.image == nil {
            out.append("<p class=warn>The \(escape(slice.architecture)) part cannot be read: "
                       + "\(escape(slice.problem ?? "it is damaged."))</p>")
        }
        for image in runnable {
            let prefix = file.universal ? "The \(image.architecture) part: " : ""
            if let signature = image.signature, let mismatch = signature.mismatch, !mismatch.isEmpty {
                out.append("<p class=warn><span class=bad>The signature does not match.</span> "
                           + escape(prefix + mismatch + " macOS refuses to run it as it is."))
            } else if image.signature == nil, image.architecture.hasPrefix("arm64"),
                      image.platform == nil || image.platform == "macOS" {
                out.append("<p class=warn>" + escape(prefix + "It is not signed. Apple silicon Macs run only "
                           + "signed code; an ad hoc signature, codesign -s -, is enough to run it here.") + "</p>")
            }
        }
        let architectures = Set(images.map(\.architecture))
        let macOnly = images.allSatisfy { $0.platform == nil || $0.platform == "macOS" || $0.platform == "Mac Catalyst" }
        if !runnable.isEmpty, macOnly {
            if architectures.isSubset(of: ["i386", "ppc", "ppc64"]) {
                out.append("<p class=warn>" + escape(architectures.contains("i386")
                    ? "32-bit Intel only: macOS has not run 32-bit programs since Catalina (10.15)."
                    : "PowerPC only: no Mac has run it since Rosetta was removed in Lion (10.7).") + "</p>")
            } else if host.appleSilicon, !architectures.contains(where: { $0.hasPrefix("arm64") }),
                      architectures.contains(where: { $0.hasPrefix("x86_64") }) {
                out.append("<p class=note>Intel only: on this Mac it runs under Rosetta 2.</p>")
            } else if !host.appleSilicon, !architectures.contains(where: { $0.hasPrefix("x86_64") }),
                      architectures.contains(where: { $0.hasPrefix("arm64") }) {
                out.append("<p class=warn>Apple silicon only: this Intel Mac cannot run it.</p>")
            }
            if let needed = images.compactMap({ $0.platform == "macOS" ? $0.minimumOS : nil }).first,
               newer(needed, than: host.macOS) {
                out.append("<p class=warn>It needs macOS \(escape(needed)) or later; this Mac has "
                           + "\(escape(versionText(host.macOS))).</p>")
            }
        } else if !runnable.isEmpty, let platform = images.first?.platform {
            out.append("<p class=note>Built for \(escape(platform)), not for macOS.</p>")
        }
        if images.contains(where: \.encrypted) {
            out.append("<p class=note>Its code is encrypted (App Store FairPlay): only the device it was "
                       + "bought for reads it.</p>")
        }
        return out
    }

    static func card(_ slice: MachOFile.Slice, universal: Bool) -> String {
        guard let image = slice.image else { return "" }
        var out = "<div class=card><div class=head><b>\(escape(slice.architecture))</b>"
        out += "<span class=kind>\(escape(MachOFile.processor(slice.architecture, platform: image.platform)))</span></div>"
        out += "<div class=cert>"
        out += row("Kind", escape(MachOFile.kind(image.fileType)))
        if let identity = image.identity {
            out += row("Install name", "<code>\(escape(identity.path))</code>"
                       + " <span class=dim>version \(escape(identity.current)), compatible with \(escape(identity.compatible))</span>")
        }
        if let platform = image.platform {
            var runs = platform
            if let minimum = image.minimumOS { runs += " \(minimum) or later" }
            out += row("Runs on", escape(runs))
        }
        var built: [String] = []
        if let sdk = image.sdk, sdk != "0.0" { built.append("\(image.platform ?? "") SDK \(sdk)".trimmingCharacters(in: .whitespaces)) }
        built += image.tools
        if !built.isEmpty { out += row("Built with", escape(built.joined(separator: ", "))) }
        if let version = image.sourceVersion, version != "0.0" { out += row("Source version", escape(version)) }
        if let uuid = image.uuid { out += row("UUID", "<code>\(uuid)</code>") }
        if universal { out += row("In the file", escape("\(bytes(slice.size)) from byte \(slice.offset.formatted())")) }
        if image.flags & 0x20_0000 != 0, image.fileType == 2 { out += row("Loads at", "a random address (PIE)") }
        if image.flags & 0x2_0000 != 0 { out += row("Stack", "<span class=bad>executable</span>") }
        out += signatureRows(image.signature, architecture: image.architecture)
        out += "</div></div>"
        return out
    }

    static func signatureRows(_ signature: MachOFile.CodeSignature?, architecture: String) -> String {
        guard let signature else {
            return row("Signature", architecture.hasPrefix("arm64")
                       ? "<span class=soon>none</span>" : "none <span class=dim>— Intel Macs run unsigned code</span>")
        }
        var out = ""
        let who: String
        if let signer = signature.signer {
            let name = X509.shortName(signer.subject)
            who = escape(name) + (authority(of: name).map { " <span class=dim>— \(escape($0))</span>" } ?? "")
        } else if signature.isLinkerSigned {
            who = "ad hoc, by the linker <span class=dim>— no certificate: it runs, but Gatekeeper stops it "
                + "when it was downloaded</span>"
        } else if signature.isAdHoc {
            who = "ad hoc <span class=dim>— no certificate: it runs, but Gatekeeper stops it when it was "
                + "downloaded</span>"
        } else {
            who = "<span class=dim>no certificate in it</span>"
        }
        out += row("Signed by", who)
        if signature.certificates.count > 1, let signer = signature.signer {
            var chain: [String] = [], current = signer
            while chain.count < 8, !current.isSelfIssued,
                  let issuer = signature.certificates.first(where: { $0.subjectBytes == current.issuerBytes }) {
                chain.append(X509.shortName(issuer.subject))
                current = issuer
            }
            if !chain.isEmpty { out += row("Issued by", escape(chain.joined(separator: " ← "))) }
        }
        if let date = signature.signedAt {
            out += row("Signed at", escape(date.formatted(date: .long, time: .shortened)))
        }
        if !signature.identifier.isEmpty { out += row("Identifier", "<code>\(escape(signature.identifier))</code>") }
        if let team = signature.teamID { out += row("Team", escape(team)) }
        if signature.platformBinary { out += row("Platform", "part of the operating system") }
        out += row("Hardened runtime", signature.hasHardenedRuntime ? "yes" : "no")
        let pages = signature.pageSize == 0 ? "one page"
            : "\(signature.pages.formatted()) page\(signature.pages == 1 ? "" : "s") of "
              + ByteCountFormatter.string(fromByteCount: Int64(signature.pageSize), countStyle: .memory)
        let check: String = switch signature.isIntact {
        case .some(true): " <span class=good>— all match the contents</span>"
        case .some(false): " <span class=bad>— \(escape(lowercasedFirst(signature.mismatch ?? "")))</span>"
        case .none: " <span class=dim>— not checked here, it is too large</span>"
        }
        out += row("Hashes", escape("\(signature.hashName), \(pages)") + check)
        return out
    }

    /// What kind of certificate signed it, from the name Apple gives each kind.
    static func authority(of name: String) -> String? {
        if name.hasPrefix("Developer ID Application") { return "Developer ID, for distribution outside the App Store" }
        if name.hasPrefix("Apple Development") || name.hasPrefix("Mac Developer") || name.hasPrefix("iPhone Developer") {
            return "a development certificate, for the developer's own devices"
        }
        if name.hasPrefix("Apple Distribution") || name.hasPrefix("3rd Party Mac Developer")
            || name.hasPrefix("Apple Mac OS Application Signing") || name.hasPrefix("iPhone Distribution") {
            return "for the App Store"
        }
        if name == "Software Signing" || name.hasSuffix(" Software Signing")
            || name.hasPrefix("Apple iPhone OS Application Signing") { return "Apple" }
        return nil
    }

    static func libraries(_ libraries: [MachOFile.Library], rpaths: [String], title: String) -> String {
        guard !libraries.isEmpty else { return "" }
        var out = "<h2>\(escape(title)) <span class=count>\(libraries.count)</span></h2>"
        out += "<table class=summary><tr><th>Library</th><th>Version</th><th></th></tr>"
        for library in libraries {
            let system = library.path.hasPrefix("/usr/lib/") || library.path.hasPrefix("/System/")
            out += "<tr><td><code\(system ? " class=dim" : "")>\(escape(library.path))</code></td>"
            out += "<td>\(escape(library.current == "0.0" ? "" : library.current))</td>"
            out += "<td>\(escape(library.kind == .weak ? "weak, may be missing" : library.kind.rawValue))</td></tr>"
        }
        out += "</table>"
        if !rpaths.isEmpty {
            out += "<p class=dim>@rpath is searched in: " + rpaths.map { "<code>\(escape($0))</code>" }.joined(separator: ", ") + "</p>"
        }
        return out
    }

    static func entitlements(_ rows: [(key: String, value: String)], title: String) -> String {
        guard !rows.isEmpty else { return "" }
        var out = "<h2>\(escape(title)) <span class=count>\(rows.count)</span></h2><table class=summary>"
        for (key, value) in rows {
            let known = MachOFile.CodeSignature.entitlementNames[key]
            out += "<tr><td>\(known.map { escape($0) + "<br>" } ?? "")<code class=dim>\(escape(key))</code></td>"
            out += "<td>\(escape(value))</td></tr>"
        }
        return out + "</table>"
    }

    static func segments(_ image: MachOFile.Image, universal: Bool) -> String {
        let title = universal ? "Segments, \(image.architecture)" : "Segments"
        var out = "<details><summary><h2>\(escape(title)) <span class=count>\(image.segments.count)</span></h2></summary>"
        out += "<table class=summary><tr><th>Segment</th><th>In the file</th><th>In memory</th><th>Sections</th></tr>"
        for segment in image.segments {
            out += "<tr><td><code>\(escape(segment.name))</code></td><td>\(tableSize(segment.fileSize))</td>"
            out += "<td>\(tableSize(segment.memorySize))</td>"
            out += "<td><code class=dim>\(escape(segment.sections.joined(separator: " ")))</code></td></tr>"
        }
        return out + "</table></details>"
    }

    // MARK: - ELF

    static func html(for file: ELF, name: String, path: String, size: Int) -> String {
        let processor = "\(file.machine), \(file.is64 ? "64" : "32")-bit \(file.bigEndian ? "big" : "little")-endian"
        let lead = "ELF \(file.kind.lowercased()) for \(file.system), \(file.machine), \(bytes(size))"
        var body = "<h1>\(escape(name))</h1><p class=lead>\(escape(lead))</p><p class=meta>\(escape(path))</p>"
        if [2, 3].contains(file.fileType) {
            let note = "Built for \(file.system): macOS cannot run it. It runs on that system, "
                + "in a virtual machine or in a container."
            body += "<p class=note>\(escape(note))</p>"
        }
        if file.executableStack {
            body += "<p class=warn>Its stack is executable, which makes exploiting a bug in it easier; "
                + "modern systems refuse to load it as a library.</p>"
        }
        body += "<div class=card><div class=head><b>\(escape(file.kind))</b>"
        body += "<span class=kind>\(escape(file.system))</span></div><div class=cert>"
        body += row("Processor", escape(processor))
        if file.fileType == 2 || file.fileType == 3 { body += row("Linked", escape(file.linking)) }
        if let soname = file.soname { body += row("Library name", "<code>\(escape(soname))</code>") }
        let needs = file.versionsNeeded.map { family, version in
            (["GLIBC": "glibc", "GLIBCXX": "libstdc++", "CXXABI": "C++ ABI", "GCC": "libgcc"][family] ?? family)
                + " \(version)"
        }
        if !needs.isEmpty { body += row("Needs", escape(needs.joined(separator: ", ") + " or later")) }
        if let kernel = file.minimumKernel { body += row("Kernel", escape("\(kernel) or later")) }
        if !file.runpath.isEmpty || !file.rpath.isEmpty {
            body += row("Searches", (file.runpath + file.rpath).map { "<code>\(escape($0))</code>" }.joined(separator: ", "))
        }
        if let buildID = file.buildID { body += row("Build ID", "<code>\(buildID)</code>") }
        if file.entry != 0 { body += row("Starts at", "<code>0x\(String(file.entry, radix: 16))</code>") }
        if !file.sections.isEmpty {
            var symbols = file.sections.contains(".symtab") ? "kept" : "stripped"
            if file.sections.contains(".debug_info") { symbols += ", with debug information" }
            else if file.sections.contains(".gnu_debuglink") { symbols += ", debug information in a separate file" }
            body += row("Symbols", escape(symbols))
        }
        if file.sections.contains(".go.buildinfo") || file.noteOwners.contains("Go") { body += row("Written in", "Go") }
        else if file.sections.contains(where: { $0.hasPrefix(".rustc") }) { body += row("Written in", "Rust") }
        body += "</div></div>"

        if !file.needed.isEmpty {
            body += "<h2>Needed Libraries <span class=count>\(file.needed.count)</span></h2><table class=summary>"
            body += file.needed.map { "<tr><td><code>\(escape($0))</code></td></tr>" }.joined() + "</table>"
        }
        if !file.segments.isEmpty {
            body += "<details><summary><h2>Segments <span class=count>\(file.segments.count)</span></h2></summary>"
            body += "<table class=summary><tr><th>Type</th><th>Access</th><th>In the file</th><th>In memory</th><th>Address</th></tr>"
            for segment in file.segments {
                body += "<tr><td><code>\(escape(segment.type))</code></td><td><code>\(segment.flags)</code></td>"
                body += "<td>\(tableSize(segment.fileSize))</td><td>\(tableSize(segment.memorySize))</td>"
                body += "<td><code>0x\(String(segment.address, radix: 16))</code></td></tr>"
            }
            body += "</table></details>"
        }
        let named = file.sections.filter { !$0.isEmpty }
        if !named.isEmpty {
            body += "<details><summary><h2>Sections <span class=count>\(named.count)</span></h2></summary>"
            body += "<p><code class=dim>\(escape(named.joined(separator: " ")))</code></p></details>"
        }
        return KeyStoreReport.page(title: name, body: style + body)
    }

    // MARK: - Scripts

    static func html(for script: Script, name: String, path: String, size: Int) -> String {
        let what = script.line == nil ? "Text marked executable"
            : script.language.map { "\($0) script" } ?? "Script"
        var body = "<h1>\(escape(name))</h1><p class=lead>\(escape("\(what), \(bytes(size))"))</p>"
        body += "<p class=meta>\(escape(path))</p>"
        for problem in script.problems { body += "<p class=warn>\(escape(problem))</p>" }
        for note in script.notes { body += "<p class=note>\(escape(note))</p>" }
        if script.line != nil || script.here != nil {
            func verdict(_ outcome: Script.Outcome) -> String {
                switch outcome {
                case .runs(let with): "<span class=good>runs</span>, with <code>\(escape(with))</code>"
                case .fails(let why): "<span class=bad>does not run</span> \u{2014} \(escape(why))"
                case .depends(let how): "<span class=soon>runs</span> \(escape(how))"
                }
            }
            body += "<div class=card><div class=cert>"
            if let line = script.line { body += row("Line", "<code>#!\(escape(line))</code>") }
            if let here = script.here { body += row("On this Mac", verdict(here)) }
            if let linux = script.onLinux { body += row("On Linux", verdict(linux)) }
            var rest = script.arguments
            if let program = script.program,
               let index = rest.firstIndex(where: { $0 == program || $0 == "-S" + program }) {
                rest = Array(rest[(index + 1)...])
            }
            if !rest.isEmpty { body += row("Arguments", "<code>\(escape(rest.joined(separator: " ")))</code>") }
            body += row("Executable", script.executable ? "yes" : "no")
            body += "</div></div>"
        }
        body += source(script.text)
        return KeyStoreReport.page(title: name, body: style + body)
    }

    /// The text with line numbers, and its invisible characters named in
    /// frames as Text Edit shows them -- a byte-order mark among them.
    static func source(_ text: String) -> String {
        var text = text
        var cut = false
        if text.utf8.count > shownText {
            text = String(decoding: text.utf8.prefix(shownText), as: UTF8.self)
            cut = true
        }
        // "\r\n" is one Character, not split at "\n".
        let lines = (text.replacingOccurrences(of: "\r\n", with: "\n") as NSString).components(separatedBy: "\n")
        var out = "<pre class=source>"
        out += lines.enumerated().map { number, line in
            var shown = ""
            for scalar in line.unicodeScalars {
                if InvisibleCharacters.isInvisible(scalar.value) {
                    let label = InvisibleCharacters.label(scalar.value, atStart: number == 0 && shown.isEmpty)
                    shown += "<i class=inv>\(label)</i>"
                } else {
                    shown += escape(String(scalar))
                }
            }
            return "<span>\(shown)</span>"
        }.joined(separator: "\n")
        out += "</pre>"
        if cut { out += "<p class=dim>Only the first \(bytes(shownText)) are shown.</p>" }
        return out
    }

    // MARK: - Windows

    static func html(for file: PEFile, name: String, path: String, size: Int) -> String {
        var lead = file.kind
        if file.format == .pe { lead += " for \(PEFile.machine(file.machine))" }
        lead += ", " + bytes(size)
        var body = "<h1>\(escape(name))</h1><p class=lead>\(escape(lead))</p><p class=meta>\(escape(path))</p>"
        switch file.format {
        case .dos:
            body += "<p class=note>An MS-DOS program: macOS cannot run it; DOSBox can.</p>"
        case .newExecutable, .linearExecutable:
            body += "<p class=note>A program for 16-bit Windows or OS/2: macOS cannot run it, nor can 64-bit "
                + "Windows. It runs in an emulator such as DOSBox with Windows 3.1, or in a virtual machine.</p>"
        case .pe:
            if let runtime = file.dotNet {
                let version = runtime.isEmpty ? "" : " (runtime \(runtime))"
                let note = "A .NET assembly\(version): on a Mac, dotnet runs it if it was built for .NET Core "
                    + "or .NET 5 and later, and Mono runs most .NET Framework ones."
                body += "<p class=note>\(escape(note))</p>"
            } else if [10, 11, 12, 13].contains(file.subsystem) {
                body += "<p class=note>A UEFI program: it runs from a computer's firmware, before any operating "
                    + "system starts.</p>"
            } else {
                body += "<p class=note>Built for Windows: macOS cannot run it. It runs on Windows, in a virtual "
                    + "machine, or with Wine or CrossOver.</p>"
            }
        }
        if file.executionLevel == "requireAdministrator" {
            body += "<p class=warn>It asks for administrator rights every time it starts.</p>"
        }
        if file.signature?.intact == false {
            body += "<p class=warn><span class=bad>The signature does not match.</span> The file changed after "
                + "it was signed; Windows treats it as unsigned, or refuses it.</p>"
        }
        guard file.format == .pe else { return KeyStoreReport.page(title: name, body: style + body) }

        body += "<div class=card><div class=head><b>\(escape(file.kind))</b>"
        body += "<span class=kind>\(escape(PEFile.machine(file.machine)))</span></div><div class=cert>"
        body += row("Format", file.is64 ? "PE32+ (64-bit)" : "PE32 (32-bit)")
        body += row("Subsystem", escape(file.subsystemName))
        if let windows = file.windowsName, file.dotNet == nil || file.minimumWindows.major > 4 {
            body += row("Needs", escape("\(windows) or later"))
        }
        let strings = Dictionary(file.version.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        for (key, label) in [("FileDescription", "Description"), ("ProductName", "Product"),
                             ("CompanyName", "Company"), ("LegalCopyright", "Copyright"),
                             ("OriginalFilename", "Original name")] {
            if let value = strings[key] { body += row(label, escape(value)) }
        }
        if let version = strings["FileVersion"] ?? file.fixedVersion { body += row("Version", escape(version)) }
        if let product = strings["ProductVersion"], product != strings["FileVersion"] {
            body += row("Product version", escape(product))
        }
        if let level = file.executionLevel {
            let words = ["asInvoker": "as the user who starts it", "highestAvailable": "with the highest rights the user has",
                         "requireAdministrator": "as administrator"][level] ?? level
            body += row("Runs", escape(words))
        }
        if let runtime = file.dotNet, !runtime.isEmpty {
            var flags: [String] = []
            if file.dotNetFlags & 0x1 != 0 { flags.append("only .NET code") }
            if file.dotNetFlags & 0x2 != 0 { flags.append("32-bit only") }
            if file.dotNetFlags & 0x2_0000 != 0 { flags.append("prefers 32-bit") }
            body += row(".NET runtime", escape(([runtime] + flags).joined(separator: ", ")))
        }
        let protections = file.protections
        body += row("Protections", protections.isEmpty ? "<span class=soon>none</span>" : escape(protections.joined(separator: ", ")))
        // Reproducible builds put a hash in the time stamp, not a time.
        let stamp = Date(timeIntervalSince1970: TimeInterval(file.timeStamp))
        if file.timeStamp > 631_152_000, stamp < Date().addingTimeInterval(86_400 * 365) {
            body += row("Linked", escape(stamp.formatted(date: .long, time: .shortened)
                                         + (file.linker.map { ", linker \($0)" } ?? "")))
        } else if let linker = file.linker {
            body += row("Linker", escape(linker))
        }
        if let debug = file.debugFile, !debug.isEmpty { body += row("Debug symbols", "<code>\(escape(debug))</code>") }
        body += windowsSignatureRows(file.signature)
        body += "</div></div>"

        let direct = file.imports.filter { !$0.delayed }, delayed = file.imports.filter(\.delayed)
        if !file.imports.isEmpty {
            body += "<h2>Libraries It Uses <span class=count>\(file.imports.count)</span></h2><table class=summary>"
            body += "<tr><th>Library</th><th>Functions</th><th></th></tr>"
            for item in direct + delayed {
                body += "<tr><td><code>\(escape(item.library))</code></td><td>\(item.functions.formatted())</td>"
                body += "<td>\(item.delayed ? "loaded when first used" : "")</td></tr>"
            }
            body += "</table>"
        }
        if file.exportCount > 0 || !file.exports.isEmpty {
            let title = file.exportName.map { "Exports, as \($0)" } ?? "Exports"
            body += "<details\(file.exports.count <= 20 ? " open" : "")><summary><h2>\(escape(title)) "
            body += "<span class=count>\(max(file.exportCount, file.exports.count).formatted())</span></h2></summary>"
            body += "<p><code class=dim>\(escape(file.exports.joined(separator: " ")))</code></p></details>"
        }
        if !file.sections.isEmpty {
            body += "<details><summary><h2>Sections <span class=count>\(file.sections.count)</span></h2></summary>"
            body += "<table class=summary><tr><th>Section</th><th>In the file</th><th>In memory</th><th>Access</th></tr>"
            for section in file.sections {
                let flags = section.characteristics
                let access = (flags & 0x4000_0000 != 0 ? "r" : "-") + (flags & 0x8000_0000 != 0 ? "w" : "-")
                    + (flags & 0x2000_0000 != 0 ? "x" : "-")
                body += "<tr><td><code>\(escape(section.name))</code></td><td>\(tableSize(UInt64(section.fileSize)))</td>"
                body += "<td>\(tableSize(UInt64(section.memorySize)))</td><td><code>\(access)</code></td></tr>"
            }
            body += "</table></details>"
        }
        return KeyStoreReport.page(title: name, body: style + body)
    }

    static func windowsSignatureRows(_ signature: PEFile.Signature?) -> String {
        guard let signature else { return row("Signature", "<span class=soon>none</span>") }
        var out = ""
        if let signer = signature.signer {
            out += row("Signed by", escape(X509.shortName(signer.subject)))
            var chain: [String] = [], current = signer
            while chain.count < 8, !current.isSelfIssued,
                  let issuer = signature.certificates.first(where: { $0.subjectBytes == current.issuerBytes }) {
                chain.append(X509.shortName(issuer.subject))
                current = issuer
            }
            if !chain.isEmpty { out += row("Issued by", escape(chain.joined(separator: " ← "))) }
            else if !signer.isSelfIssued { out += row("Issued by", escape(X509.shortName(signer.issuer))) }
        } else {
            out += row("Signed by", "<span class=dim>no certificate in it</span>")
        }
        if let date = signature.signedAt { out += row("Signed at", escape(date.formatted(date: .long, time: .shortened))) }
        let check: String = switch signature.intact {
        case .some(true): "<span class=good>the file matches it</span>"
        case .some(false): "<span class=bad>the file changed after signing</span>"
        case .none: "<span class=dim>not checked</span>"
        }
        out += row("Hash", escape(signature.digestName ?? "unknown") + " \u{2014} " + check)
        return out
    }

    static func html(for archive: ArArchive, name: String, path: String, size: Int) -> String {
        var lead = archive.kind
        if archive.importedFrom.count == 1 { lead += " for \(archive.importedFrom[0].library)" }
        lead += ", " + bytes(size)
        var body = "<h1>\(escape(name))</h1><p class=lead>\(escape(lead))</p><p class=meta>\(escape(path))</p>"
        if !archive.importedFrom.isEmpty {
            body += "<p class=note>An import library holds no code: it lets a program be linked against the DLL "
                + "it names, which must be there when the program runs.</p>"
        }
        body += "<div class=card><div class=cert>"
        body += row("Members", archive.members.count.formatted())
        if archive.symbols > 0 { body += row("Symbols", archive.symbols.formatted()) }
        if !archive.architectures.isEmpty, archive.importedFrom.isEmpty {
            body += row("Object code", escape(archive.architectures.joined(separator: ", ")))
        }
        if archive.thin { body += row("Thin", "the members are separate files, named here") }
        body += "</div></div>"
        if !archive.importedFrom.isEmpty {
            body += "<h2>Imports From <span class=count>\(archive.importedFrom.count)</span></h2><table class=summary>"
            body += "<tr><th>Library</th><th>Functions</th></tr>"
            body += archive.importedFrom.map { "<tr><td><code>\(escape($0.library))</code></td><td>\($0.functions.formatted())</td></tr>" }.joined()
            body += "</table>"
        }
        let dlls = Set(archive.importedFrom.map(\.library))
        let objects = archive.members.filter { $0.kind != "import record" && !dlls.contains($0.name) }
        if !objects.isEmpty {
            body += "<details\(objects.count <= 20 ? " open" : "")><summary><h2>Members "
            body += "<span class=count>\(objects.count.formatted())</span></h2></summary><table class=summary>"
            body += "<tr><th>Name</th><th>Kind</th><th>Size</th></tr>"
            for member in objects.prefix(500) {
                body += "<tr><td><code>\(escape(member.name))</code></td><td>\(escape(member.kind))</td>"
                body += "<td>\(tableSize(UInt64(max(member.size, 0))))</td></tr>"
            }
            body += "</table></details>"
        }
        return KeyStoreReport.page(title: name, body: style + body)
    }

    static func html(objectFile data: Data, machine: UInt16, name: String, path: String) -> String {
        let reader = BinaryReader(data)
        let count = Int((try? reader.u16(2)) ?? 0)
        let sections = (0..<count).map { reader.string(20 + $0 * 40, limit: 8) }
        var body = "<h1>\(escape(name))</h1><p class=lead>\(escape("Windows object file for \(PEFile.machine(machine)), \(bytes(data.count))"))</p>"
        body += "<p class=meta>\(escape(path))</p><p class=note>Compiled code not linked yet: the linker makes a "
            + "program or a DLL of it.</p><div class=card><div class=cert>"
        body += row("Sections", "<code>\(escape(sections.joined(separator: " ")))</code>")
        body += row("Symbols", ((try? reader.u32(12)).map { Int($0).formatted() }) ?? "\u{2014}")
        body += "</div></div>"
        return KeyStoreReport.page(title: name, body: style + body)
    }

    static func html(for batch: BatchFile, name: String, path: String, size: Int) -> String {
        var body = "<h1>\(escape(name))</h1><p class=lead>\(escape("Windows batch file, \(bytes(size))"))</p>"
        body += "<p class=meta>\(escape(path))</p>"
        for problem in batch.problems { body += "<p class=warn>\(escape(problem))</p>" }
        for note in batch.notes { body += "<p class=note>\(escape(note))</p>" }
        body += "<div class=card><div class=cert>"
        body += row("On this Mac", "<span class=bad>does not run</span> \u{2014} macOS has no cmd.exe; Wine runs it")
        body += row("On Windows", batch.problems.isEmpty ? "<span class=good>runs</span>, with <code>cmd.exe</code>"
                    : "<span class=soon>runs</span>, with <code>cmd.exe</code>, not as meant \u{2014} see above")
        if batch.labels > 0 { body += row("Labels", batch.labels.formatted()) }
        body += "</div></div>"
        body += source(batch.text)
        return KeyStoreReport.page(title: name, body: style + body)
    }

    // MARK: - Failure

    static func html(failure: Error, kind: String, name: String, path: String, size: Int) -> String {
        KeyStoreReport.page(title: name, body: "<h1>\(escape(name))</h1><p class=lead>\(escape("\(kind), \(bytes(size))"))</p>"
                            + "<p class=meta>\(escape(path))</p><p class=warn>It cannot be read: "
                            + "\(escape(String(describing: failure)))</p>")
    }

    // MARK: - Pieces

    static let style = """
        <style>
        h2 { font-size: 13px; margin: 16px 0 4px; display: inline-block; }
        .count { color: var(--dim); font-weight: 400; font-size: 11px; margin-left: 4px; }
        .row { grid-template-columns: 120px 1fr; }
        details { display: block; margin-top: 4px; }
        summary { list-style: none; cursor: default; }
        summary::-webkit-details-marker { display: none; }
        summary::before { content: "\\25B8"; color: var(--dim); display: inline-block; width: 14px; }
        details[open] > summary::before { content: "\\25BE"; }
        pre.source { font: 11px ui-monospace, Menlo, monospace; background: var(--panel); border-radius: 6px;
                     padding: 8px 10px 8px 0; margin: 6px 0; overflow-x: auto; counter-reset: line; }
        pre.source > span { counter-increment: line; }
        .inv { font-style: normal; font-size: 9px; border: 1px solid #e08a00; border-radius: 3px;
               padding: 0 2px; margin: 0 1px; color: var(--dim); background: rgba(224,138,0,.12); }
        pre.source > span::before { content: counter(line); display: inline-block; width: 4em; padding-right: 1em;
                                    text-align: right; color: var(--dim); }
        </style>
        """

    static func row(_ label: String, _ value: String) -> String {
        "<div class=row><span>\(escape(label))</span><span>\(value)</span></div>"
    }

    static func escape(_ text: String) -> String { KeyStoreReport.escape(text) }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func lowercasedFirst(_ text: String) -> String {
        text.prefix(1).lowercased() + text.dropFirst()
    }

    /// A size in a table, a dash for none.
    static func tableSize(_ count: UInt64) -> String {
        count == 0 ? "\u{2014}" : bytes(Int(clamping: count))
    }

    static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    static func list(_ parts: [String]) -> String {
        parts.count <= 1 ? parts.first ?? "" : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }

    static func newer(_ version: String, than host: OperatingSystemVersion) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) } + [0, 0, 0]
        return [parts[0], parts[1], parts[2]].lexicographicallyPrecedes([host.majorVersion, host.minorVersion, host.patchVersion]) == false
            && [parts[0], parts[1], parts[2]] != [host.majorVersion, host.minorVersion, host.patchVersion]
    }

    static func versionText(_ version: OperatingSystemVersion) -> String {
        version.patchVersion == 0 ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
