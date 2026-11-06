import Foundation

/// The deadlines and to-dos widgets' data. Pure, so it is tested on Linux.
extension HomelabState {
    /// The countdown card of the deadlines ("deadlines", else the first countdown card).
    public var deadlinesCard: Card? {
        cards.first { $0.id == "deadlines" && $0.style == .countdown } ?? cards.first { $0.style == .countdown }
    }

    /// The to-do list ("todos", else the first checklist card).
    public var todosCard: Card? {
        cards.first { $0.id == "todos" && $0.style == .checklist } ?? cards.first { $0.style == .checklist }
    }
}

public enum Deadlines {
    /// "This week" in the locked widget: due within 7 days, overdue ones included.
    public static let weekSeconds: TimeInterval = 7 * 86400

    /// The deadlines with a `due`, soonest first (overdue lead).
    public static func list(_ card: Card?) -> [Card.Item] {
        (card?.sortedForCountdown ?? []).filter { $0.due != nil }
    }

    /// Items due within 7 days (a day-only due counts from its midnight), overdue included.
    public static func dueThisWeek(_ card: Card?, now: Date, calendar: Calendar = .current) -> Int {
        list(card).filter { within7Days($0, now: now, calendar: calendar) }.count
    }

    static func within7Days(_ item: Card.Item, now: Date, calendar: Calendar) -> Bool {
        guard let due = item.due else { return false }
        let at = item.dueIsDay ? Format.dueDay(due, calendar: calendar) : due
        // Today and the 7 days after it.
        guard let end = calendar.date(byAdding: .day, value: 8, to: calendar.startOfDay(for: now)) else { return false }
        return at < end
    }

    /// 0 (a week away or more) … 1 (due or overdue): the circular widget's gauge for the nearest deadline.
    public static func urgency(_ card: Card?, now: Date, calendar: Calendar = .current) -> Double {
        guard let item = list(card).first, let due = item.due else { return 0 }
        let at = item.dueIsDay ? Format.dueDay(due, calendar: calendar) : due
        let left = max(at.timeIntervalSince(now), 0)
        return min(max(1 - left / weekSeconds, 0), 1)
    }

    /// When the widget redraws: now, each midnight within a week (a day-only countdown changes then) and each timed
    /// due (to the hour: "5 h" turns "4 h"; to the due itself: it turns "min" then "ago"). At most `limit`.
    public static func redrawDates(_ card: Card?, now: Date, calendar: Calendar = .current, limit: Int = 40) -> [Date] {
        var dates: Set<Date> = [now]
        let start = calendar.startOfDay(for: now)
        for d in 1...7 { if let m = calendar.date(byAdding: .day, value: d, to: start) { dates.insert(m) } }
        for item in list(card) where !item.dueIsDay {
            if let due = item.due, due > now {
                dates.insert(due)
                var t = due.addingTimeInterval(-3600)
                while t > now && t > due.addingTimeInterval(-24 * 3600) { dates.insert(t); t = t.addingTimeInterval(-3600) }
            }
        }
        return Array(dates.filter { $0 >= now }.sorted().prefix(limit))
    }
}

public enum Todos {
    /// Open items, in the server's order.
    public static func open(_ card: Card?) -> [Card.Item] {
        (card?.items ?? []).filter { $0.done != true }
    }
}
