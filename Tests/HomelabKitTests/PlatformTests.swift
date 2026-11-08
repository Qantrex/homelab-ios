import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HomelabKit

/// Links with prefill (`ActionLink`), the Home-screen quick actions (`ActionUsage`, `HomeShortcuts`) and Approve /
/// Deny on notifications (`ProposalNotice`).
@Suite struct ActionLinkTests {
    private func specs() throws -> [String: ActionSpec] {
        let list = try fixture(ActionList.self, "actions.json").actions
        return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
    }

    private func link(_ s: String) -> ActionLink? { URL(string: s).flatMap(ActionLink.init) }

    @Test func parsesNameArgAndFields() throws {
        let l = try #require(link("homelab://actions/todo-add?summary=Buy%20milk&list=shopping&due=&summary=second"))
        #expect(l.name == "todo-add" && l.arg == "")
        #expect(l.values == ["summary": "Buy milk", "list": "shopping"])   // empty ignored, the first duplicate counts
        let w = try #require(link("homelab://actions/wake-set?arg=%202026-11-07T07:30%20"))
        #expect(w.arg == "2026-11-07T07:30" && w.values.isEmpty)        // trimmed
        #expect(link("homelab://actions/wake-set")?.values == [:])
        #expect(link("homelab://ACTIONS/wake-set")?.name == "wake-set")
        #expect(link("homelab://actions/C%2B%2B?x=1") == nil)           // not a valid action name
    }

    @Test func refusesOtherLinks() {
        for s in ["https://actions/wake-set", "homelab://chat/wake-set", "homelab://actions", "homelab://actions/a/b",
                  "homelab://actions/..%2Fstate", "homelab://actions/Wake-Set", "homelab://scan"] {
            #expect(link(s) == nil, "\(s)")
        }
    }

    @Test func plusStaysAPlusAndOverlongValuesAreDropped() throws {
        #expect(link("homelab://actions/todo-add?summary=C++")?.values["summary"] == "C++")
        let long = String(repeating: "a", count: ActionLink.maxValue + 1)
        #expect(link("homelab://actions/todo-add?summary=\(long)")?.values.isEmpty == true)
        // At most `maxItems` query items are read.
        let many = (0..<40).map { "f\($0)=x" }.joined(separator: "&")
        #expect(link("homelab://actions/todo-add?\(many)")?.values.count == ActionLink.maxItems)
    }

    @Test func urlRoundTrips() throws {
        let l = ActionLink(name: "todo-add", arg: "", values: ["summary": "Milk & eggs + C++ = 100%", "list": "shopping"])
        let url = try #require(l.url)
        #expect(url.absoluteString.hasPrefix("homelab://actions/todo-add?list=shopping&summary="))
        #expect(ActionLink(url) == l)
        #expect(ActionLink(name: "wake-set").url?.absoluteString == "homelab://actions/wake-set")
    }

    @Test func prefillFillsTheFormLikeACard() throws {
        let s = try specs()
        let todo = try #require(link("homelab://actions/todo-add?summary=Milk&list=shopping&description=2%20l"))
        let form = todo.form(for: try #require(s["todo-add"]))
        #expect(form.payload == ["summary": "Milk", "list": "shopping", "description": "2 l"])
        #expect(form.isReady)

        let wakeSpec = try #require(s["wake-set"])
        let w = try #require(link("homelab://actions/wake-set?arg=2026-11-07T07:30")).form(for: wakeSpec)
        #expect(w.variant == 0 && w.arg == "2026-11-07T07:30")
        let off = try #require(link("homelab://actions/wake-set?arg=2026-11-07:off")).form(for: wakeSpec)
        #expect(off.variant == 1 && off.arg == "2026-11-07:off")
        // An argument that fits no variant is ignored: the form starts as from a Start tile.
        let bad = try #require(link("homelab://actions/wake-set?arg=tomorrow")).form(for: wakeSpec)
        #expect(bad.variant == 0 && bad == ActionForm(wakeSpec))
    }

    @Test func linksNeverFillHiddenFieldsUnknownNamesOrBadChoices() throws {
        let s = try specs()
        let done = try #require(s["todo-done"])
        let l = try #require(link("homelab://actions/todo-done?item=Milk&uid=abc-123&list=fridge&evil=1"))
        let prefill = try #require(l.prefill(for: done))
        #expect(prefill.payload == ["item": "Milk"])                    // no uid, no unknown, no bad choice
        #expect(l.form(for: done).payload == ["item": "Milk"])
        #expect(l.prefill(for: try #require(s["todo-add"])) == nil)      // another action's spec
        // An argument longer than the server takes is dropped.
        let long = String(repeating: "a", count: ActionForm.maxArg + 1)
        #expect(ActionLink(name: "parcel-done", arg: long).prefill(for: try #require(s["parcel-done"]))?.arg == "")
    }
}

@MainActor @Suite(.serialized) struct ActionLinkModelTests {
    @Test func linkPrefillReachesTheRequestedForm() async throws {
        let (m, _, _, _) = makeModel(FakeServer())
        try m.save(ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity), token: nil)
        m.open(URL(string: "homelab://actions/todo-add?summary=Milk&list=shopping")!)
        #expect(m.openAction == "todo-add" && m.openActionLink?.values["summary"] == "Milk")
        #expect(m.takeOpenActionForm() == nil)                         // the list isn't loaded yet: waits
        await m.refresh()
        m.validateTab()
        let request = try #require(m.takeOpenActionForm())
        #expect(request.spec.name == "todo-add")
        #expect(request.prefill?.payload == ["summary": "Milk", "list": "shopping"])
        #expect(m.openAction == nil && m.openActionLink == nil)

        // A plain link replaces the waiting one, values and all; a launch-style request has no prefill.
        m.open(URL(string: "homelab://actions/todo-add?summary=Eggs")!)
        m.open(URL(string: "homelab://actions/wake-set")!)
        #expect(try #require(m.takeOpenActionForm()).prefill == ItemAction(name: "wake-set"))
        m.open(URL(string: "homelab://actions/todo-add?summary=Eggs")!)
        m.openAction = "wake-set"                                      // someone else's request: the link's values don't apply
        #expect(try #require(m.takeOpenActionForm()).prefill == nil)

        // Card-only actions can't be opened by a link (they need their card's hidden values).
        m.open(URL(string: "homelab://actions/todo-done?item=Milk&uid=1")!)
        #expect(m.takeOpenActionForm() == nil && m.openAction == nil && m.openActionLink == nil)

        // Picking a tab by hand ends the request, values included.
        m.open(URL(string: "homelab://actions/todo-add?summary=Eggs")!)
        m.pick(.chat)
        #expect(m.openAction == nil && m.openActionLink == nil)
    }

    @Test func startsAndStartListsFeedTheQuickActions() async throws {
        let (m, server, storage, _) = makeModel(FakeServer())
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        var changes = 0
        m.onQuickActionsChange = { changes += 1 }
        await m.refresh()
        let usage = try #require(storage.read(ActionUsage.self, ActionUsage.fileName))
        // Only Start actions, in the server's order (no todo-done, parcel-done).
        #expect(usage.top(server: lab.id).map(\.name) == ["todo-add", "dns-pause", "calendar-add"])
        #expect(changes == 1)

        var form = ActionForm(try #require(m.selectedStatus.actions.first { $0.name == "ha-control" }))
        form.values[0][0] = "lamps-on"
        _ = await m.run(form, on: lab)                                 // 404 on the fake server, but it was started
        let after = try #require(storage.read(ActionUsage.self, ActionUsage.fileName))
        #expect(after.top(server: lab.id).first?.name == "ha-control")
        #expect(changes == 2)
        let items = HomeShortcuts.items(after, server: lab.id)
        #expect(items.map(\.link.absoluteString) == ["homelab://actions/ha-control", "homelab://actions/todo-add",
                                                       "homelab://actions/dns-pause"])
        #expect(items.first?.title == "Living room" && items.first?.icon == "lightbulb")

        // A hidden Start tile is no quick action.
        let hiddenItems = HomeShortcuts.items(after, server: lab.id, tiles: ItemOrder(order: [], hidden: ["ha-control"]))
        #expect(hiddenItems.map(\.link.absoluteString) == ["homelab://actions/todo-add", "homelab://actions/dns-pause",
                                                           "homelab://actions/calendar-add"])

        // The same list again writes nothing.
        await m.refresh()
        #expect(changes == 2)
        _ = server
    }
}

@Suite struct ActionUsageTests {
    let server = UUID()
    let offered = [ActionUsage.Offered(name: "a", label: "A"), ActionUsage.Offered(name: "b", label: "B"),
                   ActionUsage.Offered(name: "c", label: "C"), ActionUsage.Offered(name: "d", label: "D")]

    @Test func rankingByCountThenRecencyThenServerOrder() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(ActionUsage.ranked(offered, counts: [:], limit: 3).map(\.name) == ["a", "b", "c"])
        let counts: [String: ActionUsage.Entry] = [
            "c": .init(count: 2, last: t0), "d": .init(count: 2, last: t0.addingTimeInterval(60)),
            "b": .init(count: 1, last: t0), "gone": .init(count: 9, last: t0),
        ]
        #expect(ActionUsage.ranked(offered, counts: counts, limit: 3).map(\.name) == ["d", "c", "b"])
        #expect(ActionUsage.ranked(offered, counts: counts, limit: 10).map(\.name) == ["d", "c", "b", "a"])
        #expect(ActionUsage.ranked(offered, counts: counts, limit: -1).isEmpty)
    }

    @Test func recordsPerServerAndOnlyStartActions() throws {
        var u = ActionUsage()
        let other = UUID()
        let first = u.setOffered([ActionSpec(name: "a"), ActionSpec(name: "hidden", start: false),
                                  ActionSpec(name: "b", label: "Bee", icon: "b.circle")], server: server)
        let again = u.setOffered([ActionSpec(name: "a"), ActionSpec(name: "b", label: "Bee", icon: "b.circle")], server: server)
        #expect(first && !again)
        #expect(u.offered[server.uuidString.lowercased()]?.map(\.name) == ["a", "b"])
        u.record("b", server: server, at: Date(timeIntervalSince1970: 1_000_000))   // storage keeps whole seconds
        u.record("a", server: other, at: Date(timeIntervalSince1970: 1_000_000))
        u.record("../bad", server: server)
        #expect(u.top(server: server).map(\.name) == ["b", "a"])
        #expect(u.top(server: other).isEmpty)                           // nothing offered there
        #expect(u.counts[server.uuidString.lowercased()]?.keys.sorted() == ["b"])

        // Survives storage, forgets removed servers.
        let storage = Storage(directory: temporaryDirectory())
        try storage.write(u, ActionUsage.fileName)
        var back = try #require(storage.read(ActionUsage.self, ActionUsage.fileName))
        #expect(back == u)
        back.keep(servers: [server])
        #expect(back.counts.count == 1 && back.offered.count == 1)
        let cleared = u.setOffered([], server: server)
        #expect(cleared && u.offered.isEmpty)
    }

    @Test func keepsAtMostMaxNamesPerServer() {
        var u = ActionUsage()
        let t0 = Date(timeIntervalSince1970: 0)
        u.record("keep", server: server, at: t0)
        u.record("keep", server: server, at: t0)
        for i in 0..<(ActionUsage.maxNames + 5) { u.record("n\(i)", server: server, at: t0.addingTimeInterval(Double(i))) }
        let names = u.counts[server.uuidString.lowercased()] ?? [:]
        #expect(names.count == ActionUsage.maxNames)
        #expect(names["keep"]?.count == 2)                              // the most used stays
        #expect(names["n0"] == nil)                                     // the oldest single uses go
    }

    @Test func shortcutLinks() {
        #expect(HomeShortcuts.link(type: HomeShortcuts.scanType, userInfo: nil)?.absoluteString == "homelab://scan")
        #expect(HomeShortcuts.link(type: HomeShortcuts.actionType, userInfo: ["link": "homelab://actions/wake-set"])?
            .absoluteString == "homelab://actions/wake-set")
        // Only the action's plain link, whatever else the item carries.
        #expect(HomeShortcuts.link(type: HomeShortcuts.actionType, userInfo: ["link": "homelab://actions/todo-add?uid=1"])?
            .absoluteString == "homelab://actions/todo-add")
        #expect(HomeShortcuts.link(type: HomeShortcuts.actionType, userInfo: ["link": "https://evil.example"]) == nil)
        #expect(HomeShortcuts.link(type: HomeShortcuts.actionType, userInfo: nil) == nil)
        #expect(HomeShortcuts.link(type: "other", userInfo: ["link": "homelab://actions/wake-set"]) == nil)
        #expect(HomeShortcuts.items(ActionUsage(), server: nil).isEmpty)
    }
}

@Suite struct ProposalNoticeTests {
    let server = UUID()

    private func state() throws -> HomelabState { try fixture(HomelabState.self, "state-pending.json") }

    @Test func categoriesFollowTheButtons() throws {
        let p = try state().pending
        #expect(ProposalNotice.category(for: p[0]) == .approveDeny)   // Always stays in the app
        #expect(ProposalNotice.category(for: p[3]) == nil)            // information only
        #expect(ProposalNotice.category(for: PendingAction(id: "x", buttons: [.approve: "s"])) == .approve)
        #expect(ProposalNotice.category(for: PendingAction(id: "x", buttons: [.deny: "s", .always: "t"])) == .deny)
        #expect(ProposalNotice.Category.approveDeny.verbs == [.approve, .deny])
        #expect(Set(ProposalNotice.Category.allCases.map(\.rawValue)).count == 3)
    }

    /// Owner, 2026-11-06: with the app lock on, a proposal keeps Approve / Deny (iOS asks for Face ID before a press)
    /// and may name its action (iOS hides previews on the locked lock screen by default). Everything else stays vague.
    @Test func withTheLockOnlyAnswerableProposalsNameTheirAction() throws {
        let p = try state().pending
        let proposal = AlertTracker.Alert(id: "pending-pa01", kind: .pending, title: "lab: approve \(p[0].title)?",
                                          body: "Disk almost full.", moment: .notice(.waiting), proposal: p[0])
        let open = ProposalNotice.content(for: proposal, locked: false, voice: .snarky)
        #expect(open.title == proposal.title && open.body == "Disk almost full." && open.category == .approveDeny)
        #expect(open.subtitle != nil)                                    // the personality's line
        let locked = ProposalNotice.content(for: proposal, locked: true, voice: .snarky)
        #expect(locked.title == proposal.title && locked.body == "Disk almost full.")
        #expect(locked.category == .approveDeny && locked.subtitle == nil)

        // Information only (no buttons): nothing to answer on the lock screen, so it stays vague.
        let info = AlertTracker.Alert(id: "pending-pa04", kind: .pending, title: "lab: approve \(p[3].title)?",
                                      body: "Reboot.", moment: .notice(.waiting), proposal: p[3])
        let lockedInfo = ProposalNotice.content(for: info, locked: true)
        #expect(lockedInfo == .init(title: "Homelab", subtitle: nil, body: "An action is waiting for you.", category: nil))
        #expect(ProposalNotice.content(for: info, locked: false).title == info.title)

        // Problems and the summary: vague with the lock on, as before.
        let problem = AlertTracker.Alert(id: "problem-1", kind: .problem, title: "lab: problem", body: "nas: disk 97%",
                                         moment: .notice(.problem))
        let lockedProblem = ProposalNotice.content(for: problem, locked: true, voice: .snarky)
        #expect(lockedProblem == .init(title: "Homelab", subtitle: nil, body: "Something needs a look.", category: nil))
        let summary = AlertTracker.Alert(id: "summary-1", kind: .summary, title: "lab", body: "3 more new items.")
        #expect(ProposalNotice.content(for: summary, locked: true).body == "Something needs a look.")
        #expect(ProposalNotice.content(for: problem, locked: false).body == "nas: disk 97%")
    }

    @Test func requestsComeOnlyFromOurButtonsAndIds() {
        let info = ProposalNotice.userInfo(server: server, proposal: "pa01") as [AnyHashable: Any]
        #expect(info.values.allSatisfy { !"\($0)".contains("HOMELAB_") })          // no signed button in it
        #expect(ProposalNotice.Request(actionID: ProposalNotice.approveAction, userInfo: info)
                == .init(server: server, proposal: "pa01", verb: .approve))
        #expect(ProposalNotice.Request(actionID: ProposalNotice.denyAction, userInfo: info)?.verb == .deny)
        #expect(ProposalNotice.Request(actionID: "com.apple.UNNotificationDefaultActionIdentifier", userInfo: info) == nil)
        #expect(ProposalNotice.Request(actionID: ProposalNotice.approveAction, userInfo: ["link": "homelab://actions"]) == nil)
        #expect(ProposalNotice.Request(actionID: ProposalNotice.approveAction,
                                       userInfo: ["server": "nope", "proposal": "pa01"]) == nil)
        #expect(ProposalNotice.actionID(.always) == nil && ProposalNotice.actionID(.deny) == ProposalNotice.denyAction)
    }

    @Test func pressUsesTheCachedButtonAndFallsBackToAFreshState() async throws {
        let server = FakeServer()
        server.state = "state-pending.json"
        let api = CompanionClient(config: ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity),
                                  tokens: MemoryTokenStore(), transport: server.transport)
        let cached = try state()
        let out = await ProposalNotice.press(.init(server: self.server, proposal: "pa02", verb: .deny), api: api,
                                             cached: cached, host: "lab")
        #expect(out == .init(title: "apt-upgrade server", result: .success("done")))
        #expect(server.calls("/api/v1/state") == 0)                    // the cached button was enough
        #expect(bodyJSON(server.transport.last) == ["action": "HOMELAB_DENY_pa02_b000000000000003"])

        // Not cached (or no such button there): a fresh state. The press above made the fake server's state empty.
        let gone = await ProposalNotice.press(.init(server: self.server, proposal: "pa01", verb: .approve), api: api,
                                              cached: nil, host: "lab")
        #expect(server.calls("/api/v1/state") == 1)
        #expect(gone.result == .failure(.forbidden) && gone.title == nil)
        server.state = "state-pending.json"
        let fresh = await ProposalNotice.press(.init(server: self.server, proposal: "pa04", verb: .approve), api: api,
                                               cached: cached, host: "lab")
        #expect(fresh.result == .failure(.forbidden) && fresh.title == "reboot server")   // information only
    }

    @Test func pressReportsAConnectionFailure() async throws {
        let api = CompanionClient(config: ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity),
                                  tokens: MemoryTokenStore(), transport: FakeTransport(error: URLError(.notConnectedToInternet)))
        let out = await ProposalNotice.press(.init(server: server, proposal: "pa01", verb: .approve), api: api,
                                             cached: nil, host: "lab")
        guard case .failure = out.result else { Issue.record("expected a failure"); return }
    }

    @Test func messagesSayWhatHappenedAndHideDetailsWhenLocked() {
        let ok = ProposalNotice.Outcome(title: "restart server jellyfin", result: .success("Restarted jellyfin.\n\nAll good."))
        let shown = ProposalNotice.message(ok, verb: .approve, server: "lab", hidden: false, hasChat: true)
        #expect(shown.title == "lab: approved restart server jellyfin" && shown.body == "Restarted jellyfin. All good.")
        #expect(ProposalNotice.message(ok, verb: .deny, server: "lab", hidden: false, hasChat: true).title
                == "lab: denied restart server jellyfin")
        let hidden = ProposalNotice.message(ok, verb: .approve, server: "lab", hidden: true, hasChat: true)
        #expect(hidden.title == "Homelab" && !hidden.body.contains("jellyfin") && hidden.body.hasPrefix("Approved"))

        let spent = ProposalNotice.Outcome(title: "restart server jellyfin", result: .failure(.forbidden))
        let s = ProposalNotice.message(spent, verb: .approve, server: "lab", hidden: false, hasChat: false)
        #expect(s.title == "lab: no longer valid" && s.body.hasPrefix("Approve restart server jellyfin: This button"))
        let sh = ProposalNotice.message(spent, verb: .approve, server: "lab", hidden: true, hasChat: false)
        #expect(sh.title == "Homelab" && !sh.body.contains("jellyfin"))

        let long = ProposalNotice.Outcome(title: nil, result: .success(String(repeating: "x", count: 500)))
        let l = ProposalNotice.message(long, verb: .approve, server: "lab", hidden: false, hasChat: false)
        #expect(l.title == "lab: approved the action" && l.body.count == ProposalNotice.maxBody && l.body.hasSuffix("…"))
        #expect(ProposalNotice.message(.init(title: "x", result: .success("")), verb: .approve, server: "lab",
                                       hidden: false, hasChat: false).body == "Done.")
    }

    @Test func pendingAlertsCarryTheirProposal() throws {
        var tracker = AlertTracker()
        let now = Date()
        _ = tracker.update(with: HomelabState(), server: "lab", serverID: server, now: now)   // learns first
        let alerts = tracker.update(with: try state(), server: "lab", serverID: server,
                                    options: .init(problems: false, pending: true), now: now.addingTimeInterval(60))
        let pending = alerts.filter { $0.kind == .pending }
        #expect(!pending.isEmpty && pending.allSatisfy { $0.proposal.map { "pending-\($0.id)" } == $0.id })
    }
}
