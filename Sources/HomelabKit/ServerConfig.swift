import Foundation

/// One configured server. The token is NOT part of this struct: it lives in the Keychain (`TokenStore`), keyed by `id`.
public struct ServerConfig: Codable, Sendable, Equatable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case companion       // Homelab Companion API v1 (agent, reference server)
        case homeAssistant   // Home Assistant REST API, long-lived token
        case demo            // built-in fixtures, no network
    }

    public enum Auth: String, Codable, Sendable, CaseIterable {
        case identity   // a proxy adds the identity (tailscale serve); the app sends nothing
        case token      // Authorization: Bearer <token from the Keychain>
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var baseURL: URL
    public var auth: Auth
    /// HA only: the entities pinned on the Home tab, in order.
    public var pinnedEntities: [String]
    /// HA only: short names for the pinned tiles, by entity id (set in the app only; Home Assistant keeps its names).
    /// Always cleaned by `TileName.clean`; an entity without an entry shows HA's friendly name.
    public var tileNames: [String: String]
    /// HA only: icons for the pinned tiles, by entity id, from `TileIcon.choices`. No entry = the icon by domain.
    public var tileIcons: [String: String]
    /// Companion only: the optional public https address (Cloudflare Access + app token, see `PublicRoute`). The
    /// secrets are in the `TokenStore`, not here. nil = tailnet only; then nothing about it is saved or sent.
    public var publicURL: URL?

    public init(id: UUID = UUID(), name: String, kind: Kind, baseURL: URL, auth: Auth, pinnedEntities: [String] = [],
                tileNames: [String: String] = [:], tileIcons: [String: String] = [:], publicURL: URL? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.baseURL = baseURL; self.auth = auth
        self.pinnedEntities = pinnedEntities
        self.tileNames = tileNames
        self.tileIcons = tileIcons
        self.publicURL = publicURL
    }

    /// Settings saved before custom tile names or icons existed have no `tileNames`/`tileIcons`: they still decode.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let savedName = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        baseURL = try c.decode(URL.self, forKey: .baseURL)
        // Servers added before the short default name was saved with the whole host as their name
        // ("nas.tail1234.ts.net" twice in the list, cut mid-word): they get the short one.
        // Only for tailnet names (the app filled those in itself); a full host typed on purpose stays.
        name = savedName == baseURL.host && savedName.hasSuffix(".ts.net") ? Self.defaultName(for: baseURL) : savedName
        auth = try c.decode(Auth.self, forKey: .auth)
        pinnedEntities = try c.decodeIfPresent([String].self, forKey: .pinnedEntities) ?? []
        tileNames = TileName.cleaned(try c.decodeIfPresent([String: String].self, forKey: .tileNames) ?? [:], pinned: pinnedEntities)
        tileIcons = TileIcon.cleaned(try c.decodeIfPresent([String: String].self, forKey: .tileIcons) ?? [:], pinned: pinnedEntities)
        publicURL = try c.decodeIfPresent(URL.self, forKey: .publicURL)
    }

    /// The server as the editor saves it: the edited fields over `original`, so everything else (pins, the tiles'
    /// names and icons, and whatever comes next) stays. Nil `original` = a new server.
    public static func edited(_ original: ServerConfig?, name: String, kind: Kind, baseURL: URL, auth: Auth) -> ServerConfig {
        var c = original ?? ServerConfig(name: name, kind: kind, baseURL: baseURL, auth: auth)
        c.name = name; c.kind = kind; c.baseURL = baseURL; c.auth = auth
        return c
    }

    /// The same with a public route address (nil removes it). Only a Companion server has one.
    public func withPublicURL(_ url: URL?) -> ServerConfig {
        var c = self
        c.publicURL = kind == .companion ? url : nil
        return c
    }

    /// The name a server gets when none is typed: the first part of a DNS name ("nas" for
    /// "nas.tail1234.ts.net"). An IP address or a one-word host stays whole.
    public static func defaultName(for url: URL) -> String {
        guard let host = url.host, !host.isEmpty else { return "Homelab" }
        guard !host.contains(":"), let first = host.split(separator: ".").first, first.contains(where: \.isLetter) else { return host }
        return String(first)
    }

    /// The tile's custom name for an entity, or nil (then the tile shows HA's friendly name).
    public func tileName(for entityID: String) -> String? { tileNames[entityID] }

    /// The tile's custom icon (an SF Symbol from `TileIcon.choices`), or nil (then the icon by domain).
    public func tileIcon(for entityID: String) -> String? { tileIcons[entityID] }

    public static let demoURL = URL(string: "https://demo.invalid")!   // .invalid never resolves (RFC 2606)

    public static func demo() -> ServerConfig {
        ServerConfig(name: "Demo homelab", kind: .demo, baseURL: demoURL, auth: .identity)
    }

    public static func demoHomeAssistant() -> ServerConfig {
        ServerConfig(name: "Demo Home Assistant", kind: .demo, baseURL: URL(string: "https://ha.demo.invalid")!,
                     auth: .identity, pinnedEntities: ["light.living_room", "script.goodnight", "switch.heater",
                                                       "sensor.living_room_temperature"])
    }

    public var isDemoHomeAssistant: Bool { kind == .demo && baseURL.host == "ha.demo.invalid" }

    /// The host shown in errors and lists.
    public var host: String { baseURL.host ?? baseURL.absoluteString }

    public var showsHomeTab: Bool { kind == .homeAssistant || isDemoHomeAssistant }

    /// Same kind and the same scheme, host, port and path. A stored token may only be reused when this holds:
    /// otherwise it would be sent to a different server (or an HA admin token to a Companion server).
    public func isSameTarget(as other: ServerConfig) -> Bool {
        kind == other.kind && Self.origin(baseURL) == Self.origin(other.baseURL)
    }

    /// "id|kind|scheme://host:port/path": changes exactly when cached data stops belonging to this server, and
    /// differs between two entries that happen to share an address.
    public var target: String { id.uuidString + "|" + kind.rawValue + "|" + Self.origin(baseURL) }

    public static func origin(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(url.host?.lowercased() ?? ""):\(port)\(path)"
    }
    /// The server gets a bearer token: a Companion server with `auth == .token`, and Home Assistant always.
    public var sendsToken: Bool { Self.sendsToken(kind: kind, auth: auth) }

    public static func sendsToken(kind: Kind, auth: Auth) -> Bool {
        kind == .homeAssistant || (kind == .companion && auth == .token)
    }

    /// Why this server's token can't be sent (a token over plain http to an address outside this device and the
    /// tailnet's `.ts.net` names, `URLPolicy.allowsToken`), or nil. The editor shows it as an error: the clients
    /// refuse such a server with the same text.
    public var tokenTransportProblem: String? {
        Self.tokenTransportProblem(kind: kind, auth: auth, url: baseURL)
    }

    /// The same for an entry the editor hasn't saved yet.
    public static func tokenTransportProblem(kind: Kind, auth: Auth, url: URL) -> String? {
        sendsToken(kind: kind, auth: auth) ? URLPolicy.tokenProblem(url) : nil
    }

    public var speaksCompanionAPI: Bool { kind == .companion || (kind == .demo && !isDemoHomeAssistant) }
}

/// Where tokens live. The app uses the Keychain; tests use memory.
public protocol TokenStore: Sendable {
    func token(for server: UUID) -> String?
    func setToken(_ token: String?, for server: UUID) throws
    /// Deletes every token of this app (Reset everything).
    func removeAll()
}

public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private var tokens: [UUID: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func token(for server: UUID) -> String? {
        lock.withLock { tokens[server] }
    }

    public func setToken(_ token: String?, for server: UUID) throws {
        lock.withLock { tokens[server] = token?.isEmpty == true ? nil : token }
    }

    public func removeAll() {
        lock.withLock { tokens.removeAll() }
    }

    public var count: Int { lock.withLock { tokens.count } }
}
