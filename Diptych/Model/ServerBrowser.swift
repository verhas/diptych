import Foundation
import Network
import dnssd
import Observation

/// File servers that announce themselves on the local network, by Bonjour:
/// NAS boxes, other Macs sharing files, WebDAV and FTP servers. Looked for
/// only while Connect to Server is open, so macOS asks about the local
/// network only when the user has gone looking.
@MainActor
@Observable
final class ServerBrowser {

    struct Found: Identifiable, Hashable, Sendable {
        let name: String
        let type: String
        let domain: String
        var kind: ServerAddress.Kind { ServerBrowser.kinds[type] ?? .smb }
        var id: String { "\(type)|\(name)" }
    }

    /// The Bonjour types, and what each is.
    nonisolated static let kinds: [String: ServerAddress.Kind] = [
        "_smb._tcp": .smb,
        "_afpovertcp._tcp": .afp,
        "_nfs._tcp": .nfs,
        "_webdav._tcp": .webdav,
        "_webdavs._tcp": .webdav,
        "_ftp._tcp": .ftp,
    ]

    private(set) var found: [Found] = []
    /// Why nothing can be found, when something says so.
    private(set) var problem: String?

    @ObservationIgnored private var browsers: [NWBrowser] = []
    @ObservationIgnored private var byType: [String: [Found]] = [:]

    /// This Mac's own sharing is not somewhere to connect to.
    @ObservationIgnored private let ownName = Host.current().localizedName ?? ""

    func start() {
        guard browsers.isEmpty else { return }
        problem = nil
        for type in Self.kinds.keys.sorted() {
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let found = results.compactMap { result -> Found? in
                    guard case let .service(name, type, domain, _) = result.endpoint else {
                        return nil
                    }
                    return Found(name: name, type: type, domain: domain)
                }
                Task { @MainActor in self?.update(type, found) }
            }
            browser.stateUpdateHandler = { [weak self] state in
                let denied: Bool
                switch state {
                case .failed(let error), .waiting(let error):
                    if case .dns(let code) = error, code == kDNSServiceErr_PolicyDenied {
                        denied = true
                    } else { denied = false }
                default: denied = false
                }
                guard denied else { return }
                Task { @MainActor in
                    self?.problem = "Diptych may not look on the local network. Allow it in "
                        + "System Settings \u{25B8} Privacy & Security \u{25B8} Local Network."
                }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers = []
        byType = [:]
        found = []
    }

    private func update(_ type: String, _ list: [Found]) {
        guard !browsers.isEmpty else { return }
        byType[type] = list.filter { $0.name != ownName }
        found = byType.values.joined().sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.type < $1.type : order == .orderedAscending
        }
    }

    // MARK: - From a name to an address

    /// The address to mount a found server at: its host, port and -- for
    /// the kinds that announce one -- its path. Nil when it does not answer.
    nonisolated static func address(of server: Found) async -> URL? {
        guard let (host, port, path) = await resolve(server) else { return nil }
        return address(kind: server.type, host: host, port: port, path: path)
    }

    /// Built from what Bonjour said. A default port is left out, so the
    /// address reads as one typed by hand would.
    nonisolated static func address(kind type: String, host: String, port: UInt16,
                                     path: String?) -> URL? {
        let scheme: String
        let standard: UInt16
        switch type {
        case "_smb._tcp": (scheme, standard) = ("smb", 445)
        case "_afpovertcp._tcp": (scheme, standard) = ("afp", 548)
        case "_nfs._tcp": (scheme, standard) = ("nfs", 2049)
        case "_webdav._tcp": (scheme, standard) = ("http", 80)
        case "_webdavs._tcp": (scheme, standard) = ("https", 443)
        case "_ftp._tcp": (scheme, standard) = ("ftp", 21)
        default: return nil
        }
        var parts = URLComponents()
        parts.scheme = scheme
        var name = host
        while name.hasSuffix(".") { name.removeLast() }
        parts.host = name
        if port != standard, port != 0 { parts.port = Int(port) }
        if let path, !path.isEmpty, path != "/" {
            parts.path = path.hasPrefix("/") ? path : "/" + path
        }
        return parts.url
    }

    /// One answer from DNS-SD, handed back through its context pointer.
    private final class Resolution: @unchecked Sendable {
        let continuation: CheckedContinuation<(String, UInt16, String?)?, Never>
        private let lock = NSLock()
        private var done = false
        var ref: DNSServiceRef?

        init(_ continuation: CheckedContinuation<(String, UInt16, String?)?, Never>) {
            self.continuation = continuation
        }

        /// Once only: the answer and the time-out race.
        func finish(_ value: (String, UInt16, String?)?) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            let ref = self.ref
            self.ref = nil
            lock.unlock()
            if let ref { DNSServiceRefDeallocate(ref) }
            continuation.resume(returning: value)
        }
    }

    private nonisolated static let resolveQueue = DispatchQueue(label: "Diptych.ServerBrowser.resolve")

    private nonisolated static func resolve(_ server: Found) async -> (String, UInt16, String?)? {
        await withCheckedContinuation { continuation in
            resolveQueue.async {
                let resolution = Resolution(continuation)
                let context = Unmanaged.passRetained(resolution).toOpaque()
                var ref: DNSServiceRef?
                let error = DNSServiceResolve(&ref, 0, 0, server.name, server.type, server.domain, {
                    _, _, _, error, _, host, port, length, txt, context in
                    guard let context else { return }
                    let resolution = Unmanaged<Resolution>.fromOpaque(context).takeUnretainedValue()
                    guard error == kDNSServiceErr_NoError, let host else {
                        resolution.finish(nil)
                        return
                    }
                    var path: String?
                    var size: UInt8 = 0
                    if let txt, let value = TXTRecordGetValuePtr(length, txt, "path", &size) {
                        path = String(decoding: UnsafeRawBufferPointer(start: value, count: Int(size)),
                                      as: UTF8.self)
                    }
                    resolution.finish((String(cString: host), UInt16(bigEndian: port), path))
                }, context)
                guard error == kDNSServiceErr_NoError, let ref else {
                    Unmanaged<Resolution>.fromOpaque(context).release()
                    continuation.resume(returning: nil)
                    return
                }
                resolution.ref = ref
                DNSServiceSetDispatchQueue(ref, resolveQueue)
                // A server that has gone quiet is given five seconds.
                resolveQueue.asyncAfter(deadline: .now() + 5) {
                    resolution.finish(nil)
                }
                // Released once whichever comes first has finished it.
                resolveQueue.asyncAfter(deadline: .now() + 6) {
                    Unmanaged.passUnretained(resolution).release()
                }
            }
        }
    }
}
