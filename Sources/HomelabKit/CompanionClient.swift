import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the app needs from a Companion API server. `CompanionClient` speaks HTTP; `DemoBackend` serves fixtures.
public protocol CompanionAPI: Sendable {
    func info() async throws -> ServerInfo
    func state() async throws -> HomelabState
    func messages(after: Int64) async throws -> MessagePage
    func send(_ text: String) async throws -> Int64?
    func press(_ button: String) async throws -> String
    func services() async throws -> [Service]
}

public struct CompanionClient: CompanionAPI {
    public let baseURL: URL
    let token: String?
    let transport: any HTTPTransport

    public static let maxMessageLength = 4000

    public init(baseURL: URL, token: String?, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.token = token?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.transport = transport
    }

    public init(config: ServerConfig, tokens: any TokenStore, transport: any HTTPTransport = URLSessionTransport()) {
        self.init(baseURL: config.baseURL, token: config.auth == .token ? tokens.token(for: config.id) : nil,
                  transport: transport)
    }

    public func info() async throws -> ServerInfo {
        let info: ServerInfo = try await get("info", timeout: 10)
        guard info.api == 1 else { throw APIError.unsupportedVersion(info.api) }
        return info
    }

    public func state() async throws -> HomelabState {
        try await get("state", timeout: 15)
    }

    public func messages(after: Int64) async throws -> MessagePage {
        try await get("messages", query: [URLQueryItem(name: "after", value: String(max(after, 0)))], timeout: 15)
    }

    public func send(_ text: String) async throws -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError.badRequest("The message is empty.") }
        guard trimmed.count <= Self.maxMessageLength else {
            throw APIError.badRequest("Messages can be at most \(Self.maxMessageLength) characters.")
        }
        let reply: SendReply = try await post("messages", body: ["text": trimmed], timeout: 20)
        return reply.id
    }

    public func press(_ button: String) async throws -> String {
        // The server waits for the action's result (up to ~2 minutes).
        let reply: TextReply = try await post("button", body: ["action": button], timeout: 150)
        return reply.text ?? "Done."
    }

    public func services() async throws -> [Service] {
        let list: ServiceList = try await get("services", timeout: 10)
        return list.services
    }

    // MARK: - HTTP

    func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil,
                 timeout: TimeInterval) -> URLRequest {
        var url = baseURL.appendingPathComponent("api/v1").appendingPathComponent(path)
        if !query.isEmpty, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = query
            url = parts.url ?? url
        }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            r.httpBody = body
            r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        r.httpShouldHandleCookies = false
        return r
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], timeout: TimeInterval) async throws -> T {
        try await perform(request(path, query: query, timeout: timeout))
    }

    func post<T: Decodable>(_ path: String, body: [String: String], timeout: TimeInterval) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request(path, method: "POST", body: data, timeout: timeout))
    }

    func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let host = baseURL.host ?? "the server"
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw APIError.from(error, host: host)
        }
        if let error = APIError.from(status: response.statusCode, body: data) { throw error }
        // A captive portal or web page instead of the API.
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if type.contains("text/html") { throw APIError.decoding("HTML instead of JSON") }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error).prefix(300).description)
        }
    }
}

struct SendReply: Decodable {
    var id: Int64?
    enum CodingKeys: String, CodingKey { case id }
    init(from decoder: any Decoder) throws {
        id = try decoder.container(keyedBy: CodingKeys.self).int64(.id)
    }
}

struct TextReply: Decodable {
    var text: String?
    enum CodingKeys: String, CodingKey { case text }
    init(from decoder: any Decoder) throws {
        text = try decoder.container(keyedBy: CodingKeys.self).text(.text)
    }
}
