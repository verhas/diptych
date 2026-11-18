import Foundation

/// An installer package: a flat one (a xar archive holding a Distribution,
/// or a single component) or an old bundle one (a folder). Everything is
/// read from the package; nothing is installed, extracted or run.
nonisolated struct InstallerPackage {

    enum Kind: String {
        case product = "Installer package"
        case component = "Component package"
        case bundle = "Installer package (old bundle form)"
        case metapackage = "Installer metapackage (old bundle form)"
    }

    struct Script {
        var name: String
        var text: String?
        var size: Int
        var executable: Bool
        /// A compiled program among the scripts, not a script.
        var isProgram: Bool
        /// Called by Installer itself: preinstall, postinstall and the old names.
        var isHook: Bool
    }

    struct Component {
        var name: String
        var identifier: String?
        var version: String?
        var installLocation: String?
        var installKBytes: Int?
        var numberOfFiles: Int?
        var runsAsRoot = false
        var restart: String?
        var bundles: [(path: String, identifier: String?, version: String?)] = []
        var scripts: [Script] = []
        var files: [Bom.Item] = []
        var filesUnread: String?
        var hasPayload = false
        var relocatable = false
    }

    struct Choice {
        var id: String
        var title: String?
        var visible: Bool
        var packages: [String]
    }

    static let extensions: Set<String> = ["pkg", "mpkg"]
    static let maximumSize = 64 * 1024 * 1024 * 1024
    static let shownScript = 256 * 1024
    static let shownFiles = 3000

    let url: URL
    var kind: Kind
    var title: String?
    var identifier: String?
    var version: String?
    var created: Date?
    var signature: XarArchive.Signature?
    var stapled = false
    var minimumSystem: String?
    var maximumSystem: String?
    var architectures: [String] = []
    var startupDiskOnly = false
    var userHomeAllowed = false
    var installationCheck = false
    var volumeCheck = false
    var javaScript: String?
    var choices: [Choice] = []
    var components: [Component] = []
    var texts: [String] = []
    /// From the Distribution: what Installer does after a component.
    var conclusions: [String] = []
    var problems: [String] = []

    static func looksLikePackage(_ data: Data) -> Bool { XarArchive.looksLikeXar(data) }

    // MARK: - Flat

    init(url: URL, data: Data) throws {
        self.url = url
        let archive = try XarArchive(data: data)
        created = archive.created
        signature = archive.signature
        // The notarization ticket stapled on: appended after the archive,
        // with a short trailer that starts with this tag.
        stapled = data.count > 12 && data.suffix(12).prefix(4) == Data("t8lr".utf8)

        let paths = Set(archive.entries.map(\.path))
        if paths.contains("Distribution"), let xml = archive.contents(of: "Distribution", limit: 8 * 1024 * 1024) {
            kind = .product
            readDistribution(xml)
            let folders = archive.entries.filter { $0.isDirectory && !$0.path.contains("/")
                && paths.contains($0.path + "/PackageInfo") }.map(\.path)
            for folder in folders { components.append(Self.component(folder, prefix: folder + "/", in: archive)) }
            // In the order the Distribution lists them.
            let order = components.map(\.name)
            components.sort { a, b in
                let ia = choices.flatMap(\.packages).firstIndex(of: a.identifier ?? "") ?? order.firstIndex(of: a.name)!
                let ib = choices.flatMap(\.packages).firstIndex(of: b.identifier ?? "") ?? order.firstIndex(of: b.name)!
                return ia < ib
            }
        } else if paths.contains("PackageInfo") {
            kind = .component
            let component = Self.component(url.lastPathComponent, prefix: "", in: archive)
            identifier = component.identifier
            version = component.version
            components = [component]
        } else {
            kind = .product
            problems.append("It holds neither a Distribution nor a PackageInfo: Installer would not open it.")
        }
        texts = archive.entries.filter { entry in
            let base = (entry.path as NSString).lastPathComponent.lowercased()
            return entry.path.hasPrefix("Resources/")
                && ["welcome", "readme", "license", "conclusion"].contains { base.hasPrefix($0) }
        }.map(\.path)
    }

    private mutating func readDistribution(_ xml: Data) {
        guard let root = (try? XMLDocument(data: xml, options: []))?.rootElement() else {
            problems.append("Its Distribution cannot be read.")
            return
        }
        func first(_ name: String, in element: XMLElement? = nil) -> XMLElement? {
            (element ?? root).elements(forName: name).first
        }
        func attribute(_ element: XMLElement?, _ name: String) -> String? {
            element?.attribute(forName: name)?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        }
        title = first("title")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let product = first("product") {
            identifier = attribute(product, "id")
            version = attribute(product, "version")
        }
        let options = first("options")
        architectures = (attribute(options, "hostArchitectures") ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if attribute(options, "rootVolumeOnly") == "true" { startupDiskOnly = true }
        if let domains = first("domains") {
            startupDiskOnly = startupDiskOnly || (attribute(domains, "enable_anywhere") == "false"
                && attribute(domains, "enable_currentUserHome") != "true")
            userHomeAllowed = attribute(domains, "enable_currentUserHome") == "true"
        }
        let versions = first("allowed-os-versions") ?? first("allowed-os-versions", in: first("volume-check"))
        if let version = versions?.elements(forName: "os-version").first {
            minimumSystem = attribute(version, "min")
            maximumSystem = attribute(version, "before")
        }
        installationCheck = first("installation-check") != nil
        volumeCheck = first("volume-check").map { attribute($0, "script") != nil } ?? false
        let scripts = root.elements(forName: "script").compactMap(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !scripts.isEmpty { javaScript = scripts.joined(separator: "\n\n") }

        // What Installer asks for once a component is in: a restart, a logout.
        for reference in root.elements(forName: "pkg-ref") {
            if let action = attribute(reference, "onConclusion"), action != "None" { conclusions.append(action) }
        }
        for choice in root.elements(forName: "choice") {
            choices.append(Choice(id: attribute(choice, "id") ?? "",
                                  title: attribute(choice, "title"),
                                  visible: attribute(choice, "visible") != "false",
                                  packages: choice.elements(forName: "pkg-ref").compactMap { attribute($0, "id") }))
        }
    }

    /// A component: its PackageInfo, the scripts it runs and the files its
    /// bill of materials lists.
    private static func component(_ name: String, prefix: String, in archive: XarArchive) -> Component {
        var component = Component(name: name.removingPercentEncoding ?? name)
        if let xml = archive.contents(of: prefix + "PackageInfo", limit: 4 * 1024 * 1024),
           let info = (try? XMLDocument(data: xml, options: []))?.rootElement() {
            func attribute(_ element: XMLElement?, _ key: String) -> String? {
                element?.attribute(forName: key)?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            }
            component.identifier = attribute(info, "identifier")
            component.version = attribute(info, "version")
            component.installLocation = attribute(info, "install-location")
            component.runsAsRoot = attribute(info, "auth")?.lowercased() == "root"
            component.relocatable = attribute(info, "relocatable") == "true"
            if let action = attribute(info, "postinstall-action"), action != "none" { component.restart = action }
            if let payload = info.elements(forName: "payload").first {
                // Numbers from the package: kept to what can be added up.
                component.installKBytes = attribute(payload, "installKBytes").flatMap { Int($0) }.map { min(max($0, 0), 1 << 40) }
                component.numberOfFiles = attribute(payload, "numberOfFiles").flatMap { Int($0) }.map { min(max($0, 0), 1 << 40) }
            }
            component.bundles = info.elements(forName: "bundle").map {
                (attribute($0, "path") ?? "", attribute($0, "id"), attribute($0, "CFBundleShortVersionString"))
            }
        }
        component.hasPayload = (archive.entry(prefix + "Payload")?.size ?? 0) > 0

        if let packed = archive.contents(of: prefix + "Scripts", limit: 64 * 1024 * 1024) {
            let cpio = Decompress.isGzip(packed) ? Decompress.gzip(packed, limit: 64 * 1024 * 1024) : packed
            component.scripts = (cpio.map { CPIO.members($0) } ?? []).filter { $0.isFile && !Self.isAppleDouble($0.name) }
                .map(Self.script)
                .sorted { ($0.isHook ? 0 : 1, $0.name) < ($1.isHook ? 0 : 1, $1.name) }
        }
        if let bomData = archive.contents(of: prefix + "Bom", limit: 256 * 1024 * 1024) {
            do {
                component.files = try Bom(data: bomData).items.filter { !Self.isAppleDouble($0.path) }
            } catch {
                component.filesUnread = String(describing: error)
            }
        } else if archive.entry(prefix + "Bom") != nil {
            component.filesUnread = "Its bill of materials is too large to read here."
        }
        return component
    }

    /// `._name`: the extended attributes of `name`, which Installer puts
    /// back on it; not a file of its own.
    static func isAppleDouble(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.hasPrefix("._")
    }

    static let hooks: Set<String> = ["preinstall", "postinstall", "preflight", "postflight",
                                     "preupgrade", "postupgrade", "InstallationCheck", "VolumeCheck"]

    private static func script(_ member: CPIO.Member) -> Script {
        let data = member.data
        let program = MachOFile.looksLikeMachO(data)
        var text: String?
        if !program, !data.prefix(8192).contains(0) {
            text = String(decoding: data.prefix(shownScript), as: UTF8.self)
        }
        return Script(name: member.name, text: text, size: data.count, executable: member.isExecutable,
                      isProgram: program, isHook: hooks.contains(member.name))
    }

    // MARK: - Bundle form

    /// An old bundle package (a folder): Info.plist, Archive.bom, and the
    /// scripts in Resources; a metapackage lists packages of its own.
    init(bundle url: URL) throws {
        self.url = url
        let contents = url.appendingPathComponent("Contents")
        let plist = (try? Data(contentsOf: contents.appendingPathComponent("Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        guard let plist else { throw XarArchive.Problem.damaged("Its Contents/Info.plist cannot be read.") }
        let packages = contents.appendingPathComponent("Packages")
        let inner = ((try? FileManager.default.contentsOfDirectory(at: packages, includingPropertiesForKeys: nil)) ?? [])
            .filter { Self.extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        kind = url.pathExtension.lowercased() == "mpkg" || !inner.isEmpty ? .metapackage : .bundle
        identifier = plist["CFBundleIdentifier"] as? String
        version = plist["CFBundleShortVersionString"] as? String ?? plist["CFBundleVersion"] as? String
        title = plist["CFBundleName"] as? String ?? plist["IFPkgDescriptionTitle"] as? String

        if kind == .bundle {
            components = [Self.bundleComponent(url, plist: plist)]
        } else {
            for package in inner.prefix(64) {
                let info = (try? Data(contentsOf: package.appendingPathComponent("Contents/Info.plist")))
                    .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
                if let info { components.append(Self.bundleComponent(package, plist: info)) }
            }
        }
    }

    private static func bundleComponent(_ url: URL, plist: [String: Any]) -> Component {
        var component = Component(name: url.lastPathComponent)
        component.identifier = plist["CFBundleIdentifier"] as? String
        component.version = plist["CFBundleShortVersionString"] as? String
        component.installLocation = plist["IFPkgFlagDefaultLocation"] as? String
        let action = (plist["IFPkgFlagAuthorizationAction"] as? String) ?? ""
        component.runsAsRoot = action == "RootAuthorization" || action == "AdminAuthorization"
        if let restart = plist["IFPkgFlagRestartAction"] as? String, restart != "NoRestart" { component.restart = restart }
        let contents = url.appendingPathComponent("Contents")
        if let bom = try? Data(contentsOf: contents.appendingPathComponent("Archive.bom"), options: .mappedIfSafe) {
            component.files = (try? Bom(data: bom).items.filter { !Self.isAppleDouble($0.path) }) ?? []
        }
        component.hasPayload = FileManager.default.fileExists(atPath: contents.appendingPathComponent("Archive.pax.gz").path)
        let resources = contents.appendingPathComponent("Resources")
        for name in hooks.sorted() {
            let file = resources.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            let member = CPIO.Member(name: name, mode: FileManager.default.isExecutableFile(atPath: file.path) ? 0o100755 : 0o100644,
                                     data: data)
            component.scripts.append(script(member))
        }
        return component
    }

    // MARK: - What it means

    var allScripts: [Script] { components.flatMap(\.scripts) }
    var runsScripts: Bool { allScripts.contains(where: \.isHook) }
    var installsNothing: Bool { !components.isEmpty && components.allSatisfy { !$0.hasPayload && $0.files.count <= 1 } }

    /// Where each file goes: the install location joined to its path.
    static func destination(of item: Bom.Item, in component: Component) -> String {
        var path = item.path
        if path.hasPrefix("./") { path.removeFirst(2) } else if path == "." { path = "" }
        let base = component.installLocation ?? "/"
        if path.isEmpty { return base }
        return base.hasSuffix("/") ? base + path : base + "/" + path
    }

    static let bundleExtensions: Set<String> = ["app", "framework", "plugin", "kext", "bundle", "appex", "prefpane",
                                                "systemextension", "qlgenerator", "mdimporter", "driver", "component",
                                                "vst", "vst3", "saver", "xpc"]

    /// The places it writes to, each with how many files go there.
    func destinations() -> [(path: String, files: Int, bytes: UInt64)] {
        var groups: [String: (Int, UInt64)] = [:], order: [String] = []
        for component in components {
            for item in component.files where item.kind != .directory {
                let parts = Self.destination(of: item, in: component).split(separator: "/").map(String.init)
                var key: [String] = []
                for part in parts {
                    key.append(part)
                    if Self.bundleExtensions.contains((part as NSString).pathExtension.lowercased()) || key.count == 3 { break }
                }
                let path = "/" + key.joined(separator: "/")
                if groups[path] == nil { order.append(path) }
                let current = groups[path] ?? (0, 0)
                groups[path] = (current.0 + 1, current.1 + item.size)
            }
        }
        return order.map { ($0, groups[$0]!.0, groups[$0]!.1) }
    }

    /// Files worth a word before installing: what starts by itself, what
    /// runs inside macOS, what runs as its owner whoever starts it.
    func notable() -> [(path: String, why: String)] {
        var out: [(String, String)] = []
        for component in components {
            for item in component.files {
                let path = Self.destination(of: item, in: component)
                let lower = path.lowercased()
                if item.kind == .file, item.mode & 0o6000 != 0 {
                    out.append((path, item.mode & 0o4000 != 0 ? "runs as its owner (\(item.user == 0 ? "root" : "user \(item.user)")), whoever starts it (setuid)"
                                : "runs with its group's rights (setgid)"))
                } else if item.kind == .file, lower.hasPrefix("/library/launchdaemons/") {
                    out.append((path, "a launch daemon: starts with the Mac, as root"))
                } else if item.kind == .file, lower.hasPrefix("/library/launchagents/") {
                    out.append((path, "a launch agent: starts at every login, for every user"))
                } else if item.kind == .directory, lower.hasSuffix(".kext"), !lower.contains(".kext/") {
                    out.append((path, "a kernel extension: runs inside macOS"))
                } else if item.kind == .file, lower.hasPrefix("/library/privilegedhelpertools/") {
                    out.append((path, "a privileged helper: runs as root"))
                } else if item.kind == .directory, lower.hasSuffix(".systemextension"), !lower.contains(".systemextension/") {
                    out.append((path, "a system extension"))
                } else if item.kind == .directory, lower.hasPrefix("/library/security/securityagentplugins/"),
                          lower.hasSuffix(".bundle"), !lower.contains(".bundle/") {
                    out.append((path, "an authorization plug-in: runs in the login window"))
                }
                if out.count >= 200 { return out }
            }
        }
        return out
    }
}
