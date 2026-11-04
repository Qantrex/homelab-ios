import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HomelabKit

/// A scriptable server: answers by path, counts calls, can be slowed down and switched to another state.
final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _state = "state-problem.json"
    private var _calls: [String: Int] = [:]
    private var _infoStatus = 200
    private var _delay: TimeInterval = 0
    private var _authHeaders: [String?] = []
    private var _hosts: [String] = []

    var state: String { get { lock.withLock { _state } } set { lock.withLock { _state = newValue } } }
    var infoStatus: Int { get { lock.withLock { _infoStatus } } set { lock.withLock { _infoStatus = newValue } } }
    var delay: TimeInterval { get { lock.withLock { _delay } } set { lock.withLock { _delay = newValue } } }
    func calls(_ path: String) -> Int { lock.withLock { _calls[path] ?? 0 } }
    var authHeaders: [String?] { lock.withLock { _authHeaders } }
    var hosts: [String] { lock.withLock { _hosts } }

    // Strong capture on purpose: a test may drop its FakeServer while the model still uses the transport.
    lazy var transport = FakeTransport { r in self.answer(r) }

    func answer(_ r: URLRequest) -> FakeTransport.Reply {
        let path = r.url?.path ?? ""
        let (delay, state, infoStatus): (TimeInterval, String, Int) = lock.withLock {
            _calls[path, default: 0] += 1
            _authHeaders.append(r.value(forHTTPHeaderField: "Authorization"))
            _hosts.append(r.url?.host ?? "")
            return (_delay, _state, _infoStatus)
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        switch path {
        case "/api/v1/info":
            return infoStatus == 200 ? .init(body: Fixtures.data("info.json") ?? Data()) : .init(status: infoStatus)
        case "/api/v1/state": return .init(body: Fixtures.data(state) ?? Data())
        case "/api/v1/services": return .init(body: Fixtures.data("services.json") ?? Data())
        case "/api/v1/button":
            lock.withLock { _state = "state-ok.json" }   // the press handled the action
            return .init(body: Data(#"{"text":"done"}"#.utf8))
        default: return .init(status: 404)
        }
    }
}

@MainActor
func makeModel(_ server: FakeServer = FakeServer(), args: [String] = [], storage: Storage? = nil,
               tokens: MemoryTokenStore = MemoryTokenStore()) -> (AppModel, FakeServer, Storage, MemoryTokenStore) {
    let storage = storage ?? Storage(directory: temporaryDirectory())
    let model = AppModel(storage: storage, tokens: tokens, transport: server.transport, arguments: args)
    return (model, server, storage, tokens)
}

let labURL = URL(string: "https://lab.example.ts.net")!

@MainActor @Suite(.serialized) struct AppModelTests {
    @Test func savingAndTokens() throws {
        let (m, _, _, tokens) = makeModel()
        var lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .token)
        try m.save(lab, token: "secret")
        #expect(tokens.token(for: lab.id) == "secret" && m.selected?.id == lab.id)

        lab.name = "renamed"
        try m.save(lab, token: nil)                                    // rename: token stays
        #expect(tokens.token(for: lab.id) == "secret")

        lab.baseURL = URL(string: "https://other.example.ts.net")!
        try m.save(lab, token: nil)                                    // new host, no new token: dropped
        #expect(tokens.token(for: lab.id) == nil)

        try m.save(lab, token: "new")
        lab.auth = .identity
        try m.save(lab, token: nil)                                    // identity auth never keeps a token
        #expect(tokens.token(for: lab.id) == nil)

        var ha = ServerConfig(name: "ha", kind: .homeAssistant, baseURL: labURL, auth: .token)
        try m.save(ha, token: "llat")
        ha.kind = .companion
        try m.save(ha, token: nil)                                     // HA token never moves to a Companion server
        #expect(tokens.token(for: ha.id) == nil)

        m.remove(lab.id)
        #expect(m.servers.servers.map(\.id) == [ha.id])
    }

    @Test func refreshStoresSnapshotAndWidgetCopy() async throws {
        let (m, server, storage, _) = makeModel()
        var widgetReloads = 0
        m.onWidgetDataChange = { widgetReloads += 1 }
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        await m.refresh()
        let st = try #require(m.status[lab.id])
        #expect(st.snapshot?.state.pending.count == 2 && st.error == nil && !st.loading)
        #expect(st.info?.name == "Demo homelab" && st.services.count == 5)
        #expect(storage.read(Snapshot.self, Snapshot.fileName(lab.id))?.state.hosts.count == 4)
        #expect(storage.read(Snapshot.self, Snapshot.widgetFileName) != nil)
        #expect(widgetReloads > 0)
        #expect(server.authHeaders.allSatisfy { $0 == nil })           // identity: never a token
        await m.refresh()
        #expect(server.calls("/api/v1/info") == 1)                     // info only once
        #expect(server.calls("/api/v1/services") == 1)                 // services cached for 10 min
    }

    @Test func failedInfoKeepsCachedFeatures() async throws {
        let storage = Storage(directory: temporaryDirectory())
        let first = makeModel(storage: storage)
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try first.0.save(lab, token: nil)
        await first.0.refresh()
        #expect(first.0.availableTabs.contains(.chat))
        // Next launch: /info fails (500), /state works. Tabs and the cached info must stay.
        let flaky = FakeServer()
        flaky.infoStatus = 500
        let (m, _, _, _) = makeModel(flaky, storage: storage)
        m.tab = .chat
        await m.refresh()
        #expect(m.selectedStatus.features.contains(.chat))
        #expect(m.tab == .chat)
        #expect(storage.read(Snapshot.self, Snapshot.fileName(lab.id))?.info?.name == "Demo homelab")
    }

    @Test func pressWaitsForFreshState() async throws {
        let (m, server, _, _) = makeModel()
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        await m.refresh()
        server.delay = 0.15
        let poll = Task { await m.refresh() }                          // a poll is running when the user taps
        try await Task.sleep(for: .milliseconds(30))
        let button = try #require(m.selectedStatus.snapshot?.state.pending.first?.buttons[.approve])
        let result = await m.press(button, on: lab)
        #expect((try? result.get()) == "done")
        #expect(m.selectedStatus.snapshot?.state.pending.isEmpty == true)   // the handled action is gone
        await poll.value
    }

    @Test func concurrentRefreshesShareOneFetch() async throws {
        let (m, server, _, _) = makeModel()
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        server.delay = 0.1
        async let a: Void = m.refresh()
        async let b: Void = m.refresh()
        async let c: Void = m.refresh()
        _ = await (a, b, c)
        // One running + one queued (b and c collapse into it), not three.
        #expect(server.calls("/api/v1/state") == 2)
    }

    @Test func refreshAfterEditUsesTheNewAddress() async throws {
        let (m, server, storage, _) = makeModel()
        var lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        server.delay = 0.15
        let old = Task { await m.refresh() }
        try await Task.sleep(for: .milliseconds(30))
        lab.baseURL = URL(string: "https://new.example.ts.net")!
        try m.save(lab, token: nil)
        await m.refresh()                                              // queued behind the old fetch
        await old.value
        #expect(server.hosts.last == "new.example.ts.net")
        let snap = try #require(storage.read(Snapshot.self, Snapshot.fileName(lab.id)))
        #expect(snap.serverID == lab.id)
        #expect(m.status[lab.id]?.loading == false)
    }

    @Test func removedServerIsNotRevivedByALateAnswer() async throws {
        let (m, server, storage, _) = makeModel()
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        server.delay = 0.15
        let t = Task { await m.refresh() }
        try await Task.sleep(for: .milliseconds(30))
        m.remove(lab.id)
        await t.value
        #expect(m.status[lab.id] == nil)
        #expect(storage.read(Snapshot.self, Snapshot.fileName(lab.id)) == nil)
    }

    @Test func errorsKeepTheLastSnapshot() async throws {
        let (m, server, _, _) = makeModel()
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        await m.refresh()
        server.state = "missing.json"                                  // empty body → decoding error
        await m.refresh()
        let st = try #require(m.status[lab.id])
        #expect(st.error != nil && st.failures == 1 && st.snapshot?.state.pending.count == 2)
    }

    @Test func tabsAndDeepLinks() async throws {
        let (m, _, _, _) = makeModel()
        #expect(m.availableTabs == [.overview, .settings])
        m.open(URL(string: "homelab://home")!)
        #expect(m.tab == .overview)                                    // no HA server: no Home tab
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        #expect(!m.availableTabs.contains(.chat))                      // before /info: only what data shows
        await m.refresh()
        #expect(m.availableTabs.isSuperset(of: [.actions, .chat]))
        m.open(URL(string: "homelab://chat")!)
        #expect(m.tab == .chat)
        m.open(URL(string: "https://evil.example/chat")!)
        #expect(m.tab == .chat)                                        // other schemes are ignored
        m.remove(lab.id)
        #expect(m.tab == .overview)                                    // tab went away with the server
    }

    @Test func launchArguments() throws {
        let storage = Storage(directory: temporaryDirectory())
        let tokens = MemoryTokenStore()
        let old = ServerConfig(name: "old", kind: .companion, baseURL: URL(string: "http://127.0.0.1:8791")!, auth: .token)
        try storage.write(ServerList(servers: [old], selected: old.id), ServerList.fileName)
        try tokens.setToken("t", for: old.id)
        let (m, _, _, _) = makeModel(args: ["app", "-HomelabServer", "http://127.0.0.1:8791", "-HomelabTab", "chat"],
                                     storage: storage, tokens: tokens)
        #expect(m.servers.servers.count == 1 && m.selected?.id != old.id && m.selected?.auth == .identity)
        #expect(tokens.token(for: old.id) == nil)                      // the replaced server's token is gone
        #expect(m.tab == .overview)                                    // chat isn't known to exist yet

        let (r, _, rs, rt) = makeModel(args: ["app", "-HomelabResetState", "YES", "-HomelabDemo", "YES"],
                                       storage: storage, tokens: tokens)
        #expect(r.isDemo && r.servers.servers.count == 2 && rt.count == 0)
        #expect(rs.read(ServerList.self, ServerList.fileName)?.servers.count == 2)
    }

    @Test func demoAndReset() async throws {
        let (m, _, storage, tokens) = makeModel()
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .token)
        try m.save(lab, token: "secret")
        m.setDemo(true)
        #expect(m.isDemo && m.homeAssistant?.isDemoHomeAssistant == true && m.selected?.id == lab.id)
        m.select(m.servers.servers.first { $0.kind == .demo && $0.speaksCompanionAPI }!.id)
        await m.refresh()
        #expect(m.selectedStatus.snapshot?.state.pending.count == 2)
        m.setDemo(false)
        #expect(!m.isDemo && m.selected?.id == lab.id)
        m.settings.faceIDLock = true
        #expect(storage.read(AppSettings.self, AppSettings.fileName)?.faceIDLock == true)
        m.resetAll()
        #expect(!m.hasServers && tokens.count == 0 && !m.settings.faceIDLock)
        #expect(storage.read(ServerList.self, ServerList.fileName) == nil)
    }

    @Test func selectIgnoresUnknownOrHomeAssistantServers() throws {
        let (m, _, _, _) = makeModel()
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        let ha = ServerConfig(name: "ha", kind: .homeAssistant, baseURL: labURL, auth: .token)
        try m.save(lab, token: nil)
        try m.save(ha, token: "t")
        m.select(ha.id)
        m.select(UUID())
        #expect(m.selected?.id == lab.id)
    }
}

@Suite struct ChatConfirmTests {
    @Test func sentWithoutIDStaysUntilItsEcho() {
        var t = ChatTimeline()
        t.merge(MessagePage(messages: [ChatMessage(id: 10, from: .agent, text: "old")]))
        let local = t.begin("hi")
        t.confirm(local, serverID: nil)
        t.merge(MessagePage(messages: []))                             // a poll before the echo arrives
        #expect(t.outgoing.count == 1 && t.isWorking)
        t.merge(MessagePage(messages: [ChatMessage(id: 11, from: .me, text: "hi")]))
        #expect(t.outgoing.isEmpty)
    }
}
