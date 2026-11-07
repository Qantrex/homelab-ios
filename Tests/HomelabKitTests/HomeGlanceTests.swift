import Foundation
import Testing
@testable import HomelabKit

/// Today with only Home Assistant (docs/plans/MODULAR.md, M2.1): the headline says something true from HA's states.
@Suite struct HomeGlanceTests {
    func e(_ id: String, _ state: String, _ name: String? = nil, cls: String? = nil) -> HAEntity {
        HAEntity(entityID: id, state: state, name: name, deviceClass: cls)
    }

    @Test func haStatesFixture() throws {
        let states = try fixture([Lossy<HAEntity>].self, "ha-states.json").compactMap(\.value)
        let g = HomeGlance(entities: states)
        #expect(g == HomeGlance(lights: 1, lightsOn: 1, unavailable: ["Bedroom fan"]))
        #expect(g.facts == ["1 light on"] && g.unavailableText == "Bedroom fan unavailable")
        let m = TodayMood(home: g)
        #expect(m == TodayMood(level: .headsUp, headline: "Home.", detail: "1 light on", warnings: 1,
                               warningText: "Bedroom fan unavailable"))
    }

    @Test func countsWhatMatters() {
        let g = HomeGlance(entities: [
            e("light.a", "on"), e("light.b", "on"), e("light.c", "ON"), e("light.d", "off"),
            e("light.e", "unavailable", "Hall light"), e("light.f", "unknown"),     // unknown: neither on nor counted
            e("binary_sensor.door", "on", "Front door", cls: "door"),
            e("binary_sensor.window", "on", "Kitchen window", cls: "window"),
            e("binary_sensor.motion", "on", "Hall motion", cls: "motion"),          // not an opening
            e("binary_sensor.back", "off", "Back door", cls: "door"),
            e("cover.garage", "open", "Garage", cls: "garage"),
            e("cover.blinds", "open", "Blinds", cls: "blind"),                      // an open blind is no news
            e("lock.front", "unlocked", "Front lock"),
            e("lock.back", "locked", "Back lock"),
            e("sensor.power", "unavailable", "Power"),                              // sensors only when pinned
            e("button.bell", "unknown", "Bell"),                                    // a button never pressed
            e("fan.bedroom", "unavailable", "Bedroom fan"),
        ])
        #expect(g.lights == 4 && g.lightsOn == 3)
        #expect(g.open == ["Front door", "Kitchen window", "Garage"])
        #expect(g.unlocked == ["Front lock"])
        #expect(g.unavailable == ["Hall light", "Bedroom fan"])
        #expect(g.facts == ["3 lights on", "3 doors and windows open", "Front lock unlocked"])
        #expect(g.unavailableText == "2 unavailable")
        let m = TodayMood(home: g)
        #expect(m.level == .headsUp && m.headline == "Home." && m.warnings == 2)
        #expect(m.detail == "3 lights on · 3 doors and windows open · Front lock unlocked")
    }

    @Test func pinnedTilesCountInAnyDomain() {
        let states = [e("sensor.power", "unavailable", "Power"), e("light.a", "off")]
        #expect(HomeGlance(entities: states).unavailable.isEmpty)
        #expect(HomeGlance(entities: states, pinned: ["sensor.power"]).unavailable == ["Power"])
    }

    @Test func calmWhenEverythingAnswers() {
        let off = TodayMood(home: HomeGlance(entities: [e("light.a", "off"), e("light.b", "off")]))
        #expect(off == TodayMood(level: .calm, headline: "Home.", detail: "All lights off"))
        let one = HomeGlance(entities: [e("light.a", "on"), e("binary_sensor.d", "on", "Front door", cls: "door"),
                                        e("lock.a", "unlocked", "Front lock"), e("lock.b", "open", "Side lock")])
        #expect(one.facts == ["1 light on", "Front door open", "2 locks unlocked"])
        // No lights, nothing open: the headline alone, calm. Nothing at all to say is still true.
        #expect(TodayMood(home: HomeGlance(entities: [e("sensor.t", "21")])) == TodayMood(level: .calm, headline: "Home.", detail: nil))
    }

    @Test func nothingLoadedIsTheOldGreyHome() {
        // Before Home Assistant answered (or after an error): what Today said before M2.1.
        #expect(TodayMood(home: nil) == TodayMood(level: .unknown, headline: "Home.", detail: nil))
    }

    @MainActor @Test func theLabNeverGetsHomeWords() throws {
        // The owner's headline (a Companion server) keeps "N warnings": no warning text of its own.
        for name in OwnerInvarianceTests.stateFixtures {
            let s = try fixture(HomelabState.self, name)
            #expect(TodayMood(state: s).warningText == nil, "\(name)")
        }
        #expect(TodayMood(state: nil).warningText == nil)
    }

    @MainActor @Test func haOnlyDemoScene() async throws {
        #expect(LaunchArguments(["-HomelabDemoScene", "ha-only"]).demoScene == .haOnly)
        #expect(LaunchArguments(["-HomelabDemoScene", "HA-Only"]).demoScene == .haOnly)
        #expect(DemoBackend.Scene.haOnly.rawValue == "ha-only" && !DemoBackend.Scene.haOnly.hasHomelab)
        #expect(DemoBackend.Scene.calm.hasHomelab && DemoBackend.Scene.problem.hasHomelab)

        let (m, _, storage, _) = makeModel(args: ["-HomelabResetState", "YES", "-HomelabDemo", "YES",
                                                  "-HomelabDemoScene", "ha-only"])
        // Only the demo Home Assistant: no Companion server, so Today, Settings and nothing else.
        #expect(m.selected == nil && m.isDemo && m.hasServers)
        #expect(m.servers.servers.count == 1 && m.homeAssistant?.isDemoHomeAssistant == true)
        #expect(m.availableTabs == [.today, .settings])
        let ha = try #require(m.homeAssistant)
        let g = HomeGlance(entities: try await m.homeAssistantAPI(for: ha).states(), pinned: ha.pinnedEntities)
        #expect(TodayMood(home: g).detail == "1 light on" && TodayMood(home: g).warningText == "Bedroom fan unavailable")

        // A later ha-only launch on a calm demo drops the demo homelab, and keeps one demo Home Assistant.
        let (calm, _, _, _) = makeModel(args: ["-HomelabDemo", "YES"], storage: storage)
        #expect(calm.servers.servers.count == 1 && calm.selected == nil)   // already demo: nothing added
        let (fresh, _, freshStorage, _) = makeModel(args: ["-HomelabDemo", "YES"])
        #expect(fresh.selected != nil && fresh.servers.servers.count == 2)
        let (again, _, _, _) = makeModel(args: ["-HomelabDemo", "YES", "-HomelabDemoScene", "ha-only"], storage: freshStorage)
        #expect(again.selected == nil && again.servers.servers.map(\.isDemoHomeAssistant) == [true])
        // Demo off: gone, as always.
        again.setDemo(false)
        #expect(!again.hasServers)
    }
}
