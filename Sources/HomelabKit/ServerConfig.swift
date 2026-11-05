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

    public init(id: UUID = UUID(), name: String, kind: Kind, baseURL: URL, auth: Auth, pinnedEntities: [String] = []) {
        self.id = id; self.name = name; self.kind = kind; self.baseURL = baseURL; self.auth = auth
        self.pinnedEntities = pinnedEntities
    }

    public static let demoURL = URL(string: "https://demo.invalid")!   // .invalid never resolves (RFC 2606)

    public static func demo() -> ServerConfig {
        ServerConfig(name: "Demo homelab", kind: .demo, baseURL: demoURL, auth: .identity)
    }

    public static func demoHomeAssistant() -> ServerConfig {
        ServerConfig(name: "Demo Home Assistant", kind: .demo, baseURL: URL(string: "https://ha.demo.invalid")!,
                     auth: .identity, pinnedEntities: ["light.living_room", "switch.heater", "script.goodnight",
                                                       "sensor.living_room_temperature", "binary_sensor.front_door"])
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

    static func origin(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(url.host?.lowercased() ?? ""):\(port)\(path)"
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
