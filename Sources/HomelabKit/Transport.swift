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

    public init(session: URLSession = URLSessionTransport.defaultSession) {
        self.session = session
    }

    /// No cookies, no cache, no credential storage: every request carries its own auth.
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
        return URLSession(configuration: c)
    }()

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, http)
    }
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
    case notFound
    case tooManyRequests
    case server(status: Int)
    case invalidResponse
    case decoding(String)
    case tls
    case badRequest(String)
    case cancelled
    case unsupportedVersion(Int)
    case other(String)

    public var message: String {
        switch self {
        case .offline: "No internet connection."
        case .notOnTailnet(let host): "Can't reach \(host). Is Tailscale (or your VPN) on?"
        case .cannotFindHost(let host): "Can't find \(host). Check the address."
        case .timeout: "The server took too long to answer."
        case .unauthorized: "The server wants a login or token. Check the token in Settings."
        case .forbidden: "The server refused access. Is this login or token allowed?"
        case .notFound: "The server doesn't offer this. Is the address right, and does it speak the Homelab API?"
        case .tooManyRequests: "Too many requests. Try again in a minute."
        case .server(let status): "The server had an error (HTTP \(status))."
        case .invalidResponse: "The server sent something unexpected."
        case .decoding: "The server's answer couldn't be read. Is it a Homelab API server?"
        case .tls: "The secure connection failed (certificate?)."
        case .badRequest(let text): text.isEmpty ? "The server rejected the request." : text
        case .cancelled: "Cancelled."
        case .unsupportedVersion(let v): "This server speaks Homelab API version \(v). This app knows version 1. Update the app."
        case .other(let text): text
        }
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
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 429: return .tooManyRequests
        case 400, 413, 415, 422:
            return .badRequest(serverErrorText(body) ?? "")
        default: return .server(status: status)
        }
    }

    /// `{"error": "..."}` from the server, shortened, for 4xx messages.
    static func serverErrorText(_ body: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = obj["error"] as? String, !text.isEmpty else { return nil }
        return String(text.prefix(200))
    }
}
