import Foundation
import Testing
@testable import HomelabKit

@MainActor @Suite(.serialized) struct PublicRouteLinkTests {
    let id = "FAKE-ID.access", secret = "FAKE-SECRET-abcdef0123", token = "FAKE-APP-TOKEN-xyz"

    func link(_ obj: [String: Any], version: String = "v1") -> URL {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        let b64 = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "homelab://public-route#\(version).\(b64)")!
    }
    func valid(server: String? = "https://lab.example.ts.net:7443") -> [String: Any] {
        var o: [String: Any] = ["url": "https://h-ab12.example.com", "id": id, "secret": secret, "token": token]
        if let server { o["server"] = server }
        return o
    }
    func problem(_ url: URL) -> PublicRouteLink.Problem? {
        do { _ = try PublicRouteLink(url: url); return nil } catch { return error as? PublicRouteLink.Problem }
    }

    @Test func validPayload() throws {
        let l = try PublicRouteLink(url: link(valid()))
        #expect(l.publicURL.absoluteString == "https://h-ab12.example.com")
        #expect(l.server?.host == "lab.example.ts.net")
        #expect(l.route != nil)
        #expect(try PublicRouteLink(url: link(valid(server: nil))).server == nil)
    }

    @Test func sampleLineFromAScript() throws {
        // What a script (Python, compact JSON, urlsafe base64 without padding) makes; fake values.
        let l = try PublicRouteLink(url: URL(string: "homelab://public-route#v1.eyJzZXJ2ZXIiOiJodHRwczovL2xhYi5leGFtcGxlLnRzLm5ldDo3NDQzIiwidXJsIjoiaHR0cHM6Ly9oLWFiMTIuZXhhbXBsZS5jb20iLCJpZCI6IkZBS0UtSUQuYWNjZXNzIiwic2VjcmV0IjoiRkFLRS1TRUNSRVQtYWJjZGVmMDEyMyIsInRva2VuIjoiRkFLRS1BUFAtVE9LRU4teHl6In0")!)
        #expect(l.publicHost == "h-ab12.example.com" && l.server?.port == 7443)
    }

    @Test func rejects() {
        #expect(problem(link(valid(), version: "v2")) == .unsupportedVersion)
        #expect(problem(URL(string: "homelab://public-route#abc")!) == .badEncoding)
        #expect(problem(URL(string: "homelab://public-route")!) == .badEncoding)
        #expect(problem(URL(string: "homelab://public-route#v1.!!!notbase64")!) == .badEncoding)
        #expect(problem(URL(string: "homelab://public-route#v1.aGVsbG8")!) == .badEncoding)   // "hello": not JSON
        var extra = valid(); extra["more"] = "x"
        #expect(problem(link(extra)) == .badContent)
        var missing = valid(); missing["token"] = nil
        #expect(problem(link(missing)) == .badContent)
        var wrongType = valid(); wrongType["id"] = 5
        #expect(problem(link(wrongType)) == .badContent)
        var http = valid(); http["url"] = "http://h.example.com"
        #expect(problem(link(http)) == .notHTTPS)
        var badServer = valid(); badServer["server"] = "ftp://x"
        #expect(problem(link(badServer)) == .badContent)
    }

    @Test func keyInjectionAndLength() {
        for bad in ["a\r\nX-Evil: 1", "has space", "tab\there", "", "   ", " lead", "trail\n", "ümlaut"] {
            var o = valid(); o["secret"] = bad
            #expect(problem(link(o)) != nil, "\(bad.debugDescription)")
        }
        var long = valid(); long["token"] = String(repeating: "a", count: 513)
        #expect(problem(link(long)) != nil)
        var ok = valid(); ok["token"] = String(repeating: "a", count: 512)
        #expect(problem(link(ok)) == nil)
        var longURL = valid(); longURL["url"] = "https://h.example.com/" + String(repeating: "a", count: 520)
        #expect(problem(link(longURL)) != nil)
    }

    @Test func redaction() throws {
        let l = try PublicRouteLink(url: link(valid()))
        for text in [l.description, l.debugDescription, "\(l)", String(reflecting: l)] {
            #expect(!text.contains(id) && !text.contains(secret) && !text.contains(token))
        }
        for e in [PublicRouteLink.Problem.badKey("client id"), .badContent, .tooLong("x")] {
            #expect(!(e.errorDescription ?? "").contains(secret))
        }
    }

    func cfg(_ name: String, _ url: String, kind: ServerConfig.Kind = .companion) -> ServerConfig {
        ServerConfig(name: name, kind: kind, baseURL: URL(string: url)!, auth: .identity)
    }

    @Test func serverMatching() throws {
        let a = cfg("a", "https://lab.example.ts.net:7443"), b = cfg("b", "https://other.example.ts.net")
        let ha = cfg("ha", "https://ha.example.ts.net", kind: .homeAssistant)
        let withServer = try PublicRouteLink(url: link(valid()))
        let without = try PublicRouteLink(url: link(valid(server: nil)))
        #expect(withServer.target(in: [b, a, ha]) == .server(a))                    // origin match
        #expect(without.target(in: [ha, a]) == .server(a))                         // the only companion server
        #expect(without.target(in: [a, b]) == .choose([a, b], notFound: false))
        #expect(withServer.target(in: [b]) == .server(b))                           // unmatched, one server: that one
        #expect(withServer.target(in: [b, cfg("c", "https://c.example.ts.net")]) .isChoose(notFound: true))
        #expect(without.target(in: [ha]) == .none)
        #expect(without.target(in: []) == .none)
    }

    func routeModel() -> (AppModel, MemoryTokenStore, Storage, ServerConfig) {
        let (m, _, storage, tokens) = makeModel()
        let s = cfg("lab", "https://lab.example.ts.net:7443")
        try! m.save(s, token: nil)
        return (m, tokens, storage, s)
    }

    @Test func openingTheLinkOnlyAsksAndStoresNothing() throws {
        let (m, tokens, storage, s) = routeModel()
        m.open(link(valid()))
        guard case .link(let l)? = m.routeLinkRequest?.content else { Issue.record("no request"); return }
        #expect(l.publicHost == "h-ab12.example.com")
        #expect(m.servers.servers.first { $0.id == s.id }?.publicURL == nil)   // nothing saved before "Add"
        #expect(tokens.publicSecret(.accessSecret, for: s.id) == nil)
        m.closeRouteLink()
        #expect(m.routeLinkRequest == nil)
        // Nothing of it on disk, whatever the model wrote: no key, no link, no fragment.
        let fm = FileManager.default
        for case let f as String in fm.enumerator(atPath: storage.directory.path) ?? FileManager.default.enumerator(atPath: "/")! {
            let data = fm.contents(atPath: storage.directory.appendingPathComponent(f).path) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            for needle in [secret, token, id, "public-route", "v1."] { #expect(!text.contains(needle), "\(f) has \(needle)") }
        }
        #expect(m.requestedTab == nil && m.openAction == nil)   // it is not a tab link
    }

    @Test func badLinkShowsAMessageAndLocksClear() {
        let (m, _, _, _) = routeModel()
        m.open(URL(string: "homelab://public-route#v9.xxx")!)
        guard case .problem(let t)? = m.routeLinkRequest?.content else { Issue.record("no problem"); return }
        #expect(!t.isEmpty)
        m.open(link(valid()))
        m.lock()
        #expect(m.routeLinkRequest == nil)
    }

    @Test func addStoresLikeSettingsAndReplacesAnOldRoute() throws {
        let (m, tokens, _, s) = routeModel()
        try m.applyRouteLink(PublicRouteLink(url: link(["url": "https://old.example.com", "id": "OLDID", "secret": "OLDSEC", "token": "OLDTOK"])), to: s)
        try m.applyRouteLink(PublicRouteLink(url: link(valid())), to: s)
        let saved = try #require(m.servers.servers.first { $0.id == s.id })
        #expect(saved.publicURL?.host == "h-ab12.example.com")
        #expect(tokens.publicSecret(.accessID, for: s.id) == id)
        #expect(tokens.publicSecret(.accessSecret, for: s.id) == secret)
        #expect(tokens.publicSecret(.appToken, for: s.id) == token)
        #expect(m.tokens.publicRoute(for: saved) != nil)
    }

    @Test func testUsesThePublicRouteOnly() async throws {
        let (m, server, _, _) = makeModel()
        let l = try PublicRouteLink(url: link(valid()))
        let r = await m.testRouteLink(l)
        guard case .success = r else { Issue.record("\(r)"); return }
        #expect(Set(server.hosts) == ["h-ab12.example.com"])
    }
}

extension PublicRouteLink.Target {
    func isChoose(notFound: Bool) -> Bool { if case .choose(_, let n) = self { n == notFound } else { false } }
}
