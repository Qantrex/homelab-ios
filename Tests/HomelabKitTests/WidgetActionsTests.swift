import Foundation
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

    @Test func oldCacheDecodesAndOpensTheForm() throws {
        let old = #"{"name":"wake-pc","label":"Wake PC"}"#
        let o = try JSONDecoder().decode(ActionUsage.Offered.self, from: Data(old.utf8))
        #expect(o.destructive == nil)
        #expect(!WidgetActions.isSimple(o))
        #expect(WidgetActions.tapURL(o).absoluteString == "homelab://actions/wake-pc")
    }

    @Test func onlySimpleActionsGetTheRunLink() throws {
        let o = usage(for: identity).offered[ActionUsage.key(identity.id)] ?? []
        #expect(o.map(WidgetActions.isSimple) == [true, false, false, false, true])
        var u = usage(for: identity)
        let key = try #require(u.runKey)
        u.runKey = "k3y"
        let tiles = WidgetActions.visible(u, server: identity.id, order: nil)
        #expect(tiles.map { WidgetActions.tapURL($0).absoluteString } == [
            "homelab://actions/wake-pc?run=1&runkey=k3y", "homelab://actions/todo-add", "homelab://actions/restart",
            "homelab://actions/wake-set", "homelab://actions/lights?run=1&runkey=k3y"])
        #expect(ActionLink(WidgetActions.tapURL(tiles[0]))?.run == true)
        #expect(ActionLink(WidgetActions.tapURL(tiles[0]))?.runKey == "k3y")
        #expect(ActionLink(WidgetActions.tapURL(tiles[1]))?.run == false)
        #expect(key.count == 32)
        // The stored list has no key per item: a tap link made from it alone has no run.
        #expect(o.map { WidgetActions.tapURL($0).absoluteString } == [
            "homelab://actions/wake-pc", "homelab://actions/todo-add", "homelab://actions/restart",
            "homelab://actions/wake-set", "homelab://actions/lights"])
    }

    @Test func tilesAreTheFirstVisibleStartTilesInTheOwnersOrder() {
        let u = usage(for: identity)
        var order = ItemOrder(order: ["lights"])
        order.setVisible("todo-add", false)
        #expect(WidgetActions.tiles(usage: u, server: identity.id, order: order, size: .large).map(\.name) == ["lights", "wake-pc", "restart", "wake-set"])
        #expect(WidgetActions.tiles(usage: u, server: identity.id, order: order, size: .small).map(\.name) == ["lights", "wake-pc"])
        #expect(WidgetActions.tiles(usage: u, server: identity.id, order: order, size: .circular).map(\.name) == ["lights"])
        #expect(WidgetActions.tiles(usage: u, server: identity.id, order: nil, size: .medium).count == 4)
        #expect(WidgetActions.tiles(usage: u, server: nil, order: nil, size: .medium).isEmpty)
        #expect(WidgetActions.tiles(usage: u, server: UUID(), order: nil, size: .medium).isEmpty)
    }

    @Test func sizes() {
        #expect(WidgetActions.Size.allCases.map(\.capacity) == [2, 4, 8, 1])
    }

    @Test func badNameFallsBackToTheActionsTab() {
        #expect(WidgetActions.tapURL(ActionUsage.Offered(name: "Bad Name", label: "x")).absoluteString == "homelab://actions")
    }

    @Test func spokenLabels() {
        #expect(WidgetActions.spoken(ActionUsage.Offered(name: "wake-mc", label: "Wake Minecraft", destructive: false, needsInput: false)) == "Wake Minecraft, runs it")
        #expect(WidgetActions.spoken(ActionUsage.Offered(name: "todo-add", label: "Add a to-do", destructive: false, needsInput: true)) == "Add a to-do, opens the form")
    }

    // MARK: The link's run flag

    @Test func runFlagParsesAndNeverBecomesAField() throws {
        let l = try #require(ActionLink(URL(string: "homelab://actions/wake-pc?run=1&summary=x")!))
        #expect(l.run && l.values == ["summary": "x"])
        #expect(ActionLink(URL(string: "homelab://actions/wake-pc?run=0")!)?.run == false)
        #expect(ActionLink(URL(string: "homelab://actions/wake-pc?run=yes")!)?.run == false)
        #expect(ActionLink(URL(string: "homelab://actions/wake-pc")!)?.run == false)
        #expect(ActionLink(name: "wake-pc", run: true).url?.absoluteString == "homelab://actions/wake-pc?run=1")
        #expect(ActionLink(name: "wake-pc", run: true, runKey: "ab12").url?.absoluteString == "homelab://actions/wake-pc?run=1&runkey=ab12")
    }

    @Test func runKeyParsesAndNeverBecomesAField() throws {
        let l = try #require(ActionLink(URL(string: "homelab://actions/todo-add?run=1&runkey=ab12&summary=x")!))
        #expect(l.runKey == "ab12" && l.values == ["summary": "x"])
        #expect(ActionLink(URL(string: "homelab://actions/wake-pc?run=1")!)?.runKey == "")
        let spec = ActionSpec(name: "todo-add", label: "x", fields: [ActionSpec.Field(name: "summary", label: "s", kind: .text),
                                                                      ActionSpec.Field(name: "runkey", label: "k", kind: .text)])
        #expect(l.prefill(for: spec)?.payload == ["summary": "x"])
    }

    @Test func runKeyIsStoredOnceAndNotPerItem() throws {
        var u = ActionUsage()
        let first = u.setOffered(specs, server: identity.id)
        #expect(first)
        let key = try #require(u.runKey)
        #expect(key.count == 32 && key.allSatisfy(\.isHexDigit))
        let second = u.setOffered(specs, server: identity.id)
        #expect(!second && u.runKey == key)
        // Round trip keeps the key; the per-item copy is not written.
        var stamped = u
        stamped.offered = [ActionUsage.key(identity.id): WidgetActions.visible(u, server: identity.id, order: nil)]
        #expect(stamped.offered.values.first?.allSatisfy { $0.runKey == key } == true)
        let json = String(decoding: try JSONEncoder().encode(stamped), as: UTF8.self)
        #expect(json.components(separatedBy: key).count == 2)   // once, at the top level
        let back = try JSONDecoder().decode(ActionUsage.self, from: Data(json.utf8))
        #expect(back.runKey == key && back.offered.values.allSatisfy { $0.allSatisfy { $0.runKey == nil } })
        // An older cache without a key decodes and its taps carry no run.
        let old = #"{"counts":{},"offered":{"\#(ActionUsage.key(identity.id))":[{"name":"wake-pc","label":"Wake PC","destructive":false,"needsInput":false}]}}"#
        let older = try JSONDecoder().decode(ActionUsage.self, from: Data(old.utf8))
        #expect(older.runKey == nil)
        let tile = try #require(WidgetActions.tiles(usage: older, server: identity.id, order: nil, size: .small).first)
        #expect(WidgetActions.tapURL(tile).absoluteString == "homelab://actions/wake-pc")
    }

    @MainActor @Test func theAppRunsOnlyWhatIsSimpleAndListed() async throws {
        let (m, _, _, _) = makeModel(FakeServer())
        try m.save(ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity), token: nil)
        await m.refresh()
        m.validateTab()
        // The fixture has no simple action: fields, variants and destructive ones open their form even with run=1.
        for name in ["todo-add", "wake-set", "restart-container", "dns-pause"] {
            m.open(URL(string: "homelab://actions/\(name)?run=1")!)
            let r = try #require(m.takeOpenActionForm())
            #expect(r.spec.name == name && r.run == false)
        }
    }

    @MainActor @Test func theAppRunsOnlyWithTheWidgetsKey() async throws {
        let server = FakeServer()
        server.actions = Data(#"{"actions":[{"name":"wake-pc","label":"Wake PC","fields":[]}]}"#.utf8)
        let (m, _, storage, _) = makeModel(server)
        try m.save(ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity), token: nil)
        // The widget is redrawn at the moment the key exists (it would link to the form until its next refresh).
        var keyAtRedraw: [String?] = []
        m.onWidgetDataChange = { keyAtRedraw.append(storage.read(ActionUsage.self, ActionUsage.fileName)?.runKey) }
        await m.refresh()
        m.validateTab()
        let stored = try #require(storage.read(ActionUsage.self, ActionUsage.fileName)?.runKey)
        #expect(keyAtRedraw.contains(stored))
        func take(_ link: String) throws -> Bool {
            m.open(URL(string: link)!)
            let r = try #require(m.takeOpenActionForm())
            #expect(r.spec.name == "wake-pc")
            return r.run
        }
        #expect(try !take("homelab://actions/wake-pc?run=1"))                       // forged: no key
        #expect(try !take("homelab://actions/wake-pc?run=1&runkey=nope"))           // wrong key
        #expect(try !take("homelab://actions/wake-pc?runkey=\(stored)"))            // key without run
        #expect(try !take("homelab://actions/wake-pc"))
        #expect(try take("homelab://actions/wake-pc?run=1&runkey=\(stored)"))      // the widget's link
        // The widget's own tile link, built from the stored cache.
        let u = try #require(storage.read(ActionUsage.self, ActionUsage.fileName))
        let tile = WidgetActions.tiles(usage: u, server: m.selected?.id, order: nil, size: .small).first.unsafelyUnwrapped
        #expect(try take(WidgetActions.tapURL(tile).absoluteString))
    }

    @Test func argLabelIsTheOptionInWordsNeverTheRawArgument() throws {
        let json = #"{"actions":[{"name":"commute-mode","label":"Bike or U6","fields":[],"arg":[{"label":"Way","parts":[{"kind":"date","label":"Day"},{"kind":"literal","text":":"},{"kind":"choice","label":"Way","options":[{"value":"bike","label":"Bike"},{"value":"u6","label":"U6"}]}]}]}]}"#
        let spec = try #require(try JSONDecoder().decode(ActionList.self, from: Data(json.utf8)).actions.first)
        let form = ActionForm(spec, prefill: ItemAction(name: "commute-mode", arg: "2026-11-09:bike"))
        #expect(form.arg == "2026-11-09:bike")
        #expect(form.argLabel == "Bike")
        #expect(ActionForm(ActionSpec(name: "wake-pc", label: "Wake PC")).argLabel == nil)
    }
}
