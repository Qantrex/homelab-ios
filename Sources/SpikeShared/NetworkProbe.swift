import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Test S5: one GET from the native app over the tailnet, with no token. On the owner's homelab,
/// `tailscale serve` adds `Tailscale-User-Login`, and agent-chat answers `/api/state` with 200 for an allowed login.
/// A 403 means the header did not arrive (or the login isn't allowed); agent-chat logs the login it saw.
public struct ProbeResult: Sendable, Codable, Equatable {
    public var url: String
    public var status: Int?
    public var milliseconds: Int
    public var bodyPrefix: String
    public var error: String?
    public var at: Date

    public var summary: String {
        if let error { return "error after \(milliseconds) ms: \(error)" }
        return "HTTP \(status.map(String.init) ?? "?") in \(milliseconds) ms"
    }
}

public enum NetworkProbe {
    public static func run(_ text: String, timeout: TimeInterval = 15) async -> ProbeResult {
        let start = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else {
            return ProbeResult(url: text, status: nil, milliseconds: 0, bodyPrefix: "",
                               error: "not an http(s) URL", at: start)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            let prefix = String(decoding: data.prefix(300), as: UTF8.self)
            return ProbeResult(url: url.absoluteString, status: status, milliseconds: elapsed(),
                               bodyPrefix: prefix, error: nil, at: start)
        } catch {
            return ProbeResult(url: url.absoluteString, status: nil, milliseconds: elapsed(), bodyPrefix: "",
                               error: String(describing: error), at: start)
        }
    }
}
