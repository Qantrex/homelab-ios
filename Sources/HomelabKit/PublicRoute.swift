import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The optional second way to a Companion server: a public https address behind Cloudflare Access (service token)
/// plus the agent's own app token. The client tries it first and falls back to the tailnet address only when the
/// network failed. The three secrets live in the Keychain (`PublicSecret`), never in `ServerConfig`.
public struct PublicRoute: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let baseURL: URL
    let accessID: String
    let accessSecret: String
    let appToken: String

    /// nil unless the address is https and all three secrets are filled in: a half-set route is not used at all.
    public init?(baseURL: URL?, accessID: String?, accessSecret: String?, appToken: String?) {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
                  t.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value < 0x7f }) else { return nil }   // no spaces, no CR/LF
            return t
        }
        guard let baseURL, baseURL.scheme?.lowercased() == "https", baseURL.host?.isEmpty == false,
              let id = clean(accessID), let secret = clean(accessSecret), let token = clean(appToken) else { return nil }
        self.baseURL = baseURL
        self.accessID = id
        self.accessSecret = secret
        self.appToken = token
    }

    /// Never prints a secret, whatever logs it.
    public var description: String { "PublicRoute(\(baseURL.host ?? "?"))" }
    public var debugDescription: String { description }

    /// The same request aimed at the public address, with the Cloudflare Access headers and the app token instead
    /// of whatever the tailnet request carried. `from` is the server's tailnet base address.
    func rebased(_ request: URLRequest, from base: URL) -> URLRequest? {
        guard let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let oldPath = Self.trimmed(base.path)
        guard parts.path.hasPrefix(oldPath) else { return nil }
        let rest = String(parts.path.dropFirst(oldPath.count))
        guard rest.isEmpty || rest.hasPrefix("/") else { return nil }
        let pub = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        parts.scheme = "https"
        parts.host = pub?.host
        parts.port = pub?.port
        parts.path = Self.trimmed(baseURL.path) + rest
        guard let newURL = parts.url else { return nil }
        var r = request
        r.url = newURL
        r.setValue("Bearer " + appToken, forHTTPHeaderField: "Authorization")
        r.setValue(accessID, forHTTPHeaderField: "CF-Access-Client-Id")
        r.setValue(accessSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        // A short wait for reads: a dead tunnel must not hold the app for 10-25 s before the tailnet is tried.
        // Writes keep their time (the answer may be slow by design, and a timeout there is never retried).
        if request.httpMethod == nil || request.httpMethod == "GET" {
            r.timeoutInterval = min(request.timeoutInterval, Self.readTimeout)
        }
        return r
    }

    public static let readTimeout: TimeInterval = 6

    static func trimmed(_ path: String) -> String {
        var p = path
        while p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Did the public attempt fail before the agent could have acted on it? Then the tailnet address is tried.
    /// A GET may be repeated after a timeout or a broken connection; a write is repeated only when the request
    /// surely never arrived (no connection, DNS, or Cloudflare's "origin unreachable" 502/503/521-523/530).
    static func shouldFallBack(error: any Error, method: String) -> Bool {
        guard let u = error as? URLError else { return false }
        switch u.code {
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .notConnectedToInternet, .dataNotAllowed,
             .internationalRoamingOff, .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return true
        case .timedOut, .networkConnectionLost:
            return method == "GET"
        default:
            return false
        }
    }

    static func shouldFallBack(status: Int, method: String) -> Bool {
        switch status {
        case 502, 503, 521, 522, 523, 530: true
        case 504, 524: method == "GET"
        default: false
        }
    }
}

/// Where a public route's secrets are kept: next to the server's token in the `TokenStore` (so the Keychain and
/// `removeAll` cover them), under three ids derived from the server's id.
public enum PublicSecret: Int, CaseIterable, Sendable {
    case accessID = 1, accessSecret, appToken

    func key(_ server: UUID) -> UUID {
        var b = server.uuid
        b.15 ^= UInt8(0x40 + rawValue)
        b.14 ^= 0x5a
        return UUID(uuid: b)
    }
}

extension TokenStore {
    public func publicSecret(_ kind: PublicSecret, for server: UUID) -> String? { token(for: kind.key(server)) }

    public func setPublicSecret(_ value: String?, _ kind: PublicSecret, for server: UUID) throws {
        try setToken(value, for: kind.key(server))
    }

    public func clearPublicSecrets(for server: UUID) {
        for k in PublicSecret.allCases { try? setToken(nil, for: k.key(server)) }
    }

    public func publicRoute(for config: ServerConfig) -> PublicRoute? {
        guard config.kind == .companion else { return nil }
        return PublicRoute(baseURL: config.publicURL, accessID: publicSecret(.accessID, for: config.id),
                           accessSecret: publicSecret(.accessSecret, for: config.id), appToken: publicSecret(.appToken, for: config.id))
    }
}

/// After a network failure of the public route, the next requests skip it for a minute (so a dead tunnel costs the
/// app one short wait, not one per request).
public final class PublicRouteHealth: @unchecked Sendable {
    public static let shared = PublicRouteHealth()
    private var downUntil: [String: Date] = [:]
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    public static let pause: TimeInterval = 60

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    func isDown(_ host: String) -> Bool {
        lock.withLock { (downUntil[host] ?? .distantPast) > now() }
    }

    func markDown(_ host: String) { lock.withLock { downUntil[host] = now().addingTimeInterval(Self.pause) } }
    func markUp(_ host: String) { lock.withLock { downUntil[host] = nil } }
}
