import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HomelabKit

@Suite struct CompanionClientTests {
    @Test func identityAuthSendsNoToken() async throws {
        let t = FakeTransport(fixture: "state-problem.json")
        let state = try await CompanionClient(baseURL: base, token: nil, transport: t).state()
        #expect(state.pending.count == 2)
        let r = try #require(t.last)
        #expect(r.url?.absoluteString == "https://homelab.example.ts.net/api/v1/state")
        #expect(r.httpMethod == "GET")
        #expect(r.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(r.value(forHTTPHeaderField: "Origin") == nil)
        #expect(r.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func tokenAuthFromTheStore() async throws {
        let tokens = MemoryTokenStore()
        let server = ServerConfig(name: "x", kind: .companion, baseURL: base, auth: .token)
        try tokens.setToken("  s3cret \n", for: server.id)
        let t = FakeTransport(fixture: "info.json")
        _ = try await CompanionClient(config: server, tokens: tokens, transport: t).info()
        #expect(t.last?.value(forHTTPHeaderField: "Authorization") == "Bearer s3cret")
        // Identity servers never send the token, even if one is stored.
        let identity = ServerConfig(id: server.id, name: "x", kind: .companion, baseURL: base, auth: .identity)
        _ = try await CompanionClient(config: identity, tokens: tokens, transport: t).info()
        #expect(t.last?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func subPathIsKept() async throws {
        let t = FakeTransport(fixture: "info.json")
        _ = try await CompanionClient(baseURL: URL(string: "https://h.example/homelab")!, token: nil, transport: t).info()
        #expect(t.last?.url?.absoluteString == "https://h.example/homelab/api/v1/info")
    }

    @Test func messagesUseTheCursor() async throws {
        let t = FakeTransport(fixture: "messages.json")
        let page = try await CompanionClient(baseURL: base, token: nil, transport: t).messages(after: 1_762_290_000_000_000_000)
        #expect(page.messages.count == 4)
        #expect(t.last?.url?.query == "after=1762290000000000000")
        _ = try await CompanionClient(baseURL: base, token: nil, transport: t).messages(after: -5)
        #expect(t.last?.url?.query == "after=0")
    }

    @Test func sendPostsJSON() async throws {
        let t = FakeTransport(json: #"{"ok": true, "id": 1762290000000000001}"#)
        let id = try await CompanionClient(baseURL: base, token: nil, transport: t).send("  /pending \n")
        #expect(id == 1_762_290_000_000_000_001)
        let r = try #require(t.last)
        #expect(r.httpMethod == "POST")
        #expect(r.url?.path == "/api/v1/messages")
        #expect(r.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true)
        #expect(bodyJSON(r) == ["text": "/pending"])
    }

    @Test func sendValidatesLocally() async {
        let t = FakeTransport(json: "{}")
        let c = CompanionClient(baseURL: base, token: nil, transport: t)
        await #expect(throws: APIError.self) { try await c.send("   ") }
        await #expect(throws: APIError.self) { try await c.send(String(repeating: "a", count: 4001)) }
        #expect(t.requests.isEmpty)
        _ = try? await c.send(String(repeating: "a", count: 4000))
        #expect(t.requests.count == 1)
    }

    @Test func pressReturnsTheServerText() async throws {
        let t = FakeTransport(json: #"{"text": "Ran restart media sonarr."}"#)
        let c = CompanionClient(baseURL: base, token: nil, transport: t)
        #expect(try await c.press("HOMELAB_APPROVE_ab12_0123456789abcdef") == "Ran restart media sonarr.")
        #expect(bodyJSON(t.last) == ["action": "HOMELAB_APPROVE_ab12_0123456789abcdef"])
        #expect((t.last?.timeoutInterval ?? 0) >= 120)
        let empty = FakeTransport(json: "{}")
        #expect(try await CompanionClient(baseURL: base, token: nil, transport: empty).press("x") == "Done.")
    }

    @Test func services() async throws {
        let s = try await CompanionClient(baseURL: base, token: nil, transport: FakeTransport(fixture: "services.json")).services()
        #expect(s.count == 5 && s[0].name == "Home Assistant")
    }

    @Test(arguments: [
        (401, APIError.unauthorized), (403, .forbidden), (404, .notFound), (429, .tooManyRequests),
        (500, .server(status: 500)), (502, .server(status: 502)),
    ])
    func statusMapping(_ status: Int, _ expected: APIError) async {
        let c = CompanionClient(baseURL: base, token: nil, transport: FakeTransport(status: status, json: #"{"error":"forbidden"}"#))
        await #expect(throws: expected) { try await c.state() }
    }

    @Test func refusalCarriesTheServerReason() async {
        let c = CompanionClient(baseURL: base, token: nil,
                                transport: FakeTransport(status: 403, json: #"{"error":"host not allowed (allowed_hosts in the config)"}"#))
        await #expect(throws: APIError.refused("host not allowed (allowed_hosts in the config)")) { try await c.state() }
        #expect(APIError.refused("x").isForbidden && APIError.forbidden.isForbidden && !APIError.notFound.isForbidden)
        #expect(APIError.refused("host not allowed").message.contains("host not allowed"))
    }

    @Test func badRequestCarriesTheServerText() async {
        let c = CompanionClient(baseURL: base, token: nil,
                                transport: FakeTransport(status: 400, json: #"{"error":"empty or longer than 4000 characters"}"#))
        await #expect(throws: APIError.badRequest("empty or longer than 4000 characters")) { try await c.send("x") }
    }

    @Test func htmlIsNotTheAPI() async {
        let t = FakeTransport { _ in .init(status: 200, body: Data("<html>login</html>".utf8), headers: ["Content-Type": "text/html"]) }
        await #expect(throws: APIError.decoding("HTML instead of JSON")) {
            try await CompanionClient(baseURL: base, token: nil, transport: t).state()
        }
    }

    @Test func garbageIsADecodingError() async {
        let c = CompanionClient(baseURL: base, token: nil, transport: FakeTransport(json: "[1,2"))
        do {
            _ = try await c.state()
            Issue.record("no error")
        } catch let e as APIError {
            if case .decoding = e {} else { Issue.record("wrong error \(e)") }
        } catch {
            Issue.record("not an APIError")
        }
    }

    @Test func wrongAPIVersion() async {
        let c = CompanionClient(baseURL: base, token: nil, transport: FakeTransport(json: #"{"api": 2}"#))
        await #expect(throws: APIError.self) { try await c.info() }
    }

    @Test func networkErrorsAreExplained() {
        #expect(APIError.from(URLError(.notConnectedToInternet), host: "h") == .offline)
        #expect(APIError.from(URLError(.timedOut), host: "h") == .timeout)
        #expect(APIError.from(URLError(.cannotFindHost), host: "pi.tail01.ts.net") == .notOnTailnet(host: "pi.tail01.ts.net"))
        #expect(APIError.from(URLError(.cannotFindHost), host: "example.com") == .cannotFindHost(host: "example.com"))
        #expect(APIError.from(URLError(.cannotConnectToHost), host: "h") == .notOnTailnet(host: "h"))
        #expect(APIError.from(URLError(.serverCertificateUntrusted), host: "h") == .tls)
        #expect(APIError.from(CancellationError(), host: "h") == .cancelled)
        #expect(APIError.offline.isTransient && !APIError.unauthorized.isTransient)
    }

    @Test func transportErrorsAreMapped() async {
        let c = CompanionClient(baseURL: base, token: nil, transport: FakeTransport(error: URLError(.timedOut)))
        await #expect(throws: APIError.timeout) { try await c.state() }
    }

    @Test func messagesNeverContainTheToken() {
        let all: [APIError] = [.offline, .notOnTailnet(host: "h"), .cannotFindHost(host: "h"), .timeout, .unauthorized,
                               .forbidden, .notFound, .tooManyRequests, .server(status: 500), .invalidResponse,
                               .decoding("x"), .tls, .badRequest(""), .cancelled, .other("x")]
        for e in all {
            #expect(!e.message.isEmpty)
            #expect(!e.message.lowercased().contains("bearer"))
        }
    }
}

@Suite struct HomeAssistantTests {
    @Test func checkAndStates() async throws {
        let t = FakeTransport { r in
            if r.url?.absoluteString.hasSuffix("/api/") == true { return .init(body: Data(#"{"message":"API running."}"#.utf8)) }
            return .init(body: Fixtures.data("ha-states.json") ?? Data())
        }
        let c = HomeAssistantClient(baseURL: URL(string: "https://ha.example.ts.net")!, token: "llat", transport: t)
        #expect(try await c.check() == "API running.")
        #expect(t.last?.value(forHTTPHeaderField: "Authorization") == "Bearer llat")
        let states = try await c.states()
        #expect(states.count == 8)
        #expect(states.map(\.name) == states.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    @Test func noTokenFailsWithoutARequest() async {
        let t = FakeTransport(json: "[]")
        await #expect(throws: APIError.unauthorized) {
            try await HomeAssistantClient(baseURL: base, token: " ", transport: t).states()
        }
        #expect(t.requests.isEmpty)
    }

    @Test func callUsesTheRightService() async throws {
        let t = FakeTransport(json: #"[{"entity_id":"switch.heater","state":"on","attributes":{"friendly_name":"IR heater"}}]"#)
        let c = HomeAssistantClient(baseURL: base, token: "t", transport: t)
        let changed = try await c.call(HAEntity(entityID: "switch.heater", state: "off"))
        #expect(changed.first?.isOn == true)
        #expect(t.last?.url?.path == "/api/services/switch/toggle")
        #expect(t.last?.httpMethod == "POST")
        #expect(bodyJSON(t.last) == ["entity_id": "switch.heater"])
        _ = try await c.call(HAEntity(entityID: "script.goodnight", state: "off"))
        #expect(t.last?.url?.path == "/api/services/script/turn_on")
        _ = try await c.call(HAEntity(entityID: "scene.movie", state: "x"))
        #expect(t.last?.url?.path == "/api/services/scene/turn_on")
        _ = try await c.call(HAEntity(entityID: "input_button.bell", state: "x"))
        #expect(t.last?.url?.path == "/api/services/input_button/press")
        await #expect(throws: APIError.self) { try await c.call(HAEntity(entityID: "sensor.t", state: "1")) }
    }

    @Test func entityDisplay() throws {
        let states = try fixture([Lossy<HAEntity>].self, "ha-states.json").compactMap(\.value)
        let byID = Dictionary(uniqueKeysWithValues: states.map { ($0.entityID, $0) })
        #expect(byID["sensor.living_room_temperature"]?.displayState == "21.4 °C")
        #expect(byID["binary_sensor.front_door"]?.displayState == "Closed")
        #expect(byID["light.living_room"]?.displayState == "On" && byID["light.living_room"]?.control == .toggle)
        #expect(byID["fan.bedroom"]?.displayState == "Unavailable" && byID["fan.bedroom"]?.isAvailable == false)
        #expect(byID["script.goodnight"]?.control == .run && byID["script.goodnight"]?.displayState == "Run")
        #expect(byID["sensor.living_room_temperature"]?.control == HAEntity.Control.none)
        #expect(byID["switch.heater"]?.icon == "mdi:radiator" && byID["switch.heater"]?.name == "IR heater")
        #expect(byID["light.living_room"]?.lastChanged != nil)
    }
}

@Suite struct DemoBackendTests {
    @Test func looksCurrent() async throws {
        let demo = DemoBackend(delay: .zero)
        let s = try await demo.state()
        let checked = try #require(s.checked)
        #expect(abs(Date().timeIntervalSince(checked) - 120) < 5)
        #expect(s.pending.count == 2 && s.busy.isEmpty)
    }

    @Test func chatEchoes() async throws {
        let demo = DemoBackend(delay: .zero)
        let before = try await demo.messages(after: 0)
        let id = try #require(try await demo.send("hello"))
        let during = try await demo.messages(after: before.messages.last?.id ?? 0)
        #expect(during.messages.map(\.id) == [id] && during.busy == ["chat"])
        try await Task.sleep(for: .seconds(1.6))
        let after = try await demo.messages(after: id)
        #expect(after.messages.count == 1 && after.messages[0].from == .agent && after.busy.isEmpty)
    }

    @Test func buttons() async throws {
        let demo = DemoBackend(delay: .zero)
        await #expect(throws: APIError.forbidden) { try await demo.press("HOMELAB_APPROVE_ab12_forged") }
        let text = try await demo.press("HOMELAB_APPROVE_ab12_0123456789abcdef")
        #expect(text.contains("restart media sonarr"))
        #expect(try await demo.state().pending.map(\.id) == ["cd34"])
        await #expect(throws: APIError.forbidden) { try await demo.press("HOMELAB_APPROVE_ab12_0123456789abcdef") }
    }

    @Test func toggles() async throws {
        let demo = DemoBackend(delay: .zero)
        let heater = try #require(try await demo.states().first { $0.entityID == "switch.heater" })
        #expect(try await demo.call(heater).first?.isOn == true)
        #expect(try await demo.states().first { $0.entityID == "switch.heater" }?.isOn == true)
        let fan = try #require(try await demo.states().first { $0.entityID == "fan.bedroom" })
        await #expect(throws: APIError.self) { try await demo.call(fan) }
    }
}

@Suite struct HardeningTests {
    @Test func redirectsAreErrorsNotFollowed() async {
        let t = FakeTransport { _ in .init(status: 302, body: Data(), headers: ["Location": "https://evil.example/"]) }
        await #expect(throws: APIError.redirected(status: 302)) {
            try await CompanionClient(baseURL: base, token: "t", transport: t).state()
        }
        #expect(t.requests.count == 1)
        #expect(APIError.redirected(status: 301).message.contains("redirect"))
    }

    @Test func hugeAnswersAreRefused() async {
        let big = Data(repeating: 0x20, count: CompanionClient.maxResponseBytes + 1)
        let t = FakeTransport { _ in .init(status: 200, body: big) }
        await #expect(throws: APIError.tooLarge) { try await CompanionClient(baseURL: base, token: nil, transport: t).state() }
    }

    @Test func theRealSessionDoesNotFollowRedirects() async throws {
        // The fixture server isn't needed: the session's delegate is checked directly.
        let delegate = try #require(URLSessionTransport.defaultSession.delegate as? NoRedirects)
        _ = delegate
    }
}
