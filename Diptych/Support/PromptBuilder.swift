import Foundation

/// Builds a question about the selected files, for pasting into an LLM.
///
/// It writes text and puts it on the clipboard. It opens no connection, reads no
/// file's contents, and has no idea what an LLM is -- the whole feature is a
/// formatter. That matters for what follows, because the clipboard is where the
/// caution lives rather than in any network code.
///
/// **Names are data, not instructions.** A file can be called anything, and a
/// downloaded one usually was named by someone else -- "Ignore previous
/// instructions and ..." is a perfectly legal filename. Since this text is
/// written to be pasted into a model, every name goes inside a fenced block and
/// the prompt says in as many words that the contents of that block are data.
/// It is not a guarantee, but leaving it out would be handing an attacker the
/// instruction channel for free.
///
/// **No file contents, ever.** Only metadata the pane already shows. A keystroke
/// that quietly put the first kilobyte of whatever is selected onto the
/// clipboard would be an exfiltration primitive wearing a helpful face.
///
/// **No provenance attributes.** `com.apple.metadata:kMDItemWhereFroms` holds
/// the URL a file was downloaded from and `com.apple.quarantine` holds who
/// downloaded it and when. Both are ordinary extended attributes, and both are
/// browsing history. Attribute *names* are listed because they say something
/// about the file; their values are not.
///
/// **Paths are abbreviated.** A full path contains the account name, and often a
/// client's or employer's name in a project folder. Anything under the home
/// directory is written with a leading `~`, which keeps the shape of the path
/// while leaving the user out of it.
enum PromptBuilder {

    /// A prompt, and whatever was wrong with the names that went into it.
    struct Prompt {
        let text: String
        /// One line per kind of trouble found, for telling the user.
        let warnings: [String]
    }

    /// A name with everything unprintable spelled out, and a note of what was
    /// found.
    ///
    /// A file name is attacker-controlled text that is about to be pasted into a
    /// model and displayed in a terminal, and it can carry:
    ///
    /// * **newlines**, which break out of the `- name:` line and forge further
    ///   fields -- the injection is into *this* format, before any model sees it;
    /// * **carriage returns and backspaces**, which overwrite what was already
    ///   drawn, so a terminal shows something other than what is there;
    /// * **ANSI escapes**, which move the cursor, recolour, and in some
    ///   terminals reach the clipboard;
    /// * **bidirectional overrides** (U+202E and friends), the Trojan Source
    ///   trick that reverses displayed order without changing a byte;
    /// * **zero-width and tag characters** (U+200B, U+E0000-E007F), which render
    ///   as nothing at all and are the usual way instructions are smuggled past
    ///   a human reader into a model.
    ///
    /// Everything suspect becomes `\u{XXXX}`, which is visible, unambiguous and
    /// inert. Backslashes are escaped first so an escape cannot be forged by a
    /// name that merely contains the text of one.
    struct Sanitised {
        let text: String
        let findings: Set<String>
    }

    static func sanitise(_ name: String) -> Sanitised {
        var out = ""
        var findings: Set<String> = []

        for scalar in name.unicodeScalars {
            switch scalar {
            case "\\":
                // First, so nothing below can be spoofed by a literal backslash.
                out += "\\\\"

            case let s where s.value < 0x20 || s.value == 0x7F
                            || (0x80 ... 0x9F).contains(s.value):
                findings.insert("control characters, which can overwrite what is "
                                + "already on screen")
                out += escape(s)

            case "\u{061C}", "\u{200E}", "\u{200F}",
                 "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
                 "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}":
                findings.insert("bidirectional overrides, which reorder text on screen "
                                + "without changing it")
                out += escape(scalar)

            case "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}":
                findings.insert("zero-width characters, which are invisible")
                out += escape(scalar)

            case let s where (0xE0000 ... 0xE007F).contains(s.value):
                findings.insert("Unicode tag characters, which render as nothing and are "
                                + "used to hide instructions")
                out += escape(s)

            default:
                out.unicodeScalars.append(scalar)
            }
        }

        // A run of backticks cannot close the fence -- newlines are gone by now,
        // so it can never begin a line -- but a name that looks like a fence in
        // the middle of one is still worth defusing.
        if out.contains("```") {
            findings.insert("a code fence, which could close the data block")
            out = out.replacingOccurrences(of: "```", with: "\\u{60}\\u{60}\\u{60}")
        }
        return Sanitised(text: out, findings: findings)
    }

    private static func escape(_ scalar: Unicode.Scalar) -> String {
        String(format: "\\u{%04X}", scalar.value)
    }


    /// Attributes whose *values* are provenance rather than description.
    private static let privateAttributes: Set<String> = [
        "com.apple.metadata:kMDItemWhereFroms",
        "com.apple.quarantine",
        "com.apple.metadata:kMDItemDownloadedDate",
    ]

    static func prompt(for items: [FileItem], in directory: URL) -> Prompt {
        let home = NSHomeDirectory()
        var findings: Set<String> = []

        var metadata: [String] = []
        for item in items {
            let (described, found) = describe(item, home: home)
            findings.formUnion(found)
            metadata.append(contentsOf: described)
        }

        let one = items.count == 1
        let warning = findings.isEmpty ? "" : """

            Note: some of the names above contained characters that do not print normally, \
            and I have replaced them with \\u{...} escapes. That is itself worth commenting on.

            """

        let rendered = PromptTemplate.render(PromptTemplate.load(), with: [
            "count": "\(items.count)",
            "itemWord": one ? "item" : "items",
            "pronoun": one ? "it" : "they",
            "isAre": one ? "is" : "are",
            "parent": "`\(abbreviate(directory.path, home: home))`",
            "parentNote": directory.path == home ? " (my home directory)"
                        : (directory.path.hasPrefix(home + "/") ? " (inside my home directory)" : ""),
            "metadata": metadata.joined(separator: "\n"),
            "warning": warning,
        ])
        return Prompt(text: rendered, warnings: findings.sorted())
    }

    private static func describe(_ item: FileItem,
                                 home: String) -> (lines: [String], findings: Set<String>) {
        let name = sanitise(item.name)
        var findings = name.findings
        var lines = ["- name: \(name.text)"]

        var kind = item.isDirectory ? "directory" : "file"
        if item.isPackage { kind = "package (a directory macOS shows as one item)" }
        if item.isSymlink { kind = "symbolic link" }
        lines.append("  kind: \(kind)")

        if !item.kind.isEmpty { lines.append("  type: \(item.kind)") }
        // Said explicitly, because a leading dot is the whole of what "hidden"
        // means here and it is easy to miss in a name.
        if item.name.hasPrefix(".") {
            lines.append("  hidden: yes (the name begins with a dot)")
        }
        if !item.isDirectory {
            let size = ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file)
            lines.append("  size: \(size)")
        }
        if item.modified != .distantPast {
            lines.append("  modified: \(ISO8601DateFormatter().string(from: item.modified))")
        }
        // Owner, group and permissions are only loaded when their columns are
        // switched on, so they are read here when missing rather than left out
        // of a prompt for want of a column nobody had enabled.
        let attributes = try? FileManager().attributesOfItem(atPath: item.url.path)
        let permissions = item.permissions.isEmpty
            ? (attributes?[.posixPermissions] as? NSNumber)
                .map { (item.isDirectory ? "d" : "-") + FileOperations.rwxString(mode_t($0.uint16Value)) }
            : item.permissions
        if let permissions { lines.append("  permissions: \(permissions)") }

        let owner = item.owner.isEmpty
            ? attributes?[.ownerAccountName] as? String : item.owner
        let group = item.group.isEmpty
            ? attributes?[.groupOwnerAccountName] as? String : item.group
        if let owner, !owner.isEmpty { lines.append("  owner: \(owner)") }
        if let group, !group.isEmpty { lines.append("  group: \(group)") }

        if item.created != .distantPast {
            lines.append("  created: \(ISO8601DateFormatter().string(from: item.created))")
        }
        if item.isExecutable { lines.append("  executable: yes") }
        if !item.tags.isEmpty {
            let tags = item.tags.map { sanitise($0) }
            for tag in tags { findings.formUnion(tag.findings) }
            lines.append("  tags: " + tags.map(\.text).joined(separator: ", "))
        }
        if item.isSymlink, !item.linkTarget.isEmpty {
            // A link target is attacker-controlled in exactly the same way a
            // name is, and is written by whoever made the link.
            let target = sanitise(abbreviate(item.linkTarget, home: home))
            findings.formUnion(target.findings)
            lines.append("  points to: \(target.text)")
        }

        // Names only. What an attribute is called describes the file; what it
        // contains is often where the file came from.
        let extended = ExtendedAttributes.names(of: item.url.path)
            .filter { !privateAttributes.contains($0) }
            .map { sanitise($0) }
        for attribute in extended { findings.formUnion(attribute.findings) }
        if !extended.isEmpty {
            lines.append("  extended attributes: "
                         + extended.map(\.text).joined(separator: ", "))
        }
        // Said out loud rather than silently omitted, so the reader knows the
        // list is edited rather than complete.
        let withheld = ExtendedAttributes.names(of: item.url.path)
            .filter { privateAttributes.contains($0) }
        if !withheld.isEmpty {
            lines.append("  (\(withheld.count) provenance attribute"
                         + "\(withheld.count == 1 ? "" : "s") withheld)")
        }
        return (lines, findings)
    }

    /// `~` for the home directory: the shape of the path without the account
    /// name in it.
    static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
