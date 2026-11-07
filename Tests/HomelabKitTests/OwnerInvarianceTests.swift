import Foundation
import Testing
@testable import HomelabKit

/// Owner invariance (docs/plans/MODULAR.md, M0.1): the app as its owner uses it, frozen in golden files under
/// `Tests/Goldens/`. A made-up owner-shaped `servers.json` (a Companion server with identity login, a Home Assistant with
/// pins, tile names and icons) and `settings.json` (a reordered layout with hidden sections, a personality, Leave-by
/// off) must load and save back byte for byte, and for every state fixture the tabs, Today's sections per density,
/// the headline and the widget snapshot must stay exactly what they are.
///
/// If one of these fails, a change altered what the owner sees. Don't regenerate the goldens to make it pass: stop and
/// ask the owner (docs/plans/MODULAR.md, section 4). `UPDATE_GOLDENS=1 swift test` rewrites them for a deliberate,
/// approved change; commit them on their own.
@MainActor @Suite(.serialized) struct OwnerInvarianceTests {
    static let goldens = URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // Tests/HomelabKitTests
        .deletingLastPathComponent().appendingPathComponent("Goldens", isDirectory: true)
    static var updating: Bool { ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1" }

    static let companionID = UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000001")!
    static let homeID = UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000002")!

    /// The owner's kind of setup, made up (nothing real): written once with the app's own encoder.
    static func ownerServers() -> ServerList {
        let lab = ServerConfig(id: companionID, name: "nas", kind: .companion,
                               baseURL: URL(string: "https://nas.tail1234.ts.net")!, auth: .identity)
        let ha = ServerConfig(id: homeID, name: "Home Assistant", kind: .homeAssistant,
                              baseURL: URL(string: "https://ha.tail1234.ts.net")!, auth: .token,
                              pinnedEntities: ["light.living_room", "script.relax", "scene.party", "script.goodnight"],
                              tileNames: ["light.living_room": "Living room", "script.goodnight": "Goodnight"],
                              tileIcons: ["light.living_room": "lamp.floor", "scene.party": "sparkles"])
        return ServerList(servers: [lab, ha], selected: companionID, home: homeID)
    }

    static func ownerSettings() -> AppSettings {
        var s = AppSettings()
        var layout = TodayLayout.standard
        layout.move(fromOffsets: IndexSet(integer: layout.sections.count - 1), toOffset: 1)   // a reordered layout
        layout.setVisible(.machines, false)
        if let last = layout.sections.last, last != .day { layout.setVisible(last, false) }
        s.today = layout
        s.personality = .snarky
        s.leaveActivity = false
        s.notifyPending = true
        return s
    }

    static let stateFixtures = ["state-ok.json", "state-problem.json", "state-pending.json", "state-demo.json",
                                "state-departures.json", "state-empty.json", "state-huge.json", "state-lab-cards.json",
                                "state-legacy.json", "state-tomorrow.json", "state-unknown-fields.json"]

    /// Reads a golden, or writes it when updating (then the test passes and says so on stderr).
    static func golden(_ name: String, _ data: Data) throws -> Data {
        let url = goldens.appendingPathComponent(name)
        if updating {
            try FileManager.default.createDirectory(at: goldens, withIntermediateDirectories: true)
            try data.write(to: url)
            FileHandle.standardError.write(Data("golden written: \(name)\n".utf8))
            return data
        }
        return try Data(contentsOf: url)
    }

    static func pretty(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
    }

    // MARK: Saved files

    @Test func savedServersAndSettingsRoundTripByteForByte() throws {
        let servers = try Self.golden("owner-servers.json", Storage.encoder.encode(Self.ownerServers()))
        let settings = try Self.golden("owner-settings.json", Storage.encoder.encode(Self.ownerSettings()))
        // What an older or this version saved decodes and saves back to the very same bytes.
        let s1 = try Storage.decoder.decode(ServerList.self, from: servers)
        #expect(try Storage.encoder.encode(s1) == servers)
        let s2 = try Storage.decoder.decode(AppSettings.self, from: settings)
        #expect(try Storage.encoder.encode(s2) == settings)
        // And through the app model: loading them changes nothing on disk.
        let storage = Storage(directory: temporaryDirectory())
        try servers.write(to: storage.url(ServerList.fileName))
        try settings.write(to: storage.url(AppSettings.fileName))
        let (m, _, _, _) = makeModel(storage: storage)
        #expect(m.servers == s1 && m.settings == s2)
        #expect(m.hasServers)   // no first-run surface for the owner
        #expect(try Data(contentsOf: storage.url(ServerList.fileName)) == servers)
        #expect(try Data(contentsOf: storage.url(AppSettings.fileName)) == settings)
    }

    // MARK: What the owner sees

    /// Tabs, Today's sections per density, the headline and the widget snapshot for one state fixture.
    func observe(_ fixture: String) async throws -> [String: Any] {
        let storage = Storage(directory: temporaryDirectory())
        try Storage.encoder.encode(Self.ownerServers()).write(to: storage.url(ServerList.fileName))
        try Storage.encoder.encode(Self.ownerSettings()).write(to: storage.url(AppSettings.fileName))
        let server = FakeServer()
        server.state = fixture
        let (m, _, _, tokens) = makeModel(server, storage: storage)
        try tokens.setToken("ha-token", for: Self.homeID)
        await m.refresh()
        let layout = m.settings.today ?? .standard
        var sections: [String: [String]] = [:]
        for d in Density.allCases { sections[d.rawValue] = d.sections(layout).map(\.rawValue) }
        let mood = TodayMood(state: m.selectedStatus.snapshot?.state)
        // The widget's copy, with the fetch time masked (it is "now").
        var widget: Any = NSNull()
        if let data = try? Data(contentsOf: storage.url(Snapshot.widgetFileName)),
           var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object["fetched"] = "<now>"
            widget = object
        }
        return ["tabs": m.availableTabs.map(\.rawValue).sorted(),
                "sections": sections,
                "headline": mood.headline,
                "detail": mood.detail ?? NSNull(),
                "warnings": mood.warnings,
                "level": "\(mood.level)",
                "widget": widget]
    }

    @Test func tabsSectionsHeadlineAndWidgetPerFixture() async throws {
        var all: [String: Any] = [:]
        for fixture in Self.stateFixtures { all[fixture] = try await observe(fixture) }
        let now = try Self.pretty(all)
        let golden = try Self.golden("owner-observed.json", now)
        if now != golden {
            // Name the fixtures that differ, so the failure says what changed.
            let old = (try? JSONSerialization.jsonObject(with: golden) as? [String: Any]) ?? [:]
            for fixture in Self.stateFixtures {
                let a = try Self.pretty(all[fixture] ?? NSNull())
                let b = try Self.pretty(old[fixture] ?? NSNull())
                #expect(a == b, "owner view changed for \(fixture): see Tests/Goldens/owner-observed.json")
            }
        }
        #expect(now == golden)
    }

    @Test func goldensAreNotEmpty() throws {
        guard !Self.updating else { return }
        for name in ["owner-servers.json", "owner-settings.json", "owner-observed.json"] {
            let data = try Data(contentsOf: Self.goldens.appendingPathComponent(name))
            #expect(data.count > 100, "\(name)")
        }
    }
}
