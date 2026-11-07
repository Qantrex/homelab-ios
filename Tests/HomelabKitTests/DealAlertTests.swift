import Foundation
import Testing
@testable import HomelabKit

/// A new "act now" deal can become a local notification (Settings → Notifications → New deals to act on): once per
/// deal, never for a stale one, never as a storm, and with the app lock on it says nothing about the deal.
@Suite struct DealAlertTests {
    let now = Date(timeIntervalSince1970: 1_794_044_400)
    let calm = HomelabState(status: .ok)
    let on = AlertTracker.Options(problems: true, pending: true, deals: true)

    func deal(_ id: Int64, _ verdict: Deal.Verdict? = .act, minutesAgo: Double = 10, price: Double? = 100, value: Double? = 200) -> Deal {
        Deal(id: id, title: "Deal \(id)", price: price, value: value, location: "Krems", state: "Niederösterreich",
             seen: now.addingTimeInterval(-minutesAgo * 60), verdict: verdict)
    }

    func list(_ deals: Deal...) -> DealList { DealList(updated: now, deals: deals) }

    /// A tracker that has seen one run, so the next one may alert.
    func learned(_ deals: DealList? = DealList()) -> AlertTracker {
        var t = AlertTracker()
        _ = t.update(with: calm, deals: deals, server: "lab", serverID: server, options: on, now: now.addingTimeInterval(-300))
        return t
    }

    let server = UUID()

    @Test func aNewActDealAlertsOnceWithItsLink() {
        var t = learned()
        let first = t.update(with: calm, deals: list(deal(1)), server: "lab", serverID: server, options: on, now: now)
        #expect(first.count == 1 && first[0].kind == .deal && first[0].id == "deal-1")
        #expect(first[0].title == "lab: deal at €\u{00A0}100 (\u{2212}50\u{00A0}%)" && first[0].body == "Deal 1 · Krems, Niederösterreich")
        #expect(first[0].moment == .notice(.deal) && first[0].proposal == nil)
        // The next run, the same deal: nothing.
        #expect(t.update(with: calm, deals: list(deal(1)), server: "lab", serverID: server, options: on, now: now + 120).isEmpty)
        #expect(t.update(with: calm, deals: list(deal(1)), server: "lab", serverID: server, options: on, now: now + 240).isEmpty)
    }

    @Test func onlyActDealsCount() {
        var t = learned()
        let out = t.update(with: calm, deals: list(deal(1, .consider), deal(2, .skip), deal(3, nil)), server: "lab", serverID: server,
                           options: on, now: now)
        #expect(out.isEmpty)
        // A deal that was "consider" and is judged "act" later is a new act deal.
        let up = t.update(with: calm, deals: list(deal(1, .act)), server: "lab", serverID: server, options: on, now: now + 60)
        #expect(up.map(\.id) == ["deal-1"])
    }

    @Test func theFirstListOnlyLearns() {
        // Turning the toggle on (or the first run with deals) must not announce the whole week.
        var t = learned(nil)
        #expect(!t.dealsLearned)
        let out = t.update(with: calm, deals: list(deal(1), deal(2)), server: "lab", serverID: server, options: on, now: now)
        #expect(out.isEmpty && t.dealsLearned && t.seenDeals == ["1", "2"])
        let next = t.update(with: calm, deals: list(deal(1), deal(2), deal(3)), server: "lab", serverID: server, options: on, now: now + 60)
        #expect(next.map(\.id) == ["deal-3"])
    }

    @Test func aMissingListChangesNothing() {
        var t = learned(list(deal(1)))
        // A failed request (nil) or a server without deals: no alert, nothing forgotten.
        #expect(t.update(with: calm, deals: nil, server: "lab", serverID: server, options: on, now: now).isEmpty)
        #expect(t.seenDeals == ["1"] && t.dealsLearned)
        // So the connection coming back doesn't make the old deal new.
        #expect(t.update(with: calm, deals: list(deal(1)), server: "lab", serverID: server, options: on, now: now + 60).isEmpty)
    }

    @Test func aStaleDealNeverAlerts() {
        var t = learned()
        let old = deal(1, minutesAgo: 6 * 60 + 1)
        let edge = deal(2, minutesAgo: 6 * 60)
        let none = Deal(id: 3, title: "no time", seen: nil, verdict: .act)
        let out = t.update(with: calm, deals: list(old, edge, none), server: "lab", serverID: server, options: on, now: now)
        #expect(out.map(\.id) == ["deal-2"])
        // And it is not announced later either.
        #expect(t.update(with: calm, deals: list(old, edge, none), server: "lab", serverID: server, options: on, now: now + 60).isEmpty)
    }

    @Test func theOptionTurnsItOff() {
        var t = learned()
        let off = AlertTracker.Options(problems: true, pending: true, deals: false)
        #expect(t.update(with: calm, deals: list(deal(1)), server: "lab", serverID: server, options: off, now: now).isEmpty)
        #expect(AlertTracker.Options().deals == false)
    }

    @Test func noStorm() {
        var t = learned()
        let many = DealList(updated: now, deals: (1...8).map { deal(Int64($0)) })
        let out = t.update(with: calm, deals: many, server: "lab", serverID: server, options: on, now: now)
        #expect(out.count == AlertTracker.maxPerRun)
        #expect(out.last?.kind == .summary && out.last?.body == "6 more new items. Open the app to see them.")
        // All eight are known now.
        #expect(t.update(with: calm, deals: many, server: "lab", serverID: server, options: on, now: now + 60).isEmpty)
    }

    @Test func sharesTheLimitWithProblemsAndActions() {
        var t = learned()
        let s = HomelabState(status: .problem, problems: [Problem(text: "disk full")], pending: [PendingAction(id: "p1", action: "restart", arg: "x")])
        let out = t.update(with: s, deals: list(deal(1), deal(2)), server: "lab", serverID: server, options: on, now: now)
        #expect(out.map(\.kind) == [.problem, .pending, .summary] || out.map(\.kind) == [.problem, .summary])
        #expect(out.count <= AlertTracker.maxPerRun)
    }

    @Test func aLongGapOnlyLearns() {
        var t = learned()
        let later = now + AlertTracker.relearnAfter + 1
        let fresh = Deal(id: 1, title: "x", seen: later.addingTimeInterval(-60), verdict: .act)
        #expect(t.update(with: calm, deals: DealList(updated: later, deals: [fresh]), server: "lab", serverID: server, options: on, now: later).isEmpty)
        #expect(t.seenDeals == ["1"])
    }

    @Test func anotherServerStartsOver() {
        var t = learned(list(deal(1)))
        let other = UUID()
        // The other server: learn only, and its own deals replace the old server's.
        #expect(t.update(with: calm, deals: list(deal(7)), server: "b", serverID: other, options: on, now: now).isEmpty)
        #expect(t.seenDeals == ["7"])
        // Without a list the old server's ids are forgotten (not kept as the new server's).
        var u = learned(list(deal(1)))
        _ = u.update(with: calm, deals: nil, server: "b", serverID: other, options: on, now: now)
        #expect(u.seenDeals.isEmpty && !u.dealsLearned)
        // And the first list afterwards only learns.
        #expect(u.update(with: calm, deals: list(deal(9)), server: "b", serverID: other, options: on, now: now + 60).isEmpty)
    }

    @Test func trackerFilesFromBeforeDealsStillLoad() throws {
        let old = #"{"seenProblems": ["a"], "seenPending": ["p"], "lastRun": 780000000, "serverID": "\#(server.uuidString)"}"#
        let t = try JSONDecoder().decode(AlertTracker.self, from: Data(old.utf8))
        #expect(t.seenProblems == ["a"] && t.seenDeals.isEmpty && !t.dealsLearned && t.serverID == server)
        let back = try JSONDecoder().decode(AlertTracker.self, from: JSONEncoder().encode(learned(list(deal(1)))))
        #expect(back.seenDeals == ["1"] && back.dealsLearned)
        #expect((try JSONDecoder().decode(AlertTracker.self, from: Data("{}".utf8))).seenProblems.isEmpty)
    }

    @Test func titleHasWhatIsKnown() {
        #expect(AlertTracker.dealTitle(Deal(id: 1, title: "t"), server: "lab") == "lab: deal")
        #expect(AlertTracker.dealTitle(Deal(id: 1, title: "t", price: 100), server: "lab") == "lab: deal at €\u{00A0}100")
        #expect(AlertTracker.dealBody(Deal(id: 1, title: "t")) == "t")
    }

    // MARK: What the notification shows

    @Test func theAppLockHidesTheDeal() {
        let alert = AlertTracker.Alert(id: "deal-1", kind: .deal, title: "lab: deal at €\u{00A0}100", body: "Graphics card", moment: .notice(.deal))
        let locked = ProposalNotice.content(for: alert, locked: true, voice: .snarky)
        #expect(locked.title == "Homelab" && locked.body == "A deal is waiting for you." && locked.subtitle == nil && locked.category == nil)
        let open = ProposalNotice.content(for: alert, locked: false, voice: .off)
        #expect(open.title == alert.title && open.body == "Graphics card" && open.subtitle == nil && open.category == nil)
        #expect(ProposalNotice.content(for: alert, locked: false, voice: .dry).subtitle != nil)
    }

    @Test func noButtonsOnADeal() {
        let alert = AlertTracker.Alert(id: "deal-1", kind: .deal, title: "t", body: "b", moment: .notice(.deal))
        #expect(ProposalNotice.content(for: alert, locked: false).category == nil)
        #expect(AlertTracker.Alert.Kind.deal.rawValue == "deal")   // the notification thread
    }

    @Test func voiceHasAnEmptyScreenAndANoticeForDeals() {
        for p in [Personality.dry, .snarky, .ultrakill] {
            #expect(Voice.line(for: .empty(.deals), personality: p, now: now) != nil)
            #expect(Voice.line(.notice(.deal), p, on: now) != nil)
        }
        #expect(Voice.line(for: .empty(.deals), personality: .off, now: now) == nil)
    }
}
