import Foundation
import Testing
@testable import HomelabKit

/// Hyperdetail shows every field but never a secret: the signed approval buttons (`HOMELAB_APPROVE_...`) are bearer
/// tokens and never go to the screen or a notification body (ProposalNotice.swift).
@Suite struct HyperdetailSecretsTests {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    static let now = Date(timeIntervalSince1970: 1_794_132_000)
    static let states = ["state-pending", "state-problem", "state-demo", "state-ok", "state-huge", "state-bridge",
                         "state-lab-cards", "state-departures", "state-tomorrow", "state-unknown-fields", "state-legacy", "state-empty"]

    @Test func pendingShowsWhichButtonsAreOfferedNeverTheirValues() throws {
        let state = try fixture(HomelabState.self, "state-pending.json")
        let p = try #require(state.pending.first)
        #expect(!p.buttons.isEmpty)
        let lines = Hyper.pending(p, now: Self.now, calendar: Self.utc)
        #expect(lines.contains(HyperLine("button approve", "offered")))
        #expect(lines.contains(HyperLine("button deny", "offered")))
        for line in lines {
            #expect(!line.value.contains("HOMELAB_") && !line.label.contains("HOMELAB_"))
            for v in p.buttons.values { #expect(!line.value.contains(v)) }
        }
    }

    @Test func noLineOrNoticeOfAnyFixtureCarriesAButtonValue() throws {
        var secrets: [String] = []
        var texts: [String] = []
        for name in Self.states {
            let state = try fixture(HomelabState.self, name + ".json")
            for p in state.pending {
                secrets += p.buttons.values
                texts += Hyper.pending(p, now: Self.now, calendar: Self.utc).flatMap { [$0.label, $0.value] }
                for personality in Personality.allCases {
                    let alert = AlertTracker.Alert(id: "pending-\(p.id)", kind: .pending, title: "t", body: "b",
                                                   moment: .notice(.waiting), proposal: p)
                    texts.append(Hyper.noticeExtra(alert, state: state, deals: nil, personality: personality,
                                                   now: Self.now, calendar: Self.utc) ?? "")
                }
            }
            for h in state.hosts { texts += Hyper.host(h, now: Self.now, calendar: Self.utc).flatMap { [$0.label, $0.value] } }
            for p in state.problems { texts += Hyper.problem(p, now: Self.now, calendar: Self.utc).flatMap { [$0.label, $0.value] } }
            for c in state.cards {
                texts += Hyper.card(c, now: Self.now, calendar: Self.utc).flatMap { [$0.label, $0.value] }
                for i in c.items { texts += Hyper.item(i, now: Self.now, calendar: Self.utc).flatMap { [$0.label, $0.value] } }
            }
        }
        #expect(!secrets.isEmpty)
        for t in texts {
            #expect(!t.contains("HOMELAB_"), "\(t)")
            for s in secrets { #expect(!t.contains(s), "\(t)") }
        }
    }

    @Test func densityDecodesCaseInsensitively() throws {
        for (word, level) in [("Overkill", Density.overkill), ("HYPERDETAIL", .hyperdetail), ("Calm", .calm)] {
            let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"density":"\#(word)"}"#.utf8))
            #expect(s.todayDensity == level)
        }
        #expect(Density.hyperdetail.summary == "Everything, unfolded; commentary when a personality is on. Not recommended.")
    }

    @Test func builtInTilesAndNotSentGetFields() {
        #expect(Hyper.startTile(.scan, waiting: 3).contains(HyperLine("outbox waiting", "3")))
        #expect(Hyper.startTile(.deals, toAct: 2).contains(HyperLine("deals to act on", "2")))
        #expect(Hyper.startTile(.find).contains(HyperLine("feature", "search")))
        #expect(Hyper.fact(tile: .find).isComplete)
        let d = Outbox.Dropped(when: Self.now, what: "A scan", why: "the server has no place for it (404)")
        #expect(Hyper.notSent(d, now: Self.now, calendar: Self.utc).map(\.label) == ["what", "why", "when"])
    }

    @Test func secretsInOtherFieldsAreScrubbed() {
        #expect(HyperSecret.scrub("HOMELAB_APPROVE_x_1") == "<secret>")
        #expect(HyperSecret.scrub("Bearer abcdef123456") == "Bearer <secret>")
        #expect(HyperSecret.scrub("https://x.example/a?token=abc&b=1") == "https://x.example/a?token=<secret>&b=1")
        #expect(HyperSecret.scrub("https://user:pw@x.example/a") == "https://<credentials>@x.example/a")
        #expect(HyperSecret.scrub("https://x.example/a?page=2") == "https://x.example/a?page=2")
        #expect(HyperLine("url", "https://h/?api_key=K1").value == "https://h/?api_key=<secret>")
        let item = Card.Item(title: "x", url: URL(string: "https://h/feed?key=SECRET"))
        #expect(!Hyper.item(item).contains { $0.value.contains("SECRET") })
        let fact = Hyper.Fact(.approval, ["title": "restart HOMELAB_APPROVE_a_1"])
        #expect(fact.values["title"] == "restart <secret>")
    }
}
