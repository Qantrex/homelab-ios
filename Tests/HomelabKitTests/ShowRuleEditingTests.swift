import Foundation
import Testing
@testable import HomelabKit

private func utc() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    c.locale = Locale(identifier: "en_US_POSIX")
    return c
}

private func at(_ text: String) -> Date { ServerDate.parse(text)! }

/// The rule sheet: which choices a section gets, and that each choice reads back as itself.
@Suite struct RuleOptionTests {
    @Test func optionsPerSection() {
        let named = TimeWindow.named.indices.map { RuleOption.named($0) }
        #expect(RuleOption.options(for: .deals, presence: false) == [.always, .needsMe] + named + [.custom])
        #expect(RuleOption.options(for: .day, presence: false) == [.always] + named + [.custom])     // the day can't need me
        #expect(RuleOption.options(for: .machines, presence: false).first == .overkillOnly)
        #expect(!RuleOption.options(for: .cards, presence: false).contains(.atHome))                  // no presence yet
        #expect(RuleOption.options(for: .cards, presence: true).suffix(2) == [.atHome, .away])
        #expect(!RuleOption.options(for: .deals, presence: true).contains(.overkillOnly))
        #expect(RuleOption.options(for: .machines, kinds: [.always, .away]) == [.overkillOnly, .always, .away])
    }

    @Test func eachOptionReadsBackAsItself() {
        for section in TodaySection.allCases {
            for option in RuleOption.options(for: section, presence: true) {
                var layout = TodayLayout.standard
                layout.setRule(option.rule(from: nil), for: section)
                #expect(RuleOption.current(layout.rule(for: section), for: section) == option, "\(section) \(option)")
                #expect(option.title.isEmpty == false)
            }
        }
    }

    @Test func noRuleIsAlwaysExceptForMachines() {
        #expect(RuleOption.current(nil, for: .deals) == .always)
        #expect(RuleOption.current(nil, for: .machines) == .overkillOnly)
        #expect(TodayLayout.standard.ruleWords(for: .machines) == "Only in Overkill")
        #expect(TodayLayout.standard.ruleWords(for: .deals) == "Always")
        var l = TodayLayout.standard
        l.setRule(.always, for: .machines)
        #expect(l.ruleWords(for: .machines) == "Always" && RuleOption.current(l.rule(for: .machines), for: .machines) == .always)
        l.setRule(.times(.evenings), for: .deals)
        #expect(l.ruleWords(for: .deals, calendar: utc()) == "Evenings")
    }

    @Test func customKeepsItsWindow() {
        let own = ShowRule.times(TimeWindow(from: 6 * 60, to: 10 * 60, days: [2, 3, 4, 5, 6]))
        #expect(RuleOption.current(own, for: .cards) == .custom)
        #expect(RuleOption.custom.rule(from: own) == own)
        #expect(RuleOption.custom.rule(from: .times(.evenings)) == .times(.evenings))                // starts from the named one
        #expect(RuleOption.custom.rule(from: .always) == .times(TimeWindow(from: 18 * 60, to: 22 * 60)))
        #expect(RuleOption.overkillOnly.rule(from: own) == nil)
    }

    @Test func needsMeWordsForEverySectionThatCanNeedMe() {
        for s in TodaySection.allCases { #expect((s.needsMeWords != nil) == s.canNeedMe) }
        #expect(RuleOption.needsMe.detail(for: .deals) == "While there is a new deal to act on")
        #expect(TimeWindow.named.indices.allSatisfy { RuleOption.named($0).detail(for: .deals) != nil })
    }
}

/// The time pickers and day chips of Custom.
@Suite struct TimeWindowEditingTests {
    @Test func pickersRoundTrip() {
        let day = at("2026-11-06T09:00:00Z")
        for m in [0, 1, 359, 18 * 60, 1439] {
            #expect(TimeWindow.minutes(of: TimeWindow.date(minutes: m, on: day, calendar: utc()), calendar: utc()) == m)
        }
        #expect(TimeWindow.minutes(of: TimeWindow.date(minutes: 1440, on: day, calendar: utc()), calendar: utc()) == 0)
    }

    @Test func midnightAsEndIsTheEndOfTheDay() {
        let w = TimeWindow(from: 9 * 60, to: 12 * 60).with(from: 18 * 60).with(to: 0)
        #expect(w == .evenings && w.words(calendar: utc()) == "Evenings")
        #expect(TimeWindow.evenings.with(to: 22 * 60) == TimeWindow(from: 18 * 60, to: 22 * 60))
    }

    @Test func dayChips() {
        let every = TimeWindow(from: 6 * 60, to: 10 * 60)
        #expect(TimeWindow.mondayFirst.allSatisfy(every.includes(day:)))
        let noSunday = every.toggling(day: 1)
        #expect(noSunday.days == [2, 3, 4, 5, 6, 7] && !noSunday.includes(day: 1))
        #expect(noSunday.toggling(day: 1) == every)                                                  // all seven = every day
        var one = TimeWindow(from: 0, to: 60, days: [4])
        one = one.toggling(day: 4)
        #expect(one.days == [4])                                                                     // the last day stays
        #expect(TimeWindow(from: 0, to: 60, days: [2, 3, 4, 5]).toggling(day: 6).words(calendar: utc()) == "Weekdays 0–1")
    }
}

/// Today's "Hidden now: Deals (evenings)" line.
@Suite struct HiddenNowTests {
    @Test func words() {
        var l = TodayLayout.standard
        l.setRule(.times(.evenings), for: .deals)
        l.setRule(.times(.evenings), for: .cards)
        l.setRule(.times(TimeWindow(from: 6 * 60, to: 10 * 60, days: [2, 3, 4, 5, 6])), for: .report)
        l.setRule(.times(TimeWindow(from: 9 * 60 + 30, to: 12 * 60, days: [2, 4])), for: .machines)
        l.setRule(.away, for: .home)
        #expect(HiddenNow.text([], layout: l) == nil)
        #expect(HiddenNow.text([.deals], layout: l, calendar: utc()) == "Hidden now: Deals (evenings)")
        #expect(HiddenNow.text([.deals, .report, .cards], layout: l, calendar: utc())
                == "Hidden now: Deals and Cards (evenings), Last report (weekdays 6–10)")
        #expect(HiddenNow.text([.machines, .home], layout: l, calendar: utc())
                == "Hidden now: Machines (Mon, Wed 9:30–12), Home tiles (away)")
        #expect(HiddenNow.spoken("Hidden now: Last report (weekdays 6–10)") == "Hidden now: Last report (weekdays 6 to 10)")
        #expect(ListWords.join(["A", "B", "C"]) == "A, B and C" && ListWords.join(["A"]) == "A" && ListWords.join([]) == "")
    }
}

/// `-HomelabRules` and `-HomelabTime`, and the model's side of Today's rules.
@MainActor @Suite(.serialized) struct ShowRuleModelTests {
    @Test func launchArguments() {
        let args = LaunchArguments(["-HomelabRules", "deals=evenings, cards=18:00-22:00,report=needs-me,machines=none",
                                    "-HomelabTime", "14:00"])
        #expect(args.time == 14 * 60)
        let rules = args.rules ?? []
        #expect(rules.map { $0.0 } == [.deals, .cards, .report, .machines])
        #expect(rules.map { $0.1 } == [.times(.evenings), .times(TimeWindow(from: 18 * 60, to: 22 * 60)), .needsMe, nil])
        #expect(LaunchArguments(["-HomelabRules", "deals=18:00-0:00"]).rules?.first?.1 == .times(.evenings))
        for odd in ["deals", "nope=always", "deals=sometimes", "deals=25:00-26:00", "", "deals=evenings,x"] {
            #expect(LaunchArguments(["-HomelabRules", odd]).rules == nil, "\(odd)")
        }
        for odd in ["14", "14:60", "25:00", "2pm", ""] { #expect(LaunchArguments(["-HomelabTime", odd]).time == nil) }
        #expect(LaunchArguments([]).rules == nil && LaunchArguments([]).time == nil)
    }

    /// The CI shots: a Deals rule (evenings) hides at 14:00 and shows at 19:00; "Show" brings it back until the app
    /// closes.
    @Test func ruleAndFixedTimeFromLaunchArguments() async throws {
        let server = FakeServer()
        server.state = "state-problem.json"
        let storage = Storage(directory: temporaryDirectory())
        try Storage.encoder.encode(OwnerInvarianceTests.ownerServers()).write(to: storage.url(ServerList.fileName))
        let rules = ["-HomelabRules", "report=evenings,cards=evenings"]
        let (m, _, _, _) = makeModel(server, args: rules + ["-HomelabTime", "14:00"], storage: storage)
        await m.refresh()
        let now = at("2026-11-07T20:00:00Z")                                    // the real clock is in the evening
        let c = m.todayContext(now: now, calendar: utc())
        #expect(TimeWindow.minutes(of: c.now, calendar: utc()) == 14 * 60)
        #expect(m.settings.todayLayout.rule(for: .report) == .times(.evenings))
        #expect(m.hiddenOnToday(c, now: now) == m.settings.todayLayout.visible.filter { [.report, .cards].contains($0) })
        #expect(!Density.standard.sections(m.settings.todayLayout, c).contains(.report))

        m.showAnyway([.report])
        let shown = m.todayContext(now: now, calendar: utc())
        #expect(Density.standard.sections(m.settings.todayLayout, shown).contains(.report))
        #expect(m.hiddenOnToday(shown, now: now) == [.cards])

        let (evening, _, _, _) = makeModel(server, args: ["-HomelabTime", "19:00"], storage: storage)
        await evening.refresh()
        let e = evening.todayContext(now: now, calendar: utc())
        #expect(evening.hiddenOnToday(e, now: now).isEmpty)                    // the rule is stored, 19:00 is evening
        #expect(Density.standard.sections(evening.settings.todayLayout, e).contains(.report))

        let away = Presence(atHome: false, fetched: now)
        #expect(m.todayContext(now: now, calendar: utc(), presence: away).presence == away)          // passed through
        #expect(RuleOption.options(for: .deals, kinds: m.ruleKinds(for: .deals)) == RuleOption.options(for: .deals, presence: false))

        let (cleared, _, _, _) = makeModel(server, args: ["-HomelabRules", "report=always,cards=none"], storage: storage)
        #expect(cleared.settings.todayLayout.rules == nil && cleared.settings.today == nil)    // back to no rules
    }

    @Test func emptySectionsAreNotHiddenNow() throws {
        let storage = Storage(directory: temporaryDirectory())
        try Storage.encoder.encode(OwnerInvarianceTests.ownerServers()).write(to: storage.url(ServerList.fileName))
        let (m, _, _, _) = makeModel(args: ["-HomelabRules", "deals=evenings,report=evenings", "-HomelabTime", "14:00"],
                                     storage: storage)
        let now = at("2026-11-07T14:00:00Z")
        let c = m.todayContext(now: now, calendar: utc())
        #expect(Density.standard.hiddenNow(m.settings.todayLayout, c) == [.deals, .report])
        #expect(m.hiddenOnToday(c, now: now).isEmpty)                            // no data yet: nothing to show anyway
        #expect(m.todayHasContent(.home, now: now))                              // the owner has a Home Assistant
    }

    @Test func serversCanFill() throws {
        let (none, _, _, _) = makeModel()
        #expect(TodaySection.allCases.allSatisfy { !none.serversCanFill($0) })
        let storage = Storage(directory: temporaryDirectory())
        try Storage.encoder.encode(OwnerInvarianceTests.ownerServers()).write(to: storage.url(ServerList.fileName))
        let (owner, _, _, _) = makeModel(storage: storage)
        #expect(TodaySection.allCases.allSatisfy(owner.serversCanFill))
    }

    /// The owner (no rules): Today's sections from the model's context are the old ones at every hour, and nothing
    /// is ever "Hidden now".
    @Test func ownerUnchanged() async throws {
        let storage = Storage(directory: temporaryDirectory())
        try Storage.encoder.encode(OwnerInvarianceTests.ownerServers()).write(to: storage.url(ServerList.fileName))
        try Storage.encoder.encode(OwnerInvarianceTests.ownerSettings()).write(to: storage.url(AppSettings.fileName))
        let server = FakeServer()
        server.state = "state-problem.json"
        let (m, _, _, _) = makeModel(server, storage: storage)
        await m.refresh()
        #expect(m.settings.todayLayout.rules == nil && m.fixedTime == nil && m.shownAnyway.isEmpty)
        let start = at("2026-11-02T00:00:00Z")
        for hour in 0..<(7 * 24) {
            let now = start.addingTimeInterval(Double(hour) * 3600)
            let c = m.todayContext(now: now)
            #expect(c.now == now)
            #expect(m.hiddenOnToday(c, now: now).isEmpty)
            for d in Density.allCases {
                #expect(d.sections(m.settings.todayLayout, c) == d.sections(m.settings.todayLayout))
            }
        }
    }
}
