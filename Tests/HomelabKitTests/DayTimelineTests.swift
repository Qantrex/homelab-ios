import Foundation
import Testing
@testable import HomelabKit

@Suite struct DayTimelineTests {
    static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// 2026-11-06 at hh:mm UTC.
    static func at(_ h: Int, _ m: Int) -> Date {
        Date(timeIntervalSince1970: 1_793_923_200 + Double(h * 3600 + m * 60))
    }

    /// The agent's card: wake-up, first lesson, leave-by (in that order), plus a disruption without a time.
    let card = Card(id: "today", style: .metrics, items: [
        .init(title: "Wake-up", value: "06:20"),
        .init(title: "First lesson", value: "08:00"),
        .init(title: "Leave by", subtitle: "U6 07:36", value: "07:31"),
        .init(title: "Disruption", subtitle: "U6: delays"),
    ])

    func line(_ h: Int, _ m: Int, _ card: Card? = nil) -> DayTimeline {
        DayTimeline(card: card ?? self.card, now: Self.at(h, m), calendar: Self.utc)
    }

    @Test func clockTimes() {
        #expect(DayTimeline.minute("06:20") == 380 && DayTimeline.minute("6:05") == 365 && DayTimeline.minute(" 23:59 ") == 1439)
        #expect(DayTimeline.minute("00:00") == 0)
        for bad in [nil, "", "?", "too late", "24:00", "7:60", "7:5", "07:31:00", "123:00", "a7:30", "-1:30", "٠٧:٣٠"] {
            #expect(DayTimeline.minute(bad) == nil, "\(bad ?? "nil")")
        }
    }

    @Test func stopsInTimeOrderNotesApart() {
        let t = line(7, 5)
        #expect(t.stops.map(\.item.title) == ["Wake-up", "Leave by", "First lesson"])
        #expect(t.stops.map(\.minute) == [380, 451, 480])
        #expect(t.notes.map(\.title) == ["Disruption"])
        #expect(t.text == nil)
    }

    @Test func phasesAndCountdown() {
        let t = line(7, 5)
        #expect(t.stops.map(\.phase) == [.past, .next, .later])
        #expect(t.next?.item.title == "Leave by" && t.minutesToNext == 26)
        #expect(Format.countdown(minutes: t.minutesToNext!) == "in 26 min")
        // Before the first stop: the first one is next, nothing is past.
        let early = line(5, 0)
        #expect(early.stops.map(\.phase) == [.next, .later, .later] && early.minutesToNext == 80)
        // At the exact minute the stop is still "next" ("now"), one minute later it's past.
        #expect(line(7, 31).next?.item.title == "Leave by" && line(7, 31).minutesToNext == 0)
        #expect(line(7, 32).next?.item.title == "First lesson")
        // After the last stop: all past, no countdown.
        let evening = line(20, 0)
        #expect(evening.stops.allSatisfy { $0.phase == .past } && evening.next == nil && evening.minutesToNext == nil)
    }

    @Test func fillFollowsNow() {
        let early = line(5, 0)
        #expect((0..<3).map(early.fill(after:)) == [0, 0, 0])
        // 07:05 is 45 of the 71 minutes between wake-up (06:20) and leave-by (07:31).
        let t = line(7, 5)
        #expect(abs(t.fill(after: 0) - 45.0 / 71.0) < 1e-9 && t.fill(after: 1) == 0 && t.fill(after: 2) == 0)
        let mid = line(7, 45)
        #expect(mid.fill(after: 0) == 1 && abs(mid.fill(after: 1) - 14.0 / 29.0) < 1e-9 && mid.fill(after: 2) == 0)
        // The piece after the last stop fills once it's past; out of range is empty.
        #expect(line(8, 0).fill(after: 2) == 0 && line(8, 1).fill(after: 2) == 1)
        #expect(t.fill(after: -1) == 0 && t.fill(after: 3) == 0)
    }

    @Test func sameMinuteStopsKeepServerOrder() {
        let c = Card(id: "today", items: [.init(title: "B", value: "08:00"), .init(title: "A", value: "8:00"),
                                          .init(title: "C", value: "07:00")])
        let t = line(7, 30, c)
        #expect(t.stops.map(\.item.title) == ["C", "B", "A"])
        #expect(t.fill(after: 1) == 0 && line(8, 1, c).fill(after: 1) == 1)   // zero-length piece: full once past
        #expect(t.stops.map(\.phase) == [.past, .next, .later])
    }

    @Test func textOnlyDayAndOtherMetrics() {
        // "No school today": a text card without items keeps its text and has no stops.
        let off = Card(id: "today", style: .text, text: "No school today: autumn holidays.")
        let t = line(9, 0, off)
        #expect(t.stops.isEmpty && t.notes.isEmpty && t.text == "No school today: autumn holidays.")
        // A metrics card without clock times (another server's numbers) has no stops; its items are notes.
        let numbers = Card(id: "load", style: .metrics, items: [.init(title: "CPU", value: "45%"), .init(title: "RAM", value: "3 GB")])
        let n = line(9, 0, numbers)
        #expect(n.stops.isEmpty && n.notes.count == 2 && n.text == nil && n.next == nil)
    }

    @Test func dayCardIsTodayElseFirstMetrics() {
        let other = Card(id: "load", style: .metrics)
        #expect(HomelabState(cards: [other, card]).dayCard?.id == "today")
        #expect(HomelabState(cards: [Card(id: "note", style: .text), other]).dayCard?.id == "load")
        #expect(HomelabState(cards: [Card(id: "note", style: .text)]).dayCard == nil)
    }

    @Test func widgetRedraws() {
        func t(_ h: Int, _ m: Int) -> Date { Self.at(h, m) }
        // No card: the 15-minute ones only.
        #expect(DayTimeline.redrawDates(card: nil, now: t(7, 5), calendar: Self.utc) == [t(7, 5), t(7, 20), t(7, 35), t(7, 50)])
        // 07:05, stops at 07:31 and 08:00 ahead: every minute up to 08:00, then 08:01 (the last stop turns past).
        let d = DayTimeline.redrawDates(card: card, now: t(7, 5), calendar: Self.utc)
        #expect(d.first == t(7, 5) && d.last == t(8, 1) && d.count == 57)
        #expect(d.contains(t(7, 32)) && zip(d, d.dropFirst()).allSatisfy { $0 < $1 })
        // 05:00: an hour of minutes (to 06:00), then a minute after each stop.
        let early = DayTimeline.redrawDates(card: card, now: t(5, 0), calendar: Self.utc)
        #expect(early.count == 1 + 60 + 3 && early.suffix(3) == [t(6, 21), t(7, 32), t(8, 1)])
        // Evening: the day is over, back to every 15 minutes. A capped list keeps the earliest.
        #expect(DayTimeline.redrawDates(card: card, now: t(20, 0), calendar: Self.utc).count == 4)
        #expect(DayTimeline.redrawDates(card: card, now: t(5, 0), calendar: Self.utc, limit: 10).last == t(5, 9))
        // Mid-minute: the minute ticks fall on whole minutes.
        let odd = Self.at(7, 5).addingTimeInterval(30)
        #expect(DayTimeline.redrawDates(card: card, now: odd, calendar: Self.utc).dropFirst().first == t(7, 6))
    }

    @Test func acrossOrDown() {
        #expect(line(7, 5).across(accessibilityText: false))
        #expect(!line(7, 5).across(accessibilityText: true))
        let many = Card(id: "today", items: (0..<5).map { .init(title: "\($0)", value: "0\($0):00") })
        #expect(!line(7, 5, many).across(accessibilityText: false))
    }

    @Test func countdownText() {
        #expect(Format.countdown(minutes: 0) == "now" && Format.countdown(minutes: -3) == "now")
        #expect(Format.countdown(minutes: 1) == "in 1 min" && Format.countdown(minutes: 59) == "in 59 min")
        #expect(Format.countdown(minutes: 60) == "in 1 h" && Format.countdown(minutes: 125) == "in 2 h 5 min")
    }

    @Test func ringPercent() {
        #expect(Format.ringPercent(0) == 0 && Format.ringPercent(0.29) == 29 && Format.ringPercent(0.81) == 81)
        #expect(Format.ringPercent(0.999) == 99 && Format.ringPercent(1) == 100)
        #expect(Format.ringPercent(-1) == 0 && Format.ringPercent(7) == 100 && Format.ringPercent(.nan) == 0)
    }

    @Test func demoDayFollowsTheClock() {
        // 09:10 now: the first stop (wake-up) moves to 08:25, everything else by the same 2 h 05 min.
        let moved = DemoBackend.demoDay(card, now: Self.at(9, 10), calendar: Self.utc)
        #expect(moved.items.map(\.value) == ["08:25", "10:05", "09:36", nil])
        #expect(moved.items[2].subtitle == "U6 09:41" && moved.items[3].subtitle == "U6: delays")
        let t = DayTimeline(card: moved, now: Self.at(9, 10), calendar: Self.utc)
        #expect(t.next?.item.title == "Leave by" && t.minutesToNext == 26)
        // Too close to midnight for the day to fit: the fixture times stay.
        #expect(DemoBackend.demoDay(card, now: Self.at(0, 30), calendar: Self.utc) == card)
        #expect(DemoBackend.demoDay(card, now: Self.at(23, 30), calendar: Self.utc) == card)
        // No clock times: unchanged.
        let numbers = Card(id: "today", items: [.init(title: "CPU", value: "45%")])
        #expect(DemoBackend.demoDay(numbers, now: Self.at(9, 10), calendar: Self.utc) == numbers)
    }

    @Test func demoStateHasALiveDay() async throws {
        let now = Date()
        let s = try await DemoBackend(delay: .zero, now: now).state()
        let today = try #require(s.cards.first { $0.id == "today" })
        let t = DayTimeline(card: today, now: now)
        let h = Calendar.current.component(.hour, from: now)
        if (1...22).contains(h) {   // the shift is skipped near midnight
            #expect(t.minutesToNext == 26 && t.stops.first?.phase == .past)
        }
        #expect(t.stops.count == 3)
    }

    // MARK: Tomorrow (step 6b)

    let tomorrowCard = Card(id: "today", title: "Tomorrow", style: .metrics, items: [
        .init(title: "Wake-up", value: "06:20"),
        .init(title: "First lesson", value: "08:00"),
        .init(title: "Leave by", subtitle: "U6 07:36", value: "07:31"),
    ], date: "2026-11-07")

    @Test func tomorrowModeFromTheCardDate() {
        // 2026-11-06 20:00: the card is for the 7th.
        let t = line(20, 0, tomorrowCard)
        #expect(t.isTomorrow && t.now == 20 * 60 - 1440)
        #expect(t.stops.map(\.phase) == [.next, .later, .later])
        #expect(t.next?.item.title == "Wake-up" && t.minutesToNext == 10 * 60 + 20)
        #expect(Format.countdown(minutes: t.minutesToNext!) == "in 10 h 20 min")
        #expect((0..<3).map(t.fill(after:)) == [0, 0, 0])
        // Just before midnight, and after midnight (the card is now today's: normal mode, the line fills).
        #expect(line(23, 59, tomorrowCard).minutesToNext == 6 * 60 + 21)
        #expect(!DayTimeline(card: tomorrowCard, now: Self.at(24, 5), calendar: Self.utc).isTomorrow)
        // No date, the same day, an old day, garbage: today's rules.
        for d in [nil, "2026-11-06", "2026-11-05", "tomorrow", "2026-11-8"] as [String?] {
            var c = tomorrowCard; c.date = d
            #expect(!line(20, 0, c).isTomorrow, "\(d ?? "nil")")
        }
        #expect(!line(20, 0).isTomorrow && line(20, 0).stops.allSatisfy { $0.phase == .past })
    }

    @Test func tomorrowAcrossMonthEnd() {
        var c = tomorrowCard; c.date = "2026-12-01"
        let nov30 = Date(timeIntervalSince1970: 1_793_923_200 + 24 * 86400 + 20 * 3600)   // 2026-11-30 20:00 UTC
        #expect(DayTimeline(card: c, now: nov30, calendar: Self.utc).isTomorrow)
    }

    @Test func tomorrowWidgetRedraws() {
        // Only the 15-minute ones in the evening: no per-minute countdown, nothing turns past.
        let d = DayTimeline.redrawDates(card: tomorrowCard, now: Self.at(20, 0), calendar: Self.utc)
        #expect(d == [Self.at(20, 0), Self.at(20, 15), Self.at(20, 30), Self.at(20, 45)])
    }

    @Test func cancelledAndDateDecode() throws {
        let json = #"""
        {"id": "lessons", "style": "list", "date": "2026-11-07", "items": [
          {"title": "Maths", "value": "08:00-08:50", "cancelled": true},
          {"title": "German", "tint": "orange", "cancelled": "perhaps"},
          {"title": "English", "cancelled": false}, {"title": "Art"}]}
        """#
        let c = try JSONDecoder().decode(Card.self, from: Data(json.utf8))
        #expect(c.date == "2026-11-07" && c.items.map(\.cancelled) == [true, nil, false, nil])
        let again = try JSONDecoder().decode(Card.self, from: JSONEncoder().encode(c))
        #expect(again == c)
        let bad = try JSONDecoder().decode(Card.self, from: Data(#"{"id": "today", "date": "soon"}"#.utf8))
        #expect(bad.date == nil)
        #expect(Card(id: "x", date: "2026-11-07T10:00").date == nil)
    }

    @Test func fixturesCarryTheNewCards() throws {
        let s = try fixture(HomelabState.self, "state-problem.json")
        let lessons = try #require(s.cards.first { $0.id == "lessons" })
        #expect(lessons.items.map(\.cancelled) == [nil, nil, true, nil] && lessons.items.filter { $0.tint == .orange }.count == 2)
        #expect(s.cards.first { $0.id == "weather" }?.subtitle == "Rain from 15:00, take an umbrella")
        #expect(s.cards.first { $0.id == "briefing" }?.style == .text)
        #expect(s.dayCard?.date == "2026-11-04")
        let t = try fixture(HomelabState.self, "state-tomorrow.json")
        #expect(t.dayCard?.title == "Tomorrow" && t.dayCard?.date == "2026-11-05")
        let at = Self.at(20, 0).addingTimeInterval(-86400)   // 2026-11-05 20:00 UTC
        let line = DayTimeline(card: try #require(t.dayCard), now: at, calendar: Self.utc)
        #expect(line.isTomorrow == false)   // the 5th is the card's own day
        let before = Self.at(20, 0).addingTimeInterval(-2 * 86400)   // the 4th, 20:00
        let tl = DayTimeline(card: try #require(t.dayCard), now: before, calendar: Self.utc)
        #expect(tl.isTomorrow && tl.next?.item.title == "Wake-up" && tl.notes.map(\.title) == ["Substitution"])
    }
}
