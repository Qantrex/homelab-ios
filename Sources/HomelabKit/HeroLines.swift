import Foundation

// Small decisions behind Today's hero and Lab's card rows, kept out of the views so they are tested on Linux.

/// Today's weather sentence under the headline: the `weather` card's subtitle, plus the "Now" item's temperature
/// when the subtitle has none ("Clear" → "Clear, 3°C now"). A subtitle that already says a temperature ("Clear, 7 °C
/// now, 4–10 °C today") stays as it is.
public enum WeatherLine {
    public static func text(_ card: Card?) -> String? {
        guard let card else { return nil }
        let subtitle = card.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let now = card.items.first { $0.title?.lowercased() == "now" }?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let nowText = now.flatMap { $0.isEmpty ? nil : "\($0) now" }
        if subtitle.isEmpty { return nowText }
        guard !hasTemperature(subtitle), let nowText else { return subtitle }
        return subtitle + ", " + nowText
    }

    /// "7 °C", "7°C", "-2°", "45 °F": a number followed by a degree sign.
    static func hasTemperature(_ text: String) -> Bool {
        text.contains(/\d\s?°/)
    }
}

/// When Today shows where its data is from ("homelab · checked 4 min ago"): only when that is worth reading. While a
/// pull to refresh runs (and a moment after), when the last fetch failed, or when the data is older than
/// `Snapshot.staleAfter` (10 min), by the app's fetch or by the server's own check. Otherwise the line is gone.
public enum FreshnessLine {
    public static func shows(pulled: Bool, failed: Bool, fetched: Date?, checked: Date?, now: Date = Date()) -> Bool {
        if pulled || failed { return true }
        for date in [fetched, checked].compactMap({ $0 }) where now.timeIntervalSince(date) > Snapshot.staleAfter {
            return true
        }
        return false
    }
}

/// Lab's card rows (docs/DESIGN.md §6, API.md "Cards for Lab"): long lists fold, the tailnet keeps quiet about
/// devices that are simply there.
public enum LabRows {
    /// A list card with more rows than this shows this many and a "Show N more" row.
    public static let folded = 3

    /// Whether a lab card folds: `list` cards with more than `folded` items.
    public static func folds(_ card: Card) -> Bool {
        card.style == .list && card.items.count > folded
    }

    /// The items to draw: all of them, or the first `folded` while folded.
    public static func shown(_ card: Card, expanded: Bool) -> [Card.Item] {
        folds(card) && !expanded ? Array(card.items.prefix(folded)) : card.items
    }

    /// The value in the right column. A tailnet device that is "online" says nothing (it is simply there; servers
    /// may also send no value), so only the devices that are away or need a look have a word there. "–" and empty
    /// values are no value.
    public static func value(_ item: Card.Item, in card: Card) -> String? {
        guard let v = item.value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        if card.id == "tailnet", v.lowercased() == "online" { return nil }
        return v
    }

    /// The row shows a warning glyph instead of its dot: a warm or red tint, or a tailnet device that is away (any
    /// value other than "online": "offline", "seen 3 h ago").
    public static func warns(_ item: Card.Item, in card: Card) -> Bool {
        switch item.tint {
        case .orange, .yellow, .red: return true
        default: return card.id == "tailnet" && value(item, in: card) != nil
        }
    }

    /// The line under a lab card's title: its `subtitle`, else its `text` when it has rows (the text of a card without
    /// rows is drawn in the panel instead). "Key expiry off on all servers".
    public static func subtitle(_ card: Card) -> String? {
        if let s = card.subtitle, !s.isEmpty { return s }
        guard !card.items.isEmpty, let t = card.text, !t.isEmpty else { return nil }
        return t
    }
}

/// A search poster's words.
public enum PosterText {
    /// "2019 · TV · not requested" → "2019 · TV", once it was requested from the app (its value then says
    /// "requested"). Other subtitles stay.
    public static func withoutRequestState(_ subtitle: String) -> String {
        let suffix = " · not requested"
        return subtitle.hasSuffix(suffix) ? String(subtitle.dropLast(suffix.count)) : subtitle
    }
}

public extension Format {
    /// The clock time under a relative age: "21:03" today, "Thu 21:03" another day this week, "02.11. 21:03"
    /// before that.
    static func clock(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if (1...6).contains(days) {
            let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            return weekdays[(calendar.component(.weekday, from: date) - 1 + 7) % 7] + " " + time
        }
        let d = calendar.dateComponents([.day, .month], from: date)
        return String(format: "%02d.%02d. ", d.day ?? 0, d.month ?? 0) + time
    }
}
