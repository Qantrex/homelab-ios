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

    /// An `image` reference from a server as the model keeps it: trimmed, either a path starting with one "/" or an
    /// http(s) URL, short, without control characters or backslashes. Anything else is nil. Whether it may be loaded
    /// is `imageURL`'s decision, once the server is known.
    public static func cleanImageReference(_ text: String) -> String? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 512, !s.contains("\\"),
              s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return nil }
        if s.hasPrefix("/") { return s.hasPrefix("//") ? nil : s }
        let lower = s.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") ? s : nil
    }

    /// The URL an `image` reference means on `server`, or nil. A path is resolved against the server (its own path
    /// prefix, if it has one, is kept). An absolute URL must have the server's scheme, host and port and no user
    /// name or password. Dot segments, encoded slashes and backslashes are refused, and fragments are dropped, so
    /// nothing but this server's own host is ever asked.
    public static func imageURL(_ text: String, server base: URL) -> URL? {
        guard let s = cleanImageReference(text),
              var out = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let scheme = out.scheme?.lowercased(), let host = out.host?.lowercased(),
              let given = URLComponents(string: s) else { return nil }
        var prefix = out.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        var path = given.percentEncodedPath
        if s.hasPrefix("/") {
            guard given.scheme == nil, given.host == nil else { return nil }
            if !prefix.isEmpty, !path.hasPrefix(prefix + "/") { path = prefix + path }
        } else {
            // Under the server's own path only: with a base of `/homelab`, `/other-app/...` on the same host is
            // another service, which must not get this server's token.
            guard given.scheme?.lowercased() == scheme, given.host?.lowercased() == host, given.port == out.port,
                  given.user == nil, given.password == nil, prefix.isEmpty || path.hasPrefix(prefix + "/") else { return nil }
        }
        let lower = path.lowercased()
        let dotSegment = path.split(separator: "/", omittingEmptySubsequences: false).contains { seg in
            let d = seg.lowercased().replacingOccurrences(of: "%2e", with: ".")
            return d == "." || d == ".."
        }
        guard path.hasPrefix("/"), !lower.contains("%2f"), !lower.contains("%5c"), !lower.contains("%00"),
              !dotSegment else { return nil }
        out.percentEncodedPath = path
        out.percentEncodedQuery = given.percentEncodedQuery
        out.fragment = nil
        return out.url
    }

    /// Where the app may use plain http: what iOS ATS allows with NSAllowsLocalNetworking (single-label names,
    /// `.local`) plus private and tailnet IP addresses. Not `.lan`/`.home.arpa`: ATS blocks those over http. Not a
    /// number written as one label (`134744072`, `0x08080808`): the resolver reads that as a public IPv4 address.
    public static func allowsPlainHTTP(host rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if isSingleLabelName(host) { return true }
        if ipv4(host) != nil || host.contains(":") { return isLocal(host: host) }
        return false
    }

    /// May a bearer token travel to `url`? `https` always. Plain `http` only to this device (`localhost`,
    /// `127.0.0.1`, `::1`) and to Tailscale MagicDNS names (`*.ts.net`): those resolve only inside the tailnet, so
    /// the traffic is WireGuard-encrypted. Not to a raw `100.64/10` address (carrier CGNAT when Tailscale is off),
    /// a private LAN address, `.local` or a single-label name: anyone on that network could read the token.
    public static func allowsToken(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), var host = url.host?.lowercased(), !host.isEmpty else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".") { host.removeLast() }
        if ["localhost", "127.0.0.1", "::1"].contains(host) { return true }
        let tailnet = ".ts.net"
        return host.hasSuffix(tailnet) && host.count > tailnet.count && !host.contains(":")
    }

    /// Why a token must not go to `url`, or nil when it may (`allowsToken`).
    public static func tokenProblem(_ url: URL) -> String? {
        allowsToken(url) ? nil : tokenOverHTTPMessage
    }

    public static let tokenOverHTTPMessage =
        "This server uses a token over plain http. Use its https://….ts.net address (tailscale serve)."

    /// A name without dots that DNS (or mDNS) resolves on the LAN. A label of digits or `0x` hex is not one: it is
    /// an IPv4 address in another notation.
    static func isSingleLabelName(_ host: String) -> Bool {
        guard !host.isEmpty, !host.contains("."), !host.contains(":") else { return false }
        return !isNumericLabel(host)
    }

    /// `134744072`, `0x08080808`, `0X1`, `017`: what inet_aton would read as a number.
    static func isNumericLabel(_ label: String) -> Bool {
        let l = label.lowercased()
        if l.hasPrefix("0x") { return l.dropFirst(2).allSatisfy(\.isHexDigit) }
        return l.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// True for names and addresses that don't leave the LAN or tailnet (used to explain errors).
    public static func isLocal(host rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa")
            || host.hasSuffix(".internal") {
            return true
        }
        if isSingleLabelName(host) { return true }   // single-label name (LAN DNS)
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

    /// Dotted decimal only: four parts of 1-3 digits, no sign and no leading zero (`010` is octal 8 to the resolver,
    /// so `010.8.8.8` would be checked as 10.8.8.8 but reach 8.8.8.8).
    static func ipv4(_ host: String) -> (Int, Int, Int, Int)? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ p in
            (1...3).contains(p.count) && p.allSatisfy { $0.isASCII && $0.isNumber } && (p == "0" || p.first != "0")
        }) else { return nil }
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
        case .insecureRemote: "http:// is only allowed for private addresses (home network, 100.x). Use https://, also for .ts.net names."
        }
    }
}
