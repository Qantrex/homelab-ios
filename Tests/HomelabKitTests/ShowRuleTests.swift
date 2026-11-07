import Foundation
import Testing
@testable import HomelabKit

/// A fixed calendar and clock, so no rule depends on where or when the tests run.
private func calendar(_ zone: String = "UTC") -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: zone)!
    c.locale = Locale(identifier: "en_US_POSIX")
    return c
}

/// 2026-11-06 is a Friday (weekday 6), 2026-11-08 a Sunday (1).
private func at(_ text: String) -> Date { ServerDate.parse(text)! }

private func context(_ now: String, needsMe: Set<TodaySection> = [], presence: Presence? = nil,
                     shownAnyway: Set<TodaySection> = []) -> ShowContext {
    ShowContext(now: at(now), calendar: calendar(), needsMe: needsMe, presence: presence, shownAnyway: shownAnyway)
}

@Suite struct TimeWindowTests {
    @Test func plainWindowIncludesFromExcludesTo() {
        let w = TimeWindow(from: 6 * 60, to: 10 * 60)
        let c = calendar()
        #expect(!w.contains(at("2026-11-06T05:59:00Z"), calendar: c))
        #expect(w.contains(at("2026-11-06T06:00:00Z"), calendar: c))
        #expect(w.contains(at("2026-11-06T09:59:00Z"), calendar: c))
        #expect(!w.contains(at("2026-11-06T10:00:00Z"), calendar: c))
    }

    @Test func midnightWrap() {
        let w = TimeWindow(from: 22 * 60, to: 2 * 60)
        let c = calendar()
        #expect(!w.contains(at("2026-11-06T21:59:00Z"), calendar: c))
        #expect(w.contains(at("2026-11-06T22:00:00Z"), calendar: c))
        #expect(w.contains(at("2026-11-06T23:59:00Z"), calendar: c))
        #expect(w.contains(at("2026-11-07T00:00:00Z"), calendar: c))
        #expect(w.contains(at("2026-11-07T01:59:00Z"), calendar: c))
        #expect(!w.contains(at("2026-11-07T02:00:00Z"), calendar: c))
        #expect(!w.contains(at("2026-11-07T12:00:00Z"), calendar: c))
    }

    @Test func daysAreTheDayTheWindowStarts() {
        let friNight = TimeWindow(from: 22 * 60, to: 2 * 60, days: [6])
        let c = calendar()
        #expect(friNight.contains(at("2026-11-06T23:00:00Z"), calendar: c))     // Friday evening
        #expect(friNight.contains(at("2026-11-07T01:00:00Z"), calendar: c))     // Saturday morning, Friday's window
        #expect(!friNight.contains(at("2026-11-07T23:00:00Z"), calendar: c))    // Saturday evening
        #expect(!friNight.contains(at("2026-11-06T01:00:00Z"), calendar: c))    // Friday morning is Thursday's window
        // Saturday's window runs into Sunday: the week wraps from 7 to 1.
        let satNight = TimeWindow(from: 22 * 60, to: 2 * 60, days: [7])
        #expect(satNight.contains(at("2026-11-08T01:00:00Z"), calendar: c))
        #expect(!satNight.contains(at("2026-11-09T01:00:00Z"), calendar: c))    // Monday morning is Sunday's
    }

    @Test func weekdaysAndWeekends() {
        let c = calendar()
        let friday = at("2026-11-06T12:00:00Z"), saturday = at("2026-11-07T12:00:00Z"), sunday = at("2026-11-08T23:59:00Z")
        #expect(TimeWindow.weekdays.contains(friday, calendar: c) && !TimeWindow.weekdays.contains(saturday, calendar: c))
        #expect(TimeWindow.weekends.contains(saturday, calendar: c) && TimeWindow.weekends.contains(sunday, calendar: c))
        #expect(!TimeWindow.weekends.contains(friday, calendar: c))
        let weekdayMornings = TimeWindow(from: 6 * 60, to: 10 * 60, days: [2, 3, 4, 5, 6])
        #expect(weekdayMornings.contains(at("2026-11-06T07:00:00Z"), calendar: c))
        #expect(!weekdayMornings.contains(at("2026-11-07T07:00:00Z"), calendar: c))
        #expect(!weekdayMornings.contains(at("2026-11-06T11:00:00Z"), calendar: c))
    }

    @Test func wholeDayAndEndOfDay() {
        let c = calendar()
        #expect(TimeWindow(from: 9 * 60, to: 9 * 60).contains(at("2026-11-06T03:00:00Z"), calendar: c))   // from == to
        #expect(TimeWindow.evenings.contains(at("2026-11-06T23:59:00Z"), calendar: c))                    // to 24:00
        #expect(!TimeWindow.evenings.contains(at("2026-11-07T00:00:00Z"), calendar: c))
    }

    @Test func usesTheCalendarsTimeZone() {
        let t = at("2026-11-06T17:30:00Z")                                 // 18:30 in Vienna (UTC+1 in November)
        #expect(TimeWindow.evenings.contains(t, calendar: calendar("Europe/Vienna")))
        #expect(!TimeWindow.evenings.contains(t, calendar: calendar("UTC")))
        // Summer time: 2026-07-01 17:30 UTC is 19:30 in Vienna.
        #expect(TimeWindow(from: 19 * 60, to: 20 * 60).contains(at("2026-07-01T17:30:00Z"), calendar: calendar("Europe/Vienna")))
    }

    @Test func oddValuesAreClampedAndDaysNormalized() {
        let w = TimeWindow(from: -5, to: 9999, days: [9, 3, 3, 0, 1])
        #expect(w.from == 0 && w.to == 1440 && w.days == [1, 3])
        #expect(TimeWindow(from: 0, to: 60, days: []).days == nil)
        #expect(TimeWindow(from: 0, to: 60, days: Array(1...7)).days == nil)
    }

    @Test func words() {
        let c = calendar()
        #expect(TimeWindow.evenings.words(calendar: c) == "Evenings")
        #expect(TimeWindow.weekends.words(calendar: c) == "Weekends")
        #expect(TimeWindow(from: 6 * 60, to: 10 * 60, days: [2, 3, 4, 5, 6]).words(calendar: c) == "Weekdays 6–10")
        #expect(TimeWindow(from: 9 * 60 + 30, to: 12 * 60, days: [1, 7, 2]).words(calendar: c) == "Mon, Sat, Sun 9:30–12")
        #expect(TimeWindow(from: 22 * 60, to: 2 * 60 + 5).words(calendar: c) == "22–2:05")
        #expect(TimeWindow(from: 0, to: 1440).words(calendar: c) == "All day")
        #expect(ShowRule.needsMe.words(calendar: c) == "When it needs me" && ShowRule.always.words(calendar: c) == "Always")
    }
}

@Suite struct ShowRuleTests {
    @Test func timesRule() {
        let rule = ShowRule.times(.evenings)
        #expect(!rule.shows(.deals, in: context("2026-11-06T14:00:00Z")))
        #expect(rule.shows(.deals, in: context("2026-11-06T19:00:00Z")))
        #expect(rule.shows(.deals, in: context("2026-11-06T14:00:00Z", shownAnyway: [.deals])))   // "Show" overrides
    }

    @Test func needsMeRule() {
        #expect(!ShowRule.needsMe.shows(.waiting, in: context("2026-11-06T14:00:00Z")))
        #expect(ShowRule.needsMe.shows(.waiting, in: context("2026-11-06T14:00:00Z", needsMe: [.waiting])))
        #expect(!ShowRule.needsMe.shows(.cards, in: context("2026-11-06T14:00:00Z", needsMe: [.waiting])))
        // The day can't need me: such a rule shows it always.
        #expect(ShowRule.needsMe.shows(.day, in: context("2026-11-06T14:00:00Z")))
    }

    @Test func unknownOrStalePresencePasses() {
        let now = "2026-11-06T14:00:00Z"
        for rule in [ShowRule.atHome, .away] {
            #expect(rule.shows(.home, in: context(now)))                                                    // not set up
            let stale = Presence(atHome: rule == .away, fetched: at(now).addingTimeInterval(-31 * 60))      // the wrong place, but old
            #expect(rule.shows(.home, in: context(now, presence: stale)))
        }
        let home = Presence(atHome: true, fetched: at(now).addingTimeInterval(-30 * 60))                     // 30 min: still fresh
        #expect(ShowRule.atHome.shows(.home, in: context(now, presence: home)))
        #expect(!ShowRule.away.shows(.home, in: context(now, presence: home)))
        let away = Presence(atHome: false, fetched: at(now))
        #expect(!ShowRule.atHome.shows(.home, in: context(now, presence: away)))
        #expect(ShowRule.away.shows(.home, in: context(now, presence: away)))
    }

    @Test func kindsOffered() {
        #expect(ShowRule.kinds(for: .deals, presence: false) == [.always, .needsMe, .times])
        #expect(ShowRule.kinds(for: .day, presence: false) == [.always, .times])
        #expect(ShowRule.kinds(for: .home, presence: true) == [.always, .needsMe, .times, .atHome, .away])
    }
}

@Suite struct ShowRuleLayoutTests {
    @Test func standardWithATimesRule() {
        var l = TodayLayout.standard
        l.setRule(.times(.evenings), for: .deals)
        let afternoon = context("2026-11-06T14:00:00Z"), evening = context("2026-11-06T19:00:00Z")
        #expect(Density.standard.sections(l, afternoon) == [.day, .waiting, .home, .cards, .report])
        #expect(Density.standard.hiddenNow(l, afternoon) == [.deals])
        #expect(Density.standard.sections(l, evening) == [.day, .waiting, .deals, .home, .cards, .report])
        #expect(Density.standard.hiddenNow(l, evening).isEmpty)
        #expect(Density.overkill.sections(l, afternoon) == TodaySection.allCases)                  // Overkill ignores rules
        #expect(Density.overkill.hiddenNow(l, afternoon).isEmpty)
        let shown = context("2026-11-06T14:00:00Z", shownAnyway: [.deals])
        #expect(Density.standard.sections(l, shown).contains(.deals) && Density.standard.hiddenNow(l, shown).isEmpty)
    }

    @Test func hiddenStaysHiddenWhateverTheRule() {
        var l = TodayLayout.standard
        l.setVisible(.deals, false)
        l.setRule(.times(.evenings), for: .deals)
        let evening = context("2026-11-06T19:00:00Z")
        #expect(!Density.standard.sections(l, evening).contains(.deals))
        #expect(Density.standard.hiddenNow(l, context("2026-11-06T14:00:00Z")).isEmpty)           // off, not hidden by a rule
    }

    @Test func machinesInStandardOnlyWithARule() {
        var l = TodayLayout.standard
        let now = context("2026-11-06T14:00:00Z", needsMe: [.machines])
        #expect(!Density.standard.sections(l, now).contains(.machines))
        l.setRule(.always, for: .machines)                                                          // stored: "in Standard too"
        #expect(l.rule(for: .machines) == .always && Density.standard.sections(l, now).last == .machines)
        l.setRule(.needsMe, for: .machines)
        #expect(Density.standard.sections(l, now).last == .machines)
        #expect(!Density.standard.sections(l, context("2026-11-06T14:00:00Z")).contains(.machines))
        #expect(Density.standard.hiddenNow(l, context("2026-11-06T14:00:00Z")).isEmpty)           // needs-me isn't listed
        l.setRule(nil, for: .machines)
        #expect(l.rules == nil && l == .standard)
    }

    @Test func calmAddsWhatNeedsMe() {
        var l = TodayLayout.standard
        l.setRule(.needsMe, for: .waiting)
        l.setRule(.needsMe, for: .machines)
        l.setRule(.times(.evenings), for: .cards)                                                   // not needs-me: Calm leaves it out
        #expect(Density.calm.sections(l, context("2026-11-06T19:00:00Z")) == [.day, .home])
        let busy = context("2026-11-06T19:00:00Z", needsMe: [.waiting, .machines, .cards, .report])
        #expect(Density.calm.sections(l, busy) == [.day, .waiting, .home, .machines])
        // Home by its rule in Calm too.
        l.setRule(.times(.mornings), for: .home)
        #expect(Density.calm.sections(l, busy) == [.day, .waiting, .machines])
        #expect(Density.calm.hiddenNow(l, busy) == [.home])
    }

    @Test func setRuleStoresOnlyWhatDiffers() {
        var l = TodayLayout.standard
        l.setRule(.always, for: .deals)
        #expect(l.rules == nil)
        l.setRule(.times(.evenings), for: .deals)
        l.setRule(.needsMe, for: .report)
        #expect(l.rule(for: .deals) == .times(.evenings) && l.rule(for: .report) == .needsMe)
        l.setRule(.always, for: .deals)
        l.setRule(nil, for: .report)
        #expect(l.rules == nil && l == .standard)
        var s = AppSettings()
        s.todayLayout = l
        #expect(s.today == nil)                                                                      // nothing new written
    }

    @Test func withoutRulesItIsTheOldDensity() {
        var l = TodayLayout.standard
        l.setVisible(.report, false)
        for d in Density.allCases {
            for needs in [Set<TodaySection>(), Set(TodaySection.allCases)] {
                #expect(d.sections(l, context("2026-11-06T03:00:00Z", needsMe: needs)) == d.sections(l))
            }
        }
    }
}

@MainActor @Suite struct ShowRuleCodingTests {
    @Test func encodedShape() throws {
        var l = TodayLayout(order: ["day"], hidden: [])
        l.setRule(.times(TimeWindow(from: 1080, to: 1440, days: [2, 3])), for: .deals)
        l.setRule(.needsMe, for: .waiting)
        let json = String(decoding: try Storage.encoder.encode(l), as: UTF8.self)
        #expect(json == #"{"hidden":[],"order":["day"],"rules":{"deals":{"days":[2,3],"from":1080,"kind":"times","to":1440},"waiting":{"kind":"needsMe"}}}"#)
        #expect(try Storage.decoder.decode(TodayLayout.self, from: Data(json.utf8)) == l)
        for rule in [ShowRule.always, .needsMe, .atHome, .away, .times(.mornings), .times(.weekends)] {
            #expect(try Storage.decoder.decode(ShowRule.self, from: Storage.encoder.encode(rule)) == rule)
        }
    }

    @Test func oldSettingsDecodeUnchangedAndSaveBackByteForByte() throws {
        let old = Data(#"{"faceIDLock":false,"notifyPending":false,"notifyProblems":true,"today":{"hidden":["cards"],"order":["report","home"]}}"#.utf8)
        let s = try Storage.decoder.decode(AppSettings.self, from: old)
        #expect(s.today?.rules == nil && s.today?.hidden == ["cards"] && s.today?.order == ["report", "home"])
        #expect(try Storage.encoder.encode(s) == old)
        let owner = try Data(contentsOf: OwnerInvarianceTests.goldens.appendingPathComponent("owner-settings.json"))
        #expect(try Storage.encoder.encode(Storage.decoder.decode(AppSettings.self, from: owner)) == owner)
    }

    @Test func unreadableRulesAreDroppedNotTheSettings() throws {
        // A kind from a newer version and a broken window: dropped; the good rule and the layout stay.
        let json = #"{"hidden":["cards"],"order":["day"],"rules":{"deals":{"kind":"whenRaining"},"home":{"kind":"times","from":"x"},"report":{"kind":"needsMe"}}}"#
        let l = try Storage.decoder.decode(TodayLayout.self, from: Data(json.utf8))
        #expect(l.rules == ["report": .needsMe] && l.hidden == ["cards"])
        let none = try Storage.decoder.decode(TodayLayout.self, from: Data(#"{"hidden":[],"order":[],"rules":{"deals":{"kind":"nope"}}}"#.utf8))
        #expect(none.rules == nil)
        let odd = try Storage.decoder.decode(TodayLayout.self, from: Data(#"{"hidden":[],"order":[],"rules":5}"#.utf8))
        #expect(odd.rules == nil)
        // Rules for a section this version doesn't know are kept (a newer version wrote them).
        let future = try Storage.decoder.decode(TodayLayout.self, from: Data(#"{"hidden":[],"order":[],"rules":{"chat":{"kind":"needsMe"}}}"#.utf8))
        #expect(future.rules == ["chat": .needsMe])
    }
}

@Suite struct NeedsMeTests {
    let now = at("2026-11-07T10:00:00Z")

    @Test func fromFixtures() throws {
        let problem = try fixture(HomelabState.self, "state-problem.json")
        #expect(TodaySection.needingMe(state: problem, now: now) == [.waiting, .report, .machines])
        let ok = try fixture(HomelabState.self, "state-ok.json")
        #expect(TodaySection.needingMe(state: ok, now: now).isEmpty)
        let lab = try fixture(HomelabState.self, "state-lab-cards.json")                    // red rows, but on Lab cards
        #expect(!TodaySection.cards.needsMe(state: lab, now: now))
        let huge = try fixture(HomelabState.self, "state-huge.json")
        #expect(TodaySection.cards.needsMe(state: huge, now: now))
        #expect(TodaySection.needingMe(state: nil, now: now).isEmpty)
    }

    @Test func waiting() {
        var s = HomelabState()
        #expect(!TodaySection.waiting.needsMe(state: s, now: now))
        s.pending = [PendingAction(id: "1", action: "restart", arg: "media")]
        #expect(TodaySection.waiting.needsMe(state: s, now: now))
    }

    @Test func deals() throws {
        let deals = try Storage.decoder.decode(DealList.self, from: #require(Fixtures.data("deals.json")))
        #expect(TodaySection.deals.needsMe(state: nil, deals: deals, now: now))
        #expect(!TodaySection.deals.needsMe(state: nil, deals: deals, now: at("2026-11-09T10:00:00Z")))   // not fresh
        #expect(!TodaySection.deals.needsMe(state: nil, deals: nil, now: now))
    }

    @Test func home() throws {
        let all = try fixture([HAEntity].self, "ha-states.json")
        #expect(TodaySection.home.needsMe(state: nil, home: all, now: now))                             // fan.bedroom
        #expect(!TodaySection.home.needsMe(state: nil, home: all.filter { $0.entityID != "fan.bedroom" }, now: now))
        #expect(!TodaySection.home.needsMe(state: nil, home: [HAEntity(entityID: "light.x", state: "unknown")], now: now))
    }

    @Test func cards() {
        func state(_ cards: [Card]) -> HomelabState { HomelabState(cards: cards) }
        let redCardTint = Card(id: "downloads", tint: .red, items: [Card.Item(title: "a")])
        #expect(!TodaySection.cards.needsMe(state: state([redCardTint]), now: now))                    // a card's tint is decoration
        let lateTrain = Card(id: "departures", items: [Card.Item(title: "U6", tint: .orange)])
        #expect(!TodaySection.cards.needsMe(state: state([lateTrain]), now: now))                      // a warning only
        let failed = Card(id: "backups", items: [Card.Item(title: "nas", tint: .red)])
        #expect(TodaySection.cards.needsMe(state: state([failed]), now: now))
        var done = failed
        done.items[0].done = true
        #expect(!TodaySection.cards.needsMe(state: state([done]), now: now))
        var lab = failed
        lab.place = .lab
        #expect(!TodaySection.cards.needsMe(state: state([lab]), now: now))
        let day = Card(id: "today", items: [Card.Item(title: "Leave by", tint: .red)])
        #expect(!TodaySection.cards.needsMe(state: state([day]), now: now))                           // the day card is the day's
    }

    @Test func report() {
        func state(_ status: String?, _ text: String = "Backup failed") -> HomelabState {
            HomelabState(lastMessage: ChatMessage(id: 1, from: .agent, status: status, text: text))
        }
        #expect(TodaySection.report.needsMe(state: state("ALERT"), now: now))
        #expect(TodaySection.report.needsMe(state: state("error"), now: now))
        #expect(!TodaySection.report.needsMe(state: state("WARN"), now: now))
        #expect(!TodaySection.report.needsMe(state: state("OK"), now: now))
        #expect(!TodaySection.report.needsMe(state: state(nil), now: now))
        #expect(!TodaySection.report.needsMe(state: state("ALERT", ""), now: now))                     // nothing to show
    }

    @Test func machines() {
        var s = HomelabState(hosts: [Host(id: "nas", name: "nas", reachable: true)])
        #expect(!TodaySection.machines.needsMe(state: s, now: now))
        s.hosts.append(Host(id: "pc", name: "pc", reachable: false, flags: ["asleep"]))
        #expect(!TodaySection.machines.needsMe(state: s, now: now))                                    // asleep isn't down
        s.problems = [Problem(text: "disk", host: "nas", severity: .warning)]
        #expect(TodaySection.machines.needsMe(state: s, now: now))
        s.problems = []
        s.hosts.append(Host(id: "pi", name: "pi", reachable: false))
        #expect(TodaySection.machines.needsMe(state: s, now: now))
    }

    @Test func dayNever() {
        #expect(!TodaySection.day.canNeedMe && TodaySection.allCases.filter(\.canNeedMe).count == 6)
        let s = HomelabState(status: .problem, cards: [Card(id: "today", tint: .red, items: [Card.Item(title: "x", tint: .red)])])
        #expect(!TodaySection.day.needsMe(state: s, now: now))
    }
}

/// O1/O2 for rules: the owner's settings have none, so at every hour of a week, whatever needs them and wherever they
/// are, Today shows exactly what it shows without rules, and nothing is "hidden now".
@MainActor @Suite struct ShowRuleOwnerTests {
    @Test func ownerTodayUnchangedAtEveryHourOfAWeek() throws {
        let owner = try Data(contentsOf: OwnerInvarianceTests.goldens.appendingPathComponent("owner-settings.json"))
        let layouts = [try Storage.decoder.decode(AppSettings.self, from: owner).todayLayout, TodayLayout.standard]
        let start = at("2026-11-02T00:00:00Z")                                                            // a Monday
        let needable = TodaySection.allCases.filter(\.canNeedMe)
        let subsets: [Set<TodaySection>] = (0..<(1 << needable.count)).map { bits in
            Set(needable.enumerated().filter { bits & (1 << $0.offset) != 0 }.map(\.element))
        }
        for layout in layouts {
            #expect(layout.rules == nil)
            for hour in 0..<(7 * 24) {
                let now = start.addingTimeInterval(Double(hour) * 3600)
                for presence in [nil, Presence(atHome: true, fetched: now), Presence(atHome: false, fetched: now)] {
                    for needs in subsets {
                        let c = ShowContext(now: now, calendar: calendar("Europe/Vienna"), needsMe: needs, presence: presence)
                        for d in Density.allCases where d.sections(layout, c) != d.sections(layout) || !d.hiddenNow(layout, c).isEmpty {
                            Issue.record("owner's Today changed: \(d) at hour \(hour), needs \(needs)")
                        }
                    }
                }
            }
        }
    }

    @Test func contextFromTheModel() async throws {
        let storage = Storage(directory: temporaryDirectory())
        try Storage.encoder.encode(OwnerInvarianceTests.ownerServers()).write(to: storage.url(ServerList.fileName))
        let server = FakeServer()
        server.state = "state-problem.json"
        let (m, _, _, _) = makeModel(server, storage: storage)
        await m.refresh()
        let entities = [HAEntity(entityID: "light.living_room", state: "unavailable"), HAEntity(entityID: "fan.x", state: "unavailable")]
        let c = m.showContext(now: at("2026-11-07T10:00:00Z"), calendar: calendar(), homeEntities: entities)
        #expect(c.needsMe == [.waiting, .report, .machines, .home])                                       // the light is pinned
        let unpinned = m.showContext(now: at("2026-11-07T10:00:00Z"), homeEntities: [entities[1]])
        #expect(!unpinned.needsMe.contains(.home))
    }
}
