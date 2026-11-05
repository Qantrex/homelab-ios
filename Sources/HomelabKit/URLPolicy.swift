import Foundation

/// Which URLs the app accepts, for servers and for links coming from a server.
public enum URLPolicy {
    public enum Problem: Error, Equatable, Sendable {
        case empty, notAURL, unsupportedScheme, noHost, credentialsInURL, insecureRemote
    }

    /// A server base URL the user typed. `https` always; plain `http` only for addresses that stay inside the home
    /// or the tailnet (private IPs, `.local`, single-label names, the Tailscale CGNAT range). The returned URL has
    /// no trailing slash, query or fragment.
    public static func serverURL(_ text: String) -> Result<URL, Problem> {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .failure(.empty) }
        if !s.contains("://") { s = "https://" + s }
        guard var parts = URLComponents(string: s) else { return .failure(.notAURL) }
        guard let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return .failure(.unsupportedScheme)
        }
        guard let host = parts.host, !host.isEmpty else { return .failure(.noHost) }
        if parts.user != nil || parts.password != nil { return .failure(.credentialsInURL) }
        if scheme == "http" && !allowsPlainHTTP(host: host) { return .failure(.insecureRemote) }
        parts.scheme = scheme
        parts.host = host.lowercased()
        parts.query = nil
        parts.fragment = nil
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        // Users paste the API path or a full endpoint; the app adds `/api/v1/...` itself.
        for suffix in ["/api/v1", "/api"] where parts.path.lowercased().hasSuffix(suffix) {
            parts.path.removeLast(suffix.count)
        }
        guard let url = parts.url else { return .failure(.notAURL) }
        return .success(url)
    }

    /// A link from a server (service, card item, host UI): only http(s) with a host, nothing else
    /// (no `javascript:`, `file:`, app schemes).
    public static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// Where the app may use plain http: what iOS ATS allows with NSAllowsLocalNetworking (single-label names,
    /// `.local`) plus private and tailnet IP addresses. Not `.lan`/`.home.arpa`: ATS blocks those over http.
    public static func allowsPlainHTTP(host rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if !host.contains(".") && !host.contains(":") { return true }
        if ipv4(host) != nil || host.contains(":") { return isLocal(host: host) }
        return false
    }

    /// True for names and addresses that don't leave the LAN or tailnet (used to explain errors).
    public static func isLocal(host rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa")
            || host.hasSuffix(".internal") {
            return true
        }
        if !host.contains(".") && !host.contains(":") { return true }   // single-label name (LAN DNS)
        if let v4 = ipv4(host) {
            switch (v4.0, v4.1) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (100, 64...127): return true   // CGNAT: Tailscale's 100.x addresses
            default: return false
            }
        }
        if host.contains(":") {   // IPv6
            return host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
        }
        return false
    }

    static func ipv4(_ host: String) -> (Int, Int, Int, Int)? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let n = parts.compactMap { Int($0) }
        guard n.count == 4, n.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return (n[0], n[1], n[2], n[3])
    }

    public static func message(_ problem: Problem) -> String {
        switch problem {
        case .empty: "Enter the server address."
        case .notAURL: "That is not a valid address."
        case .unsupportedScheme: "Only http:// and https:// addresses work."
        case .noHost: "The address has no host name."
        case .credentialsInURL: "Don't put a user name or password in the address. Use a token instead."
        case .insecureRemote: "http:// is only allowed for addresses in your home network or tailnet. Use https://."
        }
    }
}
