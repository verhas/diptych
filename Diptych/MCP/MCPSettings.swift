import Foundation
import MCP

/// A deliberately curated, scalar subset of `Configuration` an MCP client can
/// read and change -- not everything in Settings. Left out on purpose:
/// structural things with their own editing rules and that are really a
/// dragging/arranging job, not a "turn this on or off" one (columnOrder,
/// enabledColumns, columnWidths, toolbar, favourites); and MCP's own
/// enable/port/token, since changing those over the very connection making
/// the call could cut it off mid-request.
@MainActor
enum MCPSettings {

    struct Item {
        let key: String
        let kind: String
        let description: String
        let allowedValues: [String]?
        let get: () -> Value
        let set: (Value) -> String?
    }

    private static func bool(_ key: String, _ description: String,
                             _ path: WritableKeyPath<Configuration, Bool>) -> Item {
        Item(key: key, kind: "boolean", description: description, allowedValues: nil,
             get: { .bool(ConfigStore.shared.configuration[keyPath: path]) },
             set: { value in
                 // `value`'s schema allows both boolean and string, since
                 // this same parameter also carries enum settings' values --
                 // and at least one real MCP client sends a plain true/false
                 // as the string "true"/"false" rather than a JSON boolean
                 // when a parameter's schema allows either, so both are
                 // accepted here rather than only the stricter one.
                 let b: Bool?
                 switch value.stringValue?.lowercased() {
                 case "true": b = true
                 case "false": b = false
                 default: b = value.boolValue
                 }
                 guard let b else { return "\(key) needs a boolean (true/false)." }
                 ConfigStore.shared.configuration[keyPath: path] = b
                 return nil
             })
    }

    private static func choice<E>(_ key: String, _ description: String,
                                  _ path: WritableKeyPath<Configuration, E>) -> Item
        where E: RawRepresentable & CaseIterable, E.RawValue == String {
        let allowed = E.allCases.map(\.rawValue)
        return Item(key: key, kind: "enum", description: description, allowedValues: allowed,
                    get: { .string(ConfigStore.shared.configuration[keyPath: path].rawValue) },
                    set: { value in
                        guard let raw = value.stringValue, let parsed = E(rawValue: raw) else {
                            return "\(key) must be one of \(allowed.joined(separator: ", "))."
                        }
                        ConfigStore.shared.configuration[keyPath: path] = parsed
                        return nil
                    })
    }

    private static func permissions(_ key: String, _ what: String,
                                    _ path: WritableKeyPath<Configuration, String>) -> Item {
        Item(key: key, kind: "string",
             description: "The permissions copied \(what) get when copyPermissions is fixed, "
                 + "as ls shows them: rw-r--r--, with s/S and t/T for setuid, setgid and sticky.",
             allowedValues: nil,
             get: { .string(ConfigStore.shared.configuration[keyPath: path]) },
             set: { value in
                 guard let text = value.stringValue, CopySettings.mode(from: text) != nil else {
                     return "\(key) must be nine characters like rw-r--r--."
                 }
                 ConfigStore.shared.configuration[keyPath: path] = text
                 return nil
             })
    }

    static let items: [Item] = [
        bool("copyExtendedAttributes", "A copy takes the original's extended attributes along.",
             \.copying.extendedAttributes),
        bool("copyAccessControlList", "A copy takes the original's access control list along.",
             \.copying.accessControlList),
        choice("copyCreatedDate",
               "A copy's created date: the original's, or the time of the copy (now).",
               \.copying.createdDate),
        choice("copyModifiedDate",
               "A copy's modified date: the original's, or the time of the copy (now).",
               \.copying.modifiedDate),
        choice("copyPermissions",
               "A copy's permissions: the original's, 0666 (folders 0777) less the umask, "
               + "or copyFilePermissions and copyFolderPermissions (fixed).",
               \.copying.permissions),
        permissions("copyFilePermissions", "files", \.copying.filePermissions),
        permissions("copyFolderPermissions", "folders", \.copying.folderPermissions),
        choice("copyGroup",
               "A copy's group: the original's, or (setgid) the target folder's when that "
               + "folder has the setgid bit.",
               \.copying.group),
        bool("confirmQuit", "Ask before quitting.", \.confirmQuit),
        bool("gitEnabled", "Version tracking.", \.gitEnabled),
        bool("gitCheckOnOpen",
             "Check with the server the first time a tracked folder with changes is opened.",
             \.gitCheckOnOpen),
        bool("gitUpdateWhenSending",
             "When a send is refused for being behind, catch up and send anyway.",
             \.gitUpdateWhenSending),
        bool("scriptsEnabled", "Run the scripts in ~/.diptych/scripts.", \.scriptsEnabled),
        bool("scriptsDeveloperMode", "Developer mode for writing scripts.", \.scriptsDeveloperMode),
        bool("useAppleIntelligence",
             "Use Apple Intelligence on this Mac to suggest file names.", \.useAppleIntelligence),
        bool("showTipsAtStartup", "Show a random tip once each time Diptych starts.",
             \.showTipsAtStartup),
        bool("renameOnClick",
             "Clicking the name of an already-selected file starts a rename; off, only F2 does.",
             \.renameOnClick),
        bool("soundsEnabled", "Play a sound after copy/move/trash finishes.", \.soundsEnabled),
        bool("foldersFirst", "Directories above files, rather than everything in one sequence.",
             \.foldersFirst),
        bool("nameSeparatorEnabled",
             "Put a separator character between words in a suggested name.",
             \.nameSeparatorEnabled),
        bool("nameUnicode",
             "Suggested names may use any letter; off keeps them to plain ASCII.", \.nameUnicode),
        bool("nameGermanSpelling",
             "In plain-ASCII suggested names, write \u{00e4}/\u{00f6}/\u{00fc} as ae/oe/ue.",
             \.nameGermanSpelling),
        bool("directoryDiffComparePermissions",
             "New Compare Folders windows default to comparing permissions.",
             \.directoryDiffComparePermissions),
        bool("directoryDiffCompareAttributes",
             "New Compare Folders windows default to comparing extended attributes.",
             \.directoryDiffCompareAttributes),
        bool("directoryDiffCompareACL",
             "New Compare Folders windows default to comparing ACLs.", \.directoryDiffCompareACL),
        bool("directoryDiffCompareModificationDate",
             "New Compare Folders windows default to comparing modification dates.",
             \.directoryDiffCompareModificationDate),
        bool("directoryDiffCompareCreationDate",
             "New Compare Folders windows default to comparing creation dates.",
             \.directoryDiffCompareCreationDate),
        bool("directoryDiffCompareOwnership",
             "New Compare Folders windows default to comparing owner and group.",
             \.directoryDiffCompareOwnership),
        bool("directoryDiffRecurseHiddenDirectories",
             "New Compare Folders windows default to recursing into hidden directories.",
             \.directoryDiffRecurseHiddenDirectories),
        Item(key: "updateCheckPreference",
             kind: "enum",
             description: "Whether, and how often, Diptych looks at GitHub for a newer release.",
             allowedValues: Configuration.UpdateCheckPreference.allCases.map(\.rawValue),
             get: { .string(ConfigStore.shared.configuration.updateCheckPreference.rawValue) },
             set: { value in
                 guard let raw = value.stringValue,
                       let parsed = Configuration.UpdateCheckPreference(rawValue: raw)
                 else {
                     return "updateCheckPreference must be one of "
                         + Configuration.UpdateCheckPreference.allCases.map(\.rawValue)
                             .joined(separator: ", ") + "."
                 }
                 ConfigStore.shared.configuration.updateCheckPreference = parsed
                 return nil
             }),
        Item(key: "clipboardImageFormat",
             kind: "enum",
             description: "What a picture from the clipboard is saved as with New from Clipboard.",
             allowedValues: Configuration.ClipboardImageFormat.allCases.map(\.rawValue),
             get: { .string(ConfigStore.shared.configuration.clipboardImageFormat.rawValue) },
             set: { value in
                 guard let raw = value.stringValue,
                       let parsed = Configuration.ClipboardImageFormat(rawValue: raw)
                 else {
                     return "clipboardImageFormat must be one of "
                         + Configuration.ClipboardImageFormat.allCases.map(\.rawValue)
                             .joined(separator: ", ") + "."
                 }
                 ConfigStore.shared.configuration.clipboardImageFormat = parsed
                 return nil
             }),
    ]

    static func item(for key: String) -> Item? {
        items.first { $0.key == key }
    }
}
