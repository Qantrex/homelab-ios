import Foundation
import Testing
@testable import HomelabKit

/// Checklist and countdown cards, item and card actions, proposals and cards in chat messages (step 3).
@Suite struct CardsTests {
    var vienna: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Vienna")!
        return c
    }

    func at(_ text: String) -> Date { ActionForm.date(text, calendar: vienna)! }

    // MARK: Fixtures

    @Test func fixtureCards() throws {
        let s = try fixture(HomelabState.self, "state-problem.json")
        let todos = try #require(s.cards.first { $0.id == "todos" })
        #expect(todos.style == .checklist && todos.icon == "checklist")
        #expect(todos.action == ItemAction(name: "todo-add", label: "Add", payload: ["list": "todo"]))
        #expect(todos.items.map(\.done) == [nil, nil, nil, true])
        #expect(todos.items[1].action == ItemAction(name: "todo-done", label: "Tick off", payload: ["item": "Milk", "list": "shopping"]))
        #expect(todos.items[3].action == nil)
        #expect(todos.items[0].due == ServerDate.parse("2026-11-04T18:00"))
        #expect(todos.items[2].due.map { Format.isDayOnly($0) } == true)
        let deadlines = try #require(s.cards.first { $0.id == "deadlines" })
        #expect(deadlines.style == .countdown)
        #expect(deadlines.sortedForCountdown.map(\.title) == ["Library books", "Tax return", "Driving lesson", "Project hand-in"])
        let parcels = try #require(s.cards.first { $0.id == "parcels" })
        #expect(parcels.style == .list && parcels.items[0].tint == .orange && parcels.items[1].tint == nil)
        // The last message carries its open proposal.
        #expect(s.lastMessage?.pending.map(\.id) == ["ab12"])
    }

    @Test func fixtureMessages() throws {
        let page = try fixture(MessagePage.self, "messages.json")
        let withCards = try #require(page.messages.first { !$0.cards.isEmpty })
        #expect(withCards.job == "chat" && withCards.cards.map(\.id) == ["media-now"])
        #expect(withCards.cards[0].style == .metrics && withCards.cards[0].items.count == 3)
        let proposal = try #require(page.messages.last)
        #expect(proposal.pending.map(\.id) == ["ab12"] && proposal.pending[0].buttons.count == 3)
        // The same signed buttons as the state's pending list, so they work against the fixture server.
        let state = try fixture(HomelabState.self, "state-problem.json")
        #expect(proposal.pending[0] == state.pending[0])
        #expect(page.messages.filter { $0.pending.isEmpty && $0.cards.isEmpty }.count == 2)
    }

    // MARK: Decoding

    @Test func oddItemActionsAreReadLeniently() throws {
        let c = try decode(Card.self, """
        {"id": "c", "style": "CHECKLIST", "action": {"name": "Bad Name", "label": "x"},
         "items": [{"title": "a", "done": "yes", "due": "2026-11-07", "action": {"name": "todo-done", "arg": 5,
                    "payload": {"item": "a", "n": 3, "list": ["x"], "ok": "y"}}},
                   {"title": "b", "done": 0, "due": "soon", "action": "todo-done"},
                   {"title": "c", "action": {"label": "no name"}}]}
        """)
        #expect(c.style == .checklist && c.action == nil)
        #expect(c.items.map(\.title) == ["a", "b", "c"])
        #expect(c.items[0].done == true && c.items[1].done == false)
        #expect(c.items[0].due != nil && c.items[1].due == nil)
        #expect(c.items[0].action == ItemAction(name: "todo-done", arg: "5", payload: ["item": "a", "ok": "y"]))
        #expect(c.items[1].action == nil && c.items[2].action == nil)
        #expect(try decode(Card.self, #"{"id": "x", "style": "countdown"}"#).style == .countdown)
        #expect(try decode(Card.self, #"{"id": "x", "style": "kanban"}"#).style == .list)
    }

    @Test func oddMessageExtrasAreReadLeniently() throws {
        let m = try decode(ChatMessage.self, """
        {"id": 7, "from": "agent", "text": "x", "pending": [{"id": "a"}, {"nope": 1}, {"id": "a"}, "str"],
         "cards": {"id": "not a list"}}
        """)
        #expect(m.pending.map(\.id) == ["a"] && m.cards.isEmpty)
        let plain = try decode(ChatMessage.self, #"{"id": 8, "text": "y"}"#)
        #expect(plain.pending.isEmpty && plain.cards.isEmpty)
    }

    @Test func roundTripsThroughTheCache() throws {
        let s = try fixture(HomelabState.self, "state-problem.json")
        let again = try JSONDecoder().decode(HomelabState.self, from: Storage.encoder.encode(s))
        #expect(again.cards == s.cards)
        #expect(again.lastMessage == s.lastMessage)
        let page = try fixture(MessagePage.self, "messages.json")
        let back = try JSONDecoder().decode(MessagePage.self, from: Storage.encoder.encode(page))
        #expect(back.messages == page.messages)
        // Old shape stays old: no empty lists written for plain messages and items.
        let plain = String(decoding: try Storage.encoder.encode(ChatMessage(id: 1, from: .me, text: "hi")), as: UTF8.self)
        #expect(!plain.contains("pending") && !plain.contains("cards"))
        let item = String(decoding: try Storage.encoder.encode(Card.Item(title: "x")), as: UTF8.self)
        #expect(!item.contains("due") && !item.contains("action") && !item.contains("done"))
    }

    // MARK: Format

    @Test func countdownValues() {
        let now = at("2026-11-06T15:00")
        func c(_ due: String) -> String {
            let r = Format.countdown(at(due), now: now, calendar: vienna)
            return "\(r.text)|\(r.level.rawValue)"
        }
        #expect(c("2026-11-06") == "today|soon")
        #expect(c("2026-11-07") == "1 d|later")
        #expect(c("2026-11-08") == "2 d|later")
        #expect(c("2026-11-03") == "3 d ago|past")
        #expect(c("2026-11-06T15:40") == "40 min|soon")
        #expect(c("2026-11-06T15:00") == "1 min|soon")
        #expect(c("2026-11-06T20:30") == "5 h|soon")
        #expect(c("2026-11-07T14:59") == "23 h|soon")
        #expect(c("2026-11-07T15:00") == "1 d|later")
        #expect(c("2026-11-08T09:00") == "2 d|later")
        #expect(c("2026-11-06T14:20") == "40 min ago|past")
        #expect(c("2026-11-06T12:00") == "3 h ago|past")
        #expect(c("2026-11-05T09:00") == "1 d ago|past")
        #expect(c("2026-11-03T18:00") == "3 d ago|past")
    }

    @Test func dueValues() {
        let now = at("2026-11-06T15:00")   // a Friday
        func d(_ due: String) -> String { Format.due(at(due), now: now, calendar: vienna) }
        #expect(d("2026-11-06") == "today" && d("2026-11-06T18:00") == "today 18:00")
        #expect(d("2026-11-07T09:00") == "tomorrow 09:00" && d("2026-11-05") == "yesterday")
        #expect(d("2026-11-09") == "Mon" && d("2026-11-12T18:00") == "Thu 18:00")
        #expect(d("2026-11-13") == "13.11." && d("2026-11-20T08:30") == "20.11. 08:30")
        #expect(d("2026-11-02") == "4 d ago")
        #expect(Format.isDayOnly(at("2026-11-06"), calendar: vienna) && !Format.isDayOnly(at("2026-11-06T00:01"), calendar: vienna))
    }

    @Test func countdownOrder() {
        let card = Card(id: "d", style: .countdown, items: [
            .init(title: "none"), .init(title: "late", due: at("2026-11-09")), .init(title: "past", due: at("2026-11-01")),
            .init(title: "none2"), .init(title: "tie-a", due: at("2026-11-07")), .init(title: "tie-b", due: at("2026-11-07")),
        ])
        #expect(card.sortedForCountdown.map(\.title) == ["past", "tie-a", "tie-b", "late", "none", "none2"])
    }

    // MARK: Prefilled forms

    func spec(_ name: String) throws -> ActionSpec {
        try #require(try fixture(ActionList.self, "actions.json").actions.first { $0.name == name })
    }

    @Test func prefillFromPayload() throws {
        let now = at("2026-11-06T15:00")
        let tick = ItemAction(name: "todo-done", label: "Tick off", payload: ["item": "Milk", "list": "shopping", "evil": "x"])
        let form = ActionForm(try spec("todo-done"), prefill: tick, now: now, calendar: vienna)
        #expect(form.fieldValues == ["item": "Milk", "list": "shopping"])
        #expect(form.isReady && form.payload == ["item": "Milk", "list": "shopping"] && form.arg == "")
        let add = ActionForm(try spec("todo-add"), prefill: ItemAction(name: "todo-add", payload: ["list": "shopping"]),
                             now: now, calendar: vienna)
        #expect(add.fieldValues["list"] == "shopping" && add.problems == ["To-do is missing."])
        // No prefill: the same as the plain form.
        #expect(ActionForm(try spec("calendar-add"), prefill: nil, now: now, calendar: vienna)
            == ActionForm(try spec("calendar-add"), now: now, calendar: vienna))
    }

    @Test func prefillSplitsTheArgument() throws {
        let now = at("2026-11-06T15:00")
        func form(_ name: String, _ arg: String) throws -> ActionForm {
            ActionForm(try spec(name), prefill: ItemAction(name: name, arg: arg), now: now, calendar: vienna)
        }
        let off = try form("wake-set", "2026-11-09:off")
        #expect(off.variant == 1 && off.arg == "2026-11-09:off")
        let wake = try form("wake-set", "2026-11-10T06:15")
        #expect(wake.variant == 0 && wake.value(part: 0) == "2026-11-10" && wake.value(part: 2) == "06:15")
        let restart = try form("restart-container", "pi:sonarr")
        #expect(restart.arg == "pi:sonarr" && restart.isReady)
        let way = try form("commute-mode", "2026-11-07:u6")
        #expect(way.arg == "2026-11-07:u6")
        // An argument that fits no variant is ignored: the usual starting picks stay.
        let odd = try form("wake-set", "next tuesday")
        #expect(odd.variant == 0 && odd.arg == "2026-11-07T07:00")
        #expect(try form("commute-mode", "2026-11-07:car").arg == "2026-11-07:bike")
        #expect(try form("restart-container", "media:sonarr").arg == nil)   // host not offered
    }
}

@MainActor @Suite(.serialized) struct ItemActionModelTests {
    @Test func startableAndRun() async throws {
        let (m, server, _, _) = makeModel()
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        let tick = ItemAction(name: "todo-done", label: "Tick off", payload: ["item": "Milk", "list": "shopping"])
        #expect(m.startable(tick) == nil)   // before the server listed its actions
        await m.refresh()
        #expect(m.startable(tick)?.name == "todo-done")
        #expect(m.startable(nil) == nil && m.startable(ItemAction(name: "launch-rocket")) == nil)

        let before = server.calls("/api/v1/state")
        let result = await m.run(tick, on: lab)
        #expect(result == .success(ActionResult(ok: true, text: "Ticked off")))
        #expect(server.calls("/api/v1/state") == before + 1)
        let sent = try #require(server.transport.requests.first { $0.url?.path == "/api/v1/actions/todo-done" })
        let body = try #require(sent.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["payload"] as? [String: String] == ["item": "Milk", "list": "shopping"])
        #expect(body["arg"] as? String == "")

        #expect(await m.run(ItemAction(name: "launch-rocket"), on: lab) == .failure(.notFound))
        // A required field the item doesn't fill never reaches the server.
        #expect(await m.run(ItemAction(name: "todo-done"), on: lab) == .failure(.badRequest("Item is missing.")))
        #expect(server.calls("/api/v1/actions/todo-done") == 1)
    }
}

@Suite struct DemoCardsTests {
    @Test func dueTimesFollowTheClock() async throws {
        let now = Date()
        let demo = DemoBackend(delay: .zero, now: now)
        let state = try await demo.state()
        let todos = try #require(state.cards.first { $0.id == "todos" })
        // "Call the plumber" was due 3 h 28 min before the fixture's check, which is 2 min ago now.
        let plumber = try #require(todos.items[0].due)
        #expect(abs(plumber.timeIntervalSince(now) + (3 * 3600 + 28 * 60 + 120)) < 2)
        // Day-only dues stay on midnight, moved by whole days: the 2026-11-06 item is two days after the check.
        let deadlines = try #require(state.cards.first { $0.id == "deadlines" })
        let days = deadlines.items.compactMap(\.due).filter { Format.isDayOnly($0) }
        #expect(days.count == 3)
        let tax = try #require(deadlines.items.first { $0.title == "Tax return" }?.due)
        #expect(Calendar.current.isDate(tax, inSameDayAs: now.addingTimeInterval(-120)))
        #expect(Format.countdown(tax, now: now.addingTimeInterval(-120)).text == "today")
        // Chat extras move along too.
        let msgs = try await demo.messages(after: 0).messages
        #expect(msgs.last?.pending.first?.created.map { $0 < now } == true)
    }

    @Test func answeringAProposalClearsTheBubble() async throws {
        let demo = DemoBackend(delay: .zero)
        #expect(try await demo.messages(after: 0).messages.last?.pending.count == 1)
        #expect(try await demo.state().lastMessage?.pending.count == 1)
        _ = try await demo.press("HOMELAB_DENY_ab12_2123456789abcdef")
        #expect(try await demo.messages(after: 0).messages.allSatisfy { $0.pending.isEmpty })
        #expect(try await demo.state().lastMessage?.pending.isEmpty == true)
    }

    @Test func openPendingFollowsANewerState() throws {
        let page = try fixture(MessagePage.self, "messages.json")
        var state = try fixture(HomelabState.self, "state-problem.json")
        let m = try #require(page.messages.last)
        let ts = try #require(m.ts)
        let id = UUID()
        // No state, or one older than the message: the message's own list.
        #expect(m.openPending(in: nil).map(\.id) == ["ab12"])
        state.pending = []
        let older = Snapshot(serverID: id, serverName: "x", state: state, fetched: ts.addingTimeInterval(-60))
        #expect(m.openPending(in: older).map(\.id) == ["ab12"])
        // A newer state without the proposal: answered, no buttons.
        let newer = Snapshot(serverID: id, serverName: "x", state: state, fetched: ts.addingTimeInterval(60))
        #expect(m.openPending(in: newer).isEmpty)
        state.pending = try fixture(HomelabState.self, "state-problem.json").pending
        let stillOpen = Snapshot(serverID: id, serverName: "x", state: state, fetched: ts.addingTimeInterval(60))
        #expect(m.openPending(in: stillOpen).map(\.id) == ["ab12"])
    }

    @Test func tickingOffInTheDemo() async throws {
        let demo = DemoBackend(delay: .zero)
        let r = try await demo.run("todo-done", arg: "", payload: ["item": "Milk", "list": "shopping"])
        #expect(r.ok)
        let todos = try #require(try await demo.state().cards.first { $0.id == "todos" })
        let milk = try #require(todos.items.first { $0.title == "Milk" })
        #expect(milk.done == true && milk.action == nil)
    }
}
