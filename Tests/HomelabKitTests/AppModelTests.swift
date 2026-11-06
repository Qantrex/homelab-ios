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
    private var _stateDelay: TimeInterval = 0
    private var _authHeaders: [String?] = []
    private var _hosts: [String] = []
    private var _info: Data?

    var state: String { get { lock.withLock { _state } } set { lock.withLock { _state = newValue } } }
    var infoStatus: Int { get { lock.withLock { _infoStatus } } set { lock.withLock { _infoStatus = newValue } } }
    var delay: TimeInterval { get { lock.withLock { _delay } } set { lock.withLock { _delay = newValue } } }
    /// Extra delay for /state only (the answer is read when the request arrives, like a real server).
    var stateDelay: TimeInterval { get { lock.withLock { _stateDelay } } set { lock.withLock { _stateDelay = newValue } } }
    func calls(_ path: String) -> Int { lock.withLock { _calls[path] ?? 0 } }
    var authHeaders: [String?] { lock.withLock { _authHeaders } }
    var hosts: [String] { lock.withLock { _hosts } }
    /// Another /info answer than info.json (nil = info.json).
    var info: Data? { get { lock.withLock { _info } } set { lock.withLock { _info = newValue } } }

    // Strong capture on purpose: a test may drop its FakeServer while the model still uses the transport.
    lazy var transport = FakeTransport { r in self.answer(r) }

    func answer(_ r: URLRequest) -> FakeTransport.Reply {
        let path = r.url?.path ?? ""
        let (delay, state, infoStatus, info): (TimeInterval, String, Int, Data?) = lock.withLock {
            _calls[path, default: 0] += 1
            _authHeaders.append(r.value(forHTTPHeaderField: "Authorization"))
            _hosts.append(r.url?.host ?? "")
            return (_delay + (path == "/api/v1/state" ? _stateDelay : 0), _state, _infoStatus, _info)
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        switch path {
        case "/api/v1/info":
            return infoStatus == 200 ? .init(body: info ?? Fixtures.data("info.json") ?? Data()) : .init(status: infoStatus)
        case "/api/v1/state": return .init(body: Fixtures.data(state) ?? Data())
        case "/api/v1/services": return .init(body: Fixtures.data("services.json") ?? Data())
        case "/api/v1/actions": return .init(body: Fixtures.data("actions.json") ?? Data())
        case "/api/v1/actions/todo-add":
            lock.withLock { _state = "state-ok.json" }
            return .init(body: Data(#"{"ok": true, "text": "Done: todo-add"}"#.utf8))
        case "/api/v1/actions/todo-done":
            return .init(body: Data(#"{"ok": true, "text": "Ticked off"}"#.utf8))
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
        // A poll has already asked /state (old answer: 2 pending) when the user taps; /button is fast.
        server.stateDelay = 0.3
        let poll = Task { await m.refresh() }
        try await Task.sleep(for: .milliseconds(60))
        let button = try #require(m.selectedStatus.snapshot?.state.pending.first?.buttons[.approve])
        let result = await m.press(button, on: lab)
        #expect((try? result.get()) == "done")
        // press must not return with the poll's old answer: the queued fetch ran and the action is gone.
        #expect(m.selectedStatus.snapshot?.state.pending.isEmpty == true)
        #expect(server.calls("/api/v1/state") == 3)
        await poll.value
    }

    @Test func startedActionsLoadAndRefresh() async throws {
        let (m, server, _, _) = makeModel()
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        await m.refresh()
        #expect(m.selectedStatus.actions.map(\.name).first == "todo-add")
        await m.refresh()
        #expect(server.calls("/api/v1/actions") == 1)   // like services: not on every poll
        var form = ActionForm(try #require(m.selectedStatus.actions.first))
        // An unfinished form never reaches the server.
        let refused = await m.run(form, on: lab)
        #expect(refused == .failure(.badRequest("To-do is missing.")))
        #expect(server.calls("/api/v1/actions/todo-add") == 0)
        form.fieldValues["summary"] = "Milk"
        let before = server.calls("/api/v1/state")
        let result = await m.run(form, on: lab)
        #expect(result == .success(ActionResult(ok: true, text: "Done: todo-add")))
        #expect(server.calls("/api/v1/state") == before + 1)   // fresh state when it returns
        #expect(m.selectedStatus.snapshot?.state.status == .ok)
    }

    @Test func requestedFormsOpenOnceListed() async throws {
        let (m, _, _, _) = makeModel()
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        m.tab = .actions
        // Before the list is there the request waits.
        m.openAction = "todo-add"
        #expect(m.takeOpenAction() == nil && m.openAction == "todo-add")
        await m.refresh()
        #expect(m.takeOpenAction()?.name == "todo-add" && m.openAction == nil)
        // A name the loaded list doesn't have is dropped, not kept for a later server.
        m.openAction = "launch-rocket"
        #expect(m.takeOpenAction() == nil && m.openAction == nil)
    }

    @Test func simultaneousRefreshesCostOneFetch() async throws {
        let (m, server, _, _) = makeModel()
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        server.delay = 0.1
        async let a: Void = m.refresh()
        async let b: Void = m.refresh()
        async let c: Void = m.refresh()
        _ = await (a, b, c)
        #expect(server.calls("/api/v1/state") == 1)                    // b and c joined before /state was asked
    }

    @Test func aRefreshDuringTheStateRequestQueuesOneMore() async throws {
        let (m, server, _, _) = makeModel()
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        await m.refresh()
        server.stateDelay = 0.2
        let first = Task { await m.refresh() }
        try await Task.sleep(for: .milliseconds(60))                   // /state is in flight now
        async let b: Void = m.refresh()
        async let c: Void = m.refresh()
        _ = await (b, c)
        await first.value
        #expect(server.calls("/api/v1/state") == 3)                    // 1 initial + the running one + one queued
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
        #expect(m.availableTabs == [.today, .settings])
        m.open(URL(string: "homelab://lab")!)
        #expect(m.tab == .today)                                       // no server: no Lab tab
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        #expect(!m.availableTabs.contains(.chat))                      // before /info: only what data shows
        m.open(URL(string: "homelab://lab")!)
        #expect(m.tab == .lab)
        for old in ["homelab://overview", "homelab://home"] {         // links from older widgets open Today
            m.tab = .lab
            m.open(URL(string: old)!)
            #expect(m.tab == .today)
        }
        await m.refresh()
        #expect(m.availableTabs.isSuperset(of: [.actions, .chat]))
        m.open(URL(string: "homelab://chat")!)
        #expect(m.tab == .chat)
        m.open(URL(string: "homelab://actions/wake-set")!)
        #expect(m.tab == .actions && m.openAction == "wake-set")
        m.openAction = nil
        m.open(URL(string: "homelab://actions/..%2Fstate")!)
        #expect(m.tab == .actions && m.openAction == nil)
        m.open(URL(string: "homelab://chat")!)
        m.open(URL(string: "https://evil.example/chat")!)
        #expect(m.tab == .chat)                                        // other schemes are ignored
        m.remove(lab.id)
        #expect(m.tab == .today)                                       // tab went away with the server
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
        #expect(m.tab == .today && m.requestedTab == .chat)            // chat isn't known to exist yet: it waits
        let (a, _, _, _) = makeModel(args: ["app", "-HomelabDemo", "YES", "-HomelabAction", "wake-set"])
        #expect(a.openAction == "wake-set")
        let (b, _, _, _) = makeModel(args: ["app", "-HomelabAction", "Bad Name"])
        #expect(b.openAction == nil)

        let (r, _, rs, rt) = makeModel(args: ["app", "-HomelabResetState", "YES", "-HomelabDemo", "YES"],
                                       storage: storage, tokens: tokens)
        #expect(r.isDemo && r.servers.servers.count == 2 && rt.count == 0)
        #expect(rs.read(ServerList.self, ServerList.fileName)?.servers.count == 2)
    }

    @Test func demoArgumentSelectsTheDemo() throws {
        // CI: the live-mode shots leave the fixture server selected; -HomelabDemo must still show the demo.
        let storage = Storage(directory: temporaryDirectory())
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        let demo = ServerConfig.demo()
        try storage.write(ServerList(servers: [lab, demo, .demoHomeAssistant()], selected: lab.id), ServerList.fileName)
        let (m, _, _, _) = makeModel(args: ["app", "-HomelabDemo", "YES", "-HomelabTab", "actions"], storage: storage)
        #expect(m.selected?.id == demo.id && m.servers.servers.count == 3)
        #expect(storage.read(ServerList.self, ServerList.fileName)?.selected == demo.id)
        let (n, _, _, _) = makeModel(args: ["app", "-HomelabDemo", "YES"])   // fresh: demo added and selected
        #expect(n.selected?.kind == .demo && n.selected?.isDemoHomeAssistant == false)
    }

    @Test func requestedTabWaitsForInfo() async throws {
        let (m, server, _, _) = makeModel(args: ["app", "-HomelabResetState", "YES", "-HomelabServer",
                                                 "http://127.0.0.1:8791", "-HomelabTab", "actions"])
        #expect(m.tab == .today && m.requestedTab == .actions)
        server.infoStatus = 500                                        // no /info yet: still waiting
        server.state = "state-ok.json"                                 // (no pending actions that show the tab)
        await m.refresh()
        #expect(m.tab == .today && m.requestedTab == .actions)
        server.infoStatus = 200
        await m.refresh()                                              // /info lists actions: the tab opens
        #expect(m.tab == .actions && m.requestedTab == nil)

        // Info without the feature drops the request.
        let (c, cs, _, _) = makeModel(args: ["app", "-HomelabServer", "http://127.0.0.1:8791", "-HomelabTab", "chat"])
        cs.info = Data(#"{"name": "lab", "api": 1, "features": ["status", "hosts"]}"#.utf8)
        cs.state = "state-ok.json"
        await c.refresh()
        #expect(c.tab == .today && c.requestedTab == nil)

        // Picking a tab by hand drops the request; the action form request waits with its tab.
        let (h, _, _, _) = makeModel(args: ["app", "-HomelabServer", "http://127.0.0.1:8791", "-HomelabAction", "wake-set"])
        #expect(h.requestedTab == .actions && h.openAction == "wake-set")
        h.pick(.lab)
        #expect(h.requestedTab == nil && h.openAction == nil)

        // A deep link before /info waits the same way.
        let (d, _, _, _) = makeModel(args: ["app", "-HomelabServer", "http://127.0.0.1:8791"])
        d.open(URL(string: "homelab://actions/wake-set")!)
        #expect(d.tab == .today && d.requestedTab == .actions && d.openAction == "wake-set")
        await d.refresh()
        #expect(d.tab == .actions)
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

@Suite struct ChatWorkingTimeoutTests {
    @Test func aMessageWithoutEchoStopsCountingAsWorking() {
        var t = ChatTimeline()
        let start = Date()
        let local = t.begin("hi", now: start)
        t.confirm(local, serverID: 99)
        #expect(t.isWorking(now: start + 10))
        #expect(!t.isWorking(now: start + ChatTimeline.workingTimeout + 1))
        t.merge(MessagePage(messages: [], busy: ["chat"]))
        #expect(t.isWorking(now: start + ChatTimeline.workingTimeout + 1))   // the server says it is busy
    }

    @Test func targetDiffersForTwoEntriesWithTheSameAddress() {
        let a = ServerConfig(name: "a", kind: .companion, baseURL: labURL, auth: .token)
        let b = ServerConfig(name: "b", kind: .companion, baseURL: labURL, auth: .identity)
        #expect(a.target != b.target && a.isSameTarget(as: b))
    }
}

/// Final integration review: requests end with a manual tab change, sheet tokens, restart time, reused proposal ids,
/// server 5xx texts, one argument splitter, shared result words.
@MainActor @Suite(.serialized) struct IntegrationReviewTests {
    @Test func aManualTabEndsTheWholeRequest() async throws {
        // A form request waits for its list; the user goes to Lab by hand: tab, form and host requests all end.
        let (m, _, _, _) = makeModel(args: ["app", "-HomelabServer", "http://127.0.0.1:8791", "-HomelabAction", "wake-set"])
        m.openHost = "media"
        #expect(m.requestedTab == .actions && m.openAction == "wake-set")
        m.pick(.today)                                                 // the tab it already shows: nothing ends
        #expect(m.requestedTab == .actions && m.openAction == "wake-set" && m.openHost == "media")
        m.pick(.settings)
        #expect(m.tab == .settings && m.requestedTab == nil && m.openAction == nil && m.openHost == nil)
        await m.refresh()
        #expect(m.tab == .settings && m.takeOpenAction() == nil)       // nothing pops up later

        // validateTab and links still set the tab without ending a request.
        let (d, _, _, _) = makeModel(args: ["app", "-HomelabDemo", "YES"])
        await d.refresh()
        d.open(URL(string: "homelab://actions/wake-set")!)
        #expect(d.tab == .actions && d.openAction == "wake-set")
        d.validateTab()
        #expect(d.openAction == "wake-set")
        // A newer link replaces the older request as a whole.
        d.open(URL(string: "homelab://lab/media")!)
        #expect(d.tab == .lab && d.openHost == "media" && d.openAction == nil && d.requestedTab == nil)
    }

    @Test func requestsOpenOnlyOnTheirTab() async throws {
        let (m, _, _, _) = makeModel(args: ["app", "-HomelabDemo", "YES"])
        await m.refresh()
        m.openAction = "wake-set"
        m.openHost = "media"
        m.tab = .today
        #expect(m.takeOpenAction() == nil && m.takeOpenHost() == nil)   // another tab: both wait
        #expect(m.openAction == "wake-set" && m.openHost == "media")
        m.tab = .actions
        #expect(m.takeOpenAction()?.name == "wake-set" && m.takeOpenHost() == nil)
        m.tab = .lab
        #expect(m.takeOpenHost()?.id == "media")
    }

    @Test func lockAndResetForgetSheetsAndRequests() async throws {
        let (m, _, _, _) = makeModel(args: ["app", "-HomelabDemo", "YES"])
        await m.refresh()
        let sheet = UUID()
        m.formSheet(sheet, open: true)
        m.formSheet(sheet, open: true)                                  // appeared twice: one sheet
        m.formSheet(sheet, open: false)
        #expect(!m.formSheetOpen)
        m.formSheet(sheet, open: true)
        m.lock()                                                        // the lock closes every sheet
        #expect(m.locked && !m.formSheetOpen)

        m.formSheet(sheet, open: true)
        m.openAction = "wake-set"
        m.openHost = "media"
        m.noteRestart(host: "media", container: "sonarr", at: Date())
        #expect(!m.restarted.isEmpty)
        m.resetAll()
        #expect(!m.formSheetOpen && m.openAction == nil && m.openHost == nil && m.requestedTab == nil)
        #expect(m.restarted.isEmpty && m.proposalsSending.isEmpty)
    }

    @Test func removedServersForgetTheirRestarts() throws {
        let (m, _, _, _) = makeModel()
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        m.noteRestart(host: "media", container: "sonarr", at: Date())
        #expect(m.restarted[lab.id] != nil)
        m.remove(lab.id)
        #expect(m.restarted.isEmpty)
        m.noteRestart(host: "media", container: "sonarr", at: Date(), on: lab.id)   // a server that's gone: not kept
        #expect(m.restarted.isEmpty)
    }

    @Test func aDemoRestartDoesNotWait() async throws {
        // The demo checks the host while the request runs: the restart's time is when it was sent, so the newer
        // check already shows the container and the row doesn't say "waiting for the next check".
        let (m, _, _, _) = makeModel(args: ["app", "-HomelabDemo", "YES"])
        await m.refresh()
        let server = try #require(m.selected)
        let host = try #require(m.selectedStatus.snapshot?.state.hosts.first { $0.id == "media" })
        let sonarr = try #require(host.containerList.first { $0.name == "sonarr" })
        let form = try #require(m.selectedStatus.restartForm(host: host, container: sonarr))
        let r = await m.restart(form, host: host.id, container: sonarr.name, on: server)
        #expect((try? r.get())?.ok == true)
        #expect(m.restarted[server.id]?["media:sonarr"] != nil)
        let after = try #require(m.selectedStatus.snapshot?.state.hosts.first { $0.id == "media" })
        #expect(m.restartWaiting(host: after, container: sonarr) == nil)
        // The same restart judged by a host checked before it was sent still waits.
        var stale = after
        stale.checked = Date().addingTimeInterval(-600)
        #expect(m.restartWaiting(host: stale, container: sonarr) != nil)
    }

    @Test func aProposalIsPressedOnceAtATime() async throws {
        let server = FakeServer()
        server.delay = 0.2
        let (m, _, _, _) = makeModel(server)
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        async let first = m.press("HOMELAB_APPROVE_ab12_x", proposal: "ab12", on: lab)
        try await Task.sleep(for: .milliseconds(50))
        #expect(m.proposalsSending == ["ab12"])
        let second = await m.press("HOMELAB_DENY_ab12_y", proposal: "ab12", on: lab)   // from the chat meanwhile
        #expect(second == nil)
        #expect(await first == Result<String, APIError>.success("done"))
        #expect(m.proposalsSending.isEmpty && server.calls("/api/v1/button") == 1)
    }
}

/// The alert words for every place an action runs from (`ActionReport`).
@Suite struct ActionReportTests {
    @Test func startedRestartedAndPressed() {
        #expect(ActionReport.started("Wake", .success(ActionResult(ok: true, text: "Set.")), hasChat: true)
            == ActionReport(ok: true, title: "Wake", text: "Set."))
        #expect(ActionReport.started("Wake", .success(ActionResult(ok: false, text: "exit 1")), hasChat: true)
            == ActionReport(ok: false, title: "Wake failed", text: "exit 1"))
        #expect(ActionReport.started("Wake", .failure(.serverSaid(status: 503, text: "nothing was run")), hasChat: true)
            == ActionReport(ok: false, title: "Wake failed", text: "nothing was run"))
        #expect(ActionReport.started("Wake", .failure(.badRequest("bad day")), hasChat: true)
            == ActionReport(ok: false, title: "Didn't run", text: "bad day"))
        #expect(ActionReport.started("Wake", .failure(.timeout), hasChat: false).title == "Not sure it ran")

        #expect(ActionReport.restart("sonarr", .success(ActionResult(ok: true, text: "ok")), hasChat: true).title == "Restarted sonarr")
        #expect(ActionReport.restart("sonarr", .success(ActionResult(ok: true, text: "…", running: true)), hasChat: true).title
            == "Restart of sonarr started")
        #expect(ActionReport.restart("sonarr", .success(ActionResult(ok: false, text: "no")), hasChat: true)
            == ActionReport(ok: false, title: "Restart of sonarr failed", text: "no"))
        #expect(ActionReport.restart("sonarr", .failure(.serverSaid(status: 502, text: "docker down")), hasChat: true)
            == ActionReport(ok: false, title: "Restart of sonarr failed", text: "docker down"))

        #expect(ActionReport.pressed("restart media", .success("done"), hasChat: true)
            == ActionReport(ok: true, title: "restart media", text: "done"))
        // A spent or expired button has its own title, distinct from "Didn't run" and "Not sure it ran".
        let expired = ActionReport.pressed("restart media", .failure(.refused("forged or outdated button")), hasChat: true)
        #expect(!expired.ok && expired.title == "No longer valid" && expired.text.contains("no longer valid"))
        #expect(ActionReport.pressed("x", .failure(.forbidden), hasChat: true).title == "No longer valid")
        #expect(ActionReport.pressed("x", .failure(.notOnTailnet(host: "h")), hasChat: true).title == "Didn't run")
    }
}

/// One way to split an argument into form parts, for cards and Lab alike; `word` as the agent checks it.
@Suite struct ArgumentSplitTests {
    func spec(_ name: String) throws -> ActionSpec {
        try #require(try fixture(ActionList.self, "actions.json").actions.first { $0.name == name })
    }

    @Test func cardPrefillBacktracks() throws {
        // word ":" word: the first word takes the shortest value that lets the rest fit.
        let pair = ActionSpec(name: "x", variants: [.init(label: "", parts: [.word(label: "A"), .literal(":"), .word(label: "B")])])
        #expect(ActionForm.split("a.b:c", into: pair.variants[0].parts) == ["a.b", "", "c"])
        let form = ActionForm(pair, prefill: ItemAction(name: "x", arg: "a.b:c"))
        #expect(form.arg == "a.b:c")
        #expect(ActionForm.prefilled(pair, arg: "a.b:c")?.values == form.values)
        let restart = ActionForm(try spec("restart-container"), prefill: ItemAction(name: "restart-container", arg: "media:sonarr"))
        #expect(restart.values[0] == ["media", "", "sonarr"])
        let unfit = ActionForm(try spec("restart-container"), prefill: ItemAction(name: "restart-container", arg: "gpu:steam"))
        #expect(unfit.values[0][2] == "")                                // fits no variant: ignored
    }

    @Test func wordsStartWithALetterOrDigit() throws {
        var form = ActionForm(try spec("restart-container"))
        for bad in [".hidden", "_x", "-rf", String(repeating: "a", count: 65)] {
            form.set(part: 2, bad)
            #expect(form.arg == nil && form.problems.count == 1, "\(bad)")
        }
        for good in ["a", "9", "a.b_c-d", String(repeating: "a", count: 58)] {
            form.set(part: 2, good)
            #expect(form.problems.isEmpty, "\(good)")
        }
        #expect(ActionForm.prefilled(try spec("restart-container"), arg: "media:.x") == nil)
    }
}
