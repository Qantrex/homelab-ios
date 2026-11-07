import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one network seam: URLSession in the app, a fake in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Like `send`, but stops reading past `maxBytes` (`APIError.tooLarge`): for pictures, which are small.
    func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse)
}

extension HTTPTransport {
    /// Transports that can't stop early read everything and check afterwards.
    public func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await send(request)
        if data.count > maxBytes { throw APIError.tooLarge }
        return (data, response)
    }
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    /// For PDF uploads (`POST /documents`): the same rules, but up to 15 minutes in total like the server's upload
    /// deadline. With the default session's 150 s a 25 MB scan over a slow relayed tailnet link never finished.
    let uploadSession: URLSession
    /// Stop reading past this many bytes (the clients check their own, smaller limits too).
    let maxBytes: Int

    public init(session: URLSession = URLSessionTransport.defaultSession,
                uploadSession: URLSession = URLSessionTransport.uploadSession, maxBytes: Int = 32 * 1024 * 1024) {
        self.session = session
        self.uploadSession = uploadSession
        self.maxBytes = maxBytes
    }

    static func isUpload(_ request: URLRequest) -> Bool {
        request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Content-Type") == "application/pdf"
    }

    /// No cookies, no cache, no credential storage: every request carries its own auth. Redirects are not followed,
    /// so a bearer token can never be carried to another host by a 3xx answer.
    public static let defaultSession: URLSession = makeSession(resourceTimeout: 150)
    public static let uploadSession: URLSession = makeSession(resourceTimeout: 900)

    /// For widgets: an extension has a few seconds, and an off tailnet must not hang it. 8 s for the request and the
    /// whole transfer, answers up to 2 MB (`/state` is about 11 KB), still no redirects, cookies or cache.
    public static let widget = URLSessionTransport(session: makeSession(resourceTimeout: 8, requestTimeout: 8),
                                                   uploadSession: makeSession(resourceTimeout: 8, requestTimeout: 8),
                                                   maxBytes: 2 * 1024 * 1024)

    static func makeSession(resourceTimeout: TimeInterval, requestTimeout: TimeInterval = 20) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = requestTimeout
        c.timeoutIntervalForResource = resourceTimeout
        #if canImport(Darwin)
        c.waitsForConnectivity = false   // fail fast: the UI shows "is Tailscale on?"
        #endif
        c.httpAdditionalHeaders = ["User-Agent": "HomelabiOS/\(AppVersion.short)"]
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await send(request, maxBytes: maxBytes)
    }

    public func send(_ request: URLRequest, maxBytes limit: Int) async throws -> (Data, HTTPURLResponse) {
        let maxBytes = min(limit, self.maxBytes)
        #if canImport(Darwin)
        // Streamed, so a hostile server can't make the app buffer more than `maxBytes`.
        let (bytes, response) = try await (Self.isUpload(request) ? uploadSession : session).bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.expectedContentLength > Int64(maxBytes) { throw APIError.tooLarge }
        var data = Data()
        data.reserveCapacity(Int(max(0, min(http.expectedContentLength, Int64(maxBytes)))))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw APIError.tooLarge }
        }
        return (data, http)
        #else
        let (data, response) = try await (Self.isUpload(request) ? uploadSession : session).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if data.count > maxBytes { throw APIError.tooLarge }
        return (data, http)
        #endif
    }
}

/// Stops every redirect: the 3xx answer comes back as it is and becomes `APIError.redirected`.
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    #if canImport(Darwin)
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    #else
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    #endif
}

public enum AppVersion {
    public static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}

/// Every failure the UI has to explain. `message` is what the user reads; it never contains a token.
public enum APIError: Error, Equatable, Sendable {
    case offline
    case notOnTailnet(host: String)
    case cannotFindHost(host: String)
    case timeout
    case unauthorized
    /// Home Assistant answered 401 (or there is no token): its long-lived token is wrong or was deleted. Not the
    /// Tailscale message of `.unauthorized`, which would send the user to `tailscale serve`.
    case homeAssistantToken
    case forbidden
    /// 403 with the server's own reason ("host not allowed", "forged or outdated button").
    case refused(String)
    case notFound
    case tooManyRequests
    case server(status: Int)
    /// A 5xx answer to starting an action with the server's own words (`{"error": "..."}`): it knows what happened
    /// ("the agent is down, nothing was run"), so the app shows that instead of guessing.
    case serverSaid(status: Int, text: String)
    case invalidResponse
    case decoding(String)
    case tls
    case badRequest(String)
    case cancelled
    case unsupportedVersion(Int)
    case redirected(status: Int)
    case tooLarge
    case other(String)

    public var message: String {
        switch self {
        case .offline: "No internet connection."
        case .notOnTailnet(let host): "Can't reach \(host). Is Tailscale (or your VPN) on?"
        case .cannotFindHost(let host): "Can't find \(host). Check the address."
        case .timeout: "The server took too long to answer."
        case .unauthorized: "No login reached the server. With Tailscale: is it behind `tailscale serve`, and is this phone logged in (tagged devices get no login)? With a token: check it in Settings."
        case .homeAssistantToken: "Home Assistant refused the token. Create a new long-lived token (your profile → Security) and paste it under Edit server."
        case .forbidden: "The server refused access. Is this login or token allowed?"
        case .refused(let why): "The server refused access: \(why)"
        case .notFound: "The server doesn't offer this. Is the address right, and does it speak the Homelab API?"
        case .tooManyRequests: "Too many requests. Try again in a minute."
        case .server(let status): "The server had an error (HTTP \(status))."
        case .serverSaid(_, let text): text
        case .invalidResponse: "The server sent something unexpected."
        case .decoding: "The server's answer couldn't be read. Is it a Homelab API server?"
        case .tls: "The secure connection failed (certificate?)."
        case .badRequest(let text): text.isEmpty ? "The server rejected the request." : text
        case .cancelled: "Cancelled."
        case .unsupportedVersion(let v): "This server speaks Homelab API version \(v). This app knows version 1. Update the app."
        case .redirected(let status): "The server answered with a redirect (HTTP \(status)). Enter the final address: often https:// or another port."
        case .tooLarge: "The server's answer is too large."
        case .other(let text): text
        }
    }

    /// Any 403, with or without a reason.
    public var isForbidden: Bool {
        if case .refused = self { return true }
        return self == .forbidden
    }

    /// After a request that changes something (start an action, press a button): could it have run anyway? False
    /// when the request never reached the server (no connection could be made) or the server refused it (4xx, a
    /// redirect), or it failed and said why in its own words (`serverSaid`: its text tells). True when the connection
    /// broke after sending, the answer was unreadable or the server failed without a word (5xx): then "didn't run"
    /// would be a guess.
    public var mayHaveRun: Bool {
        switch self {
        case .notOnTailnet, .cannotFindHost, .tls, .unauthorized, .homeAssistantToken, .forbidden, .refused, .notFound, .tooManyRequests,
             .badRequest, .unsupportedVersion, .redirected, .serverSaid:
            false
        case .offline, .timeout, .cancelled, .server, .invalidResponse, .decoding, .tooLarge, .other:
            true
        }
    }

    /// Title and text for a failed start or button press: "Didn't run" only when it surely didn't, "Failed" with
    /// the server's own words, else "Not sure it ran". `hasChat`: the server has a chat to look in (feature `chat`).
    public func actionFailure(hasChat: Bool) -> (title: String, text: String) {
        if case .serverSaid = self { return ("Failed", message) }
        guard mayHaveRun else { return ("Didn't run", message) }
        let check = hasChat ? "Check the chat before trying again." : "Check whether it did before trying again."
        return ("Not sure it ran", message + "\n\nIt may have run anyway. " + check)
    }

    /// Worth an automatic retry later (vs. a setup problem the user must fix).
    public var isTransient: Bool {
        switch self {
        case .offline, .notOnTailnet, .timeout, .tooManyRequests, .server, .serverSaid: true
        default: false
        }
    }

    /// Maps URLSession errors to something the user can act on.
    public static func from(_ error: any Error, host: String) -> APIError {
        if let e = error as? APIError { return e }
        if error is CancellationError { return .cancelled }
        guard let u = error as? URLError else { return .other(String(describing: error)) }
        switch u.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .timedOut:
            return .timeout
        case .cannotFindHost, .dnsLookupFailed:
            return host.hasSuffix(".ts.net") || URLPolicy.isLocal(host: host) ? .notOnTailnet(host: host)
                : .cannotFindHost(host: host)
        case .cannotConnectToHost:
            return .notOnTailnet(host: host)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return .tls
        case .cancelled:
            return .cancelled
        case .userAuthenticationRequired:
            return .unauthorized
        default:
            return .other(u.localizedDescription)
        }
    }

    public static func from(status: Int, body: Data) -> APIError? {
        switch status {
        case 200..<300: return nil
        case 300..<400: return .redirected(status: status)
        case 401: return .unauthorized
        case 403:
            // Pass on a specific reason; a bare "forbidden" says nothing new.
            if let text = serverErrorText(body), !["forbidden", "unauthorized"].contains(text.lowercased()) {
                return .refused(text)
            }
            return .forbidden
        case 404: return .notFound
        case 429: return .tooManyRequests
        case 400, 413, 415, 422:
            return .badRequest(serverErrorText(body) ?? "")
        default: return .server(status: status)
        }
    }

    /// The answer to `POST /actions/<name>`: a 404 ("no such action") or 429 ("one at a time") with the server's own
    /// reason shows that reason, and so does a 5xx (`serverSaid`); without one, the generic texts.
    public static func fromAction(status: Int, body: Data) -> APIError? {
        if status == 404 || status == 429, let text = serverErrorText(body) { return .badRequest(text) }
        if (500..<600).contains(status), let text = serverErrorText(body) { return .serverSaid(status: status, text: text) }
        return from(status: status, body: body)
    }

    /// The answer to `GET /search`: a 5xx with the server's own words ("Seerr did not answer") shows them.
    public static func fromSearch(status: Int, body: Data) -> APIError? {
        if (500..<600).contains(status), let text = serverErrorText(body) { return .serverSaid(status: status, text: text) }
        return from(status: status, body: body)
    }

    /// `{"error": "..."}` from the server, shortened, for 4xx messages and failed starts.
    static func serverErrorText(_ body: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = obj["error"] as? String, !text.isEmpty else { return nil }
        return String(text.prefix(200))
    }
}
