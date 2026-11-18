import CryptoKit
import Foundation

/// An application -- or another bundle of code: an app extension, an XPC
/// service, a framework, a plug-in -- read as a folder: its Info.plist, its
/// main executable and signature, what is embedded in it, where it came
/// from. Nothing is launched, registered or looked up online.
///
/// `read` is quick, for the page shown at once; `seal` and `size` walk every
/// file, and run after.
nonisolated struct AppBundle {

    static let extensions: Set<String> = ["app", "appex", "xpc", "framework", "bundle", "plugin", "kext",
                                          "systemextension", "saver", "prefpane", "qlgenerator", "mdimporter",
                                          "driver", "component", "vst", "vst3"]

    enum Problem: Error, CustomStringConvertible {
        case noInfo
        var description: String { "It has no Info.plist, so it is not a bundle macOS can use." }
    }

    struct Embedded {
        let group: String
        let name: String
        let version: String?
        let identifier: String?
        let team: String?
        let signed: Bool
    }

    struct Permission {
        let what: String
        let reason: String
    }

    struct Quarantine {
        let agent: String
        let date: Date?
        let opened: Bool
    }

    let url: URL
    /// Where the bundle's files are: `Contents` on macOS, the bundle itself
    /// for an iOS app or a shallow bundle, `Resources` in a framework.
    let contents: URL
    let info: [String: Any]
    let infoData: Data

    var executable: MachOFile?
    /// The signature of an executable that is a script.
    var scriptSignature: MachOFile.CodeSignature?
    var executableURL: URL?
    var executableProblem: String?
    var embedded: [Embedded] = []
    var permissions: [Permission] = []
    var localizations: [String] = []
    var technologies: [String] = []
    var stapled = false
    var fromAppStore = false
    var quarantine: Quarantine?
    var whereFrom: [String] = []
    var translocated = false

    /// The main executable's signature, Mach-O or script.
    var signature: MachOFile.CodeSignature? {
        executable?.slices.compactMap { $0.image?.signature }.first ?? scriptSignature
    }

    // MARK: - Info.plist

    func string(_ key: String) -> String? {
        (info[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    var name: String {
        string("CFBundleDisplayName") ?? string("CFBundleName") ?? url.deletingPathExtension().lastPathComponent
    }
    var identifier: String? { string("CFBundleIdentifier") }
    var version: String? { string("CFBundleShortVersionString") }
    var build: String? { string("CFBundleVersion") }
    var copyright: String? { string("NSHumanReadableCopyright") }
    var minimumSystem: String? { string("LSMinimumSystemVersion") }

    var category: String? {
        guard let raw = string("LSApplicationCategoryType") else { return nil }
        let last = raw.replacingOccurrences(of: "public.app-category.", with: "")
        return last.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    var kind: String {
        let type = string("CFBundlePackageType")
        switch url.pathExtension.lowercased() {
        case "app":
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Wrapper").path)
                || FileManager.default.fileExists(atPath: url.appendingPathComponent("WrappedBundle").path) {
                return "iPhone and iPad app"
            }
            if info["LSBackgroundOnly"] as? Bool == true { return "Background application" }
            if info["LSUIElement"] as? Bool == true || string("LSUIElement") == "1" { return "Menu bar application" }
            return "Application"
        case "appex": return "App extension"
        case "xpc": return "XPC service"
        case "framework": return "Framework"
        case "kext": return "Kernel extension"
        case "systemextension": return "System extension"
        case "saver": return "Screen saver"
        case "prefpane": return "System Settings pane"
        case "qlgenerator": return "Quick Look generator"
        case "mdimporter": return "Spotlight importer"
        case "component": return "Audio Unit"
        case "vst", "vst3": return "VST audio plug-in"
        default: return type == "APPL" ? "Application" : "Plug-in bundle"
        }
    }

    /// What the app extension extends, from its NSExtensionPointIdentifier.
    var extensionPoint: String? {
        (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String
    }

    var documentTypes: [String] {
        ((info["CFBundleDocumentTypes"] as? [[String: Any]]) ?? []).compactMap { type in
            (type["CFBundleTypeName"] as? String)
                ?? (type["LSItemContentTypes"] as? [String])?.joined(separator: ", ")
                ?? (type["CFBundleTypeExtensions"] as? [String]).map { $0.map { "." + $0 }.joined(separator: ", ") }
        }
    }

    var urlSchemes: [String] {
        ((info["CFBundleURLTypes"] as? [[String: Any]]) ?? []).flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
    }

    var builtWith: String? {
        var parts: [String] = []
        if let xcode = string("DTXcode"), let number = Int(xcode) {
            // "1610" is Xcode 16.1; "0830" is 8.3.
            parts.append("Xcode \(number / 100).\(number % 100 / 10)" + (number % 10 == 0 ? "" : ".\(number % 10)"))
        }
        if let sdk = string("DTSDKName") { parts.append(sdk.replacingOccurrences(of: "macosx", with: "macOS SDK ")) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: - Reading

    /// `shallow` reads only the Info.plist and the executable: enough for
    /// code embedded in another bundle.
    static func read(_ url: URL, verify: Bool = false, shallow: Bool = false) throws -> AppBundle {
        let manager = FileManager.default
        let candidates = [url.appendingPathComponent("Contents"), url.appendingPathComponent("Resources"),
                          url.appendingPathComponent("Versions/Current/Resources"), url]
        guard let contents = candidates.first(where: { manager.fileExists(atPath: $0.appendingPathComponent("Info.plist").path) }),
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Problem.noInfo
        }
        var bundle = AppBundle(url: url, contents: contents, info: info, infoData: data)
        bundle.readExecutable(verify: verify)
        guard !shallow else { return bundle }
        bundle.readEmbedded()
        bundle.readPermissions()
        bundle.readOrigin()
        return bundle
    }

    /// Where the main executable is in this layout.
    static func mainExecutable(of url: URL, contents: URL, name: String) -> URL {
        if url.pathExtension.lowercased() == "framework" {
            let top = url.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: top.path) ? top
                : url.appendingPathComponent("Versions/Current/\(name)")
        }
        if contents.lastPathComponent == "Contents" { return contents.appendingPathComponent("MacOS/\(name)") }
        return url.appendingPathComponent(name)
    }

    private mutating func readExecutable(verify: Bool) {
        // Without the key, macOS takes the bundle's own name.
        let fallback = url.deletingPathExtension().lastPathComponent
        guard let name = string("CFBundleExecutable")
                ?? (FileManager.default.fileExists(atPath: Self.mainExecutable(of: url, contents: contents, name: fallback).path)
                    ? fallback : nil) else {
            executableProblem = "Its Info.plist names no executable."
            return
        }
        let found = Self.mainExecutable(of: url, contents: contents, name: name).resolvingSymlinksInPath()
        executableURL = found
        guard let data = try? Data(contentsOf: found, options: .alwaysMapped) else {
            executableProblem = "Its executable, \(name), is missing."
            return
        }
        guard MachOFile.looksLikeMachO(data) else {
            // A script: its signature, if any, is in extended attributes.
            scriptSignature = MachOFile.CodeSignature.fromFolder(sealBase.appendingPathComponent("_CodeSignature"),
                                                                 code: data, verify: verify)
                ?? MachOFile.CodeSignature.fromAttributes(of: found, code: data, verify: verify)
            let line = data.starts(with: [0x23, 0x21])
                ? String(decoding: data.prefix(256).prefix { $0 != 0x0A }, as: UTF8.self) : nil
            executableProblem = line.map { "Its executable, \(name), is a script: \($0)" }
                ?? "Its executable, \(name), is not a program macOS can run."
            return
        }
        do {
            executable = try MachOFile(data: data, verify: verify)
        } catch {
            executableProblem = "Its executable, \(name), cannot be read: \(error)"
        }
    }

    /// The code inside: frameworks, plug-ins, extensions, helpers, login
    /// items, services -- each with its version and its signer's team.
    private mutating func readEmbedded() {
        let manager = FileManager.default
        let places: [(String, String, Set<String>?)] = [
            ("Frameworks", "Frameworks", ["framework", "dylib"]),
            ("PlugIns", "Plug-ins and extensions", nil),
            ("Library/LoginItems", "Login items", nil),
            ("Library/LaunchServices", "Privileged helpers", nil),
            ("Library/SystemExtensions", "System extensions", nil),
            ("XPCServices", "XPC services", nil),
            ("Helpers", "Helpers", nil),
            ("Library/QuickLook", "Quick Look extensions", nil),
            ("Library/Spotlight", "Spotlight importers", nil),
            ("Library/LaunchAgents", "Starts at login (launch agents)", ["plist"]),
            ("Library/LaunchDaemons", "Runs as a system service (launch daemons)", ["plist"]),
        ]
        for (path, group, only) in places {
            let folder = contents.appendingPathComponent(path)
            guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let item = folder.appendingPathComponent(name)
                let ext = item.pathExtension.lowercased()
                if let only, !only.contains(ext) { continue }
                embedded.append(Self.embedded(item, group: group))
            }
        }
        // Other programs beside the main one.
        if contents.lastPathComponent == "Contents", let main = string("CFBundleExecutable"),
           let names = try? manager.contentsOfDirectory(atPath: contents.appendingPathComponent("MacOS").path) {
            for name in names.sorted() where name != main && !name.hasPrefix(".") {
                embedded.append(Self.embedded(contents.appendingPathComponent("MacOS/\(name)"), group: "Other programs"))
            }
        }
        let frameworks = Set(embedded.filter { $0.group == "Frameworks" }.map(\.name))
        let known: [(String, String)] = [
            ("Electron Framework.framework", "Electron"), ("Chromium Embedded Framework.framework", "Chromium Embedded"),
            ("QtCore.framework", "Qt"), ("FlutterMacOS.framework", "Flutter"), ("Python.framework", "Python"),
            ("Sparkle.framework", "Sparkle (updates itself)"), ("libswift_Concurrency.dylib", "Swift (bundled runtime)"),
            ("Squirrel.framework", "Squirrel (updates itself)"), ("ReactiveObjC.framework", "ReactiveObjC"),
            ("Mono.framework", "Mono"), ("libmonosgen-2.0.dylib", ".NET (Mono)"),
        ]
        technologies = known.filter { frameworks.contains($0.0) }.map(\.1)
        if manager.fileExists(atPath: contents.appendingPathComponent("MonoBundle").path) { technologies.append(".NET (Mono)") }
        if manager.fileExists(atPath: contents.appendingPathComponent("runtime").path)
            || manager.fileExists(atPath: contents.appendingPathComponent("app").appendingPathComponent(".jpackage.xml").path)
            || string("JVMMainClassName") != nil || info["JavaX"] != nil {
            technologies.append("Java")
        }
        if executable?.slices.contains(where: { $0.image?.platform == "Mac Catalyst" }) == true {
            technologies.append("Mac Catalyst (an iPad app brought to the Mac)")
        }
        if let resources = try? manager.contentsOfDirectory(atPath: resourcesFolder.path) {
            localizations = resources.filter { $0.hasSuffix(".lproj") && $0 != "Base.lproj" }
                .map { String($0.dropLast(6)) }.sorted()
        }
        stapled = manager.fileExists(atPath: contents.appendingPathComponent("CodeResources").path)
        fromAppStore = manager.fileExists(atPath: contents.appendingPathComponent("_MASReceipt/receipt").path)
    }

    var resourcesFolder: URL {
        contents.lastPathComponent == "Contents" ? contents.appendingPathComponent("Resources") : contents
    }

    static func embedded(_ item: URL, group: String) -> Embedded {
        var version: String?, identifier: String?, executable = item.resolvingSymlinksInPath()
        if let nested = try? AppBundle.read(item, shallow: true) {
            version = nested.version ?? nested.build
            identifier = nested.identifier
            executable = nested.executableURL ?? item
        } else if item.pathExtension == "plist", let data = try? Data(contentsOf: item),
                  let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            identifier = list["Label"] as? String
            let program = (list["Program"] as? String) ?? (list["ProgramArguments"] as? [String])?.first
            return Embedded(group: group, name: item.lastPathComponent, version: program, identifier: identifier,
                            team: nil, signed: true)
        }
        var team: String?, signed = false
        if let data = try? Data(contentsOf: executable, options: .alwaysMapped),
           let file = try? MachOFile(data: data, verify: false) {
            let signature = file.slices.compactMap { $0.image?.signature }.first
            signed = signature != nil
            team = signature?.teamID
        }
        return Embedded(group: group, name: item.lastPathComponent, version: version, identifier: identifier,
                        team: team, signed: signed)
    }

    /// The NS…UsageDescription keys: what the app will ask the user for, in
    /// the words it will ask with.
    private mutating func readPermissions() {
        let names: [String: String] = [
            "NSCameraUsageDescription": "Camera", "NSMicrophoneUsageDescription": "Microphone",
            "NSLocationUsageDescription": "Location", "NSLocationWhenInUseUsageDescription": "Location",
            "NSLocationAlwaysAndWhenInUseUsageDescription": "Location, always",
            "NSContactsUsageDescription": "Contacts", "NSCalendarsUsageDescription": "Calendars",
            "NSCalendarsFullAccessUsageDescription": "Calendars", "NSRemindersUsageDescription": "Reminders",
            "NSRemindersFullAccessUsageDescription": "Reminders", "NSPhotoLibraryUsageDescription": "Photos",
            "NSPhotoLibraryAddUsageDescription": "Adding to Photos",
            "NSAppleEventsUsageDescription": "Controlling other apps", "NSBluetoothAlwaysUsageDescription": "Bluetooth",
            "NSBluetoothPeripheralUsageDescription": "Bluetooth", "NSDesktopFolderUsageDescription": "The Desktop folder",
            "NSDocumentsFolderUsageDescription": "The Documents folder",
            "NSDownloadsFolderUsageDescription": "The Downloads folder",
            "NSRemovableVolumesUsageDescription": "Removable disks", "NSNetworkVolumesUsageDescription": "Network volumes",
            "NSFileProviderDomainUsageDescription": "Files in cloud storage",
            "NSSystemAdministrationUsageDescription": "Administering the system",
            "NSSpeechRecognitionUsageDescription": "Speech recognition", "NSLocalNetworkUsageDescription": "The local network",
            "NSMotionUsageDescription": "Motion", "NSHomeKitUsageDescription": "Home", "NSFaceIDUsageDescription": "Face ID",
            "NSAudioCaptureUsageDescription": "Recording other apps' audio",
            "NSScreenCaptureUsageDescription": "Recording the screen", "NSSiriUsageDescription": "Siri",
            "NSFocusStatusUsageDescription": "Focus status", "NSHealthShareUsageDescription": "Health data",
            "NSAppleMusicUsageDescription": "Music library", "NSIdentityUsageDescription": "Identity",
        ]
        permissions = info.keys.filter { $0.hasSuffix("UsageDescription") }.sorted().compactMap { key in
            guard let reason = string(key) else { return nil }
            let what = names[key] ?? key.replacingOccurrences(of: "UsageDescription", with: "")
                .replacingOccurrences(of: "NS", with: "")
            return Permission(what: what, reason: reason)
        }
    }

    // MARK: - Where it came from

    private mutating func readOrigin() {
        translocated = url.path.contains("/AppTranslocation/")
        if let raw = Self.attribute("com.apple.quarantine", of: url),
           let text = String(data: raw, encoding: .utf8) {
            let parts = text.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            let flags = parts.first.flatMap { UInt32($0, radix: 16) } ?? 0
            let date = parts.count > 1 ? UInt64(parts[1], radix: 16).map { Date(timeIntervalSince1970: TimeInterval($0)) } : nil
            quarantine = Quarantine(agent: parts.count > 2 ? parts[2] : "", date: date, opened: flags & 0x40 != 0)
        }
        if let raw = Self.attribute("com.apple.metadata:kMDItemWhereFroms", of: url),
           let list = try? PropertyListSerialization.propertyList(from: raw, format: nil) as? [String] {
            whereFrom = list.filter { !$0.isEmpty }
        }
    }

    static func attribute(_ name: String, of url: URL) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        return read == size ? data : nil
    }

    // MARK: - The seal

    enum Seal: Equatable {
        /// Signed, and every file it lists hashes as listed.
        case intact(files: Int)
        /// What differs: changed and missing files, each with its path.
        case broken(changed: [String], missing: [String], files: Int)
        /// No seal: the bundle is not signed, or signed without resources.
        case none
        case unchecked(String)
    }

    /// `_CodeSignature/CodeResources`, checked: the main executable's
    /// signature records its hash and the Info.plist's, the seal records
    /// every other file's -- and, for code nested inside, its cdhash.
    func seal(limit: Int = 1_000_000_000) -> Seal {
        let base = sealBase
        let sealURL = base.appendingPathComponent("_CodeSignature/CodeResources")
        guard let signature else {
            return executable == nil && executableURL == nil ? .unchecked("its executable cannot be read") : .none
        }
        var changed: [String] = [], missing: [String] = []
        if signature.matches(slot: 1, infoData) == false { changed.append("Info.plist") }
        guard let data = try? Data(contentsOf: sealURL) else {
            return signature.special[3].map { $0.contains { $0 != 0 } } == true
                ? .broken(changed: changed, missing: ["_CodeSignature/CodeResources"], files: 0)
                : (changed.isEmpty ? .none : .broken(changed: changed, missing: [], files: 0))
        }
        if signature.matches(slot: 3, data) == false { changed.append("_CodeSignature/CodeResources") }
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let files = (list["files2"] ?? list["files"]) as? [String: Any] else {
            return .unchecked("its seal cannot be read")
        }
        // Too big is known before any hashing: the sizes are cheap to add up.
        var total = 0
        for (path, entry) in files where (entry as? [String: Any])?["cdhash"] == nil {
            total += (try? base.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
            if total > limit {
                return .unchecked("its sealed files are over "
                                  + ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))
            }
        }
        for (path, entry) in files {
            let file = base.appendingPathComponent(path)
            var expected: [UInt8]?, sha256 = false, optional = false
            if let hash = entry as? Data {
                expected = Array(hash)
            } else if let entry = entry as? [String: Any] {
                optional = entry["optional"] as? Bool ?? false
                if let link = entry["symlink"] as? String {
                    let found = try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)
                    if found == nil { if !optional { missing.append(path) } } else if found != link { changed.append(path) }
                    continue
                }
                if let cdhash = entry["cdhash"] as? Data {
                    guard let nested = Self.nestedSignature(of: file) else {
                        if !optional { missing.append(path) }
                        continue
                    }
                    // Signed again since -- an updater does that -- it is
                    // still accepted when it meets the recorded requirement.
                    if !nested.cdhashes.contains(Array(cdhash)),
                       !Self.meets(entry["requirement"] as? String, nested) {
                        changed.append(path)
                    }
                    continue
                }
                if let hash = entry["hash2"] as? Data { expected = Array(hash); sha256 = true }
                else if let hash = entry["hash"] as? Data { expected = Array(hash) }
            }
            guard let expected else { continue }
            // Mapping costs more than reading for the many small files.
            let big = ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 1 << 20
            guard let contents = try? Data(contentsOf: file, options: big ? .alwaysMapped : []) else {
                if !optional { missing.append(path) }
                continue
            }
            let digest = sha256 ? Array(SHA256.hash(data: contents)) : Array(Insecure.SHA1.hash(data: contents))
            if digest != expected { changed.append(path) }
        }
        // The main executable's own pages.
        if executable?.slices.contains(where: { $0.image?.signature?.isIntact == false }) == true
            || scriptSignature?.isIntact == false {
            changed.insert("the main executable", at: 0)
        }
        if changed.isEmpty && missing.isEmpty { return .intact(files: files.count) }
        return .broken(changed: changed.sorted(), missing: missing.sorted(), files: files.count)
    }

    /// Where the seal and the paths in it start: `Contents`, a framework's
    /// version folder, or the bundle itself.
    var sealBase: URL {
        if contents.lastPathComponent == "Contents" { return contents }
        // A framework's Resources is a link into its current version.
        if contents.lastPathComponent == "Resources", contents != url {
            return contents.resolvingSymlinksInPath().deletingLastPathComponent()
        }
        return url
    }

    /// The signature of nested code: a bundle's main executable, a
    /// framework's binary without an Info.plist, a resource bundle's
    /// detached signature, or a file signed in its attributes.
    static func nestedSignature(of item: URL) -> MachOFile.CodeSignature? {
        let manager = FileManager.default
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: item.path, isDirectory: &isFolder) else { return nil }
        var code = item, folder: URL?
        if isFolder.boolValue {
            let name = item.deletingPathExtension().lastPathComponent
            if let nested = try? AppBundle.read(item, shallow: true) {
                folder = nested.sealBase.appendingPathComponent("_CodeSignature")
                code = nested.executableURL ?? item
            } else {
                let candidates = [item.appendingPathComponent(name), item.appendingPathComponent("Contents/MacOS/\(name)"),
                                  item.appendingPathComponent("Versions/Current/\(name)")]
                code = candidates.first { manager.fileExists(atPath: $0.path) }?.resolvingSymlinksInPath() ?? item
                folder = [item.appendingPathComponent("Versions/Current/_CodeSignature"),
                          item.appendingPathComponent("Contents/_CodeSignature"),
                          item.appendingPathComponent("_CodeSignature")]
                    .first { manager.fileExists(atPath: $0.path) }
            }
        }
        let data = (try? Data(contentsOf: code, options: .alwaysMapped)) ?? Data()
        if let file = try? MachOFile(data: data, verify: true),
           let signature = file.slices.compactMap({ $0.image?.signature }).first {
            var merged = signature
            merged.cdhashes = file.slices.compactMap { $0.image?.signature }.flatMap(\.cdhashes)
            if file.slices.contains(where: { $0.image?.signature?.isIntact == false }) { merged.mismatch = "changed" }
            return merged
        }
        if let folder, let signature = MachOFile.CodeSignature.fromFolder(folder, code: data, verify: !data.isEmpty) {
            return signature
        }
        return code == item || !isFolder.boolValue
            ? MachOFile.CodeSignature.fromAttributes(of: code, code: data, verify: true) : nil
    }

    /// Whether re-signed nested code still meets its seal entry's
    /// requirement, as far as it can be told without evaluating it: signed,
    /// intact, by the team the requirement names.
    static func meets(_ requirement: String?, _ signature: MachOFile.CodeSignature) -> Bool {
        guard let requirement, signature.isIntact != false else { return false }
        if let range = requirement.range(of: #"subject\.OU\]\s*=\s*"?([A-Z0-9]+)"?"#, options: .regularExpression) {
            let team = requirement[range].split(separator: "=").last?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            return team == signature.teamID
        }
        if requirement.contains("identifier ") {
            let name = requirement.components(separatedBy: "identifier ").dropFirst().first?
                .split(separator: " ").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            if let name, name != signature.identifier { return false }
        }
        return !signature.certificates.isEmpty || signature.platformBinary || requirement.contains("cdhash") == false
    }

    /// Bytes on disk and files, counted.
    static func size(of url: URL) -> (bytes: Int64, files: Int) {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys:
            [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return (0, 0) }
        var bytes: Int64 = 0, files = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return (bytes, files)
    }
}
