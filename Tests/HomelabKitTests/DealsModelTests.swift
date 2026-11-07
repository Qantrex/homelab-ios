import Foundation
import Testing
@testable import HomelabKit

/// A server that may or may not have `/deals`: the model asks, hides the feature on a 404 and opens `homelab://deals`.
final class DealsServer: @unchecked Sendable {
    let base = FakeServer()
    private let lock = NSLock()
    private var _deals: Data? = Fixtures.data("deals.json")
    private var _status = 200
    var deals: Data? { get { lock.withLock { _deals } } set { lock.withLock { _deals = newValue } } }
    var status: Int { get { lock.withLock { _status } } set { lock.withLock { _status = newValue } } }
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    lazy var transport = FakeTransport { r in
        guard r.url?.path == "/api/v1/deals" else { return self.base.answer(r) }
        let (deals, status) = self.lock.withLock { self._calls += 1; return (self._deals, self._status) }
        guard status == 200, let deals else { return .init(status: status == 200 ? 404 : status) }
        return .init(body: deals)
    }
}

@MainActor @Suite(.serialized) struct DealsModelTests {
    func make(_ server: DealsServer, info: String? = nil) throws -> AppModel {
        if let info { server.base.info = Data(info.utf8) }
        let m = AppModel(storage: Storage(directory: temporaryDirectory()), tokens: MemoryTokenStore(),
                         transport: server.transport, arguments: [])
        try m.save(ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity), token: nil)
        return m
    }

    @Test func listedDealsAreFetchedAndKept() async throws {
        let server = DealsServer()
        let m = try make(server, info: #"{"api": 1, "features": ["status", "hosts", "deals"]}"#)
        await m.refresh()
        let s = m.selectedStatus
        #expect(s.hasDeals && s.deals?.deals.count == 5 && s.error == nil && server.calls == 1)
        #expect(m.availableTabs.contains(.actions))   // the Deals screen lives on the Actions tab
    }

    @Test func aServerWithoutTheEndpointHidesItQuietly() async throws {
        let server = DealsServer()
        server.status = 404
        let m = try make(server)
        await m.refresh()
        let s = m.selectedStatus
        #expect(!s.hasDeals && s.deals == nil && s.error == nil && s.snapshot != nil)   // no banner, no trace
        #expect(s.dealsFetched != nil && server.calls == 1)
    }

    @Test func aServerThatForgotToListDealsIsStillAsked() async throws {
        // The contract's "not here" is a 404, so a server that has the endpoint but no `deals` in features works.
        let server = DealsServer()
        let m = try make(server, info: #"{"api": 1, "features": ["status", "hosts", "chat"]}"#)
        await m.refresh()
        #expect(m.selectedStatus.hasDeals && !m.selectedStatus.features.contains(.deals))
    }

    @Test func notFoundIsAskedAgainOnlyEveryTenMinutes() async throws {
        let server = DealsServer()
        server.status = 404
        let m = try make(server)
        await m.refresh(); await m.refresh(); await m.refresh()
        #expect(server.calls == 1)
        // Ten minutes later it is asked again, and a server that has gained deals shows them.
        m.clock = { Date().addingTimeInterval(601) }
        server.status = 200
        await m.refresh()
        #expect(server.calls == 2 && m.selectedStatus.hasDeals)
    }

    @Test func aServerWithDealsIsNotAskedOnEveryPoll() async throws {
        let server = DealsServer()
        let m = try make(server, info: #"{"api": 1, "features": ["status", "hosts", "deals"]}"#)
        await m.refresh(); await m.refresh(); await m.refresh()
        #expect(server.calls == 1)
        #expect(server.base.calls("/api/v1/state") == 3)
    }

    @Test func aFailureKeepsTheLastList() async throws {
        let server = DealsServer()
        let m = try make(server, info: #"{"api": 1, "features": ["status", "hosts", "deals"]}"#)
        await m.refresh()
        m.clock = { Date().addingTimeInterval(300) }
        server.status = 500
        await m.refresh()
        #expect(m.selectedStatus.deals?.deals.count == 5 && m.selectedStatus.error == nil && server.calls == 2)
        // Dropped for good only by a 404.
        m.clock = { Date().addingTimeInterval(600) }
        server.status = 404
        await m.refresh()
        #expect(!m.selectedStatus.hasDeals)
    }

    @Test func reloadDealsAsksNowAndReportsWhy() async throws {
        let server = DealsServer()
        let m = try make(server, info: #"{"api": 1, "features": ["status", "hosts", "deals"]}"#)
        await m.refresh()
        let lab = try #require(m.selected)
        server.deals = Data(#"{"deals": [{"id": 9, "title": "new one", "verdict": "act"}]}"#.utf8)
        #expect(await m.reloadDeals(on: lab) == nil)
        #expect(m.selectedStatus.deals?.deals.map(\.id) == [9] && server.calls == 2)
        server.status = 500
        #expect(await m.reloadDeals(on: lab) == .server(status: 500))
        #expect(m.selectedStatus.deals?.deals.map(\.id) == [9])      // the list stays
        server.status = 404
        #expect(await m.reloadDeals(on: lab) == nil)
        #expect(!m.selectedStatus.hasDeals)
    }

    @Test func demoHasDeals() async throws {
        let m = AppModel(storage: Storage(directory: temporaryDirectory()), tokens: MemoryTokenStore(),
                         transport: FakeServer().transport, arguments: ["app", "-HomelabDemo", "YES"])
        await m.refresh()
        #expect(m.selectedStatus.deals?.deals.count == 5 && m.selectedStatus.deals?.freshAct().isEmpty == false)
    }

    // MARK: Links

    @Test func theLinkOpensTheScreenOnceItIsThere() async throws {
        let server = DealsServer()
        let m = try make(server, info: #"{"api": 1, "features": ["status", "hosts", "actions", "deals"]}"#)
        await m.refresh()
        m.open(URL(string: "homelab://deals")!)
        #expect(m.tab == .actions && m.openDeals)
        #expect(m.takeOpenDeals())
        #expect(!m.openDeals && !m.takeOpenDeals())               // once
    }

    @Test func theLinkWaitsForTheActionsTabAndForAForm() async throws {
        let server = DealsServer()
        let m = try make(server, info: #"{"api": 1, "features": ["status", "hosts", "actions", "deals"]}"#)
        await m.refresh()
        m.pick(.chat)
        m.open(URL(string: "homelab://deals")!)
        m.tab = .lab                                              // somewhere else for a moment
        #expect(!m.takeOpenDeals() && m.openDeals)
        let token = UUID()
        m.tab = .actions
        m.formSheet(token, open: true)
        #expect(!m.takeOpenDeals() && m.openDeals)                // a form is open: wait
        m.formSheet(token, open: false)
        #expect(m.takeOpenDeals())
    }

    @Test func theLinkIsDroppedOnAServerWithoutDeals() async throws {
        let server = DealsServer()
        server.status = 404
        let m = try make(server)
        await m.refresh()
        m.open(URL(string: "homelab://deals")!)
        #expect(!m.takeOpenDeals() && !m.openDeals)
    }

    @Test func theLinkEndsWhenAnotherTabIsPicked() async throws {
        let server = DealsServer()
        let m = try make(server)
        await m.refresh()
        m.open(URL(string: "homelab://deals")!)
        m.pick(.lab)
        #expect(!m.openDeals)
        m.open(URL(string: "homelab://deals")!)
        m.open(URL(string: "homelab://search?q=dune")!)           // a newer link replaces it
        #expect(!m.openDeals && m.openSearch != nil)
    }

    @Test func theLinkWorksWithoutAnyServerAndDoesNotCrash() {
        let m = AppModel(storage: Storage(directory: temporaryDirectory()), tokens: MemoryTokenStore(),
                         transport: FakeServer().transport, arguments: [])
        m.open(URL(string: "homelab://deals")!)
        #expect(!m.takeOpenDeals() && !m.openDeals && m.tab == .today)
    }

    @Test func theLinkOnTheOwnersServerOpensActions() async throws {
        // The owner's server lists actions, run-actions and search, and answers /deals: the push opens the screen
        // even if it lacks `deals` in features.
        let server = DealsServer()
        let m = try make(server)   // info.json: no deals in features? the fixture lists it; use one that doesn't
        server.base.info = Data(#"{"api": 1, "features": ["status", "hosts", "actions", "run-actions", "chat", "search"]}"#.utf8)
        await m.refresh()
        m.open(URL(string: "homelab://deals")!)
        #expect(m.takeOpenDeals())
    }

    // MARK: Today's card and settings

    @Test func settingsFromBeforeDealsStillDecode() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"notifyProblems":true,"notifyPending":true,"faceIDLock":false}"#.utf8))
        #expect(!old.notifyDeals && old.notificationsOn)
        var s = AppSettings()
        s.notifyDeals = true
        #expect(s.notificationsOn)
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.notifyDeals)
    }
}
