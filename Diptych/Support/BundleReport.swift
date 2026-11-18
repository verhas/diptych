import Foundation

/// An application, or another bundle of code, as a page: what it is, what it
/// runs on, who signed it and whether it is still as signed, what it will
/// ask for, what is inside it, and where it came from. Quick Look shows only
/// its icon.
nonisolated enum BundleReport {

    typealias R = ExecutableReport

    /// The page; `seal` and `size` are nil while they are being worked out.
    static func html(for bundle: AppBundle, seal: AppBundle.Seal?, size: (bytes: Int64, files: Int)?,
                     icon: Data?, host: ExecutableReport.Host = .current) -> String {
        let images = bundle.executable?.slices.compactMap(\.image) ?? []
        let signature = bundle.signature

        var body = "<div class=title>"
        if let icon { body += "<img class=icon src=\"data:image/png;base64,\(icon.base64EncodedString())\">" }
        body += "<div><h1>\(R.escape(bundle.name))"
        if let version = bundle.version { body += " <span class=version>\(R.escape(version))</span>" }
        body += "</h1>"
        var lead = bundle.kind
        if let size {
            lead += ", " + ByteCountFormatter.string(fromByteCount: size.bytes, countStyle: .file)
                + ", \(size.files.formatted()) file\(size.files == 1 ? "" : "s")"
        } else {
            lead += ", counting its size\u{2026}"
        }
        body += "<p class=lead>\(R.escape(lead))</p><p class=meta>\(R.escape(bundle.url.path))</p></div></div>"

        body += notes(bundle, seal: seal, signature: signature, host: host)

        // About.
        body += "<div class=card><div class=head><b>About</b></div><div class=cert>"
        if let identifier = bundle.identifier { body += R.row("Identifier", "<code>\(R.escape(identifier))</code>") }
        if let version = bundle.version { body += R.row("Version", R.escape(version)) }
        if let build = bundle.build, build != bundle.version { body += R.row("Build", R.escape(build)) }
        if let point = bundle.extensionPoint { body += R.row("Extends", "<code>\(R.escape(point))</code>") }
        if let category = bundle.category { body += R.row("Category", R.escape(category)) }
        if let copyright = bundle.copyright { body += R.row("Copyright", R.escape(copyright)) }
        let minimum = bundle.minimumSystem
            ?? images.compactMap { $0.platform == "macOS" ? $0.minimumOS : nil }.first
        if let minimum { body += R.row("Runs on", R.escape("macOS \(minimum) or later")) }
        if let file = bundle.executable {
            let processors = R.unique(file.slices.map { MachOFile.processor($0.architecture, platform: $0.image?.platform) })
            body += R.row("Processors", R.escape(R.list(processors)))
        }
        if let built = bundle.builtWith { body += R.row("Built with", R.escape(built)) }
        if !bundle.technologies.isEmpty { body += R.row("Made with", R.escape(bundle.technologies.joined(separator: ", "))) }
        body += R.row("From", origin(bundle))
        body += "</div></div>"

        // Signature.
        body += "<div class=card><div class=head><b>Signature</b></div><div class=cert>"
        if let signature {
            body += R.signatureRows(signature, architecture: images.first?.architecture ?? "")
                .replacingOccurrences(of: "<div class=row><span>Hashes</span>", with: "<div class=row><span>Code pages</span>")
            let sandboxed = signature.entitlements.contains { $0.key == "com.apple.security.app-sandbox" && $0.value == "yes" }
            body += R.row("Sandbox", sandboxed ? "yes" : "no")
        } else if bundle.executable != nil {
            body += R.row("Signature", "<span class=soon>none</span>")
        } else {
            body += R.row("Signature", "<span class=dim>\(R.escape(bundle.executableProblem ?? "unknown"))</span>")
        }
        if signature?.certificates.isEmpty == false || bundle.stapled {
            body += R.row("Notarization", bundle.stapled
                          ? "<span class=good>ticket stapled</span> <span class=dim>— Gatekeeper need not ask Apple</span>"
                          : "no ticket stapled <span class=dim>— Gatekeeper asks Apple online, the first time</span>")
        }
        body += R.row("Seal", sealText(seal))
        body += "</div></div>"

        if case .broken(let changed, let missing, _)? = seal {
            body += "<h2>Not as Signed <span class=count>\(changed.count + missing.count)</span></h2><table class=summary>"
            body += changed.prefix(200).map { "<tr><td><code>\(R.escape($0))</code></td><td class=bad>changed</td></tr>" }.joined()
            body += missing.prefix(200).map { "<tr><td><code>\(R.escape($0))</code></td><td class=bad>missing</td></tr>" }.joined()
            body += "</table>"
        }

        if !bundle.permissions.isEmpty {
            body += "<h2>Asks For <span class=count>\(bundle.permissions.count)</span></h2><table class=summary>"
            body += bundle.permissions.map { "<tr><td>\(R.escape($0.what))</td><td class=dim>\u{201C}\(R.escape($0.reason))\u{201D}</td></tr>" }.joined()
            body += "</table>"
        }
        if let signature, !signature.entitlements.isEmpty {
            body += R.entitlements(signature.entitlements, title: "Entitlements")
        }
        let documents = bundle.documentTypes, schemes = bundle.urlSchemes
        if !documents.isEmpty || !schemes.isEmpty {
            body += "<h2>Opens <span class=count>\(documents.count + schemes.count)</span></h2><table class=summary>"
            body += documents.map { "<tr><td>\(R.escape($0))</td><td class=dim>documents</td></tr>" }.joined()
            body += schemes.map { "<tr><td><code>\(R.escape($0)):</code></td><td class=dim>links</td></tr>" }.joined()
            body += "</table>"
        }
        body += embedded(bundle, team: signature?.teamID)
        if !bundle.localizations.isEmpty {
            let names = bundle.localizations.map { code in
                Locale.current.localizedString(forIdentifier: code) ?? code
            }
            body += "<h2>Languages <span class=count>\(names.count)</span></h2>"
            body += "<p>\(R.escape(names.joined(separator: ", ")))</p>"
        }
        if let image = images.first, !image.libraries.isEmpty {
            body += "<details><summary>" + R.libraries(image.libraries, rpaths: image.rpaths, title: "Linked Libraries")
                .replacingOccurrences(of: "</h2>", with: "</h2></summary>") + "</details>"
        }
        return KeyStoreReport.page(title: bundle.url.lastPathComponent, body: R.style + extraStyle + body)
    }

    private static let extraStyle = """
        <style>
        .title { display: flex; gap: 14px; align-items: center; margin-bottom: 10px; }
        .icon { width: 64px; height: 64px; }
        .version { color: var(--dim); font-weight: 400; }
        </style>
        """

    private static func notes(_ bundle: AppBundle, seal: AppBundle.Seal?, signature: MachOFile.CodeSignature?,
                              host: ExecutableReport.Host) -> String {
        var out = ""
        if case .broken? = seal {
            out += "<p class=warn><span class=bad>It is not as it was signed.</span> Files in it changed or went "
                + "missing after signing, listed below; macOS refuses to open it, or says it is damaged.</p>"
        }
        if let file = bundle.executable {
            // The executable's own warnings, but not its signature's: the seal says that.
            out += R.notes(for: file, host: host).filter { !$0.contains("The signature does not match") }.joined()
        } else if let problem = bundle.executableProblem {
            out += "<p class=warn>\(R.escape(problem))</p>"
        }
        if bundle.translocated {
            out += "<p class=note>It runs from a random read-only place (App Translocation), because it was opened "
                + "where it was downloaded: move it to Applications and open it again.</p>"
        }
        if let quarantine = bundle.quarantine, !quarantine.opened, bundle.kind.hasSuffix("pplication") {
            out += "<p class=note>Downloaded and not opened yet: Gatekeeper checks it the first time it is opened.</p>"
        }
        if bundle.kind == "iPhone and iPad app" {
            out += "<p class=note>An iPhone or iPad app: it runs on a Mac with Apple silicon.</p>"
        }
        if bundle.kind == "Kernel extension" {
            out += "<p class=note>A kernel extension runs inside macOS itself; on Apple silicon it is allowed only "
                + "with reduced security, set in Recovery.</p>"
        }
        let foreign = bundle.embedded.filter { $0.signed && $0.team != nil && signature?.teamID != nil && $0.team != signature?.teamID }
        if !foreign.isEmpty {
            out += "<p class=note>\(foreign.count == 1 ? "One part is" : "\(foreign.count) parts are") signed by "
                + "another team than the app; usual for frameworks from others, worth a look otherwise.</p>"
        }
        return out
    }

    private static func origin(_ bundle: AppBundle) -> String {
        if bundle.fromAppStore { return "the Mac App Store" }
        var parts: [String] = []
        if let quarantine = bundle.quarantine {
            var text = "downloaded"
            if !quarantine.agent.isEmpty { text += " with \(quarantine.agent)" }
            if let date = quarantine.date { text += ", \(date.formatted(date: .long, time: .shortened))" }
            text += quarantine.opened ? "; opened since" : "; not opened yet"
            parts.append(R.escape(text))
        }
        if let source = bundle.whereFrom.first {
            parts.append("<code>\(R.escape(source))</code>")
        }
        return parts.isEmpty ? "<span class=dim>made here, copied, or installed \u{2014} not downloaded</span>"
            : parts.joined(separator: "<br>")
    }

    private static func sealText(_ seal: AppBundle.Seal?) -> String {
        switch seal {
        case nil: "<span class=dim>checking every file\u{2026}</span>"
        case .intact(let files)? where files == 0:
            "<span class=good>intact</span> <span class=dim>— nothing besides the program and its Info.plist is sealed</span>"
        case .intact(let files)?:
            "<span class=good>intact</span> <span class=dim>— \(files.formatted()) sealed file\(files == 1 ? "" : "s") match\(files == 1 ? "es" : "")</span>"
        case .broken(let changed, let missing, _)?:
            "<span class=bad>broken</span> — " + R.escape([changed.isEmpty ? nil : "\(changed.count) changed",
                                                           missing.isEmpty ? nil : "\(missing.count) missing"]
                .compactMap { $0 }.joined(separator: ", "))
        case .none?: "<span class=dim>none: its resources are not sealed</span>"
        case .unchecked(let why)?: "<span class=dim>not checked: \(R.escape(why))</span>"
        }
    }

    private static func embedded(_ bundle: AppBundle, team: String?) -> String {
        guard !bundle.embedded.isEmpty else { return "" }
        var out = ""
        var groups: [String] = []
        for item in bundle.embedded where !groups.contains(item.group) { groups.append(item.group) }
        for group in groups {
            let items = bundle.embedded.filter { $0.group == group }
            out += "<details\(items.count <= 12 ? " open" : "")><summary><h2>\(R.escape(group)) "
            out += "<span class=count>\(items.count)</span></h2></summary><table class=summary>"
            for item in items {
                let signer: String
                if item.name.hasSuffix(".plist") {
                    signer = ""
                } else if !item.signed {
                    signer = "<span class=soon>not signed</span>"
                } else if let other = item.team, other != team {
                    signer = "team \(R.escape(other))"
                } else {
                    signer = item.team == nil ? "<span class=dim>ad hoc or Apple</span>" : "<span class=dim>same team</span>"
                }
                out += "<tr><td><code>\(R.escape(item.name))</code>"
                if let identifier = item.identifier { out += "<br><span class=dim>\(R.escape(identifier))</span>" }
                out += "</td><td>\(R.escape(item.version ?? ""))</td><td>\(signer)</td></tr>"
            }
            out += "</table></details>"
        }
        return out
    }
}
