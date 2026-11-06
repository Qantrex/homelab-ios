import Foundation
import Testing
@testable import HomelabKit

/// Owner's review 2026-11-06: Today's weather sentence and freshness line, Lab's folding rows and the tailnet's quiet
/// "online", the proposal's clock time, and the calm demo day.
@Suite struct HeroLinesTests {
    static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// 2026-11-06 (a Friday) at hh:mm UTC, plus `days`.
    static func at(_ h: Int, _ m: Int, days: Int = 0) -> Date {
        Date(timeIntervalSince1970: 1_793_923_200 + Double(days * 86400 + h * 3600 + m * 60))
    }

    // MARK: Weather sentence

    func weather(_ subtitle: String?, now: String? = "3°C") -> Card {
        Card(id: "weather", subtitle: subtitle, style: .metrics,
             items: [.init(title: "Now", value: now), .init(title: "Today", value: "1–10°C")])
    }

    @Test func weatherSentenceAddsTheTemperatureNowWhenMissing() {
        #expect(WeatherLine.text(weather("Clear")) == "Clear, 3°C now")
        #expect(WeatherLine.text(weather("Rain from 15:00, take an umbrella")) == "Rain from 15:00, take an umbrella, 3°C now")
        // The server's new sentence already says it.
        #expect(WeatherLine.text(weather("Clear, 7 °C now, 4–10 °C today")) == "Clear, 7 °C now, 4–10 °C today")
        #expect(WeatherLine.text(weather("Dry, 3–8°C")) == "Dry, 3–8°C")
        // No "Now" item, no subtitle, no card.
        #expect(WeatherLine.text(weather("Clear", now: nil)) == "Clear")
        #expect(WeatherLine.text(weather(nil)) == "3°C now")
        #expect(WeatherLine.text(weather("  ", now: " ")) == nil)
        #expect(WeatherLine.text(nil) == nil)
    }

    // MARK: Freshness line

    @Test func freshnessLineOnlyWhenWorthSaying() {
        let now = Self.at(12, 0)
        let fresh = now.addingTimeInterval(-60), old = now.addingTimeInterval(-11 * 60)
        #expect(!FreshnessLine.shows(pulled: false, failed: false, fetched: fresh, checked: fresh, now: now))
        #expect(!FreshnessLine.shows(pulled: false, failed: false, fetched: nil, checked: nil, now: now))
        #expect(FreshnessLine.shows(pulled: true, failed: false, fetched: fresh, checked: fresh, now: now))
        #expect(FreshnessLine.shows(pulled: false, failed: true, fetched: fresh, checked: fresh, now: now))
        #expect(FreshnessLine.shows(pulled: false, failed: false, fetched: old, checked: fresh, now: now))
        // The server's own check stopped: also stale, though the fetch was fresh.
        #expect(FreshnessLine.shows(pulled: false, failed: false, fetched: fresh, checked: old, now: now))
        // Exactly 10 min is not yet stale (like Snapshot.isStale).
        let ten = now.addingTimeInterval(-600)
        #expect(!FreshnessLine.shows(pulled: false, failed: false, fetched: ten, checked: ten, now: now))
    }

    // MARK: Lab rows

    func tailnet(_ n: Int) -> Card {
        Card(id: "tailnet", style: .list, items: (0..<n).map { .init(title: "node\($0)", subtitle: "linux", value: "online") },
             place: .lab)
    }

    @Test func longListsFoldToThreeRows() {
        let card = tailnet(6)
        #expect(LabRows.folds(card))
        #expect(LabRows.shown(card, expanded: false).map(\.title) == ["node0", "node1", "node2"])
        #expect(LabRows.shown(card, expanded: true).count == 6)
        // Three or fewer, or not a list (the ad-blocking metrics): never folded.
        #expect(!LabRows.folds(tailnet(3)) && LabRows.shown(tailnet(3), expanded: false).count == 3)
        var metrics = tailnet(5); metrics.style = .metrics
        #expect(!LabRows.folds(metrics) && LabRows.shown(metrics, expanded: false).count == 5)
    }

    @Test func tailnetSaysNothingForOnlineAndWarnsForAway() {
        let card = tailnet(1)
        let online = Card.Item(title: "pi", value: "online")
        let onlineCaps = Card.Item(title: "pi", value: " Online ")
        let none = Card.Item(title: "pi")
        let away = Card.Item(title: "laptop", value: "seen 3 h ago")
        let offline = Card.Item(title: "tablet", value: "offline", tint: .red)
        let expiring = Card.Item(title: "phone", value: "online", tint: .yellow)
        #expect(LabRows.value(online, in: card) == nil && LabRows.value(onlineCaps, in: card) == nil)
        #expect(!LabRows.warns(online, in: card) && !LabRows.warns(none, in: card))
        #expect(LabRows.value(away, in: card) == "seen 3 h ago" && LabRows.warns(away, in: card))
        #expect(LabRows.value(offline, in: card) == "offline" && LabRows.warns(offline, in: card))
        // A key that expires soon: online (no word), but the glyph says "look".
        #expect(LabRows.value(expiring, in: card) == nil && LabRows.warns(expiring, in: card))
        // Other cards keep "online" as a value and only warn by tint.
        let backups = Card(id: "backups", style: .list, items: [], place: .lab)
        #expect(LabRows.value(online, in: backups) == "online" && !LabRows.warns(away, in: backups))
        #expect(LabRows.value(.init(title: "x", value: ""), in: backups) == nil)
        #expect(LabRows.warns(.init(title: "x", value: "2 d ago", tint: .red), in: backups))
        #expect(!LabRows.warns(.init(title: "x", value: "–", tint: .gray), in: backups))
    }

    @Test func labSubtitleFallsBackToTheText() {
        var card = tailnet(2)
        card.text = "Key expiry off on all servers"
        #expect(LabRows.subtitle(card) == "Key expiry off on all servers")
        card.subtitle = "From the subtitle"
        #expect(LabRows.subtitle(card) == "From the subtitle")
        // Without rows the text is the panel's content, not a subtitle.
        let empty = Card(id: "tailnet", style: .list, text: "Nothing yet.", items: [], place: .lab)
        #expect(LabRows.subtitle(empty) == nil)
    }

    // MARK: Proposal time and posters

    @Test func clockUnderTheAge() {
        let now = Self.at(21, 30)
        #expect(Format.clock(Self.at(21, 3), now: now, calendar: Self.utc) == "21:03")
        #expect(Format.clock(Self.at(9, 5, days: -1), now: now, calendar: Self.utc) == "Thu 09:05")
        #expect(Format.clock(Self.at(23, 59, days: -6), now: now, calendar: Self.utc) == "Sat 23:59")
        #expect(Format.clock(Self.at(8, 0, days: -7), now: now, calendar: Self.utc) == "30.10. 08:00")
    }

    @Test func posterDropsTheRequestStateOnceRequested() {
        #expect(PosterText.withoutRequestState("2019 · TV · not requested") == "2019 · TV")
        #expect(PosterText.withoutRequestState("2024 · Movie · in Plex") == "2024 · Movie · in Plex")
    }

    // MARK: Calm demo

    let day = Card(id: "today", title: "Today", style: .metrics, items: [
        .init(title: "Wake-up", value: "06:20"),
        .init(title: "Leave by", subtitle: "U6 07:36", value: "07:31"),
        .init(title: "First lesson", value: "08:00"),
    ], date: "2026-11-04")

    @Test func calmDayIsTodayBeforeSchoolElseTomorrow() {
        // Friday 07:00: today's card, the fixture's times.
        let morning = DemoBackend.schoolDay(day, now: Self.at(7, 0), calendar: Self.utc)
        #expect(morning.date == "2026-11-06" && morning.title == "Today" && morning.items == day.items)
        let line = DayTimeline(card: morning, now: Self.at(7, 0), calendar: Self.utc)
        #expect(!line.isTomorrow && line.next?.item.title == "Leave by" && line.minutesToNext == 31)
        // Friday 12:00: tomorrow is a Saturday, "No school".
        let friday = DemoBackend.schoolDay(day, now: Self.at(12, 0), calendar: Self.utc)
        #expect(friday.date == "2026-11-07" && friday.style == .text && friday.text == "No school" && friday.items.isEmpty)
        #expect(DayTimeline(card: friday, now: Self.at(12, 0), calendar: Self.utc).isTomorrow)
        // Saturday 07:00 (no school today): tomorrow is Sunday, no school either.
        #expect(DemoBackend.schoolDay(day, now: Self.at(7, 0, days: 1), calendar: Self.utc).text == "No school")
        // Sunday evening: Monday's times, counting down to the wake-up.
        let sunday = DemoBackend.schoolDay(day, now: Self.at(20, 0, days: 2), calendar: Self.utc)
        #expect(sunday.date == "2026-11-09" && sunday.title == "Tomorrow" && sunday.items == day.items)
        let t = DayTimeline(card: sunday, now: Self.at(20, 0, days: 2), calendar: Self.utc)
        #expect(t.isTomorrow && t.next?.item.title == "Wake-up" && t.minutesToNext == 10 * 60 + 20)
    }

    @Test func calmCommuteFollowsTheDay() throws {
        let plan = CommutePlan(date: "2026-11-04", mode: "u6", line: "U6", disruptions: ["U6: delays"])
        let morning = DemoBackend.schoolDay(day, now: Self.at(7, 0), calendar: Self.utc)
        let p = DemoBackend.schoolCommute(plan, day: morning, now: Self.at(7, 0), calendar: Self.utc)
        #expect(p.date == "2026-11-06" && p.active == nil && p.disruptions.isEmpty)
        #expect(p.leaveBy == Self.at(7, 31) && p.firstLesson == Self.at(8, 0) && p.train == Self.at(7, 36))
        let evening = DemoBackend.schoolDay(day, now: Self.at(20, 0), calendar: Self.utc)
        let none = DemoBackend.schoolCommute(plan, day: evening, now: Self.at(20, 0), calendar: Self.utc)
        #expect(none.date == "2026-11-06" && none.active == false && none.leaveBy == nil)
    }

    @Test func calmDemoLooksLikeACurrentDay() async throws {
        let now = Date()
        let demo = DemoBackend(delay: .zero, now: now)
        let s = try await demo.state()
        // All quiet: no problem, no warning, nothing over a limit; one proposal waits.
        #expect(s.status == .ok && s.problems.isEmpty && s.pending.map(\.id) == ["cd34"])
        #expect(s.hosts.allSatisfy { $0.flags.allSatisfy { $0 == "asleep" } })
        #expect(s.hosts.filter { $0.reachable == true }.allSatisfy {
            !$0.loadLevel.isHigh && !$0.ramLevel.isHigh && !$0.diskLevel.isHigh && !$0.tempLevel.isHigh
        })
        #expect(s.hosts.flatMap(\.containerList).allSatisfy { $0.state == .running && $0.health != .unhealthy })
        // The cards a real server sends today, none of the old fixture's extras.
        let today = s.cards.filter { $0.place == .today }.map(\.id)
        #expect(today == ["recent", "today", "weather", "briefing", "todos", "parcels", "deadlines", "grades", "departures"])
        #expect(s.cards.filter { $0.place == .lab }.map(\.id) == ["tailnet", "dns", "dns-top", "backups"])
        // The day card is dated today or tomorrow, never an old day.
        let dayCard = try #require(s.dayCard)
        let line = DayTimeline(card: dayCard, now: now)
        #expect(!line.isStale && dayCard.date != nil)
        // Nothing overdue on Today: no past deadline or to-do.
        #expect(s.deadlinesCard?.items.allSatisfy { ($0.due ?? .distantFuture) >= Calendar.current.startOfDay(for: now) } == true)
        // The weather sentence comes with its temperature, the tailnet in the new grammar (no "online").
        #expect(WeatherLine.text(s.cards.first { $0.id == "weather" })?.contains("°C now") == true)
        #expect(s.cards.first { $0.id == "tailnet" }?.items.allSatisfy { $0.value != "online" } == true)
        // Card ages are current: a full time a few minutes old, a clock text as the server writes it.
        for c in s.cards {
            guard let u = c.updated else { continue }
            if let d = ServerDate.parse(u) {
                #expect(abs(now.timeIntervalSince(d)) < 600, "\(c.id) \(u)")
            } else {
                #expect(DayTimeline.minute(u) != nil, "\(c.id) \(u)")
            }
        }
        // The chat agrees with the state: its proposal is the one waiting, the last message is the chat's answer.
        let messages = try await demo.messages(after: 0).messages
        #expect(messages.flatMap(\.pending).map(\.id) == ["cd34"])
        #expect(s.lastMessage?.id == messages.last?.id)
        // Approving it works like on a real server.
        let approve = try #require(s.pending.first?.buttons[.approve])
        _ = try await demo.press(approve)
        #expect(try await demo.state().pending.isEmpty)
    }

    @Test func cardAgesMoveWithTheClock() {
        let checked = Self.at(21, 28), shift: TimeInterval = -(12 * 3600 + 30 * 60)   // now 09:00
        #expect(DemoBackend.shiftUpdated("21:28", by: shift, checked: checked, calendar: Self.utc) == "08:58")
        #expect(DemoBackend.shiftUpdated("21:15", by: shift, checked: checked, calendar: Self.utc) == "08:45")
        // The morning briefing's time stays, and so does anything that isn't a time.
        #expect(DemoBackend.shiftUpdated("06:30", by: shift, checked: checked, calendar: Self.utc) == "06:30")
        #expect(DemoBackend.shiftUpdated("soon", by: shift, checked: checked, calendar: Self.utc) == "soon")
        let full = ServerDate.string(checked)
        #expect(ServerDate.parse(DemoBackend.shiftUpdated(full, by: shift, checked: checked, calendar: Self.utc))
                == checked.addingTimeInterval(shift))
    }

    @Test func problemSceneStaysForScreenshots() async throws {
        let s = try await DemoBackend(scene: .problem, delay: .zero).state()
        #expect(s.status == .problem && !s.problems.isEmpty)
        #expect(s.cards.filter { $0.place == .lab }.map(\.id) == ["tailnet", "dns", "dns-top", "backups"])
    }

    @MainActor @Test func launchArgumentPicksTheScene() async throws {
        #expect(LaunchArguments(["-HomelabDemoScene", "problem"]).demoScene == .problem)
        #expect(LaunchArguments(["-HomelabDemoScene", "Calm"]).demoScene == .calm)
        #expect(LaunchArguments(["-HomelabDemoScene", "nope"]).demoScene == nil)
        #expect(LaunchArguments([]).demoScene == nil)
        let (m, _, _, _) = makeModel(args: ["-HomelabDemo", "YES", "-HomelabDemoScene", "problem"])
        await m.refresh()
        #expect(m.selectedStatus.snapshot?.state.status == .problem)
        let (calm, _, _, _) = makeModel(args: ["-HomelabDemo", "YES"])
        await calm.refresh()
        #expect(calm.selectedStatus.snapshot?.state.status == .ok)
    }
}
