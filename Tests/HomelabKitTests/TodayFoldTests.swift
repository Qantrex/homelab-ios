import Foundation
import Testing
@testable import HomelabKit

/// Today's folds (`TodayFold`): urgent rows stay, long lists fold by density, the Also summaries, the retired
/// Machines section. A fixed clock and calendar, so nothing depends on the day the tests run.
@Suite struct TodayFoldTests {
    static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    /// Sunday 2026-11-08, 10:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_794_132_000)

    /// A day-only due `days` after today.
    static func day(_ days: Int) -> Date { cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: now))! }
    static func deadlines(_ days: [Int]) -> Card {
        Card(id: "deadlines", title: "Deadlines", style: .countdown, items: days.enumerated().map { i, d in
            .init(title: "D\(i)", due: day(d), dueIsDay: true)
        })
    }
    static func rows(_ card: Card, _ density: Density = .standard, expanded: Bool = false) -> TodayFold.Rows {
        TodayFold.rows(card, density: density, expanded: expanded, now: now, calendar: cal)
    }
    static func titles(_ r: TodayFold.Rows) -> [String] { r.items.compactMap(\.title) }

    // MARK: Urgency

    @Test func deadlinesAreUrgentWhenOverdueTodayOrWithin48Hours() {
        let card = Self.deadlines([])
        func urgent(_ d: Card.Item) -> Bool { TodayFold.isUrgent(d, in: card, now: Self.now, calendar: Self.cal) }
        #expect(urgent(.init(title: "late", due: Self.day(-3), dueIsDay: true)))
        #expect(urgent(.init(title: "today", due: Self.day(0), dueIsDay: true)))
        #expect(urgent(.init(title: "tomorrow", due: Self.day(1), dueIsDay: true)))
        #expect(!urgent(.init(title: "in 2 days", due: Self.day(2), dueIsDay: true)))
        #expect(urgent(.init(title: "in 47 h", due: Self.now.addingTimeInterval(47 * 3600))))
        #expect(!urgent(.init(title: "in 49 h", due: Self.now.addingTimeInterval(49 * 3600))))
        #expect(!urgent(.init(title: "no due")))
    }

    @Test func todosAreUrgentWhenPastTheirTimeOrTinted() {
        let card = Card(id: "todos", style: .checklist)
        func urgent(_ d: Card.Item) -> Bool { TodayFold.isUrgent(d, in: card, now: Self.now, calendar: Self.cal) }
        #expect(urgent(.init(title: "past", due: Self.now.addingTimeInterval(-60))))
        #expect(!urgent(.init(title: "later today", due: Self.now.addingTimeInterval(3600))))
        #expect(urgent(.init(title: "yesterday", due: Self.day(-1), dueIsDay: true)))
        #expect(!urgent(.init(title: "today, no time", due: Self.day(0), dueIsDay: true)))
        #expect(!urgent(.init(title: "done and late", done: true, due: Self.day(-1), dueIsDay: true)))
        #expect(urgent(.init(title: "tint", tint: .orange)) && urgent(.init(title: "red", tint: .red)))
        #expect(!urgent(.init(title: "blue", tint: .blue)))
    }

    // MARK: Rows

    @Test func shortListsDoNotFold() {
        let r = Self.rows(Self.deadlines([1, 3, 5, 9]))                 // 4 rows, cap 3: hiding one row saves nothing
        #expect(r.hidden == 0 && !r.folds && r.items.count == 4)
        #expect(Self.rows(Self.deadlines([1, 3])).folds == false)
    }

    @Test func standardFoldsAfterThreeAndSaysWhatComesNext() {
        let r = Self.rows(Self.deadlines([5, 6, 7, 8, 9, 10, 11, 12]))  // none urgent
        #expect(Self.titles(r) == ["D0", "D1", "D2"] && r.hidden == 5 && r.folds)
        #expect(r.hint == "next " + Self.deadlines([8]).items[0].dueText(now: Self.now, calendar: Self.cal)!)
        #expect(TodayFold.foldLabel(r, expanded: false).hasPrefix("Show 5 more · next "))
        #expect(TodayFold.foldLabel(r, expanded: true) == "Show less")
    }

    @Test func urgentRowsNeverFoldAndAreToppedUp() {
        // Two urgent: topped up to 3 with the next soonest; the fold counts only the rest.
        var r = Self.rows(Self.deadlines([-2, 0, 5, 6, 7, 8, 9]))
        #expect(Self.titles(r) == ["D0", "D1", "D2"] && r.hidden == 4)
        // Five urgent: all five show, over the cap.
        r = Self.rows(Self.deadlines([-2, -1, 0, 1, 1, 6, 7, 8]))
        #expect(Self.titles(r) == ["D0", "D1", "D2", "D3", "D4"] && r.hidden == 3)
        // Urgent rows that leave one row behind: nothing folds.
        r = Self.rows(Self.deadlines([-2, -1, 0, 1, 1, 1, 6]))
        #expect(r.items.count == 7 && r.hidden == 0 && !r.folds)
    }

    @Test func tintedRowsOfAnyListStay() {
        let items: [Card.Item] = (0..<8).map { .init(title: "P\($0)", tint: $0 == 6 ? .orange : nil) }
        let r = Self.rows(Card(id: "parcels", style: .list, items: items))
        #expect(Self.titles(r) == ["P0", "P1", "P6"] && r.hidden == 5)   // the order of the card stays
    }

    @Test func expandedShowsAllAndKeepsTheFoldRow() {
        let card = Self.deadlines([5, 6, 7, 8, 9, 10])
        let r = Self.rows(card, expanded: true)
        #expect(r.items.count == 6 && r.hidden == 0 && r.folds)
    }

    @Test func overkillShowsAFewMoreRows() {
        let card = Self.deadlines([5, 6, 7, 8, 9, 10, 11, 12])
        #expect(Self.rows(card, .standard).items.count == 3)
        #expect(Self.rows(card, .overkill).items.count == 5 && Self.rows(card, .overkill).hidden == 3)
        #expect(TodayFold.cap(.overkill) > TodayFold.cap(.standard))
        #expect(TodayFold.approvals(.overkill) > TodayFold.approvals(.standard) && TodayFold.approvals(.standard) == 2)
        #expect(TodayFold.textLines(.overkill) > TodayFold.textLines(.standard))
    }

    @Test func countdownRowsFoldInTheirSortedOrder() {
        var card = Self.deadlines([9, 3, 7, 4, 8, 6])
        card.items[0].title = "last"
        let r = Self.rows(card)
        #expect(Self.titles(r) == ["D1", "D3", "D5"])                      // 3, 4, 6 days
    }

    @Test func otherStylesAndOddCardsNeverFold() {
        let many: [Card.Item] = (0..<12).map { .init(title: "T\($0)", value: "\($0)") }
        for style in [Card.Style.metrics, .text, .posterGrid, .departures] {
            let r = Self.rows(Card(id: "x", style: style, items: many))
            #expect(r.items.count == 12 && !r.folds)
        }
        #expect(Self.rows(Card(id: "empty", style: .list)).items.isEmpty)
        #expect(Self.rows(Card(id: "u", style: .checklist, items: many)).hidden == 9)
        #expect(Self.rows(Card(id: "u", style: .list, items: many)).hidden == 9)
    }

    @Test func textFoldsOnlyWhenItHidesTwoLines() {
        #expect(!TodayFold.textFolds(lines: 4, limit: 3))
        #expect(TodayFold.textFolds(lines: 5, limit: 3))
        #expect(!TodayFold.textFolds(lines: 0, limit: 3))
    }

    // MARK: Cards Today draws

    @Test func theWeatherCardIsDroppedWhenTheHeroSaysIt() {
        let weather = Card(id: "weather", subtitle: "Partly cloudy, 7 °C now", style: .metrics)
        #expect(!TodayFold.drawsOnToday(weather))
        // Nothing for the hero to say: the card stays.
        #expect(TodayFold.drawsOnToday(Card(id: "weather", style: .metrics)))
        #expect(TodayFold.drawsOnToday(Card(id: "weather-2", subtitle: "x", style: .metrics)))
        let plan = TodayFold.plan([weather, Card(id: "note", style: .text, text: "Hi")], dayCardID: nil, departuresMatter: false)
        #expect(plan.blocks.count == 1)
    }

    @Test func plainLines() {
        #expect(TodayFold.isPlainLine("No school"))
        #expect(!TodayFold.isPlainLine("No school\nBack on Monday") && !TodayFold.isPlainLine(String(repeating: "x", count: 81)))
        #expect(!TodayFold.isPlainLine(nil) && !TodayFold.isPlainLine("  "))
    }

    @Test func shortListCardsBecomeOneLineByShape() {
        let playing = Card(id: "anything", title: "Minecraft", icon: "gamecontroller", style: .list, items: [
            .init(title: "Vicky", subtitle: "playing"), .init(title: "Alex", subtitle: "playing")])
        #expect(TodayFold.oneLine(playing) == "Minecraft: Vicky playing, Alex playing")
        #expect(TodayFold.oneLine(Card(id: "g", title: "Game", style: .list, items: [.init(title: "Vicky")])) == "Game: Vicky")
        // Four items, a link, an action, a progress, a long title, a tint, a header action, or Lab: a card.
        let four = Card(id: "g", title: "G", style: .list, items: (0..<4).map { .init(title: "P\($0)") })
        #expect(TodayFold.oneLine(four) == nil)
        for item in [Card.Item(title: "A", url: URL(string: "https://x.example")), .init(title: "A", progress: 0.5),
                     .init(title: "A", action: ItemAction(name: "a")), .init(title: String(repeating: "L", count: 30)),
                     .init(title: "A", tint: .red), .init(title: "A", cancelled: true)] {
            #expect(TodayFold.oneLine(Card(id: "g", title: "G", style: .list, items: [item])) == nil)
        }
        #expect(TodayFold.oneLine(Card(id: "g", title: "G", style: .list, items: [.init(title: "A")], action: ItemAction(name: "a"))) == nil)
        #expect(TodayFold.oneLine(Card(id: "g", title: "G", style: .list, items: [.init(title: "A")], place: .lab)) == nil)
        #expect(TodayFold.oneLine(Card(id: "g", title: "G", style: .list)) == nil)                  // no items
        #expect(TodayFold.oneLine(Card(id: "g", title: "G", style: .metrics, items: [.init(title: "A")])) == nil)
        #expect(TodayFold.oneLine(Card(id: "parcels", title: "Parcels", style: .list, items: [.init(title: "Box")])) == nil)
        #expect(TodayFold.oneLine(Card(id: "grades", title: "Grades", style: .list, items: [.init(title: "A")])) == nil)
    }

    @Test func planSplitsCardsLinesAndAlso() {
        let cards = [
            Card(id: "today", style: .metrics), Card(id: "weather", subtitle: "Sunny, 5 °C now", style: .metrics),
            Card(id: "grades", style: .list, items: [.init(title: "T", subtitle: "Maths", value: "85 %")]),
            Card(id: "mc", title: "Minecraft", style: .list, items: [.init(title: "Vicky", subtitle: "playing")]),
            Card(id: "recent", style: .list, items: [.init(title: "A")]),
            Card(id: "departures", style: .departures),
            Card(id: "todos", style: .checklist, items: [.init(title: "x")]),
            Card(id: "tailnet", style: .list, items: [.init(title: "x")], place: .lab),
        ]
        let plan = TodayFold.plan(cards, dayCardID: "today", departuresMatter: false)
        #expect(plan.also.map(\.id) == ["recent", "grades", "departures"])      // the Also order: downloads, grades, departures
        #expect(plan.blocks.count == 2)
        #expect(plan.blocks[0] == .line(cards[3], "Minecraft: Vicky playing"))
        #expect(plan.blocks[1] == .card(cards[6]))
        // Departures that matter stay a full card, in the server's order.
        let matter = TodayFold.plan(cards, dayCardID: "today", departuresMatter: true)
        #expect(matter.also.map(\.id) == ["recent", "grades"] && matter.blocks.contains(.card(cards[5])))
    }

    // MARK: Departures that matter

    static func board(late: Bool = false, disruption: String? = nil) -> DepartureBoard {
        DepartureBoard(card: Card(id: "departures", title: "U6", style: .departures, text: disruption, items: [
            .init(title: "Floridsdorf", subtitle: "Westbahnhof", value: "10:03", due: Self.now.addingTimeInterval(3 * 60)),
            .init(title: "Floridsdorf", subtitle: late ? "Westbahnhof · +2 min" : "Westbahnhof", value: "10:10", tint: late ? .orange : nil,
                  due: Self.now.addingTimeInterval(10 * 60)),
            .init(title: "Floridsdorf", subtitle: "Westbahnhof", value: "10:17", due: Self.now.addingTimeInterval(17 * 60)),
            .init(title: "Siebenhirten", subtitle: "Jägerstraße", value: "10:05", due: Self.now.addingTimeInterval(5 * 60)),
            .init(title: "Siebenhirten", subtitle: "Jägerstraße", value: "10:11", due: Self.now.addingTimeInterval(11 * 60)),
        ]))
    }

    /// A day card with "Leave by" `minutes` from `now` (UTC), today.
    static func day(leaveIn minutes: Int, date: String = "2026-11-08") -> Card {
        let leave = 10 * 60 + minutes
        return Card(id: "today", style: .metrics, items: [
            .init(title: "Wake-up", value: "06:00"),
            .init(title: "Leave by", value: String(format: "%02d:%02d", leave / 60, leave % 60)),
            .init(title: "First lesson", value: "13:00"),
        ], date: date)
    }

    @Test func departuresMatterWithinAnHourOfLeavingOrOnADisruption() {
        func matters(_ b: DepartureBoard, _ day: Card?) -> Bool { TodayFold.departuresMatter(b, day: day, now: Self.now, calendar: Self.cal) }
        #expect(matters(Self.board(), Self.day(leaveIn: 45)))
        #expect(matters(Self.board(), Self.day(leaveIn: 60)))
        #expect(!matters(Self.board(), Self.day(leaveIn: 61)))
        #expect(!matters(Self.board(), Self.day(leaveIn: 180)))
        #expect(!matters(Self.board(), nil))
        #expect(matters(Self.board(disruption: "U6: Schadhaftes Fahrzeug"), nil))
        #expect(matters(Self.board(disruption: "x"), Self.day(leaveIn: 300)))
        // Tomorrow's card or an old one is not about now; once "Leave by" has passed the next stop is the lesson.
        #expect(!matters(Self.board(), Self.day(leaveIn: 30, date: "2026-11-09")))
        #expect(!matters(Self.board(), Self.day(leaveIn: 30, date: "2026-11-07")))
        #expect(!matters(Self.board(), Self.day(leaveIn: -20)))
    }

    // MARK: Summaries

    static let deals: [Deal] = [
        Deal(id: 1, title: "GPU", price: 140, discount: 0.7), Deal(id: 2, title: "RAM kit", price: 100, discount: 0.5),
        Deal(id: 3, title: "Monitor", price: 90, discount: 0.3), Deal(id: 4, title: "Desk", price: 50, discount: nil)]

    @Test func dealsSummary() {
        let m = "\u{2212}"
        #expect(TodayFold.summary(deals: Array(Self.deals.prefix(2)), density: .standard) == "2 deals · best \(m)70\u{00A0}%")
        #expect(TodayFold.summary(deals: [Self.deals[1]], density: .standard) == "1 deal · \(m)50\u{00A0}%")
        #expect(TodayFold.summary(deals: [Self.deals[3]], density: .standard) == "1 deal")
        #expect(TodayFold.summary(deals: [], density: .standard) == nil && TodayFold.summary(deals: [], density: .overkill) == nil)
        let overkill = TodayFold.summary(deals: Self.deals, density: .overkill)
        #expect(overkill == "4 deals · best \(m)70\u{00A0}% · GPU €140, RAM kit €100")
        #expect(overkill!.count > TodayFold.summary(deals: Self.deals, density: .standard)!.count)
        let huge = (1...200).map { Deal(id: Int64($0), title: String(repeating: "T", count: 200), price: 1, discount: 0.4) }
        #expect(TodayFold.summary(deals: huge, density: .overkill)!.count < 100)
    }

    static func downloads(_ n: Int, title: String = "Night Signals") -> Card {
        Card(id: "recent", title: "Recently added", style: .list, items: (0..<n).map { .init(title: "\(title) \($0)", subtitle: "Music") })
    }

    @Test func downloadsSummary() {
        #expect(TodayFold.summary(downloads: Self.downloads(8), density: .standard) == "Latest: Night Signals 0 · +7 more")
        #expect(TodayFold.summary(downloads: Self.downloads(8), density: .overkill) == "Latest: Night Signals 0, Night Signals 1 · +6 more")
        #expect(TodayFold.summary(downloads: Self.downloads(1), density: .standard) == "Latest: Night Signals 0")
        #expect(TodayFold.summary(downloads: Self.downloads(2), density: .overkill) == "Latest: Night Signals 0, Night Signals 1")
        #expect(TodayFold.summary(downloads: Self.downloads(0), density: .standard) == nil)
        let long = TodayFold.summary(downloads: Self.downloads(500, title: String(repeating: "x", count: 500)), density: .standard)!
        #expect(long.count < 70 && long.hasSuffix("+499 more"))
    }

    static func grades(_ n: Int) -> Card {
        let all: [Card.Item] = [.init(title: "Test", subtitle: "ITP", value: "95 %"), .init(title: "Quiz", subtitle: "SEW", value: "88 %"),
                                .init(title: "Essay", subtitle: "D", value: "2"), .init(title: "Oral", subtitle: "E", value: "1")]
        return Card(id: "grades", title: "New grades", style: .list, items: Array(all.prefix(n)))
    }

    @Test func gradesSummary() {
        #expect(TodayFold.summary(grades: Self.grades(3), density: .standard) == "3 new grades · latest ITP 95 %")
        #expect(TodayFold.summary(grades: Self.grades(3), density: .overkill) == "3 new grades · ITP 95 %, SEW 88 %, D 2")
        #expect(TodayFold.summary(grades: Self.grades(1), density: .standard) == "1 new grade · ITP 95 %")
        #expect(TodayFold.summary(grades: Self.grades(4), density: .overkill) == "4 new grades · ITP 95 %, SEW 88 %, D 2")
        #expect(TodayFold.summary(grades: Self.grades(0), density: .standard) == nil)
        let bare = Card(id: "grades", style: .list, items: [.init(), .init()])
        #expect(TodayFold.summary(grades: bare, density: .standard) == "2 new grades")
    }

    @Test func departuresSummary() {
        let b = Self.board()
        #expect(TodayFold.summary(departures: b, now: Self.now, density: .standard) == "U6 Floridsdorf 10:03 · 10:10")
        #expect(TodayFold.summary(departures: b, now: Self.now, density: .overkill)
                == "U6 Floridsdorf 10:03 · 10:10 · 10:17 · Siebenhirten 10:05 · 10:11")
        #expect(TodayFold.summary(departures: Self.board(late: true), now: Self.now, density: .standard) == "U6 Floridsdorf 10:03 · 10:10+2")
        // Trains that have left drop out; none left says so; no board, no row.
        #expect(TodayFold.summary(departures: b, now: Self.now.addingTimeInterval(4 * 60), density: .standard) == "U6 Floridsdorf 10:10 · 10:17")
        #expect(TodayFold.summary(departures: b, now: Self.now.addingTimeInterval(3600), density: .standard) == "U6 · no more departures soon")
        #expect(TodayFold.summary(departures: DepartureBoard(card: Card(id: "departures", style: .departures)), now: Self.now,
                                  density: .standard) == nil)
    }

    @Test func overkillSaysMoreInEveryLine() {
        let cards: [Card] = [Self.downloads(8), Self.grades(3), Card(id: "departures", title: "U6", style: .departures, items: Self.board().groups.flatMap { g in
            g.departures.map { Card.Item(title: g.towards, subtitle: g.stop, value: $0.value, due: $0.due) } })]
        for card in cards {
            let s = TodayFold.summary(card, now: Self.now, density: .standard)!, o = TodayFold.summary(card, now: Self.now, density: .overkill)!
            #expect(o.count > s.count, "\(card.id): \(s) | \(o)")
        }
        #expect(TodayFold.summary(Card(id: "x", style: .list, items: [.init(title: "a")]), now: Self.now, density: .standard) == nil)
    }

    @Test func alsoKindsAndSpokenLabel() {
        #expect(TodayFold.alsoKind(Self.downloads(1)) == .downloads && TodayFold.alsoKind(Self.grades(1)) == .grades)
        #expect(TodayFold.alsoKind(Card(id: "dl", title: "Downloads", style: .list)) == nil)
        #expect(TodayFold.alsoKind(Card(id: "downloads", style: .list)) == .downloads)
        #expect(TodayFold.alsoKind(Card(id: "downloads", style: .metrics)) == nil)
        #expect(TodayFold.alsoKind(Card(id: "whatever", style: .departures)) == .departures)
        #expect(TodayFold.alsoKind(Card(id: "grades", style: .list, place: .lab)) == nil)
        #expect(TodayFold.spokenAlso(.downloads, count: 8, summary: "Latest: Night Signals · +7 more")
                == "Recent downloads, 8, Latest: Night Signals · +7 more")
        #expect(TodayFold.spokenAlso(.departures, count: nil, summary: "U6 x") == "Departures, U6 x")
    }

    // MARK: Machines are not on Today

    @Test func machinesAreNotOnTodayButStayInTheFile() throws {
        #expect(!TodaySection.machines.isOnToday && TodaySection.day.isOnToday)
        let l = TodayLayout.standard
        #expect(l.sections.contains(.machines) && !l.listed.contains(.machines))
        #expect(l.listedVisibleCount == 6)
        for d in Density.allCases { #expect(!d.sections(l).contains(.machines)) }
        // An old file with machines in it decodes and saves back unchanged.
        let json = #"{"hidden":["report"],"order":["machines","day","waiting","deals","home","cards","report"],"rules":{"machines":{"kind":"always"}}}"#
        let decoded = try JSONDecoder().decode(TodayLayout.self, from: Data(json.utf8))
        #expect(decoded.sections.first == .machines && decoded.rule(for: .machines) == .always)
        #expect(!Density.overkill.sections(decoded).contains(.machines))
        let back = try JSONDecoder().decode(TodayLayout.self, from: JSONEncoder().encode(decoded))
        #expect(back == decoded)
        // Reordering what Settings lists moves machines out of the way, never into view.
        var moved = decoded
        moved.moveListed(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(moved.listed.count == 6 && moved.sections.last == .machines)
    }
}
