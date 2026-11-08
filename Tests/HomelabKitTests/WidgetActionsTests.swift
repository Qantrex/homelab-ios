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

    @Test func onlySimpleActionsGetTheRunLink() {
        let o = usage(for: identity).offered[ActionUsage.key(identity.id)] ?? []
        #expect(o.map(WidgetActions.isSimple) == [true, false, false, false, true])
        #expect(o.map { WidgetActions.tapURL($0).absoluteString } == [
            "homelab://actions/wake-pc?run=1", "homelab://actions/todo-add", "homelab://actions/restart",
            "homelab://actions/wake-set", "homelab://actions/lights?run=1"])
        #expect(ActionLink(WidgetActions.tapURL(o[0]))?.run == true)
        #expect(ActionLink(WidgetActions.tapURL(o[1]))?.run == false)
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

    @Test func argLabelIsTheOptionInWordsNeverTheRawArgument() throws {
        let json = #"{"actions":[{"name":"commute-mode","label":"Bike or U6","fields":[],"arg":[{"label":"Way","parts":[{"kind":"date","label":"Day"},{"kind":"literal","text":":"},{"kind":"choice","label":"Way","options":[{"value":"bike","label":"Bike"},{"value":"u6","label":"U6"}]}]}]}]}"#
        let spec = try #require(try JSONDecoder().decode(ActionList.self, from: Data(json.utf8)).actions.first)
        let form = ActionForm(spec, prefill: ItemAction(name: "commute-mode", arg: "2026-11-09:bike"))
        #expect(form.arg == "2026-11-09:bike")
        #expect(form.argLabel == "Bike")
        #expect(ActionForm(ActionSpec(name: "wake-pc", label: "Wake PC")).argLabel == nil)
    }
}
