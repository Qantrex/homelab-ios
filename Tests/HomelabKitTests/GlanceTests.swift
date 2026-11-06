import Foundation
import Testing
@testable import HomelabKit

/// Step 6c: the commute plan, the Live Activity decision, the departures board, the widget policy.
@Suite struct GlanceTests {
    static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// 2026-11-07 at hh:mm UTC.
    static func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        Date(timeIntervalSince1970: 1_794_009_600 + Double(h * 3600 + m * 60 + s))
    }

    static func plan(mode: String? = "u6", date: String = "2026-11-07") -> CommutePlan {
        CommutePlan(date: date, mode: mode, line: "U6", firstLesson: at(8, 0), leaveBy: at(7, 26), train: at(7, 31),
                    next: at(7, 36), nextTooLate: true, disruptions: ["U6: Schadhaftes Fahrzeug", "U6: Zweite"])
    }

    func decide(_ plan: CommutePlan?, _ now: Date, running: LeaveContent? = nil, fg: Bool = true, on: Bool = true) -> LeavePlan.Decision {
        LeavePlan.decide(plan: plan, now: now, running: running, foreground: fg, enabled: on, calendar: Self.utc)
    }

    // MARK: Models

    @Test func departuresFixtureDecodes() throws {
        let s = try fixture(HomelabState.self, "state-departures.json")
        let card = try #require(s.departuresCard)
        #expect(card.style == .departures && card.tint == .red && card.text == "U6: Schadhaftes Fahrzeug")
        #expect(card.items.count == 8 && card.items.allSatisfy { $0.due != nil })
        let c = try #require(s.commute)
        #expect(c.date == "2026-11-07" && c.nextTooLate && c.disruptions == ["U6: Schadhaftes Fahrzeug"])
        // Times keep their zone: 07:26 in +01:00 is 06:26 UTC.
        #expect(c.leaveBy == Self.at(6, 26) && c.firstLesson == Self.at(7, 0))
        let again = try JSONDecoder().decode(CommutePlan.self, from: JSONEncoder().encode(c))
        #expect(again == c)
    }

    @Test func problemFixtureHasBoth() throws {
        let s = try fixture(HomelabState.self, "state-problem.json")
        #expect(s.departuresCard != nil && s.commute?.mode == "u6")
    }

    @Test func commuteMissingOrBrokenIsNil() throws {
        #expect(try decode(HomelabState.self, #"{"status": "ok"}"#).commute == nil)
        #expect(try decode(HomelabState.self, #"{"status": "ok", "commute": "soon"}"#).commute == nil)
        #expect(try decode(HomelabState.self, #"{"status": "ok", "commute": {"mode": "u6"}}"#).commute == nil)
        #expect(try decode(HomelabState.self, #"{"status": "ok", "commute": {"date": "yesterday"}}"#).commute == nil)
        let odd = try decode(HomelabState.self, #"{"commute": {"date": "2026-11-07", "leave_by": "x", "disruptions": 3, "ride": "25"}}"#)
        #expect(odd.commute?.leaveBy == nil && odd.commute?.disruptions == [] && odd.commute?.ride == 25)
        // Other states, and an unknown card style (old code paths) still read.
        let old = try decode(HomelabState.self, #"{"cards": [{"id": "x", "style": "rockets"}]}"#)
        #expect(old.cards.first?.style == .list)
    }

    @Test func errorAndInactiveShapes() throws {
        let e = try decode(CommutePlan.self, #"{"date": "2026-11-07", "error": "no data"}"#)
        #expect(e.error == "no data" && e.leaveContent == nil)
        let n = try decode(CommutePlan.self, #"{"date": "2026-11-07", "active": false, "why": "holiday"}"#)
        #expect(n.active == false && n.why == "holiday" && n.leaveContent == nil)
    }

    // MARK: Decision

    @Test func startWindow() {
        let p = Self.plan()
        #expect(decide(p, Self.at(5, 55)) == .none)                    // 91 min before 07:26
        if case .start(let c) = decide(p, Self.at(5, 56)) {            // 90 min before
            #expect(c.leaveBy == Self.at(7, 26) && c.departure == Self.at(7, 31) && c.disruption == "U6: Schadhaftes Fahrzeug")
            #expect(c.moreDisruptions == 1 && c.nextTooLate && c.day == "2026-11-07")
        } else { Issue.record("expected start") }
        if case .start = decide(p, Self.at(7, 59, 59)) {} else { Issue.record("expected start before the lesson") }
        #expect(decide(p, Self.at(8, 0)) == .none)                      // first lesson began
    }

    @Test func startsOnlyInTheForeground() {
        #expect(decide(Self.plan(), Self.at(7, 0), fg: false) == .none)
    }

    @Test func changedPickUpdatesUnchangedDoesNot() throws {
        let p = Self.plan()
        let running = try #require(p.leaveContent)
        #expect(decide(p, Self.at(7, 10), running: running, fg: false) == .none)
        var later = p
        later.train = Self.at(7, 36); later.leaveBy = Self.at(7, 31); later.disruptions = []
        let want = try #require(later.leaveContent)
        #expect(decide(later, Self.at(7, 10), running: running, fg: false) == .update(want))
    }

    @Test func endsAtFirstLessonOtherDayErrorInactiveAndWhenOff() throws {
        let p = Self.plan()
        let running = try #require(p.leaveContent)
        #expect(decide(p, Self.at(8, 0), running: running, fg: false) == .end)
        #expect(decide(p, Self.at(8, 0), running: nil) == .none)
        #expect(decide(p, Self.at(7, 0), running: running, on: false) == .end)
        #expect(decide(p, Self.at(7, 0), on: false) == .none)
        var err = p; err.error = "no data"
        #expect(decide(err, Self.at(7, 0), running: running) == .end)
        var off = p; off.active = false
        #expect(decide(off, Self.at(7, 0), running: running) == .end)
        #expect(decide(nil, Self.at(7, 0), running: running) == .end)
        // Yesterday's plan or activity: gone. After midnight today's plan is a different day.
        #expect(decide(Self.plan(date: "2026-11-06"), Self.at(7, 0), running: running) == .end)
        let tomorrow = Self.at(0, 5).addingTimeInterval(86400)
        #expect(decide(p, tomorrow, running: running) == .end)
        var yesterdays = running; yesterdays.day = "2026-11-06"
        #expect(decide(p, Self.at(7, 0), running: yesterdays) == .end)
    }

    @Test func bikeDay() throws {
        var p = Self.plan(mode: "bike")
        p.train = nil; p.next = nil; p.ride = 25
        let c = try #require(p.leaveContent)
        #expect(c.bike && c.line == "Bike" && c.ride == 25 && c.departure == c.leaveBy)
        if case .start = decide(p, Self.at(6, 30)) {} else { Issue.record("expected start") }
        // A train day without a train has nothing to show.
        var none = Self.plan(); none.train = nil
        #expect(decide(none, Self.at(6, 30)) == .none)
    }

    // MARK: Departures

    func board() throws -> DepartureBoard {
        DepartureBoard(card: try #require(try fixture(HomelabState.self, "state-departures.json").departuresCard))
    }

    @Test func boardGroupsInTheServersOrder() throws {
        let b = try board()
        #expect(b.groups.map(\.towards) == ["Floridsdorf", "Siebenhirten"])
        #expect(b.groups.map(\.stop) == ["Erlaaer Straße", "Jägerstraße"])
        #expect(b.groups.map(\.departures.count) == [4, 4])
        #expect(b.isDisrupted && b.disruption == "U6: Schadhaftes Fahrzeug" && b.line == "U6")
        let second = b.groups[0].departures[1]
        #expect(second.late && second.delay == 3 && !second.planned)
        #expect(!b.groups[0].departures[0].late)
    }

    @Test func boardDropsPastTrainsAndEmptyDirections() throws {
        let b = try board()
        let first = b.groups[0].departures[0].due
        let u = b.upcoming(now: first)               // the train is gone at its time
        #expect(u.groups[0].departures.count == 3)
        let all = b.upcoming(now: first.addingTimeInterval(-3600))
        #expect(all.groups.map(\.departures.count) == [4, 4])
        let late = b.upcoming(now: first.addingTimeInterval(3600))
        #expect(late.isEmpty && late.groups.isEmpty && late.next == nil)
    }

    @Test func plannedAndNoteParsing() {
        let card = Card(id: "departures", style: .departures, items: [
            .init(title: "A", subtitle: "Stop · planned", value: "07:00", due: Self.at(7, 0)),
            .init(title: "A", subtitle: "Stop · +12 min · planned", value: "07:10", tint: .orange, due: Self.at(7, 10)),
            .init(title: "B", subtitle: nil, value: "07:05", due: Self.at(7, 5)),
            .init(title: "B", subtitle: "No due", value: "07:06"),
        ])
        let b = DepartureBoard(card: card)
        #expect(b.groups.count == 2 && b.groups[0].stop == "Stop" && b.groups[1].stop == nil)
        #expect(b.groups[0].departures.map(\.planned) == [true, true] && b.groups[0].departures[1].delay == 12)
        #expect(b.groups[1].departures.count == 1)
        #expect(DepartureBoard(card: Card(id: "departures", style: .departures)).isEmpty)
    }

    @Test func timelineEntriesAtEachDeparture() throws {
        let b = try board()
        let first = b.groups[0].departures[0].due
        let now = first.addingTimeInterval(-120)
        let e = DepartureTimeline.entries(b, now: now)
        #expect(e.first == now && e == e.sorted() && Set(e).count == e.count)
        #expect(e.contains(first) && e.count == 8)                          // now + 7 departures still ahead
        #expect(DepartureTimeline.entries(b, now: now, limit: 600).count == 4)   // within 10 min: 3 + now
        let empty = DepartureTimeline.entries(DepartureBoard(card: Card(id: "departures", style: .departures)), now: now)
        #expect(empty == [now])
    }

    // MARK: Widget policy

    @Test func mayFetchOnlyIdentityCompanion() {
        let u = URL(string: "https://x.ts.net")!
        #expect(WidgetPolicy.mayFetch(server: ServerConfig(name: "a", kind: .companion, baseURL: u, auth: .identity)))
        #expect(!WidgetPolicy.mayFetch(server: ServerConfig(name: "a", kind: .companion, baseURL: u, auth: .token)))
        #expect(!WidgetPolicy.mayFetch(server: ServerConfig(name: "a", kind: .homeAssistant, baseURL: u, auth: .identity)))
        #expect(!WidgetPolicy.mayFetch(server: .demo()))
        #expect(!WidgetPolicy.mayFetch(server: nil))
    }

    @Test func fiveMinuteRule() {
        let now = Self.at(7, 0)
        func snap(_ ago: TimeInterval) -> Snapshot { Snapshot(serverID: UUID(), serverName: "s", state: HomelabState(), fetched: now.addingTimeInterval(-ago)) }
        #expect(WidgetPolicy.shouldFetch(snapshot: nil, now: now))
        #expect(!WidgetPolicy.shouldFetch(snapshot: snap(299), now: now))
        #expect(!WidgetPolicy.shouldFetch(snapshot: snap(300), now: now))
        #expect(WidgetPolicy.shouldFetch(snapshot: snap(301), now: now))
        #expect(WidgetPolicy.shouldFetch(snapshot: snap(-3600), now: now))
    }

    @Test func writeRule() {
        let id = UUID(), now = Self.at(7, 0)
        func snap(_ id: UUID, _ ago: TimeInterval) -> Snapshot { Snapshot(serverID: id, serverName: "s", state: HomelabState(), fetched: now.addingTimeInterval(-ago)) }
        #expect(WidgetPolicy.shouldWrite(snap(id, 0), over: nil, selected: id))
        #expect(WidgetPolicy.shouldWrite(snap(id, 0), over: snap(id, 60), selected: id))
        #expect(!WidgetPolicy.shouldWrite(snap(id, 60), over: snap(id, 0), selected: id))      // the app was faster
        #expect(!WidgetPolicy.shouldWrite(snap(id, 0), over: snap(id, 0), selected: id))
        #expect(!WidgetPolicy.shouldWrite(snap(id, 0), over: nil, selected: UUID()))           // not the selected server
        #expect(WidgetPolicy.shouldWrite(snap(id, 3600), over: snap(UUID(), 0), selected: id)) // selection changed
    }

    @Test func redactionRule() {
        for kind in WidgetPolicy.Kind.allCases {
            #expect(WidgetPolicy.redaction(for: kind, locked: false) == .full)
        }
        #expect(WidgetPolicy.redaction(for: .departures, locked: true) == .full)
        #expect(WidgetPolicy.redaction(for: .deadlines, locked: true) == .countsOnly)
        #expect(WidgetPolicy.redaction(for: .todos, locked: true) == .countsOnly)
    }

    @Test func widgetTransportConfig() throws {
        let c = URLSessionTransport.widget.session.configuration
        #expect(c.timeoutIntervalForRequest == 8 && c.timeoutIntervalForResource == 8)
        #expect(c.urlCache == nil && c.httpCookieAcceptPolicy == .never)
        #expect(URLSessionTransport.widget.maxBytes == 2 * 1024 * 1024)
        #expect(URLSessionTransport.widget.session.delegate is NoRedirects)
    }

    // MARK: Deadlines and to-dos

    @Test func deadlinesAndTodos() throws {
        let s = try fixture(HomelabState.self, "state-problem.json")
        let now = Self.at(12, 0)
        let card = Card(id: "deadlines", style: .countdown, items: [
            .init(title: "far", due: now.addingTimeInterval(20 * 86400), dueIsDay: false),
            .init(title: "soon", due: now.addingTimeInterval(2 * 86400)),
            .init(title: "late", due: now.addingTimeInterval(-86400)),
            .init(title: "none"),
        ])
        #expect(Deadlines.list(card).map(\.title) == ["late", "soon", "far"])
        #expect(Deadlines.dueThisWeek(card, now: now, calendar: Self.utc) == 2)
        #expect(Deadlines.urgency(card, now: now, calendar: Self.utc) == 1)
        #expect(Deadlines.urgency(Card(id: "d", style: .countdown, items: [.init(title: "a", due: now.addingTimeInterval(86400 * 3.5))]),
                                  now: now, calendar: Self.utc) == 0.5)
        #expect(Deadlines.urgency(nil, now: now) == 0)
        let dates = Deadlines.redrawDates(card, now: now, calendar: Self.utc)
        #expect(dates.first == now && dates == dates.sorted() && dates.contains(Self.at(0, 0).addingTimeInterval(86400)))
        #expect(s.deadlinesCard?.id == "deadlines" && s.todosCard?.id == "todos")
        #expect(Todos.open(s.todosCard).count == 3)
        #expect(Todos.open(nil).isEmpty && Deadlines.list(nil).isEmpty)
    }

    @Test func dayOnlyDeadlinesCountFromTheirMidnight() {
        let now = Self.at(12, 0)
        let in7 = Self.at(0, 0).addingTimeInterval(7 * 86400)
        let in8 = Self.at(0, 0).addingTimeInterval(8 * 86400)
        let card = Card(id: "d", style: .countdown, items: [
            .init(title: "a", due: in7, dueIsDay: true), .init(title: "b", due: in8, dueIsDay: true),
        ])
        #expect(Deadlines.dueThisWeek(card, now: now, calendar: Self.utc) == 1)
    }

    // MARK: Demo

    @Test func demoMovesDeparturesAndCommuteToNow() async throws {
        let now = Self.at(15, 0)
        let demo = DemoBackend(delay: .zero, now: now)
        let s = try await demo.state()
        let card = try #require(s.departuresCard)
        let first = try #require(card.items.first?.due)
        #expect(first > now && first < now.addingTimeInterval(3600))
        #expect(card.items.first?.value == DepartureBoard.clock(first))
        let c = try #require(s.commute)
        let leave = try #require(c.leaveBy)
        #expect(leave > now && leave < now.addingTimeInterval(3600))
        #expect(c.date == CommutePlan.dayString(leave, calendar: .current))
    }
}
