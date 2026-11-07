import Foundation
import Testing
@testable import HomelabKit

/// The first run (docs/plans/MODULAR.md, M2.3): welcome, editor, Found and "Start with", the tile picker, Today. Only
/// for someone without servers: the owner never sees any of it.
@MainActor @Suite(.serialized) struct FirstRunTests {
    static let haURL = URL(string: "https://ha.tail1234.ts.net")!

    func ha() -> ServerConfig {
        ServerConfig(name: "Home Assistant", kind: .homeAssistant, baseURL: Self.haURL, auth: .token)
    }

    // MARK: Owner invariance

    @Test func ownerNeverSeesIt() throws {
        let storage = Storage(directory: temporaryDirectory())
        let servers = try Storage.encoder.encode(OwnerInvarianceTests.ownerServers())
        let settings = try Storage.encoder.encode(OwnerInvarianceTests.ownerSettings())
        try servers.write(to: storage.url(ServerList.fileName))
        try settings.write(to: storage.url(AppSettings.fileName))
        // Even the screenshot argument does nothing over real servers.
        let (m, _, _, _) = makeModel(args: ["-HomelabFirstRun", "YES"], storage: storage)
        #expect(!m.showsFirstRun && m.firstRun == nil && !m.showsStartTip)
        m.beginFirstRun(adding: .homeAssistant)
        m.beginFirstRun(adding: .companion)
        m.firstRunSaved(m.servers.servers[0])
        m.startFirstRun(with: .everything, canPickTiles: true)
        m.finishFirstRun()
        #expect(!m.showsFirstRun && m.firstRun == nil && !m.showsStartTip)
        #expect(try Data(contentsOf: storage.url(ServerList.fileName)) == servers)
        #expect(try Data(contentsOf: storage.url(AppSettings.fileName)) == settings)
    }

    @Test func welcomeOnlyWithoutServers() throws {
        let (m, _, _, _) = makeModel()
        #expect(m.showsFirstRun && m.firstRun == nil)   // the welcome
        try m.save(ha(), token: "t")
        #expect(!m.showsFirstRun)   // a server saved outside a run (Settings, an old install): the tabs
    }

    @Test func demoIsStillOneTap() {
        let (m, _, _, _) = makeModel()
        m.setDemo(true)
        #expect(!m.showsFirstRun && m.firstRun == nil && m.tab == .today)
        m.setDemo(false)
        #expect(m.showsFirstRun && m.firstRun == nil)   // back to the welcome
    }

    // MARK: The run

    @Test func homeAssistantOnly() throws {
        let (m, _, storage, tokens) = makeModel()
        m.beginFirstRun(adding: .homeAssistant)
        #expect(m.firstRun?.adding == .homeAssistant && m.firstRun?.showsFound == false)
        let server = ha()
        try m.save(server, token: "t")      // the editor's Save
        m.firstRunSaved(server)
        m.firstRunEditorClosed()            // and its dismiss
        #expect(m.firstRun?.step == .found && m.firstRun?.showsFound == true && tokens.token(for: server.id) == "t")
        #expect(m.showsFirstRun)            // the run goes on although a server exists now
        #expect(m.firstRunFeatures.isEmpty && m.firstRunSuggested == .home && m.firstRunPreset == .home)
        m.startFirstRun(with: m.firstRunPreset, canPickTiles: true)   // "Start"
        #expect(m.firstRun?.step == .tiles)
        #expect(m.settings.todayDensity == .calm)
        #expect(m.settings.todayLayout == StartPreset.home.layout(features: [], hasHA: true).today)
        #expect(storage.read(AppSettings.self, AppSettings.fileName)?.todayDensity == .calm)
        m.setPinned(["light.living_room"], for: server.id)            // a tile, then "Done"
        m.finishFirstRun()
        #expect(m.firstRun == nil && !m.showsFirstRun && m.showsStartTip && m.tab == .today)
        #expect(m.homeAssistant?.pinnedEntities == ["light.living_room"])
        #expect(Density.calm.sections(m.settings.todayLayout) == [.home, .day])
        m.openStartTip()
        #expect(!m.showsStartTip && m.tab == .settings)
    }

    @Test func homelabServerWithSkips() async throws {
        let fake = FakeServer()
        fake.info = Data(#"{"api": 1, "name": "lab", "features": ["status", "hosts", "cards"]}"#.utf8)
        let (m, _, storage, _) = makeModel(fake)
        m.beginFirstRun(adding: .companion)
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        m.firstRunSaved(lab)
        await m.refresh(lab)
        #expect(m.firstRunFeatures == [.status, .hosts, .cards])
        #expect(m.firstRunPreset == .watch)
        m.pickStart(.everything)
        #expect(m.firstRunPreset == .everything && m.firstRunSuggested == .watch)
        // "Skip": nothing is written, no tiles without Home Assistant, straight to Today.
        m.startFirstRun(with: nil, canPickTiles: false)
        #expect(m.firstRun == nil && m.showsStartTip && !m.showsFirstRun)
        #expect(m.settings == AppSettings())
        #expect(storage.read(AppSettings.self, AppSettings.fileName) == nil)
    }

    @Test func secondServerInTheRun() throws {
        let (m, _, _, _) = makeModel()
        m.beginFirstRun(adding: .companion)
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        m.firstRunSaved(lab)
        // "Add Home Assistant too", then Cancel: back to Found, the run goes on.
        m.beginFirstRun(adding: .homeAssistant)
        #expect(m.firstRun?.adding == .homeAssistant && m.firstRun?.showsFound == true)
        m.firstRunEditorClosed()
        #expect(m.firstRun?.step == .found)
        // Again, with a save: both are found.
        m.beginFirstRun(adding: .homeAssistant)
        let server = ha()
        try m.save(server, token: "t")
        m.firstRunSaved(server)
        #expect(m.firstRun?.added == [lab.id, server.id] && m.firstRun?.step == .found)
        // A preset over both: the tile picker is skipped (Cancel) and the run ends.
        m.startFirstRun(with: .home, canPickTiles: true)
        m.finishFirstRun()
        #expect(m.firstRun == nil && m.settings.todayDensity == .calm)
    }

    @Test func cancelOnTheWelcomeEndsTheRun() {
        let (m, _, _, _) = makeModel()
        m.beginFirstRun(adding: .homeAssistant)
        m.firstRunEditorClosed()
        #expect(m.firstRun == nil && m.showsFirstRun && !m.showsStartTip)   // the welcome again
        m.beginFirstRun(adding: .demo)   // not a kind to add
        #expect(m.firstRun == nil)
    }

    @Test func resetEndsTheRunAndTheTip() throws {
        let (m, _, _, _) = makeModel()
        m.beginFirstRun(adding: .homeAssistant)
        let server = ha()
        try m.save(server, token: "t")
        m.firstRunSaved(server)
        m.resetAll()
        #expect(m.firstRun == nil && m.showsFirstRun && !m.showsStartTip)
        m.beginFirstRun(adding: .homeAssistant)
        m.firstRunSaved(server)
        m.startFirstRun(with: nil, canPickTiles: false)
        #expect(m.showsStartTip)
        m.resetAll()
        #expect(!m.showsStartTip)
    }

    @Test func screenshotArgumentOnlyOverTheDemo() async {
        let (m, _, _, _) = makeModel(args: ["-HomelabResetState", "YES", "-HomelabDemo", "YES", "-HomelabFirstRun", "YES"])
        #expect(m.firstRun?.step == .found && m.firstRun?.added.count == 2 && m.showsFirstRun)
        #expect(m.firstRunPreset == .watch)        // until /info answered: what the data shows
        await m.refresh()                          // Found asks the server
        #expect(m.firstRunPreset == .everything)   // the demo offers everything
        let (empty, _, _, _) = makeModel(args: ["-HomelabFirstRun", "YES"])
        #expect(empty.firstRun == nil)   // no servers: the welcome, as always
    }

    // MARK: Words

    @Test func offersInOrder() {
        #expect(FirstRun.offers(features: []).isEmpty)
        #expect(FirstRun.offers(features: [.hosts, .status]).map(\.title) == ["Status and problems", "Machines"])
        let all = FirstRun.offers(features: Set(ServerInfo.Feature.allCases))
        #expect(all.count == ServerInfo.Feature.allCases.count)
        #expect(Set(all.map(\.id)) == Set(ServerInfo.Feature.allCases.map(\.rawValue)))
        #expect(all.allSatisfy { !$0.symbol.isEmpty && !$0.title.isEmpty })
    }

    @Test func homeSummary() throws {
        func e(_ id: String) -> HAEntity { HAEntity(entityID: id, state: "on") }
        #expect(FirstRun.homeOffer(entities: nil).detail == nil)   // still loading
        #expect(FirstRun.homeOffer(entities: []).detail == "Nothing to pin yet")
        #expect(FirstRun.homeSummary([e("light.a")]) == "1 light")
        #expect(FirstRun.homeSummary([e("light.a"), e("light.b"), e("scene.c")]) == "2 lights and 1 scene")
        let many = [e("scene.a"), e("scene.b"), e("light.c"), e("switch.d"), e("script.e"), e("fan.f"), e("fan.g"),
                    e("fan.h"), e("weather.home")]
        #expect(FirstRun.homeSummary(many) == "3 fans, 2 scenes, 1 light and 1 switch")
        #expect(FirstRun.homeSummary([e("button.a"), e("automation.b"), e("weather.c")]) == "2 things to pin")
        let fixture = Fixtures.decode([Lossy<HAEntity>].self, "ha-states.json")?.compactMap(\.value) ?? []
        #expect(FirstRun.homeOffer(entities: fixture).detail == "1 light, 1 switch, 1 scene and 1 script")
        #expect(FirstRun.joined(["a", "b", "c"]) == "a, b and c" && FirstRun.joined([]) == "")
    }

    @Test func tilesOnlyWithSomethingToPin() {
        let light = HAEntity(entityID: "light.a", state: "on")
        let weather = HAEntity(entityID: "weather.home", state: "sunny")
        #expect(FirstRun.canPickTiles(hasHA: true, entities: [light]))
        #expect(!FirstRun.canPickTiles(hasHA: true, entities: [weather]))
        #expect(!FirstRun.canPickTiles(hasHA: true, entities: nil))   // still loading: pin later from Today
        #expect(!FirstRun.canPickTiles(hasHA: false, entities: [light]))
    }
}
