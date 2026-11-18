import Foundation

/// A disk image as a page: what kind, how big, who signed it, and what is
/// on it -- without attaching it.
nonisolated enum DiskImageReport {

    typealias R = ExecutableReport

    /// `checking` while the signed bytes are still being hashed and the
    /// volumes read.
    static func html(for image: DiskImage, checking: Bool) -> String {
        let name = image.url.lastPathComponent
        var body = "<h1>\(R.escape(name))</h1>"
        var lead = image.formatName
        if let full = image.fullSize {
            lead += ", " + ByteCountFormatter.string(fromByteCount: full, countStyle: .file)
            if image.storedSize > 0, image.storedSize < full {
                lead += " (\(ByteCountFormatter.string(fromByteCount: image.storedSize, countStyle: .file)) stored)"
            }
        }
        body += "<p class=lead>\(R.escape(lead))</p><p class=meta>\(R.escape(image.url.deletingLastPathComponent().path))</p>"

        if image.signatureMismatch?.isEmpty == false {
            body += "<p class=warn><span class=bad>It changed after it was signed.</span> "
                + "\(R.escape(image.signatureMismatch ?? "")) macOS refuses to open it.</p>"
        }
        body += image.notes.map { "<p class=note>\(R.escape($0))</p>" }.joined()
        if image.hasLicense {
            body += "<p class=note>It shows a license agreement before it opens.</p>"
        }

        body += "<div class=card><div class=head><b>Disk Image</b></div><div class=cert>"
        body += R.row("Format", R.escape(image.formatName)
                      + (image.format.isEmpty ? "" : " <code class=dim>\(R.escape(image.format))</code>"))
        if let full = image.fullSize { body += R.row("Disk size", R.escape(R.bytes(Int(clamping: full)))) }
        body += R.row("File size", R.escape(R.bytes(Int(clamping: image.storedSize))))
        body += R.row("Encrypted", image.encryption.map { "<span class=soon>\(R.escape($0))</span>" } ?? "no")
        if let scheme = image.partitionScheme { body += R.row("Partitions", R.escape(scheme)) }
        if let checksum = image.checksum { body += R.row("Checksum", R.escape(checksum) + " <span class=dim>— not checked here</span>") }
        body += "</div></div>"

        if image.encryption == nil {
            body += "<div class=card><div class=head><b>Signature</b></div><div class=cert>"
            if let signature = image.signature {
                body += signatureRows(signature, image: image, checking: checking)
            } else {
                body += R.row("Signature", "none <span class=dim>— the apps inside may be signed on their own</span>")
                if image.stapled {
                    body += R.row("Notarization", "<span class=good>ticket stapled</span> <span class=dim>— Apple checked "
                                  + "what is on it; Gatekeeper need not ask</span>")
                }
            }
            body += "</div></div>"
        }

        if checking, image.partitions.isEmpty, image.encryption == nil, ["UDSP", "ASIF"].contains(image.format) == false {
            body += "<p class=dim>Reading what is on it\u{2026}</p>"
        }
        for partition in image.partitions {
            guard let volume = partition.volume else { continue }
            body += volumeCard(volume, partition: partition, single: image.partitions.filter { $0.volume != nil }.count == 1)
        }

        let named = image.partitions.filter { !$0.type.isEmpty }
        if !named.isEmpty {
            body += "<details><summary><h2>Partitions <span class=count>\(named.count)</span></h2></summary>"
            body += "<table class=summary><tr><th>Name</th><th>Type</th><th>Size</th></tr>"
            for partition in named {
                body += "<tr><td>\(R.escape(partition.name))</td><td><code>\(R.escape(partition.type))</code></td>"
                body += "<td>\(R.tableSize(UInt64(max(partition.size, 0))))</td></tr>"
            }
            body += "</table></details>"
        }

        if let license = image.licenseText?.trimmingCharacters(in: .whitespacesAndNewlines), !license.isEmpty {
            let lines = license.split(separator: "\n", omittingEmptySubsequences: false).count
            body += "<details><summary><h2>License Agreement <span class=count>\(lines) lines</span></h2></summary>"
            body += "<pre class=license>\(R.escape(String(license.prefix(200_000))))</pre></details>"
        }
        return KeyStoreReport.page(title: name, body: R.style + extraStyle + body)
    }

    static func html(failure: Error, url: URL, size: Int64) -> String {
        R.html(failure: failure, kind: "Disk image", name: url.lastPathComponent,
               path: url.deletingLastPathComponent().path, size: Int(clamping: size))
    }

    private static let extraStyle = """
        <style>
        pre.license { white-space: pre-wrap; font: 12px -apple-system, system-ui, sans-serif;
                      background: var(--panel); border-radius: 6px; padding: 8px 10px; }
        </style>
        """

    private static func signatureRows(_ signature: MachOFile.CodeSignature, image: DiskImage, checking: Bool) -> String {
        var out = ""
        if let signer = signature.signer {
            let name = X509.shortName(signer.subject)
            out += R.row("Signed by", R.escape(name) + (R.authority(of: name).map { " <span class=dim>— \(R.escape($0))</span>" } ?? ""))
            var chain: [String] = [], current = signer
            while chain.count < 8, !current.isSelfIssued,
                  let issuer = signature.certificates.first(where: { $0.subjectBytes == current.issuerBytes }) {
                chain.append(X509.shortName(issuer.subject))
                current = issuer
            }
            if !chain.isEmpty { out += R.row("Issued by", R.escape(chain.joined(separator: " ← "))) }
        } else {
            out += R.row("Signed by", "ad hoc <span class=dim>— no certificate</span>")
        }
        if let date = signature.signedAt { out += R.row("Signed at", R.escape(date.formatted(date: .long, time: .shortened))) }
        if !signature.identifier.isEmpty { out += R.row("Identifier", "<code>\(R.escape(signature.identifier))</code>") }
        if let team = signature.teamID { out += R.row("Team", R.escape(team)) }
        let check: String
        if checking {
            check = "<span class=dim>checking\u{2026}</span>"
        } else {
            check = switch image.signatureMismatch {
            case .some(""): "<span class=good>intact</span> <span class=dim>— \(R.escape(signature.hashName)) of the whole image matches</span>"
            case .some(let why): "<span class=bad>broken</span> — \(R.escape(R.lowercasedFirst(why)))"
            case .none: "<span class=dim>not checked here, it is too large</span>"
            }
        }
        out += R.row("Seal", check)
        out += R.row("Notarization", image.stapled
                     ? "<span class=good>ticket stapled</span> <span class=dim>— Gatekeeper need not ask Apple</span>"
                     : "no ticket stapled <span class=dim>— Gatekeeper asks Apple online, the first time</span>")
        return out
    }

    private static func volumeCard(_ volume: DiskImage.Volume, partition: DiskImage.Partition, single: Bool) -> String {
        var out = "<div class=card><div class=head><b>\(R.escape(volume.name.map { "Volume \u{201C}\($0)\u{201D}" } ?? "Volume"))</b></div><div class=cert>"
        out += R.row("File system", R.escape(volume.fileSystem))
        if !single || partition.offset != 0 { out += R.row("Size", R.escape(R.bytes(Int(clamping: partition.size)))) }
        var counts: [String] = []
        if let files = volume.files { counts.append("\(files.formatted()) file\(files == 1 ? "" : "s")") }
        if let folders = volume.folders, folders >= 0 { counts.append("\(folders.formatted()) folder\(folders == 1 ? "" : "s")") }
        if !counts.isEmpty { out += R.row("Holds", R.escape(counts.joined(separator: ", "))) }
        out += "</div></div>"
        if let why = volume.unlisted {
            out += "<p class=dim>\(R.escape(why))</p>"
        } else if !volume.items.isEmpty {
            let visible = volume.items.filter { !$0.hidden }, hidden = volume.items.filter(\.hidden)
            out += "<h2>On the Volume <span class=count>\(visible.count)</span></h2><table class=summary>"
            for item in visible.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                out += row(item)
            }
            out += "</table>"
            if !hidden.isEmpty {
                out += "<details><summary><span class=dim>\(hidden.count) hidden: "
                    + R.escape(hidden.map(\.name).sorted().joined(separator: ", ")) + "</span></summary>"
                out += "<table class=summary>" + hidden.map(row).joined() + "</table></details>"
            }
        }
        return out
    }

    private static func row(_ item: DiskImage.Item) -> String {
        let kind: String
        if item.isLink { kind = item.name == "Applications" ? "a link to Applications: drag the app onto it" : "link" }
        else if item.isFolder {
            let ext = (item.name as NSString).pathExtension.lowercased()
            kind = ext == "app" ? "application" : AppBundle.extensions.contains(ext) ? "bundle" : ext == "pkg" ? "installer package" : "folder"
        } else {
            kind = (item.name as NSString).pathExtension.lowercased() == "pkg" ? "installer package" : "file"
        }
        return "<tr><td>\(R.escape(item.name))</td><td class=dim>\(R.escape(kind))</td>"
            + "<td>\(item.size.map { R.tableSize($0) } ?? "")</td></tr>"
    }
}
