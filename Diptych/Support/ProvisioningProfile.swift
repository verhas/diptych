import Foundation
import Security

/// A provisioning profile, `.mobileprovision` or `.provisionprofile`: a
/// property list signed by Apple saying which app, made by which team and
/// signed with which certificates, may run where and with which
/// entitlements. Read and checked here; nothing is installed.
nonisolated struct ProvisioningProfile: Sendable {

    static let extensions: Set<String> = ["mobileprovision", "provisionprofile"]
    static let maximumSize = 4 * 1024 * 1024

    enum Problem: Error, CustomStringConvertible {
        case notSigned, noList
        var description: String {
            switch self {
            case .notSigned: "It is not a signed message (CMS), as a provisioning profile is."
            case .noList: "Its signed contents are not a property list."
            }
        }
    }

    enum Distribution: String, Sendable {
        case development = "Development"
        case adHoc = "Ad Hoc"
        case enterprise = "In-House (Enterprise)"
        case appStore = "App Store"
        case developerID = "Developer ID"
    }

    var name: String?
    var uuid: String?
    var appIDName: String?
    var applicationIdentifier: String?
    var teamName: String?
    var teams: [String] = []
    var platforms: [String] = []
    var created: Date?
    var expires: Date?
    var xcodeManaged = false
    var devices: [String] = []
    var allDevices = false
    var entitlements: [(key: String, value: String)] = []
    var certificates: [X509] = []
    var unreadableCertificates = 0
    var debuggable = false
    var distribution: Distribution

    /// The CMS signature: who made it, and whether it checks.
    var signers: [X509] = []
    var signedAt: Date?
    /// The signature over the contents verifies.
    var signatureValid: Bool?
    /// The signer's certificate leads to a root this Mac trusts, and the root is Apple's.
    var trust: String?
    var trusted: Bool?
    var byApple = false

    static func looksLikeProfile(_ data: Data) -> Bool {
        // A DER SEQUENCE holding the signedData OID near its start.
        guard data.count > 32, data.first == 0x30 else { return false }
        let oid: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]
        return data.prefix(32).range(of: Data(oid)) != nil
    }

    init(data: Data) throws {
        guard Self.looksLikeProfile(data) else { throw Problem.notSigned }
        let bytes = [UInt8](data)
        var content = Self.verify(data, into: &signatureValid, signedAt: &signedAt, trust: &trust,
                                  trusted: &trusted, byApple: &byApple)
        if content == nil { content = Self.encapsulated(bytes) }
        let details = MachOFile.CodeSignature.details(ofCMS: bytes)
        signers = details.0
        if signedAt == nil { signedAt = details.1 }
        guard let content,
              let list = try? PropertyListSerialization.propertyList(from: content, format: nil) as? [String: Any] else {
            throw Problem.noList
        }

        name = list["Name"] as? String
        uuid = list["UUID"] as? String
        appIDName = list["AppIDName"] as? String
        teamName = list["TeamName"] as? String
        teams = list["TeamIdentifier"] as? [String] ?? []
        platforms = list["Platform"] as? [String] ?? []
        created = list["CreationDate"] as? Date
        expires = list["ExpirationDate"] as? Date
        xcodeManaged = list["IsXcodeManaged"] as? Bool ?? false
        devices = list["ProvisionedDevices"] as? [String] ?? []
        allDevices = list["ProvisionsAllDevices"] as? Bool ?? false
        for item in (list["DeveloperCertificates"] as? [Any] ?? []).prefix(500) {
            if let der = item as? Data, let certificate = try? X509(der: [UInt8](der)) {
                certificates.append(certificate)
            } else {
                unreadableCertificates += 1
            }
        }
        let rights = list["Entitlements"] as? [String: Any] ?? [:]
        applicationIdentifier = (rights["application-identifier"] ?? rights["com.apple.application-identifier"]) as? String
        debuggable = (rights["get-task-allow"] ?? rights["com.apple.security.get-task-allow"]) as? Bool ?? false
        entitlements = rights.keys.sorted().map { ($0, Self.text(rights[$0] as Any)) }

        let names = certificates.map { X509.shortName($0.subject) }
        // A Developer ID profile says "all devices" too: the certificate tells.
        if names.contains(where: { $0.hasPrefix("Developer ID") }) {
            distribution = .developerID
        } else if allDevices {
            distribution = .enterprise
        } else if !devices.isEmpty {
            distribution = debuggable ? .development : .adHoc
        } else if debuggable || names.contains(where: { $0.contains("Development") || $0.contains("Developer:") }) {
            distribution = .development
        } else {
            distribution = .appStore
        }
    }

    /// Whether the profile may still be used, by its own expiry date.
    func isExpired(at now: Date = Date()) -> Bool { expires.map { $0 < now } ?? false }

    /// A team ID before the bundle identifier, as the identifier is written in it.
    var bundleIdentifier: String? {
        guard let identifier = applicationIdentifier else { return nil }
        for team in teams + ["\u{0}"] where identifier.hasPrefix(team + ".") { return String(identifier.dropFirst(team.count + 1)) }
        if let dot = identifier.firstIndex(of: "."), identifier[..<dot].count == 10 { return String(identifier[identifier.index(after: dot)...]) }
        return identifier
    }

    // MARK: - The signature

    /// The signed contents, checked by the system's CMS decoder: the
    /// signature over them, then the signer's chain -- with no network, as of
    /// when it was signed, so neither a sleeping network nor time passing
    /// changes the answer.
    private static func verify(_ data: Data, into valid: inout Bool?, signedAt: inout Date?, trust trustText: inout String?,
                               trusted: inout Bool?, byApple: inout Bool) -> Data? {
        var made: CMSDecoder?
        guard CMSDecoderCreate(&made) == errSecSuccess, let decoder = made else { return nil }
        let fed = data.withUnsafeBytes { buffer in
            CMSDecoderUpdateMessage(decoder, buffer.baseAddress!, buffer.count)
        }
        guard fed == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return nil }
        var content: CFData?
        CMSDecoderCopyContent(decoder, &content)
        var count = 0
        CMSDecoderGetNumSigners(decoder, &count)
        guard count > 0 else { valid = false; return content as Data? }
        var time = CFAbsoluteTime()
        if CMSDecoderCopySignerSigningTime(decoder, 0, &time) == errSecSuccess { signedAt = Date(timeIntervalSinceReferenceDate: time) }

        var status = CMSSignerStatus.unsigned
        var trust: SecTrust?
        var result = OSStatus(0)
        let policy = SecPolicyCreateBasicX509()
        guard CMSDecoderCopySignerStatus(decoder, 0, policy, false, &status, &trust, &result) == errSecSuccess else {
            return content as Data?
        }
        valid = status == .valid || status == .invalidCert
        if status == .invalidSignature { valid = false }
        if let trust {
            SecTrustSetNetworkFetchAllowed(trust, false)
            if let signedAt { SecTrustSetVerifyDate(trust, signedAt as CFDate) }
            var error: CFError?
            trusted = SecTrustEvaluateWithError(trust, &error)
            let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
            if let root = chain.last {
                let name = SecCertificateCopySubjectSummary(root) as String? ?? ""
                byApple = trusted == true && name.hasPrefix("Apple Root CA")
                trustText = name
            }
            if trusted != true, let error { trustText = CFErrorCopyDescription(error) as String? }
        }
        return content as Data?
    }

    /// The signed contents read straight from the structure, when the
    /// system's decoder refuses the message.
    private static func encapsulated(_ bytes: [UInt8]) -> Data? {
        guard let info = try? DER.leading(bytes).children(), info.count == 2,
              let signed = try? info[1].unwrapped().children(), signed.count >= 3,
              let content = try? signed[2].children(), content.count == 2,
              let octets = try? content[1].unwrapped().octets() else { return nil }
        return Data(octets)
    }

    // MARK: - Values as text

    static func text(_ value: Any) -> String {
        switch value {
        case let flag as Bool where CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(): flag ? "yes" : "no"
        case let number as NSNumber: number.stringValue
        case let string as String: string
        case let date as Date: date.formatted(date: .long, time: .shortened)
        case let data as Data: "\(data.count) bytes"
        case let list as [Any]: list.prefix(200).map(text).joined(separator: ", ")
        case let dictionary as [String: Any]:
            dictionary.keys.sorted().prefix(200).map { "\($0): \(text(dictionary[$0] as Any))" }.joined(separator: "; ")
        default: String(describing: value)
        }
    }
}
