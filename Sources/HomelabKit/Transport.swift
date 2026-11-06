import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one network seam: URLSession in the app, a fake in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    /// Stop reading past this many bytes (the clients check their own, smaller limits too).
    let maxBytes: Int

    public init(session: URLSession = URLSessionTransport.defaultSession, maxBytes: Int = 32 * 1024 * 1024) {
        self.session = session
        self.maxBytes = maxBytes
    }

    /// No cookies, no cache, no credential storage: every request carries its own auth. Redirects are not followed,
    /// so a bearer token can never be carried to another host by a 3xx answer.
    public static let defaultSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 150
        #if canImport(Darwin)
        c.waitsForConnectivity = false   // fail fast: the UI shows "is Tailscale on?"
        #endif
        c.httpAdditionalHeaders = ["User-Agent": "HomelabiOS/\(AppVersion.short)"]
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }()

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #if canImport(Darwin)
        // Streamed, so a hostile server can't make the app buffer more than `maxBytes`.
        let (bytes, response) = try await session.bytes(for: request)
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
        let (data, response) = try await session.data(for: request)
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
    case forbidden
    /// 403 with the server's own reason ("host not allowed", "forged or outdated button").
    case refused(String)
    case notFound
    case tooManyRequests
    case server(status: Int)
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
        case .forbidden: "The server refused access. Is this login or token allowed?"
        case .refused(let why): "The server refused access: \(why)"
        case .notFound: "The server doesn't offer this. Is the address right, and does it speak the Homelab API?"
        case .tooManyRequests: "Too many requests. Try again in a minute."
        case .server(let status): "The server had an error (HTTP \(status))."
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
    /// redirect). True when the connection broke after sending, the answer was unreadable or the server failed
    /// (5xx): then "didn't run" would be a guess.
    public var mayHaveRun: Bool {
        switch self {
        case .notOnTailnet, .cannotFindHost, .tls, .unauthorized, .forbidden, .refused, .notFound, .tooManyRequests,
             .badRequest, .unsupportedVersion, .redirected:
            false
        case .offline, .timeout, .cancelled, .server, .invalidResponse, .decoding, .tooLarge, .other:
            true
        }
    }

    /// Title and text for a failed start or button press: "Didn't run" only when it surely didn't.
    public var actionFailure: (title: String, text: String) {
        mayHaveRun ? ("Not sure it ran", message + "\n\nIt may have run anyway. Check the chat before trying again.")
                   : ("Didn't run", message)
    }

    /// Worth an automatic retry later (vs. a setup problem the user must fix).
    public var isTransient: Bool {
        switch self {
        case .offline, .notOnTailnet, .timeout, .tooManyRequests, .server, .cancelled: true
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
    /// reason shows that reason; without one, the generic texts.
    public static func fromAction(status: Int, body: Data) -> APIError? {
        if status == 404 || status == 429, let text = serverErrorText(body) { return .badRequest(text) }
        return from(status: status, body: body)
    }

    /// `{"error": "..."}` from the server, shortened, for 4xx messages.
    static func serverErrorText(_ body: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = obj["error"] as? String, !text.isEmpty else { return nil }
        return String(text.prefix(200))
    }
}
