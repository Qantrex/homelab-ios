import Foundation
import Testing
@testable import HomelabKit

/// A Homelab Bridge adds an optional `sources` list to /info (docs/API.md, "Source status"). This version of the app
/// doesn't read it yet (Diagnostics will, MODULAR.md M2.4): any shape of it must leave ServerInfo as it was.
@Suite struct InfoSourcesTests {
    private func info(_ json: String) throws -> ServerInfo {
        try JSONDecoder().decode(ServerInfo.self, from: Data(json.utf8))
    }

    private let base = #""api":1,"name":"bridge","server":"homelab-reference","features":["status","hosts","cards"],"auth":"token""#

    @Test func sourcesChangeNothingInServerInfo() throws {
        let plain = try info("{\(base)}")
        let rows = """
        [{"name":"Kuma","type":"uptime-kuma","state":"ok","checked":"2026-11-07T10:00:00+01:00",
          "last_ok":"2026-11-07T10:00:00+01:00"},
         {"name":"pve1","type":"proxmox","state":"failing","error":"401","checked":"2026-11-07T10:00:05+01:00",
          "last_ok":"2026-11-07T08:12:40+01:00","insecure":true},
         {"name":"Lab","type":"example","state":"never"}]
        """
        for odd in [rows, "[]", "null", #""sources""#, "42", #"[{"state":"new-state"},"junk",7]"#, #"{"name":"x"}"#] {
            let withSources = try info("{\(base),\"sources\":\(odd)}")
            #expect(withSources == plain)
        }
        #expect(plain.features == [.status, .hosts, .cards])
        // The cached copy the app writes back has no `sources` either.
        let written = try #require(String(data: JSONEncoder().encode(plain), encoding: .utf8))
        #expect(!written.contains("sources"))
    }
}
