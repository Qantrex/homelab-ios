import Foundation

/// A parsed setup link waiting for confirmation. In memory only.
public struct PublicRouteLinkRequest: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public enum Content: Sendable, Equatable {
        case link(PublicRouteLink)
        case problem(String)
    }
    public let content: Content
    public init(_ content: Content) { self.content = content }
}

extension AppModel {
    /// Parses a setup link and asks for confirmation. The URL is not kept: only the parsed link, in memory.
    func openRouteLink(_ url: URL) {
        do {
            routeLinkRequest = PublicRouteLinkRequest(.link(try PublicRouteLink(url: url)))
        } catch {
            routeLinkRequest = PublicRouteLinkRequest(.problem(error.localizedDescription))
        }
    }

    public func closeRouteLink() { routeLinkRequest = nil }

    /// Stores the link's route for `server` exactly as Settings' Save does (`save` with the address, then
    /// `savePublicSecrets`).
    public func applyRouteLink(_ link: PublicRouteLink, to server: ServerConfig) throws {
        guard let current = servers.servers.first(where: { $0.id == server.id && $0.kind == .companion }) else {
            throw PublicRouteLink.Problem.badContent
        }
        try save(current.withPublicURL(link.publicURL), token: nil)
        try savePublicSecrets(accessID: link.accessID, accessSecret: link.accessSecret, appToken: link.appToken, for: current.id)
        Task { await refresh(current.withPublicURL(link.publicURL)) }
    }

    public func hasPublicRoute(_ server: ServerConfig) -> Bool { server.publicURL != nil }

    /// The connection test over the public route only: the client's base address IS the public one, so there is no
    /// tailnet fallback to hide a failure.
    public func testRouteLink(_ link: PublicRouteLink) async -> Result<String, APIError> {
        guard let route = link.route else { return .failure(APIError.from(PublicRouteLink.Problem.badContent, host: link.publicHost)) }
        do {
            let info = try await CompanionClient(baseURL: link.publicURL, token: nil, transport: transport,
                                                 route: route, health: PublicRouteHealth()).info()
            return .success("Connected to " + (info.name ?? link.publicHost) + " over the public route.")
        } catch {
            return .failure(APIError.from(error, host: link.publicHost))
        }
    }
}
