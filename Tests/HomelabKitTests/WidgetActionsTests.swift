import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HomelabKit

@Suite struct WidgetActionsTests {
    let base = URL(string: "https://lab.example.ts.net")!
    let identity = ServerConfig(name: "lab", kind: .companion, baseURL: URL(string: "https://lab.example.ts.net")!, auth: .identity)
    let token = ServerConfig(name: "lab", kind: .companion, baseURL: URL(string: "https://lab.example.ts.net")!, auth: .token)

    let specs: [ActionSpec] = [
        ActionSpec(name: "wake-pc", label: "Wake PC", icon: "power"),
        ActionSpec(name: "todo-add", label: "Add a to-do", fields: [ActionSpec.Field(name: "summary", label: "To-do", kind: .text)]),
        ActionSpec(name: "restart", label: "Restart", destructive: true),
        ActionSpec(name: "wake-set", label: "Wake-up", variants: [ActionSpec.ArgVariant(label: "x", parts: [.literal("a")])]),
        ActionSpec(name: "card-only", label: "Card only", start: false),
        ActionSpec(name: "lights", label: "Lights"),
    ]

    func usage(for server: ServerConfig) -> ActionUsage {
        var u = ActionUsage()
        u.setOffered(specs, server: server.id)
        return u
    }

    @Test func cacheKeepsWhatTheWidgetNeeds() {
        let o = usage(for: identity).offered[ActionUsage.key(identity.id)] ?? []
        #expect(o.map(\.name) == ["wake-pc", "todo-add", "restart", "wake-set", "lights"])
        #expect(o[0].destructive == false && o[0].needsInput == false)
        #expect(o[1].needsInput == true && o[2].destructive == true && o[3].needsInput == true)
    }

    @Test func oldCacheDecodesAndOpensTheApp() throws {
        let old = #"{"name":"wake-pc","label":"Wake PC"}"#
        let o = try JSONDecoder().decode(ActionUsage.Offered.self, from: Data(old.utf8))
        #expect(o.destructive == nil)
        #expect(WidgetActions.tap(o, server: identity) == .opensApp)
    }

    @Test func runsOnlyPlainActionsOnIdentityServers() {
        let o = usage(for: identity).offered[ActionUsage.key(identity.id)] ?? []
        let taps = o.map { WidgetActions.tap($0, server: identity) }
        #expect(taps == [.runs, .opensApp, .opensApp, .opensApp, .runs])
        // A token server, a demo server or no server: always the app.
        #expect(o.allSatisfy { WidgetActions.tap($0, server: token) == .opensApp })
        #expect(o.allSatisfy { WidgetActions.tap($0, server: nil) == .opensApp })
        let demo = ServerConfig(name: "demo", kind: .demo, baseURL: base, auth: .identity)
        #expect(WidgetActions.tap(o[0], server: demo) == .opensApp)
    }

    @Test func defaultSelectionSkipsHiddenTiles() {
        let u = usage(for: identity)
        var order = ItemOrder()
        order.setVisible("wake-pc", false)
        let d = WidgetActions.defaults(u, server: identity.id, order: order, count: 2)
        #expect(d.map(\.name) == ["todo-add", "restart"])
        #expect(WidgetActions.defaults(u, server: identity.id, order: nil, count: 4).map(\.name) == ["wake-pc", "todo-add", "restart", "wake-set"])
        #expect(WidgetActions.defaults(u, server: identity.id, order: nil, count: 0).isEmpty)
    }

    @Test func entityQueryComesFromTheCacheAndKeepsHiddenLast() {
        let u = usage(for: identity)
        var order = ItemOrder(order: ["lights"])
        order.setVisible("todo-add", false)
        let c = WidgetActions.choices(u, server: identity.id, order: order)
        #expect(c.map(\.name) == ["lights", "wake-pc", "restart", "wake-set", "todo-add"])
        #expect(WidgetActions.choices(u, server: nil, order: nil).isEmpty)
        #expect(WidgetActions.choices(u, server: UUID(), order: nil).isEmpty)
    }

    @Test func pickedTilesFollowThePickAndDropWhatTheServerLost() {
        let u = usage(for: identity)
        let t = WidgetActions.tiles(picked: ["lights", "gone", "wake-pc", "lights"], usage: u, server: identity.id, order: nil, size: .medium)
        #expect(t.map(\.name) == ["lights", "wake-pc"])
        // A hidden tile can still be picked.
        var order = ItemOrder(); order.setVisible("restart", false)
        #expect(WidgetActions.tiles(picked: ["restart"], usage: u, server: identity.id, order: order, size: .circular).map(\.name) == ["restart"])
        // Nothing picked: the defaults, as many as fit.
        #expect(WidgetActions.tiles(picked: [], usage: u, server: identity.id, order: nil, size: .small).count == 2)
        #expect(WidgetActions.tiles(picked: [], usage: u, server: identity.id, order: nil, size: .circular).count == 1)
        // Never more than the size holds.
        let many = WidgetActions.tiles(picked: ["wake-pc", "todo-add", "restart"], usage: u, server: identity.id, order: nil, size: .small)
        #expect(many.count == 2)
    }

    @Test func sizes() {
        #expect(WidgetActions.Size.allCases.map(\.capacity) == [2, 4, 8, 1])
    }

    @Test func resultTexts() {
        #expect(WidgetActions.resultText(.success(ActionResult(ok: true, text: "Woke it"))) == ("Done", true))
        #expect(WidgetActions.resultText(.success(ActionResult(ok: true, text: "", running: true))) == ("Started", true))
        #expect(WidgetActions.resultText(.success(ActionResult(ok: false, text: "No route to host.\nmore"))) == ("Failed: No route to host", false))
        #expect(WidgetActions.resultText(.failure(.serverSaid(status: 502, text: "the agent is down"))) == ("Failed: the agent is down", false))
        #expect(WidgetActions.resultText(.failure(.tooManyRequests)).ok == false)
        let long = WidgetActions.resultText(.failure(.badRequest(String(repeating: "x", count: 100)))).text
        #expect(long.count == 40 && long.hasPrefix("Failed: xxx") && long.hasSuffix("…"))
        #expect(WidgetActions.resultText(.failure(.timeout)).text.hasPrefix("Failed: "))
    }

    @Test func shownResultFades() {
        let t = Date(timeIntervalSince1970: 1000)
        let s = WidgetActions.Shown(name: "a", text: "Done", ok: true, date: t)
        #expect(s.isFresh(at: t.addingTimeInterval(5)))
        #expect(!s.isFresh(at: t.addingTimeInterval(21)))
        #expect(!s.isFresh(at: t.addingTimeInterval(-5)))
    }

    @Test func openURL() {
        #expect(WidgetActions.openURL("todo-add").absoluteString == "homelab://actions/todo-add")
        #expect(ActionLink(WidgetActions.openURL("todo-add"))?.name == "todo-add")
        #expect(WidgetActions.openURL("Bad Name").absoluteString == "homelab://actions")
    }

    @Test func spokenLabels() {
        let wake = ActionUsage.Offered(name: "wake-mc", label: "Wake Minecraft")
        #expect(WidgetActions.spoken(wake, tap: .runs) == "Wake Minecraft, runs it")
        #expect(WidgetActions.spoken(ActionUsage.Offered(name: "todo-add", label: "Add a to-do"), tap: .opensApp) == "Add a to-do, opens the app")
        #expect(WidgetActions.spoken(wake, tap: .runs, result: "Done") == "Done. Wake Minecraft, runs it")
    }

    @Test func runnableChecksTheServersOwnList() {
        #expect(WidgetActions.runnable(specs[0]))
        #expect(!WidgetActions.runnable(specs[1]) && !WidgetActions.runnable(specs[2]) && !WidgetActions.runnable(specs[3]))
        #expect(!WidgetActions.runnable(specs[4]))
        #expect(!WidgetActions.runnable(nil))
    }

    // MARK: Running

    func transport(actionsJSON: String, runStatus: Int = 200, runBody: String = #"{"ok":true,"text":"Woke it"}"#) -> FakeTransport {
        FakeTransport { req in
            if req.httpMethod == "POST" { return .init(status: runStatus, body: Data(runBody.utf8)) }
            return .init(body: Data(actionsJSON.utf8))
        }
    }

    let listJSON = #"{"actions":[{"name":"wake-pc","label":"Wake PC"},{"name":"restart","label":"Restart","destructive":true},{"name":"todo-add","label":"T","fields":[{"name":"summary","label":"S","kind":"text","max":10,"required":true}]}]}"#

    @Test func runsAPlainActionAndRecordsIt() async throws {
        let storage = Storage(directory: temporaryDirectory())
        let t = transport(actionsJSON: listJSON)
        let out = await WidgetActions.run("wake-pc", server: identity, transport: t, storage: storage)
        #expect(out == .init(text: "Done", ok: true, opensApp: false))
        #expect(t.requests.map { $0.httpMethod ?? "GET" } == ["GET", "POST"])
        #expect(t.last?.url?.path.hasSuffix("/actions/wake-pc") == true)
        #expect(storage.read(ActionUsage.self, ActionUsage.fileName)?.counts[ActionUsage.key(identity.id)]?["wake-pc"]?.count == 1)
        #expect(storage.read(WidgetActions.Shown.self, WidgetActions.Shown.fileName)?.text == "Done")
    }

    @Test func neverRunsWhatTheServerDoesNotListAsPlain() async {
        let storage = Storage(directory: temporaryDirectory())
        for name in ["restart", "todo-add", "unlisted", "Bad Name"] {
            let t = transport(actionsJSON: listJSON)
            let out = await WidgetActions.run(name, server: identity, transport: t, storage: storage)
            #expect(out.opensApp)
            #expect(!t.requests.contains { $0.httpMethod == "POST" })
        }
    }

    @Test func tokenServerNeverTouchesTheNetwork() async {
        let storage = Storage(directory: temporaryDirectory())
        let t = transport(actionsJSON: listJSON)
        let out = await WidgetActions.run("wake-pc", server: token, transport: t, storage: storage)
        #expect(out.opensApp && t.requests.isEmpty)
        #expect(await WidgetActions.run("wake-pc", server: nil, transport: t, storage: storage).opensApp)
    }

    @Test func aFailedRunShowsTheServersWordsAndIsNotCounted() async {
        let storage = Storage(directory: temporaryDirectory())
        let t = transport(actionsJSON: listJSON, runStatus: 502, runBody: #"{"error":"the agent is down"}"#)
        let out = await WidgetActions.run("wake-pc", server: identity, transport: t, storage: storage)
        #expect(out == .init(text: "Failed: the agent is down", ok: false, opensApp: false))
        #expect(storage.read(ActionUsage.self, ActionUsage.fileName) == nil)
        let limited = transport(actionsJSON: listJSON, runStatus: 429, runBody: #"{"error":"too many runs"}"#)
        #expect(await WidgetActions.run("wake-pc", server: identity, transport: limited, storage: storage).text == "Failed: too many runs")
    }
}
