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
    /// Actions the app may start (feature `run-actions`).
    func actions() async throws -> [ActionSpec]
    /// Starts one now. The server checks the argument and payload again.
    func run(_ action: String, arg: String, payload: [String: String]) async throws -> ActionResult
    /// Sends a PDF to the server's document inbox (feature `documents`). `id` makes a retry harmless.
    func upload(pdf: Data, title: String?, id: String) async throws -> ShareReply
    /// Sends a web link (feature `share`).
    func share(url: URL, title: String?, id: String) async throws -> ShareReply
    /// Searches the server (feature `search`): cards with the answers. `q` is 2-100 characters.
    func search(q: String) async throws -> SearchResult
    /// A picture of this server (`Card.Item.image`): at most 1 MB, a JPEG, PNG or WebP. Nothing from another host.
    func image(path: String) async throws -> Data
}

public struct CompanionClient: CompanionAPI {
    public let baseURL: URL
    let token: String?
    let transport: any HTTPTransport

    public static let maxMessageLength = 4000
    /// The largest API answer read (`/state` is about 11 KB, a chat page a few hundred). Reading stops there.
    public static let maxResponseBytes = 8 * 1024 * 1024
    /// A poster is a few dozen KB; anything past this is not a poster.
    public static let maxImageBytes = 1024 * 1024

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
        try await get("state", timeout: 10)
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

    public func actions() async throws -> [ActionSpec] {
        let list: ActionList = try await get("actions", timeout: 10)
        return list.actions
    }

    public func run(_ action: String, arg: String, payload: [String: String]) async throws -> ActionResult {
        guard ActionSpec.isValidName(action) else { throw APIError.badRequest("No such action.") }
        // The server waits up to ~100 s for the result, then answers "still running".
        let data = try JSONSerialization.data(withJSONObject: ["arg": arg, "payload": payload] as [String: Any])
        return try await perform(request("actions/\(action)", method: "POST", body: data, timeout: 130),
                                 errors: APIError.fromAction)
    }

    public func upload(pdf: Data, title: String?, id: String) async throws -> ShareReply {
        guard pdf.count <= ShareLimits.maxPDFBytes else { throw ShareRefusal.tooLarge(bytes: pdf.count).apiError }
        return try await perform(uploadRequest(pdf: pdf, title: title, id: id), errors: APIError.fromUpload)
    }

    public func share(url: URL, title: String?, id: String) async throws -> ShareReply {
        let checked: URL
        do { checked = try ShareRouter.check(url) } catch let e as ShareRefusal { throw e.apiError }
        return try await perform(shareRequest(url: checked, title: title, id: id), errors: APIError.fromUpload)
    }

    public func search(q: String) async throws -> SearchResult {
        guard let clean = SearchQuery.clean(q) else { throw APIError.badRequest(SearchQuery.rule) }
        // The server asks Seerr (and its metadata source) per search; 1-2 s is normal.
        return try await perform(request("search", query: [URLQueryItem(name: "q", value: clean)], timeout: 25),
                                 errors: APIError.fromSearch)
    }

    public func image(path: String) async throws -> Data {
        guard let url = URLPolicy.imageURL(path, server: baseURL) else {
            throw APIError.badRequest("That picture is not on this server.")
        }
        try checkTokenTransport()
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        r.httpMethod = "GET"
        r.setValue("image/jpeg, image/png, image/webp", forHTTPHeaderField: "Accept")
        if let token = sendableToken { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        r.httpShouldHandleCookies = false
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(r, maxBytes: Self.maxImageBytes)
        } catch {
            throw APIError.from(error, host: baseURL.host ?? "the server")
        }
        if let error = APIError.from(status: response.statusCode, body: Data()) { throw error }
        if data.count > Self.maxImageBytes { throw APIError.tooLarge }
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard ImageKind(sniffing: data) != nil, type.isEmpty || type.hasPrefix("image/") else {
            throw APIError.invalidResponse
        }
        return data
    }

    /// `POST /documents`: the raw PDF, its id and title in headers (the title percent-encoded, so any text fits).
    func uploadRequest(pdf: Data, title: String?, id: String) -> URLRequest {
        var r = request("documents", method: "POST", body: pdf, timeout: 120)
        r.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        r.setValue(id, forHTTPHeaderField: "X-Homelab-Id")
        if let title = ShareRouter.cleanTitle(title, max: ShareLimits.maxPDFTitle) {
            r.setValue(Self.encodeHeader(title), forHTTPHeaderField: "X-Homelab-Title")
        }
        return r
    }

    /// `POST /share`: `{id, kind, url, title}`.
    func shareRequest(url: URL, title: String?, id: String) -> URLRequest {
        var body: [String: String] = ["id": id, "kind": "url", "url": url.absoluteString]
        if let title = ShareRouter.cleanTitle(title, max: ShareLimits.maxShareTitle) { body["title"] = title }
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return request("share", method: "POST", body: data, timeout: 30)
    }

    /// Percent-encodes everything but letters, digits and `-._~` (UTF-8 bytes), as the server decodes it.
    static func encodeHeader(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? ""
    }

    // MARK: - HTTP

    /// The token, when it may travel to this server (`URLPolicy.allowsToken`); else nil and nothing is attached.
    var sendableToken: String? { URLPolicy.allowsToken(baseURL) ? token : nil }

    /// A token server on plain http outside this device and the tailnet's `.ts.net` names: nothing is sent at all,
    /// not even without the token (the server would answer 401 and the owner would hunt for a wrong token).
    func checkTokenTransport() throws {
        if token != nil, let problem = URLPolicy.tokenProblem(baseURL) { throw APIError.badRequest(problem) }
    }

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
        if let token = sendableToken { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
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

    /// `errors` turns an HTTP status and body into an error (most endpoints: the generic texts).
    func perform<T: Decodable>(_ request: URLRequest,
                               errors: (Int, Data) -> APIError? = APIError.from(status:body:)) async throws -> T {
        try checkTokenTransport()
        let host = baseURL.host ?? "the server"
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request, maxBytes: Self.maxResponseBytes)
        } catch {
            throw APIError.from(error, host: host)
        }
        if let error = errors(response.statusCode, data) { throw error }
        // A hostile or broken server can't make the app hold hundreds of MB (the transport stops reading there too).
        if data.count > Self.maxResponseBytes { throw APIError.tooLarge }
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
