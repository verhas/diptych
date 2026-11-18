import Foundation

/// A Java class file for Quick Look: its declaration as source would write
/// it, the release it was compiled for, its fields, constructors and methods
/// with their types, and -- folded -- the classes it uses and the strings in
/// its code. Quick Look shows a class file as a name and a size.
nonisolated enum ClassFileReport {

    /// Members drawn before the page says where it stopped.
    static let maximumMembers = 3000
    /// Folded lists stop here: they are for a glance, not for an audit.
    static let maximumListed = 1000

    static func html(for data: Data, name: String, path: String) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        let file: ClassFile
        do {
            file = try ClassFile(data: data)
        } catch {
            return page(title: name, body: "<h1>\(escape(name))</h1><p class=lead>Named like a Java class file, "
                        + "\(escape(size)), but it does not read as one.</p>"
                        + "<p>\(escape(String(describing: error)))</p><p class=meta>\(escape(path))</p>")
        }
        return html(for: file, name: name, path: path, size: size)
    }

    static func html(for file: ClassFile, name: String, path: String, size: String) -> String {
        var body = "<h1>\(escape(name))</h1>"
        var lead = "Java class file for \(ClassFile.release(major: file.major))"
        if file.usesPreviewFeatures { lead += " with its preview features" }
        lead += " (class-file version \(file.major).\(file.minor)), \(size)"
        body += "<p class=lead>\(escape(lead))</p>"
        var meta: [String] = []
        if let source = file.sourceFile { meta.append("compiled from " + source) }
        meta.append(path)
        body += "<p class=meta>\(escape(meta.joined(separator: " \u{00B7} ")))</p>"

        if let module = file.module {
            body += moduleSection(module)
        } else {
            body += declaration(file)
            body += members(of: file)
        }
        body += folded(file)
        return page(title: name, body: body)
    }

    // MARK: - Declaration

    private static func declaration(_ file: ClassFile) -> String {
        let own = file.innerClasses.first { $0.inner == file.name }
        // A nested class's real modifiers -- private, protected, static -- are
        // only in InnerClasses; its own flags say public or package.
        let access = own?.access ?? file.access
        let isInterface = file.access & ClassFile.Flag.interface != 0
        let isAnnotation = file.access & ClassFile.Flag.annotation != 0
        let isEnum = file.access & ClassFile.Flag.enum != 0
        let isRecord = file.record != nil

        var words = modifiers(access, [
            (ClassFile.Flag.public, "public"), (ClassFile.Flag.private, "private"),
            (ClassFile.Flag.protected, "protected"), (ClassFile.Flag.static, "static"),
        ])
        if access & ClassFile.Flag.abstract != 0, !isInterface { words.append("abstract") }
        if !file.permitted.isEmpty { words.append("sealed") }
        if access & ClassFile.Flag.final != 0, !isEnum, !isRecord { words.append("final") }
        let kind = isAnnotation ? "@interface" : isInterface ? "interface" : isEnum ? "enum"
            : isRecord ? "record" : "class"
        words.append(kind)

        let generic = file.signature.flatMap(JavaSignature.classDeclaration(signature:))
        let simple = JavaSignature.simpleName(JavaSignature.className(file.name))
        var line = keywords(words) + " <b>\(escape(simple))</b>"
        if let parameters = generic?.typeParameters { line += escape(parameters) }
        if let components = file.record {
            line += "(" + components.map {
                escape(JavaSignature.field(descriptor: $0.descriptor, signature: $0.signature)) + " " + escape($0.name)
            }.joined(separator: ", ") + ")"
        }

        let superclass = generic?.superclass ?? file.superName.map(JavaSignature.className)
        if let superclass, !isInterface, !["Object", "Record"].contains(superclass),
           !(isEnum && (superclass == "Enum" || superclass.hasPrefix("Enum<"))) {
            line += " " + keywords(["extends"]) + " " + escape(superclass)
        }
        let interfaces = (generic?.interfaces ?? file.interfaces.map(JavaSignature.className))
            .filter { !(isAnnotation && $0 == "java.lang.annotation.Annotation") }
        if !interfaces.isEmpty {
            line += " " + keywords([isInterface ? "extends" : "implements"]) + " "
                + interfaces.map(escape).joined(separator: ", ")
        }
        if !file.permitted.isEmpty {
            line += " " + keywords(["permits"]) + " "
                + file.permitted.map { escape(JavaSignature.className($0)) }.joined(separator: ", ")
        }

        var out = "<div class=decl>"
        let package = JavaSignature.packageName(file.name)
        if !package.isEmpty { out += "<div class=pkg>\(keywords(["package"])) \(escape(package));</div>" }
        out += annotationLines(file.annotations, deprecated: file.deprecated)
        out += "<div>\(line)</div></div>"

        var facts: [String] = []
        if let host = own?.outer ?? file.nestHost, host != file.name {
            facts.append("Nested in " + code(JavaSignature.className(host)))
        }
        if let method = file.enclosingMethod {
            facts.append("Declared inside " + code(JavaSignature.className(method)))
        }
        if own != nil, own?.simpleName == nil { facts.append("An anonymous class") }
        if !facts.isEmpty { out += "<p class=facts>" + facts.joined(separator: " \u{00B7} ") + "</p>" }
        return out
    }

    // MARK: - Members

    private static func members(of file: ClassFile) -> String {
        let isInterface = file.access & ClassFile.Flag.interface != 0
        let isEnum = file.access & ClassFile.Flag.enum != 0
        let simple = JavaSignature.simpleName(JavaSignature.className(file.name))
        let compilerMade = ClassFile.Flag.synthetic | ClassFile.Flag.bridge

        let fields = file.fields.filter { $0.access & ClassFile.Flag.synthetic == 0 }
        let constants = isEnum ? fields.filter { $0.access & ClassFile.Flag.enum != 0 } : []
        let plainFields = fields.filter { !(isEnum && $0.access & ClassFile.Flag.enum != 0) }
        let methods = file.methods.filter { $0.access & compilerMade == 0 }
        let constructors = methods.filter { $0.name == "<init>" }
        let ordinary = methods.filter { $0.name != "<init>" }
        let synthetic = file.fields.filter { $0.access & ClassFile.Flag.synthetic != 0 }.map { ($0, false) }
            + file.methods.filter { $0.access & compilerMade != 0 }.map { ($0, true) }

        var out = ""
        var drawn = 0
        func section(_ title: String, _ rows: [String]) {
            guard !rows.isEmpty else { return }
            let shown = rows.prefix(max(0, maximumMembers - drawn))
            drawn += shown.count
            out += "<h2>\(title) <span class=count>\(rows.count)</span></h2><div class=list>"
                + shown.map { "<div class=member>\($0)</div>" }.joined() + "</div>"
        }
        section("Constants", constants.map { annotationLines($0.annotations, deprecated: $0.deprecated)
            + "<b>\(escape($0.name))</b>" })
        section("Fields", plainFields.map { field($0, inInterface: isInterface) })
        section("Constructors", constructors.map {
            method($0, owner: simple, inInterface: false, dropping: isEnum ? enumConstructorPrefix($0) : 0)
        })
        section("Methods", ordinary.map { method($0, owner: simple, inInterface: isInterface) })

        let nested = file.innerClasses.filter { $0.outer == file.name && $0.simpleName != nil }
        section("Nested Classes", nested.map { inner in
            var words = modifiers(inner.access, [
                (ClassFile.Flag.public, "public"), (ClassFile.Flag.private, "private"),
                (ClassFile.Flag.protected, "protected"), (ClassFile.Flag.static, "static"),
                (ClassFile.Flag.final, "final"),
            ])
            words.append(inner.access & ClassFile.Flag.annotation != 0 ? "@interface"
                         : inner.access & ClassFile.Flag.interface != 0 ? "interface"
                         : inner.access & ClassFile.Flag.enum != 0 ? "enum" : "class")
            return keywords(words) + " <b>\(escape(inner.simpleName ?? ""))</b>"
        })
        if drawn >= maximumMembers {
            out += "<p class=footnote>Only the first \(maximumMembers) members are shown.</p>"
        }

        if !synthetic.isEmpty {
            out += "<details><summary><h2>Made by the Compiler <span class=count>\(synthetic.count)</span></h2>"
                + "</summary><p class=footnote>Bridges, lambda bodies and accessors: in the class file, "
                + "not in the source.</p><div class=list>"
            for (member, isMethod) in synthetic.prefix(maximumListed) {
                out += "<div class=member>"
                    + (isMethod ? method(member, owner: simple, inInterface: isInterface)
                                : field(member, inInterface: isInterface)) + "</div>"
            }
            out += "</div></details>"
        }
        if out.isEmpty { out = "<p class=footnote>No fields or methods.</p>" }
        return out
    }

    private static func field(_ field: ClassFile.Member, inInterface: Bool) -> String {
        var words = modifiers(field.access, [
            (ClassFile.Flag.public, "public"), (ClassFile.Flag.private, "private"),
            (ClassFile.Flag.protected, "protected"), (ClassFile.Flag.static, "static"),
            (ClassFile.Flag.final, "final"), (ClassFile.Flag.volatile, "volatile"),
            (ClassFile.Flag.transient, "transient"),
        ])
        // An interface's fields are all public static final; source says none of it.
        if inInterface { words.removeAll { ["public", "static", "final"].contains($0) } }
        var line = annotationLines(field.annotations, deprecated: field.deprecated) + keywords(words)
        if !words.isEmpty { line += " " }
        line += "<span class=type>\(escape(JavaSignature.field(descriptor: field.descriptor, signature: field.signature)))</span>"
        line += " <b>\(escape(field.name))</b>"
        if let value = field.constantValue { line += " = <span class=lit>\(escape(value))</span>" }
        return line
    }

    /// javac gives every enum constructor the constant's name and ordinal
    /// first; source never writes them.
    private static func enumConstructorPrefix(_ constructor: ClassFile.Member) -> Int {
        constructor.descriptor.hasPrefix("(Ljava/lang/String;I") ? 2 : 0
    }

    private static func method(_ method: ClassFile.Member, owner: String, inInterface: Bool,
                               dropping added: Int = 0) -> String {
        if method.name == "<clinit>" { return keywords(["static"]) + " <span class=dim>{ \u{2026} }</span>" }
        var words = modifiers(method.access, [
            (ClassFile.Flag.public, "public"), (ClassFile.Flag.private, "private"),
            (ClassFile.Flag.protected, "protected"), (ClassFile.Flag.abstract, "abstract"),
            (ClassFile.Flag.static, "static"), (ClassFile.Flag.final, "final"),
            (ClassFile.Flag.synchronized, "synchronized"), (ClassFile.Flag.native, "native"),
        ])
        if inInterface {
            // Public and abstract go without saying in an interface; a body
            // that is neither static nor private is a default method.
            words.removeAll { $0 == "public" || $0 == "abstract" }
            if method.access & (ClassFile.Flag.abstract | ClassFile.Flag.static | ClassFile.Flag.private) == 0 {
                words.append("default")
            }
        }
        var line = annotationLines(method.annotations, deprecated: method.deprecated) + keywords(words)
        if !words.isEmpty { line += " " }
        guard let type = JavaSignature.method(descriptor: method.descriptor, signature: method.signature) else {
            return line + "<b>\(escape(method.name))</b> <code>\(escape(method.descriptor))</code>"
        }
        if let parameters = type.typeParameters { line += escape(parameters) + " " }
        let isConstructor = method.name == "<init>"
        if !isConstructor { line += "<span class=type>\(escape(type.result))</span> " }
        line += "<b>\(escape(isConstructor ? owner : method.name))</b>("

        var parameters = type.parameters
        var names = method.parameterNames.flatMap { $0.count == parameters.count ? $0 : nil }
        if added > 0, parameters.count >= added {
            // A generic signature has already left them out.
            if JavaSignature.parameterWidths(method.descriptor).count == parameters.count {
                parameters.removeFirst(added)
                names = names.map { Array($0.dropFirst(added)) }
            }
        }
        if method.access & ClassFile.Flag.varargs != 0, let last = parameters.last, last.hasSuffix("[]") {
            parameters[parameters.count - 1] = String(last.dropLast(2)) + "..."
        }
        line += parameters.enumerated().map { index, parameter in
            let name = names.map { $0[index] } ?? ""
            return "<span class=type>\(escape(parameter))</span>" + (name.isEmpty ? "" : " " + escape(name))
        }.joined(separator: ", ") + ")"

        let thrown = type.exceptions.isEmpty ? method.exceptions.map(JavaSignature.className) : type.exceptions
        if !thrown.isEmpty {
            line += " " + keywords(["throws"]) + " " + thrown.map(escape).joined(separator: ", ")
        }
        return line
    }

    // MARK: - Module

    private static func moduleSection(_ module: ClassFile.Module) -> String {
        var words: [String] = []
        if module.flags & 0x0020 != 0 { words.append("open") }
        words.append("module")
        var out = "<div class=decl><div>\(keywords(words)) <b>\(escape(module.name))</b>"
            + (module.version.map { " <span class=dim>@\(escape($0))</span>" } ?? "") + " {</div>"
        func line(_ text: String) { out += "<div class=inside>\(text);</div>" }
        // `requires java.base` is there in every module; source never writes it.
        for requires in module.requires where requires.flags & ClassFile.Flag.mandated == 0 {
            var words = ["requires"]
            if requires.flags & 0x0020 != 0 { words.append("transitive") }
            if requires.flags & 0x0040 != 0 { words.append("static") }
            line(keywords(words) + " " + escape(requires.name))
        }
        for (keyword, list) in [("exports", module.exports), ("opens", module.opens)] {
            for item in list {
                line(keywords([keyword]) + " " + escape(item.package)
                     + (item.to.isEmpty ? "" : " " + keywords(["to"]) + " " + item.to.map(escape).joined(separator: ", ")))
            }
        }
        for service in module.uses { line(keywords(["uses"]) + " " + escape(JavaSignature.className(service))) }
        for provides in module.provides {
            line(keywords(["provides"]) + " " + escape(JavaSignature.className(provides.service)) + " "
                 + keywords(["with"]) + " " + provides.with.map { escape(JavaSignature.className($0)) }.joined(separator: ", "))
        }
        return out + "<div>}</div></div>"
    }

    // MARK: - Folded lists

    private static func folded(_ file: ClassFile) -> String {
        var out = ""
        let used = file.referencedClasses.map(JavaSignature.className).sorted()
        if !used.isEmpty {
            out += "<details><summary><h2>Classes It Uses <span class=count>\(used.count)</span></h2></summary>"
                + "<div class=list>" + used.prefix(maximumListed).map { "<div class=member>\(escape($0))</div>" }.joined()
                + "</div></details>"
        }
        if !file.strings.isEmpty {
            out += "<details><summary><h2>Strings in Its Code <span class=count>\(file.strings.count)</span></h2></summary>"
                + "<div class=list>" + file.strings.prefix(maximumListed).map { text in
                    let shown = text.count > 300 ? String(text.prefix(300)) + "\u{2026}" : text
                    return "<div class='member lit'>\(escape(JavaSignature.quoted(shown)))</div>"
                }.joined() + "</div></details>"
        }
        if used.count > maximumListed || file.strings.count > maximumListed {
            out += "<p class=footnote>Lists stop at \(maximumListed).</p>"
        }
        return out
    }

    // MARK: - Pieces

    private static func modifiers(_ access: Int, _ table: [(Int, String)]) -> [String] {
        table.compactMap { access & $0.0 != 0 ? $0.1 : nil }
    }

    private static func keywords(_ words: [String]) -> String {
        words.isEmpty ? "" : "<span class=kw>\(escape(words.joined(separator: " ")))</span>"
    }

    private static func code(_ text: String) -> String { "<code>\(escape(text))</code>" }

    private static func annotationLines(_ annotations: [ClassFile.Annotation], deprecated: Bool) -> String {
        var lines = annotations.map { annotation in
            "<div class=ann>\(escape(annotation.text))"
                + (annotation.visible ? "" : " <span class=dim title='Kept in the class file, not at run time'>"
                   + "(class file only)</span>") + "</div>"
        }
        if deprecated, !annotations.contains(where: { $0.text.hasPrefix("@Deprecated") }) {
            lines.insert("<div class=ann>@Deprecated</div>", at: 0)
        }
        return lines.joined()
    }

    static func escape(_ text: String) -> String { PlistReport.escape(text) }

    private static func page(title: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title><style>
        :root { color-scheme: light dark;
                --ink: #1c1c1e; --dim: #6c6c70; --rule: #e4e4e8; --bg: #fff; --panel: #f6f6f8;
                --kw: #9b2393; --type: #0b4f79; --lit: #c41a16; --ann: #643820; }
        @media (prefers-color-scheme: dark) {
          :root { --ink: #ececf0; --dim: #9a9aa0; --rule: #333336; --bg: #1c1c1e; --panel: #262629;
                  --kw: #fc5fa3; --type: #5dd8ff; --lit: #fc6a5d; --ann: #fd8f3f; }
        }
        body { font: 13px -apple-system, system-ui, sans-serif; color: var(--ink);
               background: var(--bg); margin: 0; padding: 18px 22px; }
        h1 { font-size: 17px; margin: 0 0 2px; }
        h2 { font-size: 13px; margin: 18px 0 6px; display: inline-block; }
        .count { color: var(--dim); font-weight: 400; margin-left: 4px; }
        .lead { margin: 0 0 2px; color: var(--dim); }
        .meta, .footnote, .facts { color: var(--dim); font-size: 11px; margin: 0 0 12px; }
        .footnote { margin: 6px 0; }
        .decl, .member { font: 12px ui-monospace, Menlo, monospace; }
        .decl { background: var(--panel); border: 1px solid var(--rule); border-radius: 6px;
                padding: 10px 12px; margin: 12px 0 6px; overflow-wrap: anywhere; }
        .pkg { color: var(--dim); margin-bottom: 6px; }
        .inside { padding-left: 2em; }
        .list { border: 1px solid var(--rule); border-radius: 6px; overflow: hidden; }
        .member { padding: 3px 10px; border-bottom: 1px solid var(--rule); overflow-wrap: anywhere; }
        .member:last-child { border-bottom: none; }
        .kw { color: var(--kw); } .type { color: var(--type); } .lit { color: var(--lit); }
        .ann { color: var(--ann); }
        .dim { color: var(--dim); }
        code { font: 11px ui-monospace, Menlo, monospace; }
        details { display: block; }
        summary { list-style: none; cursor: default; }
        summary::-webkit-details-marker { display: none; }
        summary::before { content: "\\25B8"; color: var(--dim); font-size: 10px; margin-right: 4px; }
        details[open] > summary::before { content: "\\25BE"; }
        </style></head><body>\(body)</body></html>
        """
    }
}
