import Foundation
import Testing
@testable import HomelabKit

/// Round-1 test findings on Today, Home tiles, widgets and the Leave-by activity.
@Suite struct Round1TodayFixTests {
    // MARK: Home tiles: a scene that never ran

    @Test func aSceneThatNeverRanSaysTapToRunNotRanAgo() {
        let long = Date(timeIntervalSince1970: 1_700_000_000)
        let never = HAEntity(entityID: "scene.relax", state: "unknown", name: "Relax", lastChanged: long)
        #expect(never.runCaption == .neverRan)
        let gone = HAEntity(entityID: "scene.party", state: "unavailable", name: "Party", lastChanged: long)
        #expect(gone.runCaption == .text("Unavailable"))
        let ran = HAEntity(entityID: "scene.film", state: "2026-11-07T20:00:00+00:00", name: "Film", lastChanged: long)
        #expect(ran.runCaption == .ran(long))
        let undated = HAEntity(entityID: "scene.x", state: "2026-11-07T20:00:00+00:00", name: "X")
        #expect(undated.runCaption == .neverRan)
    }

    // MARK: Folding

    @Test func emptyListCardsAreSkippedOnTodayButNotInHyperdetail() {
        let empty = Card(id: "todos", title: "To-dos", style: .checklist)
        let noteOnly = Card(id: "recent2", title: "Nothing", style: .list, text: "All done")
        let full = Card(id: "full", style: .list, items: [.init(title: "a"), .init(title: "b"), .init(title: "c"), .init(title: "d")])
        let plan = TodayFold.plan([empty, noteOnly, full], dayCardID: nil)
        #expect(plan.blocks.map { if case .card(let c) = $0 { c.id } else { "line" } } == ["recent2", "full"])
        let hyper = TodayFold.plan([empty], dayCardID: nil, density: .hyperdetail)
        #expect(hyper.blocks.count == 1)
        #expect(TodayFold.isEmptyShell(empty) && !TodayFold.isEmptyShell(noteOnly) && !TodayFold.isEmptyShell(full))
    }

    @Test func hyperdetailDrawsTheDeparturesWhenTheDayDoesNot() {
        let board = Card(id: "departures", title: "U6", style: .departures, items: [
            .init(title: "Floridsdorf", subtitle: "Westbahnhof", value: "10:03", due: TodayFoldTests.now.addingTimeInterval(180))])
        let withStops = TodayFoldTests.day(leaveIn: 30)
        // The day section draws the board: not a block.
        let a = TodayFold.plan([withStops, board], dayCardID: "today", density: .hyperdetail)
        #expect(a.departures == board && a.blocks.isEmpty)
        // No day card, or a day without stops: the board is a normal block.
        let b = TodayFold.plan([board], dayCardID: nil, density: .hyperdetail)
        #expect(b.blocks == [.card(board)] && b.departures == nil)
        let noStops = Card(id: "today", style: .text, text: "No school", date: "2026-11-08")
        let c = TodayFold.plan([noStops, board], dayCardID: "today", density: .hyperdetail)
        #expect(c.blocks == [.card(board)])
        // Other densities keep the old rule.
        #expect(TodayFold.plan([board], dayCardID: nil).blocks.isEmpty)
    }

    @Test func timedDeadlinesCountCalendarDays() {
        let card = TodayFoldTests.deadlines([])
        func urgent(_ i: Card.Item) -> Bool { TodayFold.isUrgent(i, in: card, now: TodayFoldTests.now, calendar: TodayFoldTests.cal) }
        // Sunday 10:00 seen; Wednesday 23:59 is in 3 calendar days, like a day-only due.
        let wed = TodayFoldTests.cal.date(byAdding: .minute, value: 24 * 60 - 1, to: TodayFoldTests.day(3))!
        #expect(urgent(.init(title: "Wed late", due: wed)))
        #expect(!urgent(.init(title: "Thu early", due: TodayFoldTests.day(4).addingTimeInterval(60))))
    }

    // MARK: Copy

    @Test func neutralTexts() {
        #expect(StartPreset.everything.summary == "Every section, exact times.")
        #expect(ChatCommands.known["/sick"]?.help == "No wake-up and no train alert")
    }

    // MARK: Widgets and the activity

    @Test func homeAssistantOnlyHasNoCompanionServer() {
        let ha = ServerConfig(name: "HA", kind: .homeAssistant, baseURL: URL(string: "https://ha.ts.net")!, auth: .token)
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: URL(string: "https://lab.ts.net")!, auth: .identity)
        #expect(ServerList(servers: [ha]).hasNoCompanionServer)
        #expect(!ServerList(servers: [ha, lab]).hasNoCompanionServer)
        #expect(!ServerList().hasNoCompanionServer)
    }

    @Test func leaveActivityGoesStaleAtTheFirstLessonAndTurnsUrgent() {
        let now = TodayFoldTests.now
        let c = LeaveContent(leaveBy: now.addingTimeInterval(600), line: "U6", departure: now.addingTimeInterval(900),
                             day: "2026-11-08", firstLesson: now.addingTimeInterval(3600))
        #expect(c.staleDate == now.addingTimeInterval(3600))
        #expect(!c.isUrgent(now: now) && c.isUrgent(now: now.addingTimeInterval(400)))
        #expect(c.redrawDates(now: now) == [now, now.addingTimeInterval(300), now.addingTimeInterval(600), now.addingTimeInterval(3600)])
    }
}
