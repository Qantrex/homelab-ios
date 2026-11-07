import Foundation
import Testing
@testable import HomelabKit

/// A Homelab Bridge adds an optional `sources` list to /info (docs/API.md, "Source status"); Diagnostics shows it
/// (MODULAR.md M2.4). Missing or any odd shape must leave the rest of ServerInfo as it was and never fail decoding.
@Suite struct InfoSourcesTests {
    private func info(_ json: String) throws -> ServerInfo {
        try JSONDecoder().decode(ServerInfo.self, from: Data(json.utf8))
    }

    private let base = #""api":1,"name":"bridge","server":"homelab-reference","features":["status","hosts","cards"],"auth":"token""#

    /// The example of docs/API.md.
    private let rows = """
    [{"name":"Kuma","type":"uptime-kuma","state":"ok","checked":"2026-11-07T10:00:00+01:00",
      "last_ok":"2026-11-07T10:00:00+01:00"},
     {"name":"pve1","type":"proxmox","state":"failing","error":"401","checked":"2026-11-07T10:00:05+01:00",
      "last_ok":"2026-11-07T08:12:40+01:00","insecure":true},
     {"name":"Lab","type":"example","state":"never"}]
    """

    private func at(_ text: String) -> Date { ServerDate.parse(text)! }

    @Test func withoutTheFieldNothingChanges() throws {
        let plain = try info("{\(base)}")
        #expect(plain.sources == nil)
        #expect(plain.features == [.status, .hosts, .cards])
        // The cached copy the app writes back has no `sources` either.
        let written = try #require(String(data: JSONEncoder().encode(plain), encoding: .utf8))
        #expect(!written.contains("sources"))
        // The demo's info (and so every CI shot) has none.
        #expect(try fixture(ServerInfo.self, "info.json").sources == nil)
    }

    @Test func theDocumentedListDecodes() throws {
        let i = try info("{\(base),\"sources\":\(rows)}")
        let s = try #require(i.sources)
        #expect(s.count == 3)
        #expect(s[0] == SourceStatus(name: "Kuma", type: "uptime-kuma", state: .ok, checked: at("2026-11-07T10:00:00+01:00"),
                                     lastOK: at("2026-11-07T10:00:00+01:00")))
        #expect(s[1] == SourceStatus(name: "pve1", type: "proxmox", state: .failing, error: "401",
                                     checked: at("2026-11-07T10:00:05+01:00"), lastOK: at("2026-11-07T08:12:40+01:00"),
                                     insecure: true))
        #expect(s[2] == SourceStatus(name: "Lab", type: "example", state: .never))
        // Everything else is as without the field.
        var without = i
        without.sources = nil
        #expect(without == (try info("{\(base)}")))
    }

    @Test func oddShapesNeverBreakDecoding() throws {
        let plain = try info("{\(base)}")
        for notAList in ["null", #""sources""#, "42", "true", #"{"name":"x"}"#] {
            let i = try info("{\(base),\"sources\":\(notAList)}")
            #expect(i.sources == nil, "\(notAList)")
            #expect(i == plain)
        }
        #expect(try info("{\(base),\"sources\":[]}").sources == [])
        // Entries without a usable name are dropped, the rest stays.
        let junk = #"[{"state":"new-state"},"junk",7,null,[],{"name":"  "},{"name":42,"state":"ok"}]"#
        #expect(try info("{\(base),\"sources\":\(junk)}").sources == [SourceStatus(name: "42", state: .ok)])
    }

    @Test func oddFieldsGetFallbacks() throws {
        let long = String(repeating: "x", count: 300)
        let json = """
        [{"name":"Kuma","state":"DEGRADED"},
         {"name":"pve1","state":"Failing","error":"timeout\\nTraceback: secret stuff","insecure":"true"},
         {"name":"nas","state":"failing","error":"\(long)","checked":1794045600,"last_ok":"yesterday","insecure":1},
         {"name":"dns","type":["pihole"],"state":null,"error":{"code":1},"insecure":"maybe"}]
        """
        let s = try #require(try info("{\(base),\"sources\":\(json)}").sources)
        #expect(s.map(\.state) == [.unknown, .failing, .failing, .unknown])
        #expect(s[1].error == "timeout")                   // first line only
        #expect(s[1].insecure && s[2].insecure && !s[3].insecure)
        #expect(s[2].error?.count == 120)
        #expect(s[2].checked == Date(timeIntervalSince1970: 1_794_045_600))   // epoch seconds
        #expect(s[2].lastOK == nil)                        // not a time
        #expect(s[3].type == nil && s[3].error == nil)
    }

    @Test func encodesAndDecodesTheSame() throws {
        let i = try info("{\(base),\"sources\":\(rows)}")
        let again = try JSONDecoder().decode(ServerInfo.self, from: JSONEncoder().encode(i))
        #expect(again == i)
        // `insecure` is only written as true, like the server sends it.
        let written = try #require(String(data: JSONEncoder().encode(i.sources![0]), encoding: .utf8))
        #expect(!written.contains("insecure"))
    }

    @Test func words() throws {
        let now = at("2026-11-07T10:02:00+01:00")
        let s = try #require(try info("{\(base),\"sources\":\(rows)}").sources)
        #expect(s.map(\.stateText) == ["ok", "failing: 401", "not yet"])
        #expect(s.map { $0.timeText(now: now) } == ["checked 2 min ago", "last ok 1 h ago", "no run has finished yet"])
        #expect(SourceStatus(name: "x", state: .failing).stateText == "failing")
        #expect(SourceStatus(name: "x", state: .failing).timeText(now: now) == "never ok yet")
        #expect(SourceStatus(name: "x", state: .unknown).stateText == "unknown")
        #expect(SourceStatus(name: "x", state: .unknown).timeText(now: now) == nil)
        #expect(s[1].reportLine(now: now) == "source pve1 (proxmox): failing: 401, last ok 1 h ago, insecure")
        #expect(SourceStatus(name: "x", state: .ok).reportLine(now: now) == "source x (?): ok")
    }

    @Test func plainHTTPIsAWarning() throws {
        let json = #"[{"name":"Sonarr","type":"sonarr","state":"ok","plain_http":true},{"name":"x","plain_http":"no"}]"#
        let s = try #require(try info("{\(base),\"sources\":\(json)}").sources)
        #expect(s[0].plainHTTP && !s[0].insecure && !s[1].plainHTTP)
        #expect(s[0].reportLine() == "source Sonarr (sonarr): ok, plain http")
        let written = try #require(String(data: JSONEncoder().encode(s), encoding: .utf8))
        #expect(written.components(separatedBy: "plain_http").count == 2)   // only written as true
        #expect(try JSONDecoder().decode([SourceStatus].self, from: Data(written.utf8)) == s)
    }

    @Test func theReportMasksTailnetNames() {
        let s = SourceStatus(name: "nas.tail1234.ts.net", type: "json", state: .failing, error: "100.101.102.103 refused")
        let line = Redact.hosts(s.reportLine())
        #expect(!line.contains("tail1234") && !line.contains("100.101.102.103"))
        #expect(line.hasPrefix("source nas.<tailnet>.ts.net (json): failing: 100.x.x.x refused"))
    }
}
