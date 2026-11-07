import Foundation
import Testing
@testable import HomelabKit

/// Bugs found by the app review of 2026-11-07 (functional and Settings), each kept fixed by a test.
@MainActor @Suite(.serialized) struct AppReviewFixTests {
    let haURL = URL(string: "https://ha.example.ts.net")!

    @Test func editingTheHAServerKeepsTileNamesAndIcons() throws {
        let (m, _, _, _) = makeModel()
        let ha = ServerConfig(name: "HA", kind: .homeAssistant, baseURL: haURL, auth: .token)
        try m.save(ha, token: "llat")
        m.setPinned(["light.a", "switch.b"], names: ["light.a": "Desk"], icons: ["switch.b": "sofa"], for: ha.id)
        let original = try #require(m.homeAssistant)
        // What the server editor saves after a rename.
        try m.save(ServerConfig.edited(original, name: "Home", kind: .homeAssistant, baseURL: original.baseURL, auth: .token), token: nil)
        #expect(m.homeAssistant?.name == "Home")
        #expect(m.homeAssistant?.pinnedEntities == ["light.a", "switch.b"])
        #expect(m.homeAssistant?.tileNames == ["light.a": "Desk"])
        #expect(m.homeAssistant?.tileIcons == ["switch.b": "sofa"])
        // A new server starts empty.
        let new = ServerConfig.edited(nil, name: "x", kind: .companion, baseURL: labURL, auth: .identity)
        #expect(new.pinnedEntities.isEmpty && new.tileNames.isEmpty)
    }

    @Test func resetEverythingDoesNotComeBackFromTheLocalCopy() throws {
        let local = Storage(directory: temporaryDirectory())
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .token)
        try local.write(ServerList(servers: [lab], selected: lab.id), ServerList.fileName)
        var group = Storage(directory: temporaryDirectory())
        group.adoptFiles(from: local.directory)          // what Storage.shared() does at launch
        group.adoptedFrom = local.directory
        let (m, _, _, _) = makeModel(storage: group)
        #expect(m.servers.servers.count == 1)
        m.resetAll()
        group.adoptFiles(from: local.directory)          // the next Storage.shared()
        let (again, _, _, _) = makeModel(storage: group)
        #expect(again.servers.servers.isEmpty)
    }

    @Test func defaultServerNameIsTheShortHostName() throws {
        #expect(ServerConfig.defaultName(for: URL(string: "https://nas.tail1234.ts.net")!) == "nas")
        #expect(ServerConfig.defaultName(for: URL(string: "http://192.168.1.5:8080")!) == "192.168.1.5")
        #expect(ServerConfig.defaultName(for: URL(string: "http://lab:8080")!) == "lab")
        #expect(ServerConfig.defaultName(for: URL(string: "http://[fd7a::1]:8080")!).contains(":"))
        // Saved before: the whole host as the name becomes the short one; a typed name stays.
        let id = UUID()
        let old = #"{"id":"\#(id.uuidString)","name":"nas.tail1234.ts.net","kind":"companion","baseURL":"https://nas.tail1234.ts.net","auth":"identity"}"#
        #expect(try JSONDecoder().decode(ServerConfig.self, from: Data(old.utf8)).name == "nas")
        let typed = #"{"id":"\#(id.uuidString)","name":"My lab","kind":"companion","baseURL":"https://nas.tail1234.ts.net","auth":"identity"}"#
        #expect(try JSONDecoder().decode(ServerConfig.self, from: Data(typed.utf8)).name == "My lab")
    }

    @Test func coldLaunchDealsLinkOnADealsOnlyServer() async throws {
        let server = DealsServer()
        server.base.info = Data(#"{"api": 1, "features": ["status", "hosts", "deals"]}"#.utf8)
        let storage = Storage(directory: temporaryDirectory())
        let warm = AppModel(storage: storage, tokens: MemoryTokenStore(), transport: server.transport, arguments: [])
        try warm.save(ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity), token: nil)
        await warm.refresh()
        let m = AppModel(storage: storage, tokens: MemoryTokenStore(), transport: server.transport, arguments: [])
        m.open(URL(string: "homelab://deals")!)
        await m.refresh()
        #expect(m.tab == .actions)
        #expect(m.takeOpenDeals())
    }

    @Test func reloadDealsIsNotUndoneByARunningPoll() async throws {
        let server = DealsServer()
        server.base.info = Data(#"{"api": 1, "features": ["status", "hosts", "actions", "deals"]}"#.utf8)
        let m = AppModel(storage: Storage(directory: temporaryDirectory()), tokens: MemoryTokenStore(),
                         transport: server.transport, arguments: [])
        try m.save(ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity), token: nil)
        await m.refresh()
        let lab = try #require(m.selected)
        server.base.stateDelay = 10
        let poll = Task { await m.refresh() }
        try await server.base.waitForCalls("/api/v1/state", 2)
        server.deals = Data(#"{"deals": [{"id": 9, "title": "new one", "verdict": "act"}]}"#.utf8)
        #expect(await m.reloadDeals(on: lab) == nil)
        server.base.release()
        await poll.value
        #expect(m.selectedStatus.deals?.deals.map(\.id) == [9])
    }

    @Test func aFutureSeenDealIsNotFreshForever() {
        let now = Date()
        let far = DealList(updated: now, deals: [Deal(id: 1, title: "x", seen: now.addingTimeInterval(30 * 24 * 3600), verdict: .act)])
        #expect(far.freshAct(now: now).isEmpty)
        #expect(DealList.notifiable(far.deals, now: now, maxAge: 6 * 3600).isEmpty)
        // A server clock a few minutes fast still counts.
        let skew = DealList(updated: now, deals: [Deal(id: 2, title: "y", seen: now.addingTimeInterval(300), verdict: .act)])
        #expect(skew.freshAct(now: now).map(\.id) == [2])
    }

    @Test func duplicatePinsAreDropped() {
        #expect(LaunchArguments(["-HomelabPins", "light.a,light.a,script.b"]).pins == ["light.a", "script.b"])
    }
}

@Suite struct NoInputActionTests {
    func decode(_ json: String) throws -> [ActionSpec] { try JSONDecoder().decode(ActionList.self, from: Data(json.utf8)).actions }

    @Test func onlyActionsWithNothingToFillInSkipTheForm() throws {
        let specs = try decode("""
        {"actions": [
          {"name": "day-off", "label": "Day off", "fields": []},
          {"name": "fixed", "label": "Fixed", "fields": [], "arg": [{"label": "x", "parts": [{"kind": "literal", "text": "now"}]}]},
          {"name": "pick", "label": "Pick", "fields": [], "arg": [{"label": "x", "parts": [{"kind": "choice", "label": "W", "options": [{"value": "a", "label": "A"}]}]}]},
          {"name": "two", "label": "Two", "fields": [], "arg": [{"label": "a", "parts": [{"kind": "literal", "text": "a"}]}, {"label": "b", "parts": [{"kind": "literal", "text": "b"}]}]},
          {"name": "note", "label": "Note", "fields": [{"name": "text", "label": "Text", "kind": "text", "max": 20}]}
        ]}
        """)
        let quick = specs.filter { ActionForm($0).needsNoInput }.map(\.name)
        #expect(quick.contains("day-off") && quick.contains("fixed"))
        #expect(!quick.contains("pick") && !quick.contains("two") && !quick.contains("note"))
    }
}

@Suite struct AppExpiryTests {
    let profile = Data(("garbage\u{0}\u{1}<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">"
        + "<plist version=\"1.0\"><dict><key>Name</key><string>XTL profile</string><key>ExpirationDate</key><date>2026-11-14T12:31:29Z</date></dict></plist>\u{0}signature").utf8)

    @Test func readsTheDateFromTheProfile() {
        #expect(AppExpiry.date(fromProfile: profile) == ISO8601DateFormatter().date(from: "2026-11-14T12:31:29Z"))
        #expect(AppExpiry.date(fromProfile: Data("no plist here".utf8)) == nil)
    }

    @Test func warnsOnlyInTheLastTwoDays() throws {
        let expires = try #require(ISO8601DateFormatter().date(from: "2026-11-14T12:31:29Z"))
        #expect(AppExpiry.warning(expires: expires, now: expires.addingTimeInterval(-3 * 24 * 3600)) == nil)
        #expect(AppExpiry.warning(expires: expires, now: expires.addingTimeInterval(-36 * 3600))?.contains("in 1 day") == true)
        #expect(AppExpiry.warning(expires: expires, now: expires.addingTimeInterval(-5 * 3600))?.contains("in 5 hours") == true)
        #expect(AppExpiry.warning(expires: nil) == nil)
    }
}

@Suite struct RedactTests {
    @Test func reportMasksTheTailnet() {
        let r = Redact.hosts("server companion/identity nas.tail1234.ts.net: error Can't reach nas.tail1234.ts.net. via 100.101.102.103, LAN 192.168.1.5")
        #expect(!r.contains("tail1234") && !r.contains("100.101.102.103"))
        #expect(r.contains("nas.<tailnet>.ts.net") && r.contains("100.x.x.x") && !r.contains("192.168.1.5") && r.contains("<lan-ip>"))
    }

    @Test func reportMasksHomeNetworkNamesAndGlobalIPv6() {
        let r = Redact.hosts("a nas.lan b printer.local c router.home.arpa d db.internal e 2001:db8:85a3::8a2e:370:7334 f 2a02:1234::1 g 2001:db8:0:0:0:0:0:1 at 12:30:45 h NAS.LAN")
        for leak in ["nas.lan", "printer", "router", "db.internal", "2001", "2a02", "NAS.LAN"] { #expect(!r.localizedCaseInsensitiveContains(leak), "\(leak)") }
        #expect(r.contains("12:30:45") && r.contains("<ip6>") && r.contains("<host>"))
        #expect(Redact.host("printer.local") == "<host>" && Redact.host("2a02:1234::1") == "<ip6>")
    }

    @Test func knownHostsMatchWholeNamesOnly() {
        let r = Redact.hosts("api on nas, Homelab via pi (PI) pie nas-2 nas.example.lan", knownHosts: ["nas", "pi", "home"])
        #expect(r == "api on <host>, Homelab via <host> (<host>) pie nas-2 <host>")
    }

    @Test func reportMasksLocalAddressesAndOtherHosts() {
        let r = Redact.hosts("a 10.0.0.2 b 172.20.1.1 c 169.254.3.4 d fd12:3456::1 e fe80::1ff:fe23 f 8.8.8.8 g nas.example.lan:7443 refused (1.2.3, iOS 17.2)",
                             knownHosts: ["nas.example.lan"])
        for leak in ["10.0.0.2", "172.20.1.1", "169.254.3.4", "fd12", "fe80", "8.8.8.8", "example.lan"] { #expect(!r.contains(leak), "\(leak)") }
        #expect(r.contains("<host>:7443") && r.contains("(1.2.3, iOS 17.2)"))
        #expect(Redact.host("nas.example.lan") == "<host>" && Redact.host("192.168.1.5") == "<lan-ip>")
        #expect(Redact.host("nas.tail1234.ts.net") == "nas.<tailnet>.ts.net" && Redact.host("172.32.0.1") == "<ip>")
    }
}
