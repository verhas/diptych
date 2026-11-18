import Foundation

/// An installer package as a page: what it installs and where, who signed
/// it, what it asks of the Mac, and -- the question before installing -- the
/// scripts it runs, in full.
nonisolated enum PackageReport {

    typealias R = ExecutableReport

    static func html(for package: InstallerPackage, size: Int64) -> String {
        let name = package.url.lastPathComponent
        var body = "<h1>\(R.escape(package.title ?? name))"
        if let version = package.version { body += " <span class=version>\(R.escape(version))</span>" }
        body += "</h1>"
        let files = package.components.reduce(0) { $0 + ($1.numberOfFiles ?? $1.files.filter { $0.kind != .directory }.count) }
        let installed = package.components.reduce(0) { $0 + ($1.installKBytes ?? 0) }
        var lead = package.kind.rawValue + ", " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        if installed > 0 {
            lead += "; installs \(ByteCountFormatter.string(fromByteCount: Int64(installed) * 1024, countStyle: .file))"
            if files > 0 { lead += " in \(files.formatted()) file\(files == 1 ? "" : "s")" }
        }
        body += "<p class=lead>\(R.escape(lead))</p><p class=meta>\(R.escape(package.url.path))</p>"
        body += notes(package)

        // About.
        body += "<div class=card><div class=head><b>About</b></div><div class=cert>"
        if package.title != nil, package.title != name { body += R.row("File", R.escape(name)) }
        if let identifier = package.identifier { body += R.row("Identifier", "<code>\(R.escape(identifier))</code>") }
        if let version = package.version { body += R.row("Version", R.escape(version)) }
        if let created = package.created { body += R.row("Made", R.escape(created.formatted(date: .long, time: .shortened))) }
        var system = ""
        if let minimum = package.minimumSystem { system = "macOS \(minimum) or later" }
        if let maximum = package.maximumSystem { system += (system.isEmpty ? "macOS before " : ", before ") + maximum }
        if !system.isEmpty { body += R.row("Runs on", R.escape(system)) }
        if !package.architectures.isEmpty {
            let names = package.architectures.map { MachOFile.processor($0, platform: "macOS") }
            body += R.row("Processors", R.escape(R.list(R.unique(names))))
        }
        var target: [String] = []
        if package.startupDiskOnly { target.append("the startup disk only") }
        if package.userHomeAllowed { target.append("may install in the user's home folder instead") }
        if !target.isEmpty { body += R.row("Installs on", R.escape(target.joined(separator: "; "))) }
        var checks: [String] = []
        if package.installationCheck { checks.append("whether this Mac may install it") }
        if package.volumeCheck { checks.append("which disks it may go on") }
        if !checks.isEmpty { body += R.row("Checks first", R.escape(R.list(checks)) + " <span class=dim>— by the JavaScript below</span>") }
        let restarts = R.unique((package.components.compactMap(\.restart) + package.conclusions).map(restartText))
        if !restarts.isEmpty { body += R.row("Afterwards", R.escape(restarts.joined(separator: ", "))) }
        if !package.texts.isEmpty {
            let shown = R.unique(package.texts.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension })
            body += R.row("Shows", R.escape(R.list(shown)))
        }
        body += "</div></div>"

        // Signature.
        body += "<div class=card><div class=head><b>Signature</b></div><div class=cert>"
        body += signatureRows(package)
        body += "</div></div>"

        body += scripts(package)

        if let javaScript = package.javaScript {
            body += "<details><summary><h2>Installer JavaScript <span class=count>\(javaScript.split(separator: "\n").count) lines</span></h2></summary>"
            body += "<p class=dim>Run by Installer before installing, to decide what may be installed; it cannot change the Mac.</p>"
            body += "<pre class=source>\(R.source(javaScript))</pre></details>"
        }

        let notable = package.notable()
        if !notable.isEmpty {
            body += "<h2>Worth Knowing <span class=count>\(notable.count)</span></h2><table class=summary>"
            body += notable.map { "<tr><td><code>\(R.escape($0.path))</code></td><td>\(R.escape($0.why))</td></tr>" }.joined()
            body += "</table>"
        }

        let places = package.destinations()
        if !places.isEmpty {
            body += "<h2>Installs Into <span class=count>\(places.count)</span></h2><table class=summary>"
            body += "<tr><th>Where</th><th>Files</th><th>Size</th></tr>"
            for place in places.prefix(300) {
                body += "<tr><td><code>\(R.escape(place.path))</code></td><td>\(place.files.formatted())</td>"
                body += "<td>\(R.tableSize(place.bytes))</td></tr>"
            }
            body += "</table>"
        }

        if package.components.count > 1 || package.kind == .product {
            body += "<h2>Components <span class=count>\(package.components.count)</span></h2><table class=summary>"
            body += "<tr><th>Package</th><th>Version</th><th>Where</th><th>Size</th></tr>"
            for component in package.components {
                body += "<tr><td><code>\(R.escape(component.identifier ?? component.name))</code>"
                if !component.hasPayload { body += "<br><span class=dim>no files, scripts only</span>" }
                body += "</td><td>\(R.escape(component.version ?? ""))</td>"
                body += "<td><code>\(R.escape(component.installLocation ?? ""))</code></td>"
                body += "<td>\(component.installKBytes.map { R.tableSize(UInt64($0) * 1024) } ?? "")</td></tr>"
            }
            body += "</table>"
        }
        let visible = package.choices.filter { $0.visible && !$0.packages.isEmpty }
        if visible.count > 1 {
            body += "<h2>Choices <span class=count>\(visible.count)</span></h2><table class=summary>"
            body += visible.map { "<tr><td>\(R.escape($0.title ?? $0.id))</td><td class=dim>\(R.escape($0.packages.joined(separator: ", ")))</td></tr>" }.joined()
            body += "</table>"
        }
        let bundles = package.components.flatMap(\.bundles)
        if !bundles.isEmpty {
            body += "<h2>Applications and Bundles <span class=count>\(bundles.count)</span></h2><table class=summary>"
            for bundle in bundles.prefix(200) {
                body += "<tr><td><code>\(R.escape(bundle.path.hasPrefix("./") ? String(bundle.path.dropFirst(2)) : bundle.path))</code>"
                if let identifier = bundle.identifier { body += "<br><span class=dim>\(R.escape(identifier))</span>" }
                body += "</td><td>\(R.escape(bundle.version ?? ""))</td></tr>"
            }
            body += "</table>"
        }

        body += fileList(package)
        return KeyStoreReport.page(title: name, body: R.style + extraStyle + body)
    }

    static func html(failure: Error, url: URL, size: Int64) -> String {
        R.html(failure: failure, kind: "Installer package", name: url.lastPathComponent,
               path: url.deletingLastPathComponent().path, size: Int(clamping: size))
    }

    static let extraStyle = """
        <style>
        .version { color: var(--dim); font-weight: 400; }
        h3 { font-size: 12px; margin: 12px 0 2px; }
        </style>
        """

    private static func restartText(_ action: String) -> String {
        switch action.lowercased() {
        case "restart", "requirerestart": "restarts the Mac"
        case "shutdown", "requireshutdown": "shuts the Mac down"
        case "logout", "requirelogout": "logs out"
        default: action
        }
    }

    private static func notes(_ package: InstallerPackage) -> String {
        var out = ""
        if package.signature?.intact == false {
            out += "<p class=warn><span class=bad>It changed after it was signed.</span> "
                + "\(R.escape(package.signature?.problem ?? "")) Installer refuses it.</p>"
        }
        out += package.problems.map { "<p class=warn>\(R.escape($0))</p>" }.joined()
        if package.signature == nil, package.kind != .bundle, package.kind != .metapackage {
            out += "<p class=note>Not signed: when downloaded, macOS will not open it with a double-click.</p>"
        }
        if package.runsScripts {
            let root = package.components.contains { $0.runsAsRoot && $0.scripts.contains(where: \.isHook) }
            out += "<p class=note>It runs scripts while installing\(root ? ", as root" : ""): they are shown below.</p>"
        }
        if package.installsNothing, package.runsScripts {
            out += "<p class=note>It installs no files; all it does is run its scripts.</p>"
        }
        if package.kind == .bundle || package.kind == .metapackage {
            out += "<p class=note>An old form of package: current macOS versions install only flat packages.</p>"
        }
        return out
    }

    private static func signatureRows(_ package: InstallerPackage) -> String {
        guard let signature = package.signature else {
            return R.row("Signature", package.kind == .bundle || package.kind == .metapackage
                         ? "<span class=dim>none: bundle packages were not signed</span>" : "<span class=soon>none</span>")
        }
        var out = ""
        if let signer = signature.signer {
            let name = X509.shortName(signer.subject)
            var who = R.escape(name)
            if name.hasPrefix("Developer ID Installer") { who += " <span class=dim>— Developer ID, for distribution outside the App Store</span>" }
            else if name.hasPrefix("3rd Party Mac Developer Installer") || name.hasPrefix("Mac Installer Distribution") {
                who += " <span class=dim>— for the App Store</span>"
            } else if name.hasPrefix("Software Update") || name.hasPrefix("Apple Software") { who += " <span class=dim>— Apple</span>" }
            out += R.row("Signed by", who)
            var chain: [String] = [], current = signer
            while chain.count < 8, !current.isSelfIssued,
                  let issuer = signature.certificates.first(where: { $0.subjectBytes == current.issuerBytes }) {
                chain.append(X509.shortName(issuer.subject))
                current = issuer
            }
            if !chain.isEmpty { out += R.row("Issued by", R.escape(chain.joined(separator: " ← "))) }
            if signer.isExpired() {
                out += R.row("Certificate", "expired \(R.escape(signer.notAfter.formatted(date: .long, time: .omitted)))"
                             + (signature.signedAt != nil ? " <span class=dim>— signed with a timestamp while it was valid</span>"
                                : " <span class=soon>— and no timestamp: Installer refuses it</span>"))
            }
        } else {
            out += R.row("Signed by", "<span class=dim>no certificate in it</span>")
        }
        if let date = signature.signedAt { out += R.row("Signed at", R.escape(date.formatted(date: .long, time: .shortened))) }
        let check: String = switch signature.intact {
        case .some(true): "<span class=good>intact</span> <span class=dim>— the table of contents hashes as signed, and the signature verifies</span>"
        case .some(false): "<span class=bad>broken</span> — \(R.escape(R.lowercasedFirst(signature.problem ?? "")))"
        case .none: "<span class=dim>not checked\(signature.problem.map { ": " + R.escape(R.lowercasedFirst($0)) } ?? "")</span>"
        }
        out += R.row("Seal", check)
        out += R.row("Notarization", package.stapled
                     ? "<span class=good>ticket stapled</span> <span class=dim>— Gatekeeper need not ask Apple</span>"
                     : "no ticket stapled <span class=dim>— Gatekeeper asks Apple online, the first time</span>")
        return out
    }

    private static func scripts(_ package: InstallerPackage) -> String {
        let all = package.components.filter { !$0.scripts.isEmpty }
        guard !all.isEmpty else { return "" }
        let count = all.reduce(0) { $0 + $1.scripts.count }
        var out = "<h2>Scripts <span class=count>\(count)</span></h2>"
        for component in all {
            if all.count > 1 || package.kind == .product {
                out += "<h3>\(R.escape(component.identifier ?? component.name))\(component.runsAsRoot ? " <span class=dim>— as root</span>" : "")</h3>"
            }
            for script in component.scripts {
                var title = "<code>\(R.escape(script.name))</code>"
                if script.isHook { title += " <span class=dim>— \(R.escape(hookText(script.name)))</span>" }
                else { title += " <span class=dim>— used by the scripts</span>" }
                let open = script.isHook ? " open" : ""
                if let text = script.text {
                    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
                    out += "<details\(open)><summary>\(title) <span class=count>\(lines) lines</span></summary>"
                    out += "<pre class=source>\(R.source(text))</pre>"
                    if script.size > InstallerPackage.shownScript {
                        out += "<p class=dim>First \(R.bytes(InstallerPackage.shownScript)) of \(R.bytes(script.size)) shown.</p>"
                    }
                    out += "</details>"
                } else {
                    out += "<p>\(title) <span class=count>\(R.bytes(script.size))</span> "
                        + (script.isProgram ? "<span class=soon>a compiled program, not readable as a script</span>"
                           : "<span class=dim>binary data</span>") + "</p>"
                }
            }
        }
        return out
    }

    private static func hookText(_ name: String) -> String {
        switch name {
        case "preinstall", "preflight": "runs before the files are installed"
        case "postinstall", "postflight": "runs after the files are installed"
        case "preupgrade": "runs before, when upgrading"
        case "postupgrade": "runs after, when upgrading"
        case "InstallationCheck": "decides whether it may be installed"
        case "VolumeCheck": "decides which disks it may go on"
        default: "run by Installer"
        }
    }

    private static func fileList(_ package: InstallerPackage) -> String {
        var out = ""
        for component in package.components {
            if let problem = component.filesUnread {
                out += "<p class=dim>\(R.escape(component.identifier ?? component.name)): \(R.escape(problem))</p>"
                continue
            }
            let files = component.files.filter { $0.path != "." }
            guard !files.isEmpty else { continue }
            let title = package.components.count > 1 ? "Files, \(component.identifier ?? component.name)" : "Files"
            out += "<details><summary><h2>\(R.escape(title)) <span class=count>\(files.count.formatted())</span></h2></summary>"
            out += "<table class=summary><tr><th>Path</th><th>Size</th><th>Mode</th><th>Owner</th></tr>"
            for item in files.prefix(InstallerPackage.shownFiles) {
                let path = InstallerPackage.destination(of: item, in: component)
                let shown = item.kind == .directory ? path + "/" : path
                out += "<tr><td><code>\(R.escape(shown))</code>"
                if let link = item.link { out += " <span class=dim>→ \(R.escape(link))</span>" }
                out += "</td><td>\(item.kind == .file ? R.tableSize(item.size) : "")</td>"
                out += "<td><code>\(String(item.mode & 0o7777, radix: 8))</code></td>"
                out += "<td>\(item.user == 0 ? "root" : String(item.user)):\(item.group == 0 ? "wheel" : item.group == 80 ? "admin" : String(item.group))</td></tr>"
            }
            out += "</table>"
            if files.count > InstallerPackage.shownFiles {
                out += "<p class=dim>The first \(InstallerPackage.shownFiles.formatted()) shown.</p>"
            }
            out += "</details>"
        }
        return out
    }
}
