import Foundation

/// A `.jar`, `.war` or `.ear` as a page: what its manifest says -- the class
/// it runs, its module, its version -- who signed it and whether that still
/// holds, the Maven artifact it was built as, which Java its classes need,
/// and then what is in it, as for any archive.
nonisolated enum JarReport {

    typealias R = ExecutableReport

    static func html(for jar: JarArchive, listing: Listing.Result?, url: URL, size: Int64?,
                     now: Date = Date()) -> String {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        var body = "<h1>\(R.escape(name))</h1>"
        var lead = ext == "war" ? "Java web application" : ext == "ear" ? "Java enterprise application" : "Java archive"
        if jar.entryCount > 0 { lead += ", \(jar.entryCount.formatted()) entr\(jar.entryCount == 1 ? "y" : "ies")" }
        if let size { lead += ", " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
        body += "<p class=lead>\(R.escape(lead))</p><p class=meta>\(R.escape(url.path))</p>"

        if let trouble = jar.trouble { body += "<p class=warn>\(R.escape(trouble))</p>" }
        for signer in jar.signers {
            if signer.signatureValid == false {
                body += "<p class=warn>The signature of <code>\(R.escape(signer.name))</code> does not match what it signs: "
                    + "the archive was changed after it was signed, and Java refuses it.</p>"
            } else if signer.manifestDigest == false {
                body += "<p class=warn>The manifest is not the one <code>\(R.escape(signer.name))</code> signed: "
                    + "the archive was changed after it was signed.</p>"
            }
        }
        if jar.encryptedEntries > 0 {
            body += "<p class=note>\(jar.encryptedEntries.formatted()) entr\(jar.encryptedEntries == 1 ? "y is" : "ies are") encrypted "
                + "and \(jar.encryptedEntries == 1 ? "was" : "were") not read.</p>"
        }

        body += manifestCard(jar)
        if !jar.maven.isEmpty { body += mavenCard(jar) }
        if let module = jar.module { body += moduleCard(module, release: jar.moduleRelease) }
        if jar.classCount > 0 || !jar.releases.isEmpty { body += classesCard(jar) }
        if ext == "war" || jar.webXML || jar.webLibraries > 0 { body += webCard(jar) }
        if ext == "ear" || jar.applicationXML { body += enterpriseCard(jar) }
        body += signatureCard(jar, now: now)

        body += listingSection(listing)
        return KeyStoreReport.page(title: name, body: R.style + style + body)
    }

    // MARK: - Parts

    /// What a reader looks for first, in this order; the rest folded below.
    private static let known: [(String, String)] = [
        ("Main-Class", "Runs"), ("Launcher-Agent-Class", "Agent"), ("Premain-Class", "Agent"),
        ("Automatic-Module-Name", "Module name"), ("Multi-Release", "Multi-release"),
        ("Implementation-Title", "Title"), ("Implementation-Version", "Version"),
        ("Implementation-Vendor", "Vendor"), ("Specification-Title", "Specification"),
        ("Specification-Version", "Spec. version"), ("Bundle-SymbolicName", "OSGi bundle"),
        ("Bundle-Version", "Bundle version"), ("Created-By", "Made by"), ("Build-Jdk-Spec", "Built with"),
        ("Build-Jdk", "Built with"), ("Class-Path", "Class path"),
    ]

    private static func manifestCard(_ jar: JarArchive) -> String {
        var html = "<div class=card><div class=head><b>Manifest</b></div><div class=cert>"
        guard jar.hasManifest else {
            return html + "<p class=\"dim inset\">There is no <code>META-INF/MANIFEST.MF</code>: "
                + "it cannot be run with <code>java -jar</code>.</p></div></div>"
        }
        var shown = Set<String>()
        for (key, label) in known {
            guard let value = jar.value(key), !shown.contains(label) else { continue }
            shown.insert(label)
            switch key {
            case "Main-Class":
                html += R.row(label, "<code>\(R.escape(value))</code> <span class=dim>— <code>java -jar</code> starts here</span>")
            case "Class-Path":
                let parts = value.split(separator: " ").map(String.init)
                html += R.row(label, parts.map { "<code>\(R.escape($0))</code>" }.joined(separator: "<br>"))
            case "Multi-Release":
                html += R.row(label, value.lowercased() == "true"
                    ? "yes <span class=dim>— newer Javas use the classes in <code>META-INF/versions</code></span>"
                    : R.escape(value))
            case "Automatic-Module-Name":
                html += R.row(label, "<code>\(R.escape(value))</code> <span class=dim>— the name it has on the module path</span>")
            default:
                html += R.row(label, R.escape(value))
            }
        }
        if jar.value("Main-Class") == nil {
            html += R.row("Runs", "<span class=dim>nothing on its own — a library</span>")
        }
        let knownKeys = Set(known.map { $0.0.lowercased() } + ["manifest-version"])
        let others = jar.manifest.filter { !knownKeys.contains($0.name.lowercased()) }
        if !others.isEmpty {
            html += "<details class=inset><summary>Other entries <span class=count>\(others.count)</span></summary>"
                + "<table class=summary>"
            for entry in others {
                html += "<tr><td><code>\(R.escape(entry.name))</code></td><td>\(R.escape(String(entry.value.prefix(2000))))</td></tr>"
            }
            html += "</table></details>"
        }
        if jar.manifestSections > 0 {
            html += "<p class=\"dim inset\">And \(jar.manifestSections.formatted()) section\(jar.manifestSections == 1 ? "" : "s") "
                + "for single entries\(jar.signers.isEmpty ? "" : ", the digests the signature covers").</p>"
        }
        return html + "</div></div>"
    }

    private static func mavenCard(_ jar: JarArchive) -> String {
        var html = "<div class=card><div class=head><b>Built as</b></div><div class=cert>"
        for maven in jar.maven {
            html += R.row("Maven", "<code>\(R.escape(maven.group)):\(R.escape(maven.artifact))"
                          + "\(maven.version.isEmpty ? "" : ":" + R.escape(maven.version))</code>")
        }
        if jar.maven.count > 1 {
            html += "<p class=\"dim inset\">More than one artifact: a shaded or “fat” jar, holding its dependencies.</p>"
        }
        return html + "</div></div>"
    }

    private static func moduleCard(_ module: ClassFile.Module, release: Int?) -> String {
        var html = "<div class=card><div class=head><b>Module</b>"
        if let release { html += " <span class=kind>for Java \(release) and later</span>" }
        html += "</div><div class=cert>"
        var title = "<code>\(R.escape(module.name))</code>"
        if let version = module.version { title += " \(R.escape(version))" }
        if module.flags & 0x0020 != 0 { title += " <span class=dim>— open: all its packages to reflection</span>" }
        html += R.row("Name", title)
        let requires = module.requires.filter { $0.flags & 0x8000 == 0 && $0.name != "java.base" }
        html += list("Requires", requires.map { item in
            var text = "<code>\(R.escape(item.name))</code>"
            if item.flags & 0x0020 != 0 { text += " <span class=dim>transitive</span>" }
            if item.flags & 0x0040 != 0 { text += " <span class=dim>at compile time only</span>" }
            return text
        }, empty: "only <code>java.base</code>")
        html += list("Exports", module.exports.map { item in
            "<code>\(R.escape(item.package.replacingOccurrences(of: "/", with: ".")))</code>"
                + (item.to.isEmpty ? "" : " <span class=dim>to \(R.escape(item.to.joined(separator: ", ")))</span>")
        }, empty: "nothing")
        if !module.opens.isEmpty {
            html += list("Opens", module.opens.map { "<code>\(R.escape($0.package.replacingOccurrences(of: "/", with: ".")))</code>" }, empty: "")
        }
        if !module.uses.isEmpty {
            html += list("Uses", module.uses.map { "<code>\(R.escape($0.replacingOccurrences(of: "/", with: ".")))</code>" }, empty: "")
        }
        if !module.provides.isEmpty {
            html += list("Provides", module.provides.map {
                "<code>\(R.escape($0.service.replacingOccurrences(of: "/", with: ".")))</code> <span class=dim>with "
                    + R.escape($0.with.map { $0.replacingOccurrences(of: "/", with: ".") }.joined(separator: ", ")) + "</span>"
            }, empty: "")
        }
        return html + "</div></div>"
    }

    /// A row of a list, folded when it is long.
    private static func list(_ label: String, _ items: [String], empty: String) -> String {
        guard !items.isEmpty else { return R.row(label, "<span class=dim>\(empty)</span>") }
        guard items.count > 6 else { return R.row(label, items.joined(separator: "<br>")) }
        return R.row(label, "<details><summary>\(items.count) — \(items.prefix(3).joined(separator: ", "))…</summary>"
                     + items.joined(separator: "<br>") + "</details>")
    }

    private static func classesCard(_ jar: JarArchive) -> String {
        var html = "<div class=card><div class=head><b>Classes</b></div><div class=cert>"
        if let low = jar.lowestMajor, let high = jar.highestMajor {
            let needs = low == high ? ClassFile.release(major: high)
                : "\(ClassFile.release(major: low)) to \(ClassFile.release(major: high).replacingOccurrences(of: "Java ", with: ""))"
            html += R.row("Compiled for", R.escape(needs)
                          + " <span class=dim>— runs on \(R.escape(ClassFile.release(major: high))) or later</span>")
        }
        var count = "\(jar.classCount.formatted()) class file\(jar.classCount == 1 ? "" : "s")"
        if jar.classesRead < jar.classCount { count += " <span class=dim>(the first \(jar.classesRead.formatted()) read for their version)</span>" }
        html += R.row("Count", count)
        if jar.previewClasses > 0 {
            html += R.row("Preview", "<span class=soon>\(jar.previewClasses.formatted()) use preview features</span> "
                          + "<span class=dim>— they run only on that exact release, with <code>--enable-preview</code></span>")
        }
        if !jar.releases.isEmpty {
            html += R.row("Also for", jar.releases.map { "Java \($0.release) <span class=dim>(\($0.classes.formatted()))</span>" }
                .joined(separator: ", "))
            if !jar.isMultiRelease {
                html += "<p class=\"dim inset\">The manifest does not say <code>Multi-Release: true</code>, so Java ignores those folders.</p>"
            }
        }
        return html + "</div></div>"
    }

    private static func webCard(_ jar: JarArchive) -> String {
        var html = "<div class=card><div class=head><b>Web application</b></div><div class=cert>"
        html += R.row("web.xml", jar.webXML ? "yes" : "<span class=dim>none — configured by annotations</span>")
        html += R.row("Libraries", jar.webLibraries == 0 ? "<span class=dim>none in <code>WEB-INF/lib</code></span>"
                      : "\(jar.webLibraries.formatted()) jar\(jar.webLibraries == 1 ? "" : "s") in <code>WEB-INF/lib</code>")
        return html + "</div></div>"
    }

    private static func enterpriseCard(_ jar: JarArchive) -> String {
        var html = "<div class=card><div class=head><b>Enterprise application</b></div><div class=cert>"
        html += R.row("application.xml", jar.applicationXML ? "yes" : "<span class=dim>none</span>")
        html += list("Modules", jar.enterpriseModules.map { "<code>\(R.escape($0))</code>" }, empty: "none at the top")
        return html + "</div></div>"
    }

    private static func signatureCard(_ jar: JarArchive, now: Date) -> String {
        var html = "<div class=card><div class=head><b>Signature</b></div><div class=cert>"
        guard !jar.signers.isEmpty else {
            return html + "<p class=\"dim inset\">Not signed.\(jar.strayCount > 0 ? " A signature file is there without its other half." : "")</p></div></div>"
        }
        for signer in jar.signers {
            if let certificate = signer.certificate {
                html += R.row("Signed by", R.escape(X509.shortName(certificate.subject))
                              + " <code class=dim>\(R.escape(signer.name))</code>")
                html += R.row("Issued by", certificate.isSelfIssued ? "<span class=dim>itself — nobody else vouches for it</span>"
                              : R.escape(X509.shortName(certificate.issuer)))
                var until = R.escape(certificate.notAfter.formatted(date: .long, time: .omitted))
                if certificate.notAfter < now {
                    until += signer.timestamped ? " <span class=dim>— expired since, but a timestamp shows it was signed while it was good</span>"
                        : " <span class=bad>expired</span> <span class=dim>— with no timestamp, Java no longer accepts it</span>"
                }
                html += R.row("Valid until", until)
            } else {
                html += R.row("Signed by", "<code>\(R.escape(signer.name))</code> <span class=dim>— the certificate could not be read</span>")
            }
            if let signedAt = signer.signedAt {
                html += R.row("Signed", R.escape(signedAt.formatted(date: .long, time: .shortened))
                              + (signer.timestamped ? " <span class=dim>— vouched for by a timestamp authority</span>"
                                 : " <span class=dim>— as the signer said; no timestamp</span>"))
            }
            switch signer.signatureValid {
            case true?: html += R.row("Signature", "<span class=good>holds</span>")
            case false?: html += R.row("Signature", "<span class=bad>does not match</span>")
            case nil: html += R.row("Signature", "<span class=dim>could not be checked</span>")
            }
            switch signer.manifestDigest {
            case true?: html += R.row("Manifest", "<span class=good>as signed</span> <span class=dim>(\(R.escape(signer.digestAlgorithm ?? "")))</span>")
            case false?: html += R.row("Manifest", "<span class=bad>changed since it was signed</span>")
            case nil: break
            }
            if signer.trusted == true {
                html += R.row("Trusted", "by this Mac")
            } else if signer.trusted == false {
                html += R.row("Trusted", "<span class=dim>not by this Mac\(signer.trustText.map { " — " + R.escape($0) } ?? ""); "
                              + "Java decides with its own certificates</span>")
            }
        }
        html += "<p class=\"dim inset\">Each file's own digest in the manifest is not checked here: that reads every byte. "
            + "<code>jarsigner -verify</code> does.</p>"
        return html + "</div></div>"
    }

    private static func listingSection(_ listing: Listing.Result?) -> String {
        guard let listing else { return "<h2>Contents</h2><p class=dim>Reading…</p>" }
        var html = "<h2>Contents</h2>"
        if let trouble = listing.trouble { html += "<p class=warn>\(R.escape(trouble))</p>" }
        guard !listing.entries.isEmpty else { return html + (listing.trouble == nil ? "<p class=dim>It is empty.</p>" : "") }
        html += "<table class=summary>"
        for entry in listing.entries {
            html += "<tr><td>\(entry.isDirectory ? "\u{1F4C1}" : "\u{1F4C4}") \(R.escape(entry.name))</td>"
                + "<td class=num>\(entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")</td>"
                + "<td class=dim>\(entry.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")</td></tr>"
        }
        html += "</table>"
        if listing.omitted > 0 {
            html += "<p class=dim>\(listing.omitted.formatted()) more not listed. A preview shows the first \(Listing.mostEntries).</p>"
        }
        return html
    }

    static let style = """
        <style>
        .inset { margin: 4px 10px; }
        .row { grid-template-columns: 110px 1fr; }
        td.num { text-align: right; white-space: nowrap; color: var(--dim); font-size: 11px; width: 80px; }
        </style>
        """
}
