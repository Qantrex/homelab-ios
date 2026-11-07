import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HomelabKit

// Fixes from the security review of 2026-11-06 (its probe tests, turned into real ones).

/// Tokens never travel over plain http outside this device and the tailnet's `.ts.net` names.
struct TokenTransportTests {
    @Test func whereATokenMayGo() {
        for u in ["https://nas.example.ts.net", "https://8.8.8.8", "https://192.168.1.5:8443/homelab",
                  "http://localhost:8791", "http://127.0.0.1:8791", "http://[::1]:8791",
                  "http://nas.tail1234.ts.net", "http://NAS.Tail1234.TS.NET:8080/x", "http://nas.tail1234.ts.net./"] {
            #expect(URLPolicy.allowsToken(URL(string: u)!), "\(u)")
        }
        for u in ["http://100.101.102.103", "http://100.64.0.1:8791",          // raw tailnet IPs: CGNAT without Tailscale
                  "http://192.168.1.10:8791", "http://10.0.0.2", "http://172.16.0.1",
                  "http://nas.local", "http://nas:8123", "http://[fd7a:115c:a1e0::1]:8791", "http://[fe80::1]",
                  "http://127.0.0.2", "http://ts.net", "http://evilts.net", "http://example.com",
                  "ftp://nas.example.ts.net", "file:///etc/passwd"] {
            #expect(!URLPolicy.allowsToken(URL(string: u)!), "\(u)")
        }
    }

    @Test func editorShowsItAsAProblem() {
        let lan = URL(string: "http://192.168.1.10:8791")!
        let token = ServerConfig(name: "lab", kind: .companion, baseURL: lan, auth: .token)
        #expect(token.tokenTransportProblem == URLPolicy.tokenOverHTTPMessage)
        #expect(URLPolicy.tokenOverHTTPMessage
                == "This server uses a token over plain http. Use its https://….ts.net address (tailscale serve).")
        // Identity servers send no token: the old http rules stay.
        #expect(ServerConfig(name: "lab", kind: .companion, baseURL: lan, auth: .identity).tokenTransportProblem == nil)
        // Home Assistant always sends its token, whatever `auth` says.
        #expect(ServerConfig(name: "ha", kind: .homeAssistant, baseURL: URL(string: "http://homeassistant.local:8123")!,
                             auth: .identity).tokenTransportProblem != nil)
        #expect(ServerConfig.tokenTransportProblem(kind: .companion, auth: .token,
                                                   url: URL(string: "https://lab.example.ts.net")!) == nil)
        #expect(ServerConfig.demo().tokenTransportProblem == nil)
    }

    @Test func companionClientRefusesBeforeSending() async {
        let t = FakeTransport(fixture: "state-ok.json")
        for u in ["http://192.168.1.10:8791", "http://100.101.102.103", "http://nas.local", "http://nas"] {
            let client = CompanionClient(baseURL: URL(string: u)!, token: "secret", transport: t)
            await #expect(throws: APIError.badRequest(URLPolicy.tokenOverHTTPMessage)) { try await client.state() }
            await #expect(throws: APIError.self) { try await client.image(path: "/api/v1/poster/a.png") }
            await #expect(throws: APIError.self) { try await client.run("dns-pause", arg: "5", payload: [:]) }
            #expect(client.request("state", timeout: 1).value(forHTTPHeaderField: "Authorization") == nil)
        }
        #expect(t.requests.isEmpty)
        // The refusal says it didn't run.
        #expect(APIError.badRequest(URLPolicy.tokenOverHTTPMessage).mayHaveRun == false)
    }

    @Test func companionClientSendsWhereItMay() async throws {
        let t = FakeTransport(fixture: "state-ok.json")
        for u in ["https://lab.example.ts.net", "http://nas.tail1234.ts.net", "http://localhost:8791"] {
            _ = try await CompanionClient(baseURL: URL(string: u)!, token: "secret", transport: t).state()
            #expect(t.last?.value(forHTTPHeaderField: "Authorization") == "Bearer secret", "\(u)")
        }
        // Identity on the LAN: still allowed, and nothing attached.
        _ = try await CompanionClient(baseURL: URL(string: "http://192.168.1.10:8791")!, token: nil, transport: t).state()
        #expect(t.last?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(t.requests.count == 4)
    }

    @Test func homeAssistantRefusesBeforeSending() async throws {
        let t = FakeTransport(json: #"{"message": "API running."}"#)
        let lan = HomeAssistantClient(baseURL: URL(string: "http://homeassistant.local:8123")!, token: "llat", transport: t)
        await #expect(throws: APIError.badRequest(URLPolicy.tokenOverHTTPMessage)) { try await lan.check() }
        await #expect(throws: APIError.self) { _ = try await lan.states() }
        #expect(t.requests.isEmpty)
        #expect(lan.request("api/", timeout: 1).value(forHTTPHeaderField: "Authorization") == nil)
        let ok = HomeAssistantClient(baseURL: URL(string: "https://ha.example.ts.net")!, token: "llat", transport: t)
        #expect(try await ok.check() == "API running.")
        #expect(t.last?.value(forHTTPHeaderField: "Authorization") == "Bearer llat")
    }

    @Test func answersStopAtTheirLimits() async {
        let big = Data(repeating: 0x20, count: CompanionClient.maxResponseBytes + 1)
        let t = FakeTransport { _ in .init(body: big) }
        await #expect(throws: APIError.tooLarge) {
            try await CompanionClient(baseURL: base, token: nil, transport: t).state()
        }
        #expect(CompanionClient.maxResponseBytes == 8 * 1024 * 1024)
        #expect(HomeAssistantClient.maxResponseBytes == 32 * 1024 * 1024)
    }
}

/// http rules for identity servers: numbers written as one label are public addresses, not LAN names.
struct PlainHTTPHostTests {
    @Test func numericHostsAreNotLocal() {
        for h in ["134744072", "0x08080808", "0X7F000001", "2130706433", "017700000001", "010.8.8.8", "8.8.8.010",
                  "+10.0.0.1", "10.0.0.1.nip.io", "::ffff:8.8.8.8", "8.8.8.8"] {
            #expect(!URLPolicy.allowsPlainHTTP(host: h), "\(h)")
            #expect(!URLPolicy.isLocal(host: h), "\(h)")
        }
        #expect((try? URLPolicy.serverURL("http://134744072").get()) == nil)
        #expect((try? URLPolicy.serverURL("http://0x08080808:8791").get()) == nil)
        // Real single-label names and dotted private addresses still count.
        for h in ["nas", "pi4", "0xnas", "homeassistant", "10.0.0.1", "192.168.0.10", "100.64.0.1"] {
            #expect(URLPolicy.allowsPlainHTTP(host: h), "\(h)")
        }
    }
}

/// An absolute picture URL must sit under the server's own path, or another service on the host gets the token.
struct ImageURLBaseTests {
    @Test func absoluteURLsStayUnderTheBasePath() {
        let server = URL(string: "https://nas.example.ts.net/homelab")!
        func url(_ s: String) -> String? { URLPolicy.imageURL(s, server: server)?.absoluteString }
        #expect(url("https://nas.example.ts.net/homelab/api/v1/poster/a.jpg") == "https://nas.example.ts.net/homelab/api/v1/poster/a.jpg")
        #expect(url("/api/v1/poster/a.jpg") == "https://nas.example.ts.net/homelab/api/v1/poster/a.jpg")
        #expect(url("https://nas.example.ts.net/other/app") == nil)
        #expect(url("https://nas.example.ts.net/homelabX/a.jpg") == nil)
        #expect(url("https://nas.example.ts.net/homelab") == nil)
        #expect(url("https://nas.example.ts.net/homelab/../x") == nil)
        #expect(url("/homelab/../x") == nil)
        #expect(url("https://nas.example.ts.net:443/homelab/x") == nil)   // another port spelling: refused
        // A server at the root: everything on it is its own.
        #expect(URLPolicy.imageURL("https://nas.example.ts.net/x.png", server: URL(string: "https://nas.example.ts.net")!) != nil)
    }
}
