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
}
