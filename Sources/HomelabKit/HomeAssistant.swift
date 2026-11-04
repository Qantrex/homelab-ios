import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A Home Assistant entity, from `GET /api/states`.
public struct HAEntity: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var entityID: String
    public var state: String
    public var name: String
    public var icon: String?
    public var unit: String?
    public var deviceClass: String?
    public var lastChanged: Date?

    public var id: String { entityID }
    public var domain: String { String(entityID.split(separator: ".").first ?? "") }

    public init(entityID: String, state: String, name: String? = nil, icon: String? = nil, unit: String? = nil,
                deviceClass: String? = nil, lastChanged: Date? = nil) {
        self.entityID = entityID; self.state = state; self.name = name ?? entityID; self.icon = icon
        self.unit = unit; self.deviceClass = deviceClass; self.lastChanged = lastChanged
    }

    enum CodingKeys: String, CodingKey {
        case entityID = "entity_id", state, attributes, lastChanged = "last_changed"
        case name, icon, unit, deviceClass = "device_class"
    }
    enum AttributeKeys: String, CodingKey {
        case friendlyName = "friendly_name", icon, unit = "unit_of_measurement", deviceClass = "device_class"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.text(.entityID), id.contains(".") else {
            throw DecodingError.keyNotFound(CodingKeys.entityID, .init(codingPath: c.codingPath, debugDescription: "no entity_id"))
        }
        var name = c.text(.name), icon = c.text(.icon), unit = c.text(.unit), deviceClass = c.text(.deviceClass)
        if let a = try? c.nestedContainer(keyedBy: AttributeKeys.self, forKey: .attributes) {
            name = a.text(.friendlyName) ?? name
            icon = a.text(.icon) ?? icon
            unit = a.text(.unit) ?? unit
            deviceClass = a.text(.deviceClass) ?? deviceClass
        }
        self.init(entityID: id, state: c.string(.state) ?? "unknown", name: name, icon: icon, unit: unit,
                  deviceClass: deviceClass, lastChanged: c.date(.lastChanged))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entityID, forKey: .entityID)
        try c.encode(state, forKey: .state)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(unit, forKey: .unit)
        try c.encodeIfPresent(deviceClass, forKey: .deviceClass)
        try c.encodeIfPresent(lastChanged.map(ServerDate.string), forKey: .lastChanged)
    }

    /// What tapping does, if anything.
    public enum Control: Sendable, Equatable { case toggle, run, none }

    public var control: Control {
        switch domain {
        case "light", "switch", "input_boolean", "fan", "automation", "siren", "humidifier": .toggle
        case "script", "scene", "button", "input_button": .run
        default: .none
        }
    }

    public var isOn: Bool { ["on", "open", "playing", "home", "unlocked"].contains(state.lowercased()) }
    public var isAvailable: Bool { !["unavailable", "unknown"].contains(state.lowercased()) }

    /// The state as people read it: "21.4 °C", "On", "Open".
    public var displayState: String {
        if !isAvailable { return state.lowercased() == "unknown" ? "Unknown" : "Unavailable" }
        switch domain {
        case "scene", "script", "button", "input_button": return control == .run ? "Run" : state
        case "binary_sensor":
            let on = state.lowercased() == "on"
            switch deviceClass {
            case "door", "window", "garage_door", "opening": return on ? "Open" : "Closed"
            case "motion", "occupancy", "presence": return on ? "Detected" : "Clear"
            case "moisture": return on ? "Wet" : "Dry"
            default: return on ? "On" : "Off"
            }
        default:
            if let unit, !unit.isEmpty { return "\(state) \(unit)" }
            if ["on", "off"].contains(state.lowercased()) { return state.lowercased() == "on" ? "On" : "Off" }
            return state.prefix(1).uppercased() + state.dropFirst()
        }
    }

    /// The HA service call for a tap: (domain, service).
    public var tapService: (domain: String, service: String)? {
        switch control {
        case .toggle:
            return (domain, "toggle")
        case .run:
            switch domain {
            case "script": return ("script", "turn_on")
            case "scene": return ("scene", "turn_on")
            case "button", "input_button": return (domain, "press")
            default: return nil
            }
        case .none:
            return nil
        }
    }
}

public protocol HomeAssistantAPI: Sendable {
    func check() async throws -> String
    func states() async throws -> [HAEntity]
    func call(_ entity: HAEntity) async throws -> [HAEntity]
}

/// Home Assistant REST API (https://developers.home-assistant.io/docs/api/rest/), long-lived access token.
public struct HomeAssistantClient: HomeAssistantAPI {
    public let baseURL: URL
    let token: String?
    let transport: any HTTPTransport

    public init(baseURL: URL, token: String?, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.token = token?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.transport = transport
    }

    public init(config: ServerConfig, tokens: any TokenStore, transport: any HTTPTransport = URLSessionTransport()) {
        self.init(baseURL: config.baseURL, token: tokens.token(for: config.id), transport: transport)
    }

    /// `GET /api/` → "API running." Proves address + token.
    public func check() async throws -> String {
        let data = try await perform(request("api/", timeout: 10))
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let message = obj?["message"] as? String else { throw APIError.decoding("not Home Assistant") }
        return message
    }

    public func states() async throws -> [HAEntity] {
        let data = try await perform(request("api/states", timeout: 20))
        do {
            return try JSONDecoder().decode([Lossy<HAEntity>].self, from: data).compactMap(\.value)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            throw APIError.decoding("states")
        }
    }

    /// Runs the entity's tap action. HA answers with the states that changed.
    public func call(_ entity: HAEntity) async throws -> [HAEntity] {
        guard let service = entity.tapService else { throw APIError.badRequest("\(entity.name) has no action.") }
        let body = try JSONSerialization.data(withJSONObject: ["entity_id": entity.entityID])
        var r = request("api/services/\(service.domain)/\(service.service)", timeout: 20)
        r.httpMethod = "POST"
        r.httpBody = body
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try await perform(r)
        return ((try? JSONDecoder().decode([Lossy<HAEntity>].self, from: data)) ?? []).compactMap(\.value)
    }

    func request(_ path: String, timeout: TimeInterval) -> URLRequest {
        // appendingPathComponent drops a trailing slash, and HA's health endpoint is exactly `/api/`.
        var url = baseURL.appendingPathComponent(path)
        if path.hasSuffix("/"), !url.absoluteString.hasSuffix("/"), let withSlash = URL(string: url.absoluteString + "/") {
            url = withSlash
        }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        r.httpShouldHandleCookies = false
        return r
    }

    func perform(_ request: URLRequest) async throws -> Data {
        guard token != nil else { throw APIError.unauthorized }
        let host = baseURL.host ?? "Home Assistant"
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw APIError.from(error, host: host)
        }
        if let error = APIError.from(status: response.statusCode, body: data) { throw error }
        return data
    }
}
