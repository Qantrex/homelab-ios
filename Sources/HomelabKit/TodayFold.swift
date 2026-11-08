import Foundation

/// How much of a card Today shows (docs/DESIGN.md "Today folds"): long lists fold behind one "Show N more" row, but a
/// row that needs me is never folded; deals, downloads, grades and news become small tiles that open the full list in a
/// sheet; departures are not a card on Today but sit in the day section while a "Leave by" is near; a card the hero
/// already says (the weather) is not drawn twice. Pure, so it is tested on Linux. All
/// numbers are for the default text size; larger sizes simply scroll further.
public enum TodayFold {
    // MARK: Caps

    /// Rows a folded list shows (urgent rows come on top of this): Standard 3, Overkill a couple more.
    public static func cap(_ density: Density) -> Int { density == .overkill ? 5 : 3 }

    /// A fold hides at least this many rows; "Show 1 more" costs the row it would hide.
    public static let minHidden = 2

    /// Proposals "To approve" lists before "and N more".
    public static func approvals(_ density: Density) -> Int { density == .overkill ? 4 : 2 }

    /// Lines a folded text card (the briefing) shows.
    public static func textLines(_ density: Density) -> Int { density == .overkill ? 6 : 3 }

    /// Fold text only when that hides at least two lines.
    public static func textFolds(lines: Int, limit: Int) -> Bool { lines >= limit + 2 }

    // MARK: Which cards

    /// Whether Today draws this card at all. The `weather` card is dropped when the hero's weather line says it
    /// (`WeatherLine`); the data stays in the API.
    public static func drawsOnToday(_ card: Card) -> Bool {
        !(card.id == "weather" && WeatherLine.text(card) != nil)
    }

    /// A day card that is only a short sentence ("No school") is a plain line without a panel.
    public static func isPlainLine(_ text: String?) -> Bool {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return false }
        return !text.contains("\n") && text.count <= 80
    }

    // MARK: Urgency

    /// A deadline counts as urgent when it is overdue or due within this many days (owner 2026-11-09: "deadlines that
    /// show without folding should only be 3d or less").
    public static let urgentDays = 3

    /// A row that is never folded: a warm or red tint (`LabRows.warns`), a deadline overdue or due within
    /// `urgentDays` days, a to-do past its time. A done to-do is not urgent by its date.
    public static func isUrgent(_ item: Card.Item, in card: Card, now: Date, calendar: Calendar = .current) -> Bool {
        if LabRows.warns(item, in: card) { return true }
        guard item.done != true, let due = item.due else { return false }
        let today = calendar.startOfDay(for: now)
        switch card.style {
        case .countdown:
            if item.dueIsDay {
                let days = calendar.dateComponents([.day], from: today, to: Format.dueDay(due, calendar: calendar)).day ?? 0
                return days <= urgentDays   // overdue, today ... in 3 days
            }
            return due <= now.addingTimeInterval(Double(urgentDays) * 24 * 3600)
        case .checklist:
            return item.dueIsDay ? Format.dueDay(due, calendar: calendar) < today : due < now
        default:
            return false
        }
    }

    // MARK: Folding rows

    public struct Rows: Equatable, Sendable {
        /// The rows to draw, in display order.
        public var items: [Card.Item]
        /// Rows behind "Show N more" (0 when nothing is folded).
        public var hidden: Int
        /// The card can fold at all (a fold row shows: "Show N more" or, expanded, "Show less").
        public var folds: Bool
        /// "next Fri": when the first hidden row of a countdown card is due.
        public var hint: String?
    }

    /// Whether a card's rows fold on Today: list, checklist and countdown cards.
    public static func foldsStyle(_ style: Card.Style) -> Bool {
        style == .list || style == .checklist || style == .countdown
    }

    /// The rows Today draws for `items` (the card's rows in display order, e.g. countdown sorted): all of them when
    /// expanded or when folding would hide fewer than `minHidden`; else every urgent row, topped up with the next
    /// rows in order to the density's cap. The order of the rows stays. A countdown card (deadlines) is the exception
    /// (owner 2026-11-09): it shows only the urgent rows (overdue or within `urgentDays` days), never topped up, and
    /// folds as soon as one later deadline is behind it; if none is urgent only the fold row is left.
    public static func rows(_ items: [Card.Item], in card: Card, density: Density, expanded: Bool, now: Date,
                            calendar: Calendar = .current) -> Rows {
        let cap = cap(density)
        let strict = card.style == .countdown
        guard foldsStyle(card.style), strict ? !items.isEmpty : items.count - cap >= minHidden else {
            return Rows(items: items, hidden: 0, folds: false, hint: nil)
        }
        if expanded { return Rows(items: items, hidden: 0, folds: true, hint: nil) }
        var keep = Set(items.indices.filter { isUrgent(items[$0], in: card, now: now, calendar: calendar) })
        if !strict { for i in items.indices where keep.count < cap { keep.insert(i) } }
        let shown = items.indices.filter(keep.contains).map { items[$0] }
        let hiddenRows = items.indices.filter { !keep.contains($0) }.map { items[$0] }
        // Urgent rows can leave fewer than `minHidden` behind: then show them all.
        guard hiddenRows.count >= (strict ? 1 : minHidden) else { return Rows(items: items, hidden: 0, folds: false, hint: nil) }
        var hint: String?
        if card.style == .countdown, let next = hiddenRows.first?.dueText(now: now, calendar: calendar) { hint = "next " + next }
        return Rows(items: shown, hidden: hiddenRows.count, folds: true, hint: hint)
    }

    /// The card's own rows in display order, for `rows`.
    public static func rows(_ card: Card, density: Density, expanded: Bool, now: Date, calendar: Calendar = .current) -> Rows {
        rows(card.style == .countdown ? card.sortedForCountdown : card.items, in: card, density: density,
             expanded: expanded, now: now, calendar: calendar)
    }

    /// "Show 8 more · next Fri" / "Show less".
    public static func foldLabel(_ rows: Rows, expanded: Bool) -> String {
        if expanded { return "Show less" }
        return "Show \(rows.hidden) more" + (rows.hint.map { " · " + $0 } ?? "")
    }

    // MARK: One-line cards

    /// An unknown card as one line: a `list` card with 1…3 short, plain items (no link, action, progress, cancellation
    /// or tint) and no header action: "Minecraft: Vicky playing". By the card's shape, not its id; the cards that
    /// have their own look (parcels, lessons) and the tile kinds never. Nil: draw the card.
    public static func oneLine(_ card: Card) -> String? {
        guard card.style == .list, card.place == .today, card.action == nil, tileKind(card) == nil,
              !["parcels", "lessons"].contains(card.id), (1...3).contains(card.items.count) else { return nil }
        var parts: [String] = []
        for item in card.items {
            guard let title = item.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty, title.count <= 24,
                  (item.subtitle?.count ?? 0) <= 32, item.url == nil, item.action == nil, item.progress == nil,
                  item.cancelled != true, item.tint == nil || item.tint == .gray else { return nil }
            let rest = [item.subtitle, item.value].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            parts.append(([title] + rest).joined(separator: " "))
        }
        let name = (card.title ?? card.id).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? parts.joined(separator: ", ") : name + ": " + parts.joined(separator: ", ")
    }

    // MARK: Tiles (deals, downloads, grades, news)

    /// What the tiles on Today stand for, in this order. A tap opens the full list in a sheet.
    public enum TileKind: String, CaseIterable, Sendable, Identifiable {
        case deals, downloads, grades, news

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .deals: "Deals"
            case .downloads: "Downloads"
            case .grades: "Grades"
            case .news: "News"
            }
        }

        public var symbol: String {
            switch self {
            case .deals: "tag"
            case .downloads: "arrow.down.circle"
            case .grades: "graduationcap"
            case .news: "newspaper"
            }
        }

        var order: Int { Self.allCases.firstIndex(of: self) ?? 9 }
    }

    /// The tile kind of a Today card: the downloads card ("downloads", "recent"), "grades", "news". Deals come from the deals
    /// list, not a card.
    public static func tileKind(_ card: Card) -> TileKind? {
        guard card.place == .today, card.style == .list else { return nil }
        switch card.id {
        case "downloads", "recent": return .downloads
        case "grades": return .grades
        case "news": return .news
        default: return nil
        }
    }

    /// The departures card of Today. It is never a block of its own: the day section draws it while
    /// `departuresMatter`.
    public static func isDeparturesCard(_ card: Card) -> Bool { card.place == .today && card.style == .departures }

    /// Departures are on Today only while the day has an upcoming "Leave by" within 60 minutes (owner 2026-11-08), and
    /// then in the day section. A disruption alone does not show them on a day without one; tomorrow's or an old day
    /// card never counts. A board without departures and without a disruption has nothing to show.
    public static func departuresMatter(_ board: DepartureBoard, day: Card?, now: Date, calendar: Calendar = .current) -> Bool {
        guard !board.isEmpty || board.isDisrupted, let day else { return false }
        let line = DayTimeline(card: day, now: now, calendar: calendar)
        guard !line.isTomorrow, !line.isStale, let next = line.next, let minutes = line.minutesToNext else { return false }
        return (next.item.title ?? "").lowercased().contains("leave") && (0...60).contains(minutes)
    }

    /// How Today lays out the cards.
    public enum Block: Equatable, Sendable {
        case card(Card)
        case line(Card, String)
    }

    public struct Plan: Equatable, Sendable {
        public var blocks: [Block]
        /// The cards that become tiles, in the tile order (deals come from the deals list, not a card).
        public var tileCards: [Card]
        /// The departures card, for the day section (whether it shows is `departuresMatter`).
        public var departures: Card?
    }

    /// Splits the server's Today cards into cards, one-liners, tile cards and the departures card.
    public static func plan(_ cards: [Card], dayCardID: String?) -> Plan {
        var blocks: [Block] = []
        var tileCards: [Card] = []
        var departures: Card?
        for card in cards where card.id != dayCardID && card.place != .lab && drawsOnToday(card) {
            if isDeparturesCard(card) {
                departures = departures ?? card
            } else if tileKind(card) != nil {
                tileCards.append(card)
            } else if let line = oneLine(card) {
                blocks.append(.line(card, line))
            } else {
                blocks.append(.card(card))
            }
        }
        tileCards.sort { (tileKind($0)?.order ?? 9) < (tileKind($1)?.order ?? 9) }
        return Plan(blocks: blocks, tileCards: tileCards, departures: departures)
    }

    /// One tile: icon + title, a big count, one short line.
    public struct Tile: Equatable, Sendable, Identifiable {
        public var kind: TileKind
        public var count: Int
        /// "best −50 %", "Dune +7", "ITP 95 %"; Overkill says more ("best −70 % · GPU €140").
        public var line: String
        /// A row in it needs me (a warm tint); never for deals.
        public var urgent: Bool
        public var id: String { kind.rawValue }

        /// VoiceOver: "Deals, 2, best minus 50 percent" (the hint says "Opens the list").
        public var spoken: String {
            [kind.title, String(count), TodayFold.spokenLine(line)].filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    /// The tiles in order: deals, downloads, grades; a kind without anything is not there.
    public static func tiles(cards: [Card], deals: [Deal], density: Density) -> [Tile] {
        var tiles: [Tile] = []
        if !deals.isEmpty { tiles.append(Tile(kind: .deals, count: deals.count, line: line(deals: deals, density: density), urgent: false)) }
        for card in cards.sorted(by: { (tileKind($0)?.order ?? 9) < (tileKind($1)?.order ?? 9) }) {
            guard let kind = tileKind(card), !card.items.isEmpty, !tiles.contains(where: { $0.kind == kind }) else { continue }
            let text: String
            switch kind {
            case .downloads: text = line(downloads: card, density: density)
            case .news: text = line(news: card, density: density)
            default: text = line(grades: card, density: density)
            }
            tiles.append(Tile(kind: kind, count: card.items.count, line: text,
                              urgent: card.items.contains { LabRows.warns($0, in: card) }))
        }
        return tiles
    }

    /// How the tiles sit: the number of tiles per row. 4 is 2 by 2, 3 one row of 3, 2 one row of 2, 1 full width; at
    /// accessibility text sizes one full-width tile per row. Never uneven.
    public static func tileRows(count: Int, stacked: Bool) -> [Int] {
        guard count > 0 else { return [] }
        if stacked { return Array(repeating: 1, count: count) }
        switch count {
        case 1: return [1]
        case 2: return [2]
        case 3: return [3]
        case 4: return [2, 2]
        default:   // more than four never happens today; keep rows even where possible
            return count % 3 == 0 ? Array(repeating: 3, count: count / 3)
                 : count % 2 == 0 ? Array(repeating: 2, count: count / 2) : Array(repeating: 1, count: count)
        }
    }

    // MARK: Tile lines

    static func short(_ text: String, _ max: Int = 24) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > max ? String(t.prefix(max - 1)) + "…" : t
    }

    /// "best −50 %" (one deal: "−50 %"); no discount: "act now". Overkill adds the best deal: "best −70 % · GPU €140".
    static func line(deals: [Deal], density: Density) -> String {
        var parts: [String] = []
        if let word = DealFormat.discount(deals.compactMap(\.share).max()) {
            parts.append((deals.count > 1 ? "best " : "") + word)
        } else {
            parts.append("act now")
        }
        if density == .overkill, let top = deals.max(by: { ($0.share ?? 0) < ($1.share ?? 0) }) {
            parts.append(short(top.title, 16) + (top.price.map { " " + DealFormat.price($0).replacingOccurrences(of: "\u{00A0}", with: "") } ?? ""))
        }
        return parts.joined(separator: " · ")
    }

    /// "Dune +7" (the latest and how many more); Overkill names two: "Dune, Arrival +6".
    static func line(downloads card: Card, density: Density) -> String {
        let titles = card.items.compactMap { $0.title.map { short($0, 14) } }.filter { !$0.isEmpty }
        guard !titles.isEmpty else { return "" }
        let named = min(density == .overkill ? 2 : 1, titles.count)
        let more = card.items.count - named
        return titles.prefix(named).joined(separator: ", ") + (more > 0 ? " +\(more)" : "")
    }

    /// Standard: the top headline; Overkill: the digest when the server wrote one.
    static func line(news card: Card, density: Density) -> String {
        let top = card.items.compactMap { $0.title?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
        let digest = card.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if density == .overkill, !digest.isEmpty { return short(digest, 120) }
        return short(top, 60)
    }

    /// "ITP 95 %" (the latest); Overkill names two: "ITP 95 %, SEW 88 %".
    static func line(grades card: Card, density: Density) -> String {
        let entries: [String] = card.items.compactMap { item in
            let subject = (item.subtitle ?? item.title).map { short($0, 12) } ?? ""
            let words = [subject, item.value?.trimmingCharacters(in: .whitespaces) ?? ""].filter { !$0.isEmpty }
            return words.isEmpty ? nil : words.joined(separator: " ")
        }
        return entries.prefix(density == .overkill ? 2 : 1).joined(separator: ", ")
    }

    /// A tile line for VoiceOver: "best −50 %" -> "best minus 50 percent", "GPU €140" -> "GPU 140 euros", "+7" -> "plus 7".
    static func spokenLine(_ text: String) -> String {
        var t = Format.spoken(text).replacingOccurrences(of: "\u{2212}", with: "minus ")
        t = t.replacingOccurrences(of: "\u{00A0}%", with: " percent").replacingOccurrences(of: " %", with: " percent")
        t = t.replacing(/€\s?([0-9][0-9.,]*)/) { "\($0.output.1) euros" }
        t = t.replacing(/\+([0-9]+)/) { "plus \($0.output.1)" }
        return t
    }
}
