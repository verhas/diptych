import Foundation

/// A provisioning profile as a page: which app and team, until when, for
/// which devices, with which entitlements and certificates -- and whether
/// Apple's signature on it holds.
nonisolated enum ProvisioningReport {

    typealias R = ExecutableReport

    static func html(for profile: ProvisioningProfile, url: URL, size: Int, now: Date = Date()) -> String {
        let name = url.lastPathComponent
        var body = "<h1>\(R.escape(profile.name ?? name))</h1>"
        let platform = profile.platforms.map(platformName).joined(separator: ", ")
        body += "<p class=lead>\(R.escape("Provisioning profile, \(profile.distribution.rawValue)\(platform.isEmpty ? "" : ", " + platform), \(R.bytes(size))"))</p>"
        body += "<p class=meta>\(R.escape(url.path))</p>"

        if profile.isExpired(at: now) {
            body += "<p class=warn>This profile expired on \(R.escape(profile.expires!.formatted(date: .long, time: .shortened))): "
                + "an app signed with it no longer installs or starts.</p>"
        }
        let expired = profile.certificates.filter { $0.isExpired(at: now) }
        if !profile.certificates.isEmpty, expired.count == profile.certificates.count {
            body += "<p class=warn>Every certificate in it has expired: nobody can sign an app with this profile any more.</p>"
        }
        if profile.signatureValid == false {
            body += "<p class=warn>Its signature does not match its contents: it was changed after it was signed, and no device accepts it.</p>"
        }

        body += "<div class=card><div class=head><b>Profile</b></div><div class=cert>"
        if let appID = profile.appIDName { body += R.row("App ID name", R.escape(appID)) }
        if let identifier = profile.applicationIdentifier {
            var text = "<code>\(R.escape(identifier))</code>"
            if identifier.hasSuffix("*") { text += " <span class=dim>— a wildcard: any app of the team whose identifier matches</span>" }
            body += R.row("App identifier", text)
        }
        if let team = profile.teamName ?? profile.teams.first {
            var text = R.escape(team)
            if profile.teamName != nil, !profile.teams.isEmpty { text += " <code class=dim>\(R.escape(profile.teams.joined(separator: ", ")))</code>" }
            body += R.row("Team", text)
        }
        body += R.row("Kind", R.escape(profile.distribution.rawValue) + " <span class=dim>— \(R.escape(kindText(profile.distribution)))</span>")
        if let created = profile.created { body += R.row("Made", R.escape(created.formatted(date: .long, time: .shortened))) }
        if let expires = profile.expires {
            var text = R.escape(expires.formatted(date: .long, time: .shortened))
            if expires < now {
                text += " <span class=bad>expired</span>"
            } else if expires.timeIntervalSince(now) < 30 * 86_400 {
                let days = max(0, Int(expires.timeIntervalSince(now) / 86_400))
                text += " <span class=soon>expires in \(days) day\(days == 1 ? "" : "s")</span>"
            }
            body += R.row("Expires", text)
        }
        if profile.xcodeManaged { body += R.row("Managed", "by Xcode <span class=dim>— it renews it on its own</span>") }
        if let uuid = profile.uuid { body += R.row("UUID", "<code>\(R.escape(uuid))</code>") }
        body += "</div></div>"

        body += "<div class=card><div class=head><b>Signature</b></div><div class=cert>"
        if let signer = profile.signers.first(where: { !$0.isAuthority }) ?? profile.signers.first {
            body += R.row("Signed by", R.escape(X509.shortName(signer.subject)))
        }
        if let date = profile.signedAt { body += R.row("Signed at", R.escape(date.formatted(date: .long, time: .shortened))) }
        let seal: String = switch profile.signatureValid {
        case .some(true): "<span class=good>intact</span> <span class=dim>— the signature matches the contents</span>"
        case .some(false): "<span class=bad>broken</span> — the contents changed after signing"
        case .none: "<span class=dim>not checked</span>"
        }
        body += R.row("Seal", seal)
        if let trusted = profile.trusted {
            body += R.row("Issued by", trusted
                ? (profile.byApple ? "<span class=good>Apple</span> <span class=dim>— the chain leads to \(R.escape(profile.trust ?? "Apple's root"))</span>"
                   : "\(R.escape(profile.trust ?? "a trusted root")) <span class=soon>— not Apple: no device accepts it</span>")
                : "<span class=bad>not trusted</span> — \(R.escape(R.lowercasedFirst(profile.trust ?? "the chain does not lead to a trusted root")))")
        }
        body += "</div></div>"

        // Devices.
        if profile.distribution == .developerID {
            body += "<h2>Devices</h2><p class=dim>Any Mac: Developer ID is for apps given out outside the App Store.</p>"
        } else if profile.allDevices {
            body += "<h2>Devices</h2><p class=dim>Any device: an in-house profile runs wherever the organisation installs it.</p>"
        } else if profile.devices.isEmpty {
            body += "<h2>Devices</h2><p class=dim>None listed: \(profile.distribution == .developerID ? "it runs on any Mac" : "the App Store decides where it runs").</p>"
        } else {
            body += "<details><summary><h2>Devices <span class=count>\(profile.devices.count)</span></h2></summary><table class=summary>"
            body += profile.devices.prefix(5000).map { "<tr><td><code>\(R.escape($0))</code></td></tr>" }.joined()
            body += "</table></details>"
        }

        if !profile.entitlements.isEmpty {
            body += "<h2>Entitlements <span class=count>\(profile.entitlements.count)</span></h2><table class=summary>"
            for (key, value) in profile.entitlements {
                body += "<tr><td><code>\(R.escape(key))</code>"
                if let meaning = meanings[key] { body += "<br><span class=dim>\(R.escape(meaning))</span>" }
                body += "</td><td>\(R.escape(String(value.prefix(4000))))</td></tr>"
            }
            body += "</table>"
        }

        body += "<h2>Certificates <span class=count>\(profile.certificates.count)</span></h2>"
        body += "<p class=dim>Only an app signed with one of these may use the profile.</p><table class=summary>"
        body += "<tr><th>Certificate</th><th>Valid until</th><th>SHA-1</th></tr>"
        for certificate in profile.certificates.sorted(by: { $0.notAfter > $1.notAfter }) {
            body += "<tr><td>\(R.escape(X509.shortName(certificate.subject)))</td>"
            body += "<td>\(KeyStoreReport.validity(certificate, now: now, short: true))</td>"
            body += "<td><code>\(R.escape(certificate.sha1))</code></td></tr>"
        }
        if profile.unreadableCertificates > 0 {
            body += "<tr><td colspan=3 class=dim>and \(profile.unreadableCertificates) that cannot be read</td></tr>"
        }
        body += "</table>"
        return KeyStoreReport.page(title: name, body: R.style + body)
    }

    static func html(failure: Error, url: URL, size: Int) -> String {
        R.html(failure: failure, kind: "Provisioning profile", name: url.lastPathComponent,
               path: url.deletingLastPathComponent().path, size: size)
    }

    private static func platformName(_ platform: String) -> String {
        switch platform.lowercased() {
        case "ios": "iOS"
        case "osx", "macos": "macOS"
        case "tvos": "tvOS"
        case "watchos": "watchOS"
        case "xros", "visionos": "visionOS"
        default: platform
        }
    }

    private static func kindText(_ kind: ProvisioningProfile.Distribution) -> String {
        switch kind {
        case .development: "for running and debugging on the listed devices"
        case .adHoc: "for testing on the listed devices, without a debugger"
        case .enterprise: "for an organisation's own devices, outside the App Store"
        case .appStore: "for uploading to the App Store or TestFlight"
        case .developerID: "for apps distributed outside the Mac App Store"
        }
    }

    private static let meanings: [String: String] = [
        "application-identifier": "the app this profile is for",
        "com.apple.application-identifier": "the app this profile is for",
        "com.apple.developer.team-identifier": "the team that made it",
        "get-task-allow": "a debugger may attach: development builds only",
        "com.apple.security.get-task-allow": "a debugger may attach: development builds only",
        "keychain-access-groups": "keychain items it may share",
        "aps-environment": "push notifications",
        "com.apple.developer.aps-environment": "push notifications",
        "com.apple.developer.icloud-container-identifiers": "iCloud containers",
        "com.apple.developer.ubiquity-container-identifiers": "iCloud Drive containers",
        "com.apple.developer.ubiquity-kvstore-identifier": "iCloud key-value storage",
        "com.apple.security.application-groups": "app groups it shares data with",
        "com.apple.developer.associated-domains": "web sites linked to the app",
        "com.apple.developer.healthkit": "Health data",
        "com.apple.developer.in-app-payments": "Apple Pay",
        "com.apple.developer.networking.networkextension": "VPN, content filters or other network extensions",
        "com.apple.developer.applesignin": "Sign in with Apple",
        "beta-reports-active": "TestFlight",
        "com.apple.developer.siri": "Siri",
        "com.apple.developer.nfc.readersession.formats": "reads NFC tags",
    ]
}
