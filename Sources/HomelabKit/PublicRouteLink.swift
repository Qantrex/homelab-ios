import Foundation

/// The setup QR for a public route: `homelab://public-route#v1.<base64url JSON>`. The JSON is
/// `{"server"?, "url", "id", "secret", "token"}`. The secrets sit in the fragment so iOS hands the whole URL to the
/// app. The link lives in memory only, from `AppModel.open` to the confirmation sheet: it is never stored, logged or
/// kept in any pending-link store, and every description redacts the keys.
public struct PublicRouteLink: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let server: URL?
    public let publicURL: URL
    let accessID: String
    let accessSecret: String
    let appToken: String

    public enum Problem: Error, Equatable, Sendable, LocalizedError {
        case notARouteLink, unsupportedVersion, badEncoding, badContent, notHTTPS, badKey(String), tooLong(String)

        public var errorDescription: String? {
            switch self {
            case .notARouteLink: "This is not a public route link."
            case .unsupportedVersion: "This setup code is from a newer version. Update the app."
            case .badEncoding: "The setup code is damaged. Scan it again."
            case .badContent: "The setup code does not have the expected fields."
            case .notHTTPS: "The public address in the setup code must start with https://."
            case .badKey(let k): "The " + k + " in the setup code is empty or has spaces or line breaks."
            case .tooLong(let k): "The " + k + " in the setup code is too long."
            }
        }
    }

    public static let host = "public-route"
    public static let maxLength = 512

    public static func isRouteLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "homelab" && url.host?.lowercased() == host
    }

    private struct Payload: Decodable {
        let server: String?
        let url: String
        let id: String
        let secret: String
        let token: String
    }

    public init(url link: URL) throws {
        guard Self.isRouteLink(link) else { throw Problem.notARouteLink }
        // The fragment, taken from the string itself (no percent-decoding games).
        guard let hash = link.absoluteString.firstIndex(of: "#") else { throw Problem.badEncoding }
        let fragment = String(link.absoluteString[link.absoluteString.index(after: hash)...])
        guard fragment.hasPrefix("v1.") else {
            throw fragment.wholeMatch(of: /v[0-9]+\..*/) != nil ? Problem.unsupportedVersion : Problem.badEncoding
        }
        let body = String(fragment.dropFirst(3))
        guard body.count <= 8192, body.wholeMatch(of: /[A-Za-z0-9_-]+/) != nil else { throw Problem.badEncoding }
        var b64 = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { throw Problem.badEncoding }
        // Exactly these keys: an extra or missing one is a different (unknown) format.
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Problem.badEncoding }
        let required: Set<String> = ["url", "id", "secret", "token"]
        let keys = Set(obj.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(["server"])) else { throw Problem.badContent }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data) else { throw Problem.badContent }

        guard p.url.count <= Self.maxLength else { throw Problem.tooLong("address") }
        guard let u = URL(string: p.url.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme?.lowercased() == "https",
              u.host?.isEmpty == false, !p.url.contains(where: { $0.isWhitespace }) else { throw Problem.notHTTPS }
        for (name, value) in [("client id", p.id), ("client secret", p.secret), ("app token", p.token)] {
            guard value.count <= Self.maxLength else { throw Problem.tooLong(name) }
        }
        // The same check as the Settings fields (PublicRoute.init): non-empty, printable ASCII, no spaces or CR/LF.
        guard let route = PublicRoute(baseURL: u, accessID: p.id, accessSecret: p.secret, appToken: p.token) else {
            for (name, value) in [("client id", p.id), ("client secret", p.secret), ("app token", p.token)]
            where PublicRoute(baseURL: u, accessID: value, accessSecret: "x", appToken: "x") == nil {
                throw Problem.badKey(name)
            }
            throw Problem.badContent
        }
        // An exact value, not a trimmed one: whitespace around a key would hide an injection.
        guard route.accessID == p.id, route.accessSecret == p.secret, route.appToken == p.token else {
            throw Problem.badKey("keys")
        }
        publicURL = u
        accessID = p.id
        accessSecret = p.secret
        appToken = p.token
        if let s = p.server, !s.isEmpty {
            guard s.count <= Self.maxLength, case .success(let su) = URLPolicy.serverURL(s) else { throw Problem.badContent }
            server = su
        } else {
            server = nil
        }
    }

    public var description: String { "PublicRouteLink(\(publicURL.host ?? "?"), 3 keys hidden)" }
    public var debugDescription: String { description }

    public var publicHost: String { publicURL.host ?? publicURL.absoluteString }

    /// The route the keys make (for the connection test).
    public var route: PublicRoute? {
        PublicRoute(baseURL: publicURL, accessID: accessID, accessSecret: accessSecret, appToken: appToken)
    }

    /// Where the link goes.
    public enum Target: Equatable, Sendable {
        case none
        case server(ServerConfig)
        /// `notFound`: the link named a server that none of them matches.
        case choose([ServerConfig], notFound: Bool)
    }

    public func target(in servers: [ServerConfig]) -> Target {
        let companions = servers.filter { $0.kind == .companion }
        guard !companions.isEmpty else { return .none }
        var missed = false
        if let server {
            let o = ServerConfig.origin(server)
            if let m = companions.first(where: { ServerConfig.origin($0.baseURL) == o }) { return .server(m) }
            missed = true
        }
        if companions.count == 1 { return .server(companions[0]) }
        return .choose(companions, notFound: missed)
    }
}
