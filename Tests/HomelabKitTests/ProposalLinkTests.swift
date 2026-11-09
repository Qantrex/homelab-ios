import Foundation
import Testing
@testable import HomelabKit

/// `homelab://actions/pending/<id>`: what the ntfy push of a proposal opens (the Open button and the tap).
@MainActor @Suite(.serialized) struct ProposalLinkTests {
    func make() throws -> AppModel {
        let m = AppModel(storage: Storage(directory: temporaryDirectory()), tokens: MemoryTokenStore(),
                         transport: FakeServer().transport, arguments: [])
        try m.save(ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity), token: nil)
        return m
    }

    @Test func theIDComesOnlyFromAWellFormedLink() {
        func id(_ s: String) -> String? { AppModel.proposalID(URL(string: s)!) }
        #expect(id("homelab://actions/pending/ab12") == "ab12")
        #expect(id("homelab://actions/pending/AB12") == nil)             // lowercase only
        #expect(id("homelab://actions/pending/ab1") == nil)
        #expect(id("homelab://actions/pending/ab12/extra") == nil)
        #expect(id("homelab://actions/pending/ab-2") == nil)
        #expect(id("homelab://actions/other/ab12") == nil)
        #expect(id("homelab://chat/pending/ab12") == nil)
        #expect(id("https://actions/pending/ab12") == nil)
        #expect(id("homelab://actions") == nil)
    }

    @Test func theLinkOpensTheActionsTabAndNoActionForm() async throws {
        let m = try make()
        await m.refresh()
        m.pick(.chat)
        m.open(URL(string: "homelab://actions/pending/pa01")!)
        #expect(m.tab == .actions && m.openProposal == "pa01")
        #expect(m.openAction == nil && m.openActionLink == nil)          // "pending" is not an action name
    }

    @Test func theProposalIsFoundOnceAndNothingIsApproved() async throws {
        let m = try make()
        await m.refresh()
        let known = m.selectedStatus.snapshot?.state.pending.first?.id
        let id = try #require(known)
        m.open(URL(string: "homelab://actions/pending/\(id)")!)
        #expect(m.takeOpenProposal()?.id == id)
        #expect(m.openProposal == nil && m.takeOpenProposal() == nil)    // once
        #expect(m.selectedStatus.snapshot?.state.pending.contains { $0.id == id } == true)   // still waiting for the owner
    }

    @Test func aProposalThatIsGoneIsDropped() async throws {
        let m = try make()
        await m.refresh()
        m.open(URL(string: "homelab://actions/pending/ffff")!)
        #expect(m.takeOpenProposal() == nil && m.openProposal == nil)
    }

    @Test func pickingAnotherTabOrAnotherLinkEndsIt() async throws {
        let m = try make()
        await m.refresh()
        m.open(URL(string: "homelab://actions/pending/pa01")!)
        m.pick(.lab)
        #expect(m.openProposal == nil)
        m.open(URL(string: "homelab://actions/pending/pa01")!)
        m.open(URL(string: "homelab://deals")!)                          // a newer link replaces it
        #expect(m.openProposal == nil)
    }

    @Test func theOtherLinksTheNtfyPushesUseStillWork() throws {
        let m = try make()
        for (link, tab) in [("today", AppTab.today), ("chat", .chat), ("lab", .lab), ("actions", .actions)] {
            m.open(URL(string: "homelab://\(link)")!)
            #expect(m.tab == tab || m.requestedTab == tab, "\(link)")
        }
        // The wake-up and TV pushes: the Living room form with the argument filled in, never run by the link.
        let link = ActionLink(URL(string: "homelab://actions/ha-control?arg=wiim-pause")!)
        #expect(link?.name == "ha-control" && link?.arg == "wiim-pause" && link?.run == false)
        #expect(ActionLink(URL(string: "homelab://actions/ha-control?arg=tv-off")!)?.arg == "tv-off")
    }
}
