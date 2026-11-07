import Foundation

/// How much of a card Today shows (docs/DESIGN.md "Today folds"): long lists fold behind one "Show N more" row, but a
/// row that needs me is never folded; deals, downloads, grades and departures become one-line summaries in the
/// "Also" panel; a card the hero already says (the weather) is not drawn twice. Pure, so it is tested on Linux. All
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

    /// A row that is never folded: a warm or red tint (`LabRows.warns`), a deadline overdue, due today or within
    /// 48 hours, a to-do past its time. A done to-do is not urgent by its date.
    public static func isUrgent(_ item: Card.Item, in card: Card, now: Date, calendar: Calendar = .current) -> Bool {
        if LabRows.warns(item, in: card) { return true }
        guard item.done != true, let due = item.due else { return false }
        let today = calendar.startOfDay(for: now)
        switch card.style {
        case .countdown:
            if item.dueIsDay {
                let days = calendar.dateComponents([.day], from: today, to: Format.dueDay(due, calendar: calendar)).day ?? 0
                return days <= 1   // today, tomorrow (that day's end is within 48 h) or overdue
            }
            return due <= now.addingTimeInterval(48 * 3600)
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
    /// rows in order to the density's cap. The order of the rows stays.
    public static func rows(_ items: [Card.Item], in card: Card, density: Density, expanded: Bool, now: Date,
                            calendar: Calendar = .current) -> Rows {
        let cap = cap(density)
        guard foldsStyle(card.style), items.count - cap >= minHidden else {
            return Rows(items: items, hidden: 0, folds: false, hint: nil)
        }
        if expanded { return Rows(items: items, hidden: 0, folds: true, hint: nil) }
        var keep = Set(items.indices.filter { isUrgent(items[$0], in: card, now: now, calendar: calendar) })
        for i in items.indices where keep.count < cap { keep.insert(i) }
        let shown = items.indices.filter(keep.contains).map { items[$0] }
        let hiddenRows = items.indices.filter { !keep.contains($0) }.map { items[$0] }
        // Urgent rows can leave fewer than `minHidden` behind: then show them all.
        guard hiddenRows.count >= minHidden else { return Rows(items: items, hidden: 0, folds: false, hint: nil) }
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
    /// have their own look (parcels, lessons) and the Also kinds never. Nil: draw the card.
    public static func oneLine(_ card: Card) -> String? {
        guard card.style == .list, card.place == .today, card.action == nil, alsoKind(card) == nil,
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

    // MARK: The "Also" panel

    /// What the "Also" panel summarises, in this order.
    public enum AlsoKind: String, CaseIterable, Sendable {
        case deals, downloads, grades, departures

        public var title: String {
            switch self {
            case .deals: "Deals"
            case .downloads: "Recent downloads"
            case .grades: "New grades"
            case .departures: "Departures"
            }
        }

        public var symbol: String {
            switch self {
            case .deals: "tag"
            case .downloads: "arrow.down.circle"
            case .grades: "graduationcap"
            case .departures: "tram.fill"
            }
        }

        var order: Int { Self.allCases.firstIndex(of: self) ?? 9 }
    }

    /// The Also kind of a Today card: the departures style, the downloads card ("downloads", "recent"), "grades".
    public static func alsoKind(_ card: Card) -> AlsoKind? {
        guard card.place == .today else { return nil }
        if card.style == .departures { return .departures }
        switch card.id {
        case "downloads", "recent": return card.style == .list ? .downloads : nil
        case "grades": return card.style == .list ? .grades : nil
        default: return nil
        }
    }

    /// Departures show as the full board, not a summary, when "Leave by" is within 60 minutes or a disruption is
    /// reported: then it is what the morning is about.
    public static func departuresMatter(_ board: DepartureBoard, day: Card?, now: Date, calendar: Calendar = .current) -> Bool {
        if board.isDisrupted { return true }
        guard let day else { return false }
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
        /// The Also cards in the Also order (deals come from the deals list, not a card).
        public var also: [Card]
    }

    /// Splits the server's Today cards into cards, one-liners and the Also summaries. `departuresMatter` keeps the
    /// departures card as a card.
    public static func plan(_ cards: [Card], dayCardID: String?, departuresMatter: Bool) -> Plan {
        var blocks: [Block] = []
        var also: [Card] = []
        for card in cards where card.id != dayCardID && card.place != .lab && drawsOnToday(card) {
            if let kind = alsoKind(card), !(kind == .departures && departuresMatter) {
                also.append(card)
            } else if let line = oneLine(card) {
                blocks.append(.line(card, line))
            } else {
                blocks.append(.card(card))
            }
        }
        also.sort { (alsoKind($0)?.order ?? 9) < (alsoKind($1)?.order ?? 9) }
        return Plan(blocks: blocks, also: also)
    }

    // MARK: Summaries

    static func short(_ text: String, _ max: Int = 24) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > max ? String(t.prefix(max - 1)) + "…" : t
    }

    private static func plural(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "\(n) \(one)" : "\(n) \(many)" }

    /// "2 deals · best −50 %"; Overkill names the best ones: "4 deals · best −70 % · GPU €140, RAM kit €100".
    public static func summary(deals: [Deal], density: Density) -> String? {
        guard !deals.isEmpty else { return nil }
        var parts = [plural(deals.count, "deal", "deals")]
        if let word = DealFormat.discount(deals.compactMap(\.share).max()) { parts.append((deals.count > 1 ? "best " : "") + word) }
        if density == .overkill {
            let named = deals.sorted { ($0.share ?? 0) > ($1.share ?? 0) }.prefix(2).map { deal in
                short(deal.title, 18) + (deal.price.map { " " + DealFormat.price($0).replacingOccurrences(of: "\u{00A0}", with: "") } ?? "")
            }
            parts.append(named.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    /// "Latest: <title> · +7 more"; Overkill names two: "Latest: A, B · +6 more". Nil without titles.
    public static func summary(downloads card: Card, density: Density) -> String? {
        let titles = card.items.compactMap { $0.title.map { short($0, density == .overkill ? 28 : 36) } }.filter { !$0.isEmpty }
        guard !titles.isEmpty else { return nil }
        let named = min(density == .overkill ? 2 : 1, titles.count)
        let more = titles.count - named
        return "Latest: " + titles.prefix(named).joined(separator: ", ") + (more > 0 ? " · +\(more) more" : "")
    }

    /// "3 new grades · latest Maths 85 %"; Overkill lists up to three: "3 new grades · ITP 95 %, SEW 88 %, D 2".
    public static func summary(grades card: Card, density: Density) -> String? {
        guard !card.items.isEmpty else { return nil }
        let entries: [String] = card.items.compactMap { item in
            let subject = (item.subtitle ?? item.title).map { short($0, 18) } ?? ""
            let words = [subject, item.value?.trimmingCharacters(in: .whitespaces) ?? ""].filter { !$0.isEmpty }
            return words.isEmpty ? nil : words.joined(separator: " ")
        }
        let head = plural(card.items.count, "new grade", "new grades")
        guard !entries.isEmpty else { return head }
        if density == .overkill { return head + " · " + entries.prefix(3).joined(separator: ", ") }
        return head + " · " + (card.items.count > 1 ? "latest " : "") + entries[0]
    }

    /// "U6 Floridsdorf 00:03 · 00:10"; Overkill names both directions: "U6 Floridsdorf 00:03 · 00:10 · 00:17 ·
    /// Siebenhirten 00:05 · 00:11 · 00:18". A late train has its "+2". Nil for a board without departures.
    public static func summary(departures board: DepartureBoard, now: Date, density: Density) -> String? {
        guard !board.isEmpty else { return nil }
        let up = board.upcoming(now: now)
        guard !up.groups.isEmpty else { return board.line + " · no more departures soon" }
        func times(_ group: DepartureBoard.Group, _ count: Int) -> String {
            group.departures.prefix(count)
                .map { DepartureBoard.clock($0.due) + ($0.late ? ($0.delay.map { "+\($0)" } ?? " late") : "") }
                .joined(separator: " · ")
        }
        let overkill = density == .overkill
        let line = up.groups.prefix(overkill ? 2 : 1).map { "\(short($0.towards, 20)) \(times($0, overkill ? 3 : 2))" }
            .joined(separator: " · ")
        return board.line + " " + line
    }

    /// The Also card's summary for its kind.
    public static func summary(_ card: Card, now: Date, density: Density) -> String? {
        switch alsoKind(card) {
        case .downloads: summary(downloads: card, density: density)
        case .grades: summary(grades: card, density: density)
        case .departures: summary(departures: DepartureBoard(card: card), now: now, density: density)
        default: nil
        }
    }

    /// VoiceOver's label of an Also row: the title, the count when there is one, the summary ("Recent downloads, 8,
    /// Latest: Night Signals"); the hint says "Double-tap to expand".
    public static func spokenAlso(_ kind: AlsoKind, count: Int?, summary: String) -> String {
        [kind.title, count.map(String.init), summary].compactMap { $0 }.joined(separator: ", ")
    }
}
