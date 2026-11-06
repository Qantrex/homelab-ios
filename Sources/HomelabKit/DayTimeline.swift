import Foundation

extension HomelabState {
    /// The card Today shows as the day under the headline (and the Day widget): the server's "today" card, else the
    /// first metrics card that is not the weather card (that one has its own line under the headline).
    public var dayCard: Card? {
        cards.first { $0.id == "today" } ?? cards.first { $0.style == .metrics && $0.id != "weather" }
    }
}

/// The server's "today" card as a line through the day. Items whose value is a clock time ("06:20") become stops in
/// time order; the rest (a disruption, "Leave by ?", "too late") stay notes under the line. "Now" sits between two
/// stops, so the line fills up as the day goes on. Pure, so it's tested on Linux.
public struct DayTimeline: Equatable, Sendable {
    public enum Phase: Sendable, Equatable { case past, next, later }

    public struct Stop: Equatable, Sendable {
        public var item: Card.Item
        /// Minutes since midnight.
        public var minute: Int
        public var phase: Phase
    }

    public var stops: [Stop]
    /// Items without a clock time, in the server's order.
    public var notes: [Card.Item]
    /// The card's text when it has no items ("No school today: autumn holidays.").
    public var text: String?
    /// Minutes since midnight, now. In tomorrow mode: negative, the minutes since tomorrow's midnight (-600 = 14:00
    /// today), so every stop is ahead and the countdown is `minute - now`.
    public var now: Int
    /// The card is about tomorrow (its `date` is the day after `now`'s day): no stop is past, nothing is filled, the
    /// countdown runs to the first stop.
    public var isTomorrow: Bool
    /// Days the card's `date` lies before `now`'s day (a cached card after midnight), else 0. Then the line is stale:
    /// every stop is past, nothing counts down.
    public var staleDays: Int
    public var isStale: Bool { staleDays > 0 }
    /// Real minutes from `now` to the next stop (DST nights included); nil when there is none.
    private var toNext: Int?

    /// More stops than this don't fit side by side on a phone; the view lays them out top to bottom instead.
    public static let maxAcross = 4

    public init(card: Card, now: Date = Date(), calendar: Calendar = .current) {
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let today = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let tomorrow = Self.isTomorrow(card.date, now: now, calendar: calendar)
        let behind = Self.daysBehind(card.date, now: now, calendar: calendar)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        // Tomorrow: minus the real minutes left until tomorrow's midnight. Stale: past every stop of the day.
        let untilMidnight = startOfTomorrow.map { max(Int(($0.timeIntervalSince(now) / 60).rounded()), 0) } ?? (24 * 60 - today)
        let nowMinute = behind > 0 ? 24 * 60 : tomorrow ? -untilMidnight : today
        var timed: [(item: Card.Item, minute: Int)] = []
        var notes: [Card.Item] = []
        for item in card.items {
            if let m = Self.minute(item.value) { timed.append((item, m)) } else { notes.append(item) }
        }
        // Stable: two stops at the same time keep the server's order.
        let sorted = timed.enumerated().sorted { ($0.element.minute, $0.offset) < ($1.element.minute, $1.offset) }.map(\.element)
        let next = behind > 0 ? nil : sorted.firstIndex { $0.minute >= nowMinute }
        stops = sorted.enumerated().map { i, s in
            Stop(item: s.item, minute: s.minute, phase: next.map { i < $0 ? .past : i == $0 ? .next : .later } ?? .past)
        }
        self.notes = notes
        text = card.items.isEmpty ? card.text : nil
        self.now = nowMinute
        isTomorrow = tomorrow
        staleDays = behind
        if let next {
            let m = sorted[next].minute
            if tomorrow, let start = startOfTomorrow,
               let at = calendar.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: start) {
                toNext = Int((at.timeIntervalSince(now) / 60).rounded(.down))
            } else {
                toNext = m - nowMinute
            }
        } else {
            toNext = nil
        }
    }

    /// The card's day ('2026-11-07') as the start of that day in `calendar`; nil for nil or garbage.
    public static func day(_ date: String?, calendar: Calendar = .current) -> Date? {
        guard let date, Card.Item.isPlainDay(date) else { return nil }
        let p = date.trimmingCharacters(in: .whitespaces).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    /// How many days `date` lies before `now`'s day; 0 when it is today, later, nil or unreadable.
    public static func daysBehind(_ date: String?, now: Date, calendar: Calendar = .current) -> Int {
        guard let d = day(date, calendar: calendar) else { return 0 }
        let n = calendar.dateComponents([.day], from: d, to: calendar.startOfDay(for: now)).day ?? 0
        return max(n, 0)
    }

    /// `date` ('2026-11-07') is the calendar day after `now`'s day. Nil or unreadable: no.
    public static func isTomorrow(_ date: String?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let date, Card.Item.isPlainDay(date), let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return false }
        let d = calendar.dateComponents([.year, .month, .day], from: next)
        return date.trimmingCharacters(in: .whitespaces) == String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }

    /// "6:20" or "06:20" → 380. Anything else (an empty value, "?", "too late", "25:00") → nil.
    public static func minute(_ value: String?) -> Int? {
        guard let value else { return nil }
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let h = Int(parts[0]), let m = Int(parts[1]), h < 24, m < 60 else { return nil }
        return h * 60 + m
    }

    public var next: Stop? { stops.first { $0.phase == .next } }

    /// Minutes until the next stop; nil once the day's stops are over.
    public var minutesToNext: Int? { next == nil ? nil : toNext }

    /// How far "now" has filled the line after stop `i`, 0…1. The piece after the last stop is full once that stop is
    /// past. Two stops at the same minute: full once they are past.
    public func fill(after i: Int) -> Double {
        guard stops.indices.contains(i) else { return 0 }
        let a = stops[i].minute
        guard i + 1 < stops.count else { return now > a ? 1 : 0 }
        let b = stops[i + 1].minute
        guard b > a else { return now > a ? 1 : 0 }
        return min(max(Double(now - a) / Double(b - a), 0), 1)
    }

    /// When a widget should redraw, from `now` on: every 15 minutes for the data's age (as before the day line), every
    /// minute while a stop is less than an hour away (its countdown), and a minute after each later stop (it turns
    /// past). Sorted, without duplicates, at most `limit`. Without a card only the 15-minute ones.
    public static func redrawDates(card: Card?, now: Date, calendar: Calendar = .current, limit: Int = 100) -> [Date] {
        var dates: Set<Date> = [now]
        for i in 1...3 { dates.insert(now.addingTimeInterval(Double(i) * 15 * 60)) }
        if let card {
            let line = DayTimeline(card: card, now: now, calendar: calendar)
            let future = line.stops.filter { $0.phase != .past }
            let minute = calendar.dateInterval(of: .minute, for: now)?.start ?? now
            if !line.isTomorrow, let last = future.last {
                for i in 0..<min(last.minute - line.now, 60) { dates.insert(minute.addingTimeInterval(Double(i + 1) * 60)) }
            }
            for stop in future where !line.isTomorrow {
                if let at = calendar.date(bySettingHour: stop.minute / 60, minute: stop.minute % 60, second: 0, of: now) {
                    dates.insert(at.addingTimeInterval(60))
                }
            }
        }
        return Array(dates.filter { $0 >= now }.sorted().prefix(limit))
    }

    /// Side by side when there are few stops and the text isn't huge; else top to bottom.
    public func across(accessibilityText: Bool) -> Bool {
        !accessibilityText && stops.count <= Self.maxAcross
    }
}
