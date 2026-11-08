import Foundation

extension HomelabState {
    /// The `departures` card (step 6c).
    public var departuresCard: Card? {
        cards.first { $0.id == "departures" && $0.style == .departures } ?? cards.first { $0.style == .departures }
    }
}

/// The `departures` card as a board: rows grouped by direction and stop, in the server's order (the relevant
/// direction comes first). Pure, so it is tested on Linux.
public struct DepartureBoard: Equatable, Sendable {
    /// The departures widget in the gallery: no city's line in its name (what it shows is the server's line).
    public static let galleryName = "Departures"
    public static let galleryDescription = "Next departures from your server, with delays and disruptions."

    public struct Departure: Equatable, Sendable {
        public var due: Date
        /// The server's clock text ("20:54"), used when the time can't be computed from `due`.
        public var value: String
        /// Minutes late ("+3 min"); nil when on time or when only the tint said it is late.
        public var delay: Int?
        /// Late (orange tint or "+n min").
        public var late: Bool
        /// Only the timetable time, no real-time data ("planned").
        public var planned: Bool
    }

    public struct Group: Equatable, Sendable, Identifiable {
        /// The direction ("Floridsdorf").
        public var towards: String
        /// The stop ("Westbahnhof").
        public var stop: String?
        public var departures: [Departure]
        public var id: String { towards + "|" + (stop ?? "") }
    }

    /// The card's title ("U6"); the neutral word when the server sends none.
    public var line: String
    public var groups: [Group]
    /// The card's `text`: the disruption titles. Nil when there is none.
    public var disruption: String?
    /// The server's "updated" ("20:49").
    public var updated: String?

    public init(card: Card) {
        line = card.title ?? CommutePlan.defaultLine
        disruption = card.text.flatMap { $0.isEmpty ? nil : $0 }
        updated = card.updated
        var groups: [Group] = []
        for item in card.items {
            guard let due = item.due else { continue }
            let towards = item.title ?? ""
            let parts = (item.subtitle ?? "").components(separatedBy: " · ")
            let stop = parts.first.flatMap { $0.isEmpty || Self.isNote($0) ? nil : $0 }
            var delay: Int?
            var planned = false
            for part in parts {
                if part == "planned" { planned = true }
                if let m = part.wholeMatch(of: /\+([0-9]{1,3}) min/), let n = Int(m.1) { delay = n }
            }
            let dep = Departure(due: due, value: item.value ?? "", delay: delay, late: delay != nil || item.tint == .orange,
                                planned: planned)
            if let i = groups.firstIndex(where: { $0.towards == towards && $0.stop == stop }) {
                groups[i].departures.append(dep)
            } else {
                groups.append(Group(towards: towards, stop: stop, departures: [dep]))
            }
        }
        self.groups = groups
    }

    private static func isNote(_ text: String) -> Bool {
        text == "planned" || text.wholeMatch(of: /\+[0-9]{1,3} min/) != nil
    }

    public var isDisrupted: Bool { disruption != nil }

    /// Without the trains that have left (a train is gone at its time), and without directions that have none left.
    public func upcoming(now: Date) -> DepartureBoard {
        var copy = self
        copy.groups = groups.compactMap { g in
            var g = g
            g.departures = g.departures.filter { $0.due > now }.sorted { $0.due < $1.due }
            return g.departures.isEmpty ? nil : g
        }
        return copy
    }

    public var isEmpty: Bool { groups.allSatisfy(\.departures.isEmpty) }

    /// The first group's first departure: the train the widget counts down to.
    public var next: Departure? { groups.first?.departures.first }

    /// The time as clock text, in `calendar`'s zone ("20:54"). The server's `value` is not trusted for this: it was
    /// written in the server's zone.
    public static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// When the U6 widget redraws: now and at each departure (that train drops off the list). Timeline entries cost
/// nothing; only reloads count against the widget's budget.
public enum DepartureTimeline {
    /// Entry dates from `now` on, within `limit` (the monitor shows about 70 minutes), at most `maxEntries`.
    public static func entries(_ board: DepartureBoard, now: Date, limit: TimeInterval = 70 * 60,
                               maxEntries: Int = 24) -> [Date] {
        var dates: Set<Date> = [now]
        for g in board.groups {
            for d in g.departures where d.due > now && d.due <= now.addingTimeInterval(limit) { dates.insert(d.due) }
        }
        return Array(dates.sorted().prefix(maxEntries))
    }
}
