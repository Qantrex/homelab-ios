import Foundation
import Testing
@testable import HomelabKit

@Suite struct FixtureDecoding {
    @Test func info() throws {
        let i = try fixture(ServerInfo.self, "info.json")
        #expect(i.api == 1)
        #expect(i.name == "Demo homelab")
        #expect(i.features == Set(ServerInfo.Feature.allCases))
    }

    @Test func infoWithoutFeaturesAssumesBasics() throws {
        let i = try decode(ServerInfo.self, #"{"api": "1"}"#)
        #expect(i.api == 1 && i.features == [.status, .hosts])
        let none = try decode(ServerInfo.self, #"{"api": 1, "features": ["chat", "teleport"]}"#)
        #expect(none.features == [.chat])
        #expect(throws: (any Error).self) { try decode(ServerInfo.self, #"{"name": "no api"}"#) }
    }

    @Test func stateOK() throws {
        let s = try fixture(HomelabState.self, "state-ok.json")
        #expect(s.status == .ok)
        #expect(s.problems.isEmpty)
        #expect(s.hosts.map(\.id) == ["nas", "pi"])
        let nas = s.hosts[0]
        #expect(nas.reachable == true && nas.load == 0.42 && nas.cpuCount == 4 && nas.memPct == 38)
        #expect(nas.disks == ["/": 31, "/srv/media": 64])
        #expect(nas.containersUp == 12 && nas.containersTotal == 12)
        #expect(nas.upgradable == 0 && nas.rebootRequired == false)
        #expect(nas.backupResult == "success" && nas.backupLast == "2026-11-04T04:45:10")
        #expect(s.lastMessage?.id == 1_762_288_000_000_000_000)   // exact Int64, no Double rounding
        #expect(s.checked != nil)
    }

    @Test func stateProblem() throws {
        let s = try fixture(HomelabState.self, "state-problem.json")
        #expect(s.status == .problem)
        #expect(s.problems.count == 2)
        #expect(s.problems[1].severity == .warning && s.problems[0].host == "media")
        #expect(s.hosts.count == 4)
        #expect(s.hosts[3].reachable == false && s.hosts[3].flags == ["asleep"])
        #expect(s.hosts[0].url?.host == "server.example.ts.net")
        #expect(s.pending.count == 2)
        #expect(s.pending[0].buttons.count == 3 && s.pending[0].buttons[.always] == "HOMELAB_ALWAYS_ab12_1123456789abcdef")
        #expect(s.pending[1].buttons[.always] == nil)
        #expect(s.pending[0].title == "restart media sonarr")
        #expect(s.cards.map(\.style) == [.list, .list, .metrics, .list, .departures, .metrics, .text, .text, .checklist, .countdown, .list])
        #expect(s.cards[0].tint == .purple && s.cards[0].items[0].progress == 0.42)
        #expect(s.busy == ["chat"])
    }

    @Test func emptyStateIsUnknown() throws {
        let s = try fixture(HomelabState.self, "state-empty.json")
        #expect(s.status == .unknown && s.hosts.isEmpty && s.pending.isEmpty)
    }

    @Test func legacyAndBrokenFieldsDegradeGracefully() throws {
        let s = try fixture(HomelabState.self, "state-legacy.json")
        // Unknown status value + problems present → derived from the problems.
        #expect(s.status == .problem)
        #expect(s.problems.map(\.text) == ["pi-media: disk / at 91%", "object problem"])   // 42 dropped
        #expect(s.checked != nil)                                                         // epoch number
        #expect(s.hosts.map(\.id) == ["pi-two", "mediabox"])                              // no-id host dropped
        let h = s.hosts[0]
        #expect(h.reachable == true)          // "yes"
        #expect(h.load == 0.5)                // "0.5"
        #expect(h.memPct == 13)               // 12.7 rounded
        #expect(h.temp == nil)
        #expect(h.disks == ["/boot": 20])     // "x" dropped
        #expect(h.containersUp == 3 && h.containersTotal == nil)
        #expect(h.flags == ["undervoltage_now"])   // single string → list
        #expect(s.hosts[1].reachable == nil)
        #expect(s.pending.map(\.id) == ["ef56"] && s.pending[0].buttons.isEmpty)
        #expect(s.cards.count == 1)
        #expect(s.cards[0].style == .list && s.cards[0].tint == .gray)
        #expect(s.cards[0].items.map(\.progress) == [1, 0])   // clamped, "bad" dropped
        #expect(s.busy == ["chat"])
    }

    @Test func duplicateIDsAreDropped() throws {
        let s = try decode(HomelabState.self, """
        {"status":"ok","hosts":[{"id":"a"},{"id":"a","name":"dup"}],"problems":["x","x"],
         "pending":[{"id":"p"},{"id":"p"}],"cards":[{"id":"c"},{"id":"c"}]}
        """)
        #expect(s.hosts.count == 1 && s.hosts[0].name == "a")
        #expect(s.problems.count == 1 && s.pending.count == 1 && s.cards.count == 1)
    }

    @Test func percentagesAreClamped() throws {
        let h = try decode(Host.self, #"{"id":"x","mem_pct":140,"disks":{"/":-5,"/a":101}}"#)
        #expect(h.memPct == 100 && h.disks == ["/": 0, "/a": 100])
    }

    @Test func unsafeLinksAreDropped() throws {
        let c = try decode(Card.self, """
        {"id":"c","items":[{"title":"a","url":"javascript:alert(1)"},{"title":"b","url":"https://ok.example/x"},
                           {"title":"c","url":"file:///etc/passwd"}]}
        """)
        #expect(c.items.map(\.url) == [nil, URL(string: "https://ok.example/x"), nil])
        #expect(throws: (any Error).self) { try decode(Service.self, #"{"name":"x","url":"ftp://a"}"#) }
    }

    @Test func pendingDashArgMeansNone() throws {
        let p = try decode(PendingAction.self, #"{"id":"ab12","action":"restart","arg":"-"}"#)
        #expect(p.arg == nil && p.title == "restart")
        #expect(try decode(PendingAction.self, #"{"id":"x"}"#).title == "Action x")
    }

    @Test func messagesSortAndSkipBadOnes() throws {
        let page = try decode(MessagePage.self, """
        {"messages":[{"id":3,"from":"agent","text":"c"},{"id":"1","from":"ME","text":"a"},{"text":"no id"},
                     {"id":2,"text":"b","job":"morning","status":"ok"}],"busy":[]}
        """)
        #expect(page.messages.map(\.id) == [1, 2, 3])
        #expect(page.messages[0].from == .me && page.messages[1].from == .agent)
        #expect(page.messages[1].status == "OK" && page.messages[1].isReport)
        #expect(!page.messages[2].isReport)
    }

    @Test func servicesAcceptBareArray() throws {
        let list = try decode(ServiceList.self, #"[{"name":"a","url":"https://a.example"},{"name":"bad"}]"#)
        #expect(list.services.map(\.name) == ["a"])
        let wrapped = try fixture(ServiceList.self, "services.json")
        #expect(wrapped.services.count == 5)
    }

    @Test func roundTripThroughCache() throws {
        for name in ["state-ok.json", "state-problem.json", "state-legacy.json", "state-empty.json"] {
            let s = try fixture(HomelabState.self, name)
            let data = try Storage.encoder.encode(s)
            let again = try JSONDecoder().decode(HomelabState.self, from: data)
            #expect(again.hosts == s.hosts, "\(name) hosts")
            #expect(again.pending == s.pending, "\(name) pending")
            #expect(again.cards == s.cards, "\(name) cards")
            #expect(again.problems.map(\.text) == s.problems.map(\.text), "\(name) problems")
            #expect(again.status == s.status, "\(name) status")
            #expect(again.lastMessage?.id == s.lastMessage?.id)
            #expect(abs((again.checked ?? .distantPast).timeIntervalSince(s.checked ?? .distantPast)) < 1)
        }
        let info = try fixture(ServerInfo.self, "info.json")
        #expect(try JSONDecoder().decode(ServerInfo.self, from: Storage.encoder.encode(info)) == info)
    }

    @Test func statusWords() {
        #expect(OverallStatus(lenient: "OK") == .ok)
        #expect(OverallStatus(lenient: "degraded") == .warning)
        #expect(OverallStatus(lenient: "critical") == .problem)
        #expect(OverallStatus(lenient: nil) == .unknown)
        #expect(OverallStatus.problem.severity > OverallStatus.warning.severity)
    }
}

@Suite struct DateParsing {
    let utc = TimeZone(identifier: "UTC")!

    @Test(arguments: [
        "2026-11-04T21:30:00Z", "2026-11-04T21:30:00+00:00", "2026-11-04T22:30:00+01:00",
        "2026-11-04T21:30:00.000Z", "2026-11-04T21:30:00.123456+00:00",
    ])
    func zoned(_ text: String) throws {
        let d = try #require(ServerDate.parse(text, timeZone: utc))
        #expect(abs(d.timeIntervalSince1970 - 1_793_827_800) < 1)
    }

    @Test func localTimeUsesTheGivenZone() throws {
        let vienna = TimeZone(identifier: "Europe/Vienna")!
        let d = try #require(ServerDate.parse("2026-11-04T22:30:00", timeZone: vienna))
        #expect(d.timeIntervalSince1970 == 1_793_827_800)
        #expect(ServerDate.parse("2026-11-04 22:30:00", timeZone: vienna)?.timeIntervalSince1970 == 1_793_827_800)
        #expect(ServerDate.parse("2026-11-04", timeZone: utc) != nil)
    }

    @Test func epochs() {
        #expect(ServerDate.fromEpoch(1_762_291_800)?.timeIntervalSince1970 == 1_762_291_800)
        #expect(ServerDate.fromEpoch(1_762_291_800_000)?.timeIntervalSince1970 == 1_762_291_800)
        #expect(ServerDate.fromEpoch(1.7622918e18).map { abs($0.timeIntervalSince1970 - 1_762_291_800) < 1 } == true)
        #expect(ServerDate.parse("1762291800")?.timeIntervalSince1970 == 1_762_291_800)
        #expect(ServerDate.fromEpoch(0) == nil && ServerDate.fromEpoch(.nan) == nil)
    }

    @Test func garbage() {
        #expect(ServerDate.parse("") == nil)
        #expect(ServerDate.parse("yesterday") == nil)
        #expect(ServerDate.parse("21:30") == nil)
    }

    @Test func writtenDatesParseBack() throws {
        let now = Date(timeIntervalSince1970: 1_762_291_800)
        #expect(ServerDate.parse(ServerDate.string(now)) == now)
    }
}

@Suite struct URLRules {
    func ok(_ s: String) -> String? { try? URLPolicy.serverURL(s).get().absoluteString }
    func err(_ s: String) -> URLPolicy.Problem? {
        if case .failure(let e) = URLPolicy.serverURL(s) { return e }
        return nil
    }

    @Test func normalises() {
        #expect(ok("nas.tail1234.ts.net") == "https://nas.tail1234.ts.net")
        #expect(ok("  https://Host.Example.ts.net/  ") == "https://host.example.ts.net")
        #expect(ok("https://h.example/api/v1/") == "https://h.example")
        #expect(ok("https://h.example/sub/api") == "https://h.example/sub")
        #expect(ok("https://h.example:8443?x=1#y") == "https://h.example:8443")
        #expect(ok("http://192.168.1.10:8791") == "http://192.168.1.10:8791")
        #expect(ok("http://100.101.102.103") == "http://100.101.102.103")
        #expect(ok("http://nas.local") == "http://nas.local")
        #expect(ok("http://nas:8123") == "http://nas:8123")
        #expect(ok("http://[fd7a:115c:a1e0::1]:8791") != nil)
    }

    @Test func rejects() {
        #expect(err("") == .empty)
        #expect(err("ftp://h.example") == .unsupportedScheme)
        #expect(err("http://h.example.com") == .insecureRemote)
        #expect(err("http://8.8.8.8") == .insecureRemote)
        #expect(err("http://100.200.1.1") == .insecureRemote)   // outside 100.64/10
        #expect(err("https://user:pw@h.example") == .credentialsInURL)
        #expect(err("https://") == .noHost)
        for p in [URLPolicy.Problem.empty, .notAURL, .unsupportedScheme, .noHost, .credentialsInURL, .insecureRemote] {
            #expect(!URLPolicy.message(p).isEmpty)
        }
    }

    @Test func webLinks() {
        #expect(URLPolicy.webURL("https://a.example/x") != nil)
        #expect(URLPolicy.webURL("http://a.example") != nil)
        #expect(URLPolicy.webURL("javascript:alert(1)") == nil)
        #expect(URLPolicy.webURL("homelab://actions") == nil)
        #expect(URLPolicy.webURL("https://u:p@a.example") == nil)
        #expect(URLPolicy.webURL("not a url") == nil)
    }

    @Test func localRanges() {
        for h in ["10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.0.1", "127.0.0.1", "localhost", "router",
                  "fe80::1", "box.home.arpa", "100.64.0.1", "100.127.255.255"] {
            #expect(URLPolicy.isLocal(host: h), "\(h)")
        }
        for h in ["172.32.0.1", "8.8.8.8", "example.com", "100.128.0.1", "2001:db8::1", "a.ts.net"] {
            #expect(!URLPolicy.isLocal(host: h), "\(h)")
        }
    }
}
