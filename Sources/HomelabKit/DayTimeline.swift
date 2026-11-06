import Foundation

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
    /// Minutes since midnight, now.
    public var now: Int

    /// More stops than this don't fit side by side on a phone; the view lays them out top to bottom instead.
    public static let maxAcross = 4

    public init(card: Card, now: Date = Date(), calendar: Calendar = .current) {
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let nowMinute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        var timed: [(item: Card.Item, minute: Int)] = []
        var notes: [Card.Item] = []
        for item in card.items {
            if let m = Self.minute(item.value) { timed.append((item, m)) } else { notes.append(item) }
        }
        // Stable: two stops at the same time keep the server's order.
        let sorted = timed.enumerated().sorted { ($0.element.minute, $0.offset) < ($1.element.minute, $1.offset) }.map(\.element)
        let next = sorted.firstIndex { $0.minute >= nowMinute }
        stops = sorted.enumerated().map { i, s in
            Stop(item: s.item, minute: s.minute, phase: next.map { i < $0 ? .past : i == $0 ? .next : .later } ?? .past)
        }
        self.notes = notes
        text = card.items.isEmpty ? card.text : nil
        self.now = nowMinute
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
    public var minutesToNext: Int? { next.map { $0.minute - now } }

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

    /// Side by side when there are few stops and the text isn't huge; else top to bottom.
    public func across(accessibilityText: Bool) -> Bool {
        !accessibilityText && stops.count <= Self.maxAcross
    }
}
