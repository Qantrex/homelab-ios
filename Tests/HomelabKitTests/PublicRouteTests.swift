import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HomelabKit

@Suite struct PublicRouteTests {
    let pub = URL(string: "https://api.example.org")!
    let idSecret = "ID-SECRET-1234.access.example"
    let csSecret = "CS-SECRET-5678abcdef"
    let tkSecret = "APPTOKEN-SECRET-9012"

    func route(_ url: URL? = nil) -> PublicRoute {
        PublicRoute(baseURL: url ?? pub, accessID: idSecret, accessSecret: csSecret, appToken: tkSecret)!
    }

    func client(_ t: FakeTransport, route: PublicRoute? = nil, token: String? = "TAILNET-TOKEN", health: PublicRouteHealth = PublicRouteHealth()) -> CompanionClient {
        CompanionClient(baseURL: base, token: token, transport: t, route: route ?? self.route(), health: health)
    }

    @Test func publicRequestCarriesTheThreeKeysAndNotTheTailnetToken() async throws {
        let t = FakeTransport(fixture: "info.json")
        _ = try await client(t).info()
        let r = try #require(t.last)
        #expect(r.url?.absoluteString == "https://api.example.org/api/v1/info")
        #expect(r.value(forHTTPHeaderField: "CF-Access-Client-Id") == idSecret)
        #expect(r.value(forHTTPHeaderField: "CF-Access-Client-Secret") == csSecret)
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer " + tkSecret)
        #expect(!(r.allHTTPHeaderFields ?? [:]).values.contains { $0.contains("TAILNET-TOKEN") })
        #expect(t.requests.count == 1)
    }

    @Test func subPathAndQueryAreRebased() async throws {
        let t = FakeTransport(fixture: "messages.json")
        let c = CompanionClient(baseURL: URL(string: "https://h.example/homelab")!, token: nil, transport: t,
                                route: route(URL(string: "https://api.example.org/x/")!), health: PublicRouteHealth())
        _ = try await c.messages(after: 5)
        #expect(t.last?.url?.absoluteString == "https://api.example.org/x/api/v1/messages?after=5")
    }

    @Test func networkFailureFallsBackToTheTailnetWithoutPublicKeys() async throws {
        let t = FakeTransport { r in
            r.url?.host == "api.example.org" ? .init(error: URLError(.cannotConnectToHost)) : .init(body: Fixtures.data("info.json") ?? Data())
        }
        _ = try await client(t).info()
        #expect(t.requests.count == 2)
        let tail = t.requests[1]
        #expect(tail.url?.host == "homelab.example.ts.net")
        #expect(tail.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil)
        #expect(tail.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
        #expect(tail.value(forHTTPHeaderField: "Authorization") == "Bearer TAILNET-TOKEN")
        #expect(!(tail.allHTTPHeaderFields ?? [:]).values.contains { $0.contains(tkSecret) || $0.contains(idSecret) || $0.contains(csSecret) })
    }

    @Test func aTimeoutFallsBackForReadsOnlyAndTheReadWaitIsShort() async throws {
        let t = FakeTransport { r in
            r.url?.host == "api.example.org" ? .init(error: URLError(.timedOut)) : .init(body: Fixtures.data("info.json") ?? Data())
        }
        _ = try await client(t).info()
        #expect(t.requests.count == 2)
        #expect(t.requests[0].timeoutInterval <= PublicRoute.readTimeout)
        // A write that timed out may have run: no second try.
        let w = FakeTransport(error: URLError(.timedOut))
        await #expect(throws: APIError.timeout) { _ = try await client(w).send("hi") }
        #expect(w.requests.count == 1)
    }

    @Test func aWriteIsRepeatedOnlyWhenItSurelyNeverArrived() async throws {
        let t = FakeTransport { r in
            r.url?.host == "api.example.org" ? .init(error: URLError(.cannotFindHost)) : .init(body: Data(#"{"ok":true,"id":7}"#.utf8))
        }
        let id = try await client(t).send("hi")
        #expect(id == 7)
        #expect(t.requests.count == 2)
        let gw = FakeTransport { r in
            r.url?.host == "api.example.org" ? .init(status: 504) : .init(body: Data(#"{"ok":true,"id":7}"#.utf8))
        }
        await #expect(throws: APIError.self) { _ = try await client(gw).send("hi") }
        #expect(gw.requests.count == 1)
        let down = FakeTransport { r in
            r.url?.host == "api.example.org" ? .init(status: 530) : .init(body: Data(#"{"ok":true,"id":7}"#.utf8))
        }
        _ = try await client(down).send("hi")
        #expect(down.requests.count == 2)
    }

    @Test func accessAndTokenRefusalsNeverFallBackSilently() async throws {
        for status in [401, 403, 302] {
            let t = FakeTransport(status: status, json: #"{"error":"forbidden"}"#)
            do {
                _ = try await client(t).info()
                Issue.record("status \(status) did not throw")
            } catch let e as APIError {
                #expect(e == .publicRouteRefused(status: status))
                #expect(!e.message.contains(tkSecret) && !e.message.contains(idSecret) && !e.message.contains(csSecret))
            }
            #expect(t.requests.count == 1)
        }
        // A 5xx from the agent itself (not Cloudflare's origin-down codes) is shown too.
        let s = FakeTransport(status: 500, json: "{}")
        await #expect(throws: APIError.server(status: 500)) { _ = try await client(s).info() }
        #expect(s.requests.count == 1)
    }

    @Test func aDeadRouteIsSkippedForAMinute() async throws {
        let clock = TestClock()
        let health = PublicRouteHealth(now: { clock.now })
        let t = FakeTransport { r in
            r.url?.host == "api.example.org" ? .init(error: URLError(.cannotConnectToHost)) : .init(body: Fixtures.data("info.json") ?? Data())
        }
        let c = client(t, health: health)
        _ = try await c.info()
        #expect(t.requests.count == 2)
        _ = try await c.info()
        #expect(t.requests.count == 3)   // public skipped
        clock.advance(PublicRouteHealth.pause + 1)
        _ = try await c.info()
        #expect(t.requests.count == 5)   // tried again
    }

    @Test func noRouteMeansNoChange() async throws {
        let t = FakeTransport(fixture: "info.json")
        _ = try await CompanionClient(baseURL: base, token: "TAILNET-TOKEN", transport: t).info()
        #expect(t.requests.count == 1)
        #expect(t.last?.url?.host == "homelab.example.ts.net")
        #expect(t.last?.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil)
    }

    @Test func aRouteNeedsHttpsAndAllThreeKeysAndCleanValues() {
        #expect(PublicRoute(baseURL: URL(string: "http://api.example.org")!, accessID: "a", accessSecret: "b", appToken: "c") == nil)
        #expect(PublicRoute(baseURL: pub, accessID: "a", accessSecret: "b", appToken: nil) == nil)
        #expect(PublicRoute(baseURL: pub, accessID: "a", accessSecret: "", appToken: "c") == nil)
        #expect(PublicRoute(baseURL: nil, accessID: "a", accessSecret: "b", appToken: "c") == nil)
        // No header injection: a CR/LF or a space inside a key refuses the whole route.
        #expect(PublicRoute(baseURL: pub, accessID: "a\r\nX-Evil: 1", accessSecret: "b", appToken: "c") == nil)
        #expect(PublicRoute(baseURL: pub, accessID: "a", accessSecret: "b b", appToken: "c") == nil)
        #expect(PublicRoute(baseURL: pub, accessID: " a \n", accessSecret: "b", appToken: "c") != nil)   // outer whitespace is trimmed
    }

    @Test func secretsStayOutOfDescriptionsConfigAndTheUserAgent() throws {
        let r = route()
        for text in [r.description, r.debugDescription, String(describing: r), "\(r)"] {
            #expect(!text.contains(tkSecret) && !text.contains(idSecret) && !text.contains(csSecret))
        }
        let tokens = MemoryTokenStore()
        let s = ServerConfig(name: "x", kind: .companion, baseURL: base, auth: .identity, publicURL: pub)
        try tokens.setPublicSecret(idSecret, .accessID, for: s.id)
        try tokens.setPublicSecret(csSecret, .accessSecret, for: s.id)
        try tokens.setPublicSecret(tkSecret, .appToken, for: s.id)
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        #expect(!json.contains(tkSecret) && !json.contains(idSecret) && !json.contains(csSecret))
        #expect(!AppVersion.userAgent.contains(tkSecret))
        #expect(tokens.publicRoute(for: s) != nil)
        // The server's own token slot is untouched by the three keys.
        #expect(tokens.token(for: s.id) == nil)
        tokens.clearPublicSecrets(for: s.id)
        #expect(tokens.publicRoute(for: s) == nil)
        #expect(tokens.count == 0)
    }

    @Test func configWithoutAPublicURLEncodesLikeBefore() throws {
        let s = ServerConfig(name: "x", kind: .companion, baseURL: base, auth: .identity)
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        #expect(!json.contains("publicURL"))
        let back = try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
        #expect(back == s && back.publicURL == nil)
        let withURL = s.withPublicURL(pub)
        #expect(try JSONDecoder().decode(ServerConfig.self, from: JSONEncoder().encode(withURL)).publicURL == pub)
        // Only a Companion server has one; the cache identity does not change with it.
        #expect(ServerConfig(name: "ha", kind: .homeAssistant, baseURL: base, auth: .token).withPublicURL(pub).publicURL == nil)
        #expect(withURL.target == s.target)
    }

    @MainActor @Test func aNewPublicAddressDropsTheOldKeys() throws {
        let (model, _, _, tokens) = makeModel()
        let s = ServerConfig(name: "x", kind: .companion, baseURL: base, auth: .identity, publicURL: pub)
        try model.save(s, token: nil)
        try model.savePublicSecrets(accessID: idSecret, accessSecret: csSecret, appToken: tkSecret, for: s.id)
        #expect(tokens.publicRoute(for: s) != nil)
        try model.save(s, token: nil)   // same address: keys stay
        #expect(tokens.publicRoute(for: s) != nil)
        let moved = s.withPublicURL(URL(string: "https://evil.example")!)
        try model.save(moved, token: nil)
        #expect(tokens.publicRoute(for: moved) == nil)
        #expect(tokens.count == 0)
        try model.savePublicSecrets(accessID: idSecret, accessSecret: csSecret, appToken: tkSecret, for: s.id)
        try model.save(moved.withPublicURL(nil), token: nil)   // removing the address removes the keys
        #expect(tokens.count == 0)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}
