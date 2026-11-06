import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HomelabKit

@MainActor @Suite(.serialized) struct ScanLinkTests {
    @Test func scanLinkWaitsForTheFeatureAndOpensOnce() async throws {
        let (m, _, _, _) = makeModel(FakeServer())
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        m.open(URL(string: "homelab://scan")!)
        #expect(m.openScan)
        #expect(!m.takeOpenScan())                                     // features unknown: waits
        await m.refresh()                                              // info.json has "documents"
        m.validateTab()
        #expect(m.tab == .actions)
        #expect(m.takeOpenScan())
        #expect(!m.openScan && !m.takeOpenScan())                      // once
    }

    @Test func serverWithoutDocumentsDropsTheRequest() async throws {
        let server = FakeServer()
        server.info = Data(#"{"api": 1, "features": ["status", "hosts", "chat"]}"#.utf8)
        let (m, _, _, _) = makeModel(server)
        try m.save(ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity), token: nil)
        await m.refresh()
        m.open(URL(string: "homelab://scan")!)
        #expect(!m.takeOpenScan())
        #expect(!m.openScan)
    }

    @Test func manualTabChangeEndsTheRequestAndOutboxIsCounted() async throws {
        let (m, _, _, _) = makeModel(FakeServer())
        try m.save(ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity), token: nil)
        await m.refresh()
        m.open(URL(string: "homelab://scan")!)
        m.pick(.chat)
        #expect(!m.openScan)
        #expect(m.outboxCount == 0)
        let id = try #require(m.selected).id
        try m.outbox.add(.url(URL(string: "https://example.org")!, title: nil), id: UUID().uuidString.lowercased(), server: id)
        m.outboxChanged()
        #expect(m.outboxCount == 1)
        await m.drainOutbox()                                          // the fake server has no /share: 404 keeps it
        #expect(m.outboxCount == 1)
    }
}
