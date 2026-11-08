import Foundation
import Testing
@testable import HomelabKit

/// Hyperdetail (Hyperdetail.swift, HyperLines.swift): the fourth detail level. No folding anywhere, every field shown,
/// a remark on every fact when a personality is on, nothing but the details when it is Off; a one-time warning;
/// old files decode as before. Fixed clock and calendar.
@Suite struct HyperdetailTests {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// Sunday 2026-11-08, 10:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_794_132_000)
    static let voiced: [Personality] = [.dry, .snarky, .ultrakill]

    // MARK: The level

    @Test func fourLevelsInOrderWithTheirWords() {
        #expect(Density.allCases == [.calm, .standard, .overkill, .hyperdetail])
        #expect(Density.hyperdetail.title == "Hyperdetail")
        #expect(Density.hyperdetail.summary == "Everything, unfolded; commentary when a personality is on. Not recommended.")
        #expect(Density.explanation.hasSuffix("Hyperdetail: Everything, unfolded; commentary when a personality is on. Not recommended."))
        // Overkill's words are as they were.
        #expect(Density.overkill.summary == "The same, with more detail in every line.")
        #expect(Density.hyperdetail.isHyper && !Density.overkill.isHyper && Density.overkill.atLeastOverkill)
        #expect(Density.hyperdetail.exactTimes && Density.overkill.exactTimes && !Density.standard.exactTimes)
    }

    @Test func showsEverySectionLikeOverkill() {
        var layout = TodayLayout.standard
        layout.setVisible(.deals, false)
        #expect(Density.hyperdetail.sections(layout) == Density.overkill.sections(layout))
        #expect(Density.hyperdetail.sections(layout).count == TodaySection.allCases.filter(\.isOnToday).count)
        layout.setRule(.needsMe, for: .report)
        let context = ShowContext(now: Self.now, calendar: Self.utc, needsMe: [])
        #expect(Density.hyperdetail.sections(layout, context) == layout.listed)   // rules do not hide anything
        #expect(Density.hyperdetail.hiddenNow(layout, context).isEmpty)
    }

    @Test func storedAsAWordAndOldFilesDecodeAsBefore() throws {
        var s = AppSettings()
        s.todayDensity = .hyperdetail
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        #expect(json.contains(#""density":"hyperdetail""#))
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)).todayDensity == .hyperdetail)
        // A level from a newer version, or a typo: Standard, the rest of the file survives.
        let future = #"{"faceIDLock":true,"density":"hyperhyperdetail"}"#
        let f = try JSONDecoder().decode(AppSettings.self, from: Data(future.utf8))
        #expect(f.todayDensity == .standard && f.density == nil && f.faceIDLock)
        // Files from before the level.
        for old in ["calm", "standard", "overkill"] {
            let d = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"density":"\#(old)"}"#.utf8))
            #expect(d.todayDensity.rawValue == old)
        }
    }

    @MainActor @Test func launchArgumentSetsTheDensity() {
        for d in Density.allCases {
            let (m, _, _, _) = makeModel(args: ["app", "-HomelabDemo", "YES", "-HomelabDensity", d.rawValue.uppercased()])
            #expect(m.settings.todayDensity == d)
            #expect((m.hyper != nil) == (d == .hyperdetail))
        }
        let (n, _, _, _) = makeModel(args: ["app", "-HomelabDensity", "loud"])
        #expect(n.settings.todayDensity == .standard)
    }

    // MARK: The warning

    @Test func theWarningShowsOnceAndIsOptionalInTheFile() throws {
        var s = AppSettings()
        #expect(s.needsWarning(for: .hyperdetail))
        for d in [Density.calm, .standard, .overkill] { #expect(!s.needsWarning(for: d)) }
        // Unset: nothing in the file (the owner's settings stay byte for byte).
        #expect(!String(decoding: try JSONEncoder().encode(s), as: UTF8.self).contains("hyperdetailWarned"))
        s.confirmHyperdetail()
        #expect(s.todayDensity == .hyperdetail && !s.needsWarning(for: .hyperdetail))
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.hyperdetailWarned == true && !back.needsWarning(for: .hyperdetail))
        // Away and back later: no second question. Ultrakill's warning is separate.
        s.todayDensity = .standard
        #expect(!s.needsWarning(for: .hyperdetail) && s.needsWarning(for: .ultrakill))
        #expect(HyperdetailWarning.title == "Hyperdetail" && HyperdetailWarning.enable == "Do it" && HyperdetailWarning.back == "Back")
        #expect(HyperdetailWarning.message.hasSuffix("Why would you want that?"))
        // A hand-edited odd value falls back alone.
        let odd = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"hyperdetailWarned":"yes","faceIDLock":true}"#.utf8))
        #expect(odd.hyperdetailWarned == nil && odd.faceIDLock)
    }

    // MARK: No folding

    static func items(_ n: Int) -> [Card.Item] { (0..<n).map { .init(title: "Row \($0)", value: "\($0)") } }

    @Test func nothingFoldsInHyperdetail() {
        let card = Card(id: "parcels", style: .list, items: Self.items(30))
        let now = Self.now
        for d in [Density.hyperdetail] {
            let r = TodayFold.rows(card, density: d, expanded: false, now: now, calendar: Self.utc)
            #expect(r.items.count == 30 && r.hidden == 0 && !r.folds)
        }
        // The levels before it still fold.
        for d in [Density.standard, .overkill] {
            let r = TodayFold.rows(card, density: d, expanded: false, now: now, calendar: Self.utc)
            #expect(r.hidden > 0 && r.folds)
        }
        // A countdown shows far-off deadlines too, urgent or not.
        let day = Self.utc.startOfDay(for: now)
        let deadlines = Card(id: "deadlines", style: .countdown, items: (0..<9).map {
            .init(title: "D\($0)", due: Self.utc.date(byAdding: .day, value: $0 * 5, to: day)!, dueIsDay: true)
        })
        let r = TodayFold.rows(deadlines, density: .hyperdetail, expanded: false, now: now, calendar: Self.utc)
        #expect(r.items.count == 9 && r.hidden == 0 && !r.folds)
        #expect(TodayFold.rows(deadlines, density: .overkill, expanded: false, now: now, calendar: Self.utc).hidden > 0)
        // Limits for approvals and texts are out of reach, and the fold never wraps around on `+ 2`.
        #expect(TodayFold.approvals(.hyperdetail) > 1000 && TodayFold.textLines(.hyperdetail) > 1000)
        #expect(!TodayFold.textFolds(lines: 5000, limit: TodayFold.textLines(.hyperdetail)))
        #expect(TodayFold.approvals(.overkill) == 4 && TodayFold.approvals(.standard) == 2)
        #expect(TodayFold.cap(.overkill) == 5 && TodayFold.cap(.standard) == 3 && TodayFold.textLines(.overkill) == 6)
    }

    @Test func hyperdetailDrawsEveryCardAndOpensTheTiles() {
        let weather = Card(id: "weather", title: "Weather", subtitle: "Cloudy, 7 °C", style: .text)
        let short = Card(id: "minecraft", title: "Minecraft", style: .list, items: [.init(title: "Vicky", subtitle: "playing")])
        let downloads = Card(id: "downloads", style: .list, items: Self.items(3))
        let departures = Card(id: "departures", title: "U6", style: .departures)
        let std = TodayFold.plan([weather, short, downloads, departures], dayCardID: nil)
        #expect(std.blocks.count == 1 && std.tileCards.count == 1)   // the weather is the hero's, the short list a line
        if case .line = std.blocks[0] {} else { Issue.record("standard: one line") }
        let hyper = TodayFold.plan([weather, short, downloads, departures], dayCardID: nil, density: .hyperdetail)
        #expect(hyper.blocks.count == 2 && hyper.tileCards.count == 1)
        for block in hyper.blocks { if case .line = block { Issue.record("no one-liners in Hyperdetail") } }
        #expect(TodayFold.tilesInline(.hyperdetail) && !TodayFold.tilesInline(.overkill) && !TodayFold.tilesInline(.standard))
        // Overkill's plan is Standard's.
        #expect(TodayFold.plan([weather, short, downloads], dayCardID: nil, density: .overkill)
                == TodayFold.plan([weather, short, downloads], dayCardID: nil))
    }

    @Test func departuresShowWithoutALeaveByInHyperdetail() {
        let dep = Card(id: "departures", title: "U6", style: .departures, items: [
            .init(title: "Floridsdorf", subtitle: "Westbahnhof", value: "10:05", due: Self.now.addingTimeInterval(300)),
        ])
        let board = DepartureBoard(card: dep)
        let day = Card(id: "today", style: .metrics, items: [.init(title: "Wake up", value: "06:30")])
        #expect(!TodayFold.departuresMatter(board, day: day, now: Self.now, calendar: Self.utc))
        #expect(!TodayFold.departuresMatter(board, day: day, now: Self.now, calendar: Self.utc, density: .overkill))
        #expect(TodayFold.departuresMatter(board, day: day, now: Self.now, calendar: Self.utc, density: .hyperdetail))
        #expect(!TodayFold.departuresMatter(DepartureBoard(card: Card(id: "departures", style: .departures)), day: day,
                                            now: Self.now, density: .hyperdetail))
    }

    // MARK: Remarks: the lines

    static func worst(_ kind: Hyper.Kind) -> [String: String] {
        Dictionary(uniqueKeysWithValues: kind.placeholders.map { ($0, String(repeating: "w", count: Hyper.caps[$0] ?? 24)) })
    }

    @Test func everyKindHasEnoughWellFormedLines() {
        #expect(Hyper.Kind.allCases.count == 19)
        for p in Self.voiced {
            for kind in Hyper.Kind.allCases {
                let all = Hyper.lines(kind, p)
                #expect(all.count >= (p == .ultrakill ? 4 : 3), "\(p) \(kind): \(all.count)")
                #expect(Set(all).count == all.count, "duplicate in \(p) \(kind)")
                // A fact that lacks its optional values still has lines to use.
                let plain = all.filter { Set(Voice.placeholders(in: $0)).isSubset(of: kind.required) }
                #expect(plain.count >= (p == .ultrakill ? 3 : 2), "\(p) \(kind) plain lines: \(plain.count)")
                for line in all {
                    let keys = Set(Voice.placeholders(in: line))
                    // Tied to the fact: at least one of its own values is in the line, and none is made up.
                    #expect(!keys.isDisjoint(with: kind.required), "no fact in \(kind): \(line)")
                    #expect(keys.isSubset(of: kind.placeholders), "unknown placeholder in \(kind): \(line)")
                    let filled = Hyper.fill(line, Self.worst(kind))
                    #expect(!filled.contains("{") && !filled.contains("}"), "\(filled)")
                    #expect(filled.count <= Hyper.maxLength, "\(filled.count) > \(Hyper.maxLength): \(filled)")
                    #expect(line.hasSuffix(".") || line.hasSuffix("?") || line.hasSuffix("!"), "\(line)")
                    #expect(line.first?.isUppercase == true || line.hasPrefix("{"), "\(line)")
                    for tic in ["Ah,", "Well, well", "Oh look", "Let's", "—", "–", "  "] { #expect(!line.contains(tic), "\(tic) in \(line)") }
                    for c in ["*", "_", "`", "[", "]", "#", "%", "\\"] { #expect(!line.contains(c), "\(c) in \(line)") }
                }
            }
        }
        #expect(Hyper.Kind.allCases.allSatisfy { Hyper.lines($0, .off).isEmpty })
    }

    static var allLines: [Personality: [String]] {
        Dictionary(uniqueKeysWithValues: Self.voiced.map { p in (p, Hyper.Kind.allCases.flatMap { Hyper.lines($0, p) }) })
    }

    @Test func personalitiesDontShareLinesAndUltrakillIsItsOwnTier() {
        let sets = Self.voiced.map { Set(Self.allLines[$0]!) }
        #expect(sets[0].isDisjoint(with: sets[1]) && sets[0].isDisjoint(with: sets[2]) && sets[1].isDisjoint(with: sets[2]))
        // Not borrowed from the other places either.
        let others = Voice.Place.allCases.flatMap { place in Self.voiced.flatMap { VoiceLines.all(place, $0) } }
        let takes = Take.Fact.Kind.allCases.flatMap { k in Self.voiced.flatMap { Voice.templates(k, $0) } }
        for p in Self.voiced {
            #expect(Set(Self.allLines[p]!).isDisjoint(with: others + takes), "\(p) repeats: \(Set(Self.allLines[p]!).intersection(others + takes))")
        }
        // Ultrakill swears in at least 40% of its lines, the others never.
        let sweary = Self.allLines[.ultrakill]!.filter { l in TakeTests.swears.contains { TakeTests.words(l).contains(" \($0) ") } }
        #expect(Double(sweary.count) >= Double(Self.allLines[.ultrakill]!.count) * 0.4, "\(sweary.count) of \(Self.allLines[.ultrakill]!.count)")
        for p in [Personality.dry, .snarky] {
            for l in Self.allLines[p]! {
                for bad in TakeTests.swears { #expect(!TakeTests.words(l).contains(" \(bad) "), "\(p): \(l)") }
            }
        }
    }

    @Test func hardLimitsHoldForEveryHyperLine() {
        let all = Self.voiced.flatMap { Self.allLines[$0]! }
        #expect(all.count >= 190)
        for line in all {
            for (what, list) in [("slur", VoiceSpotTests.slurs), ("protected group", VoiceSpotTests.groups),
                                 ("sexual", VoiceSpotTests.sexual), ("self-harm", VoiceSpotTests.selfHarm),
                                 ("violence", VoiceSpotTests.violence), ("real person", VoiceSpotTests.people)] {
                let found = VoiceSpotTests.hit(line, list)
                #expect(found == nil, "\(what) '\(found ?? "")' in: \(line)")
            }
            for bad in TakeTests.banned { #expect(!TakeTests.words(line).contains(" \(bad) "), "banned word in: \(line)") }
        }
    }

    // MARK: Remarks: the pick

    static let hostDown = Host(id: "nas", name: "nas", reachable: false, checked: now.addingTimeInterval(-120))

    @Test func offSaysNothingAndTheFactIsRequired() {
        let fact = Hyper.fact(host: Self.hostDown, now: Self.now)
        #expect(fact != nil)
        #expect(Hyper.remark(fact, .off, now: Self.now) == nil)
        #expect(HyperContext(personality: .off, now: Self.now).remark(fact) == nil)
        for p in Self.voiced {
            let r = Hyper.remark(fact, p, now: Self.now, calendar: Self.utc)
            #expect(r?.lowercased().contains("nas") == true, "\(r ?? "nil")")
            #expect(HyperContext(personality: p, now: Self.now, calendar: Self.utc).remark(fact) == r)
        }
        // No fact, or one without its required values: nothing to say.
        #expect(Hyper.remark(nil, .snarky) == nil)
        #expect(Hyper.remark(Hyper.Fact(.grade, ["subject": "ITP"]), .snarky) == nil)
        #expect(Hyper.remark(Hyper.Fact(.row, ["title": "  "]), .snarky) == nil)
    }

    @Test func fixedForTheDayVariantsCycleSeedsSpread() {
        let fact = Hyper.Fact(.row, ["title": "Backups", "value": "ok"])
        for p in Self.voiced {
            let day = Self.now
            func text(_ d: Date, _ v: Int = 0, _ f: Hyper.Fact = fact) -> String? { Hyper.remark(f, p, now: d, calendar: Self.utc, variant: v) }
            #expect(text(day) == text(day.addingTimeInterval(3600)))
            #expect(text(day) != text(day.addingTimeInterval(86400)) || Hyper.lines(.row, p).count == 1)
            let n = Hyper.eligible(fact, p).count
            let cycle = (0..<n).compactMap { text(day, $0) }
            #expect(Set(cycle).count == n && text(day, n) == text(day, 0) && text(day, -1) == text(day, n - 1))
            let seeds = Set((0..<30).compactMap { text(day, 0, Hyper.Fact(.row, ["title": "Row \($0)", "value": "ok"])) })
            #expect(seeds.count > 1)
        }
    }

    @Test func optionalValuesOnlyFillWhereKnown() {
        // Without {mount} only the lines that do not need it; with it all of them.
        let bare = Hyper.Fact(.hostFull, ["host": "media", "pct": "93%"])
        let full = Hyper.Fact(.hostFull, ["host": "media", "pct": "93%", "mount": "/srv"])
        for p in Self.voiced {
            #expect(Hyper.eligible(bare, p).allSatisfy { !$0.contains("{mount}") })
            #expect(Hyper.eligible(full, p).count > Hyper.eligible(bare, p).count)
            for v in 0..<6 {
                #expect(Hyper.remark(bare, p, now: Self.now, variant: v)?.contains("{") == false)
                #expect(Hyper.remark(full, p, now: Self.now, variant: v)?.contains("{") == false)
            }
        }
        // Values are cut to their caps; a value an unknown key brings is dropped.
        let long = Hyper.Fact(.approval, ["title": String(repeating: "restart ", count: 20), "colour": "red"])
        #expect(long.values["title"]!.count <= Hyper.caps["title"]! && long.values["colour"] == nil)
    }

    // MARK: The facts

    @Test func hostFactsFollowTheNumbers() {
        func kind(_ h: HomelabKit.Host) -> Hyper.Kind? { Hyper.fact(host: h, now: Self.now)?.kind }
        #expect(kind(Self.hostDown) == .hostDown)
        #expect(kind(Host(id: "a", reachable: true, disks: ["/": 93])) == .hostFull)
        #expect(kind(Host(id: "a", reachable: true, disks: ["/": 84])) == .hostUp)
        #expect(kind(Host(id: "a", reachable: true, temp: 74)) == .hostHot)
        #expect(kind(Host(id: "a", reachable: true, load: 6.5, cpuCount: 4)) == .hostBusy)
        #expect(kind(Host(id: "a", reachable: true, load: 3.9, cpuCount: 4)) == .hostUp)
        #expect(kind(Host(id: "a", reachable: true, load: 6.5)) == .hostUp)       // no core count: no claim
        #expect(kind(Host(id: "a", reachable: nil)) == nil)                       // unknown: nothing to say
        let up = Hyper.fact(host: Host(id: "a", name: "media", reachable: true, checked: Self.now.addingTimeInterval(-300),
                                       containersUp: 5, containersTotal: 5), now: Self.now)
        #expect(up?.values["containers"] == "5 containers" && up?.values["checked"] == "5 min ago" && up?.values["host"] == "media")
        let part = Hyper.fact(host: Host(id: "a", reachable: true, containersUp: 4, containersTotal: 5), now: Self.now)
        #expect(part?.values["containers"] == nil)   // 4 of 5 is not "runs 5 containers"
        let full = Hyper.fact(host: Host(id: "m", name: "media", reachable: true, disks: ["/srv": 93]), now: Self.now)
        #expect(full?.values["pct"] == "93%" && full?.values["mount"] == "/srv")
    }

    @Test func rowFactsFollowTheCardKind() {
        let now = Self.now, cal = Self.utc
        func fact(_ item: Card.Item, _ card: Card) -> Hyper.Fact? { Hyper.fact(item: item, in: card, now: now, calendar: cal) }
        let day = cal.startOfDay(for: now)
        #expect(fact(.init(title: "Dune", progress: 0.45), Card(id: "downloads", style: .list))?.kind == .download)
        #expect(fact(.init(title: "Dune", progress: 0.45), Card(id: "downloads", style: .list))?.values["progress"] == "45%")
        #expect(fact(.init(title: "Test", subtitle: "ITP", value: "95 %"), Card(id: "grades", style: .list))?.values["subject"] == "ITP")
        #expect(fact(.init(title: "Test"), Card(id: "grades", style: .list)) == nil)   // no grade, no remark
        #expect(fact(.init(title: "Budget"), Card(id: "news", style: .list))?.kind == .news)
        let due = cal.date(byAdding: .day, value: 2, to: day)!
        let dl = fact(.init(title: "Essay", due: due, dueIsDay: true), Card(id: "d", style: .countdown))
        #expect(dl?.kind == .deadline && dl?.values["when"] == "Tue")
        #expect(fact(.init(title: "Essay"), Card(id: "d", style: .countdown)) == nil)
        let todos = Card(id: "todos", style: .checklist)
        #expect(fact(.init(title: "Milk", done: true), todos)?.values["status"] == "done")
        #expect(fact(.init(title: "Milk"), todos)?.values["status"] == "open")
        #expect(fact(.init(title: "Milk", due: cal.date(byAdding: .day, value: -2, to: day)!, dueIsDay: true), todos)?.values["status"] == "overdue")
        let dep = fact(.init(title: "Floridsdorf", value: "10:05"), Card(id: "departures", title: "U6", style: .departures))
        #expect(dep?.kind == .departure && dep?.values["line"] == "U6" && dep?.values["when"] == "10:05")
        #expect(fact(.init(title: "Cores", value: "4"), Card(id: "x", style: .metrics))?.kind == .row)
        #expect(fact(.init(value: "4"), Card(id: "x", style: .metrics)) == nil)
        #expect(Hyper.fact(card: Card(id: "x", title: "Parcels", items: Self.items(3)))?.values["count"] == "3 rows")
        #expect(Hyper.fact(card: Card(id: "x")) == nil)
    }

    @Test func otherFacts() {
        let p = PendingAction(id: "7", action: "restart", arg: "media sonarr", created: Self.now.addingTimeInterval(-3600))
        let a = Hyper.fact(pending: p, now: Self.now)
        #expect(a.kind == .approval && a.values["title"] == "restart media sonarr" && a.values["age"] == "1 h ago")
        let deal = Deal(id: 3, title: "RTX 3060", price: 140, discount: 0.5, verdict: .act)
        let d = Hyper.fact(deal: deal)
        #expect(d.values["title"] == "RTX 3060" && d.values["price"]?.contains("140") == true)
        #expect(Hyper.fact(message: ChatMessage(id: 1, from: .me, text: "hi there")) == nil)
        let reply = Hyper.fact(message: ChatMessage(id: 2, ts: Self.now, from: .agent, text: "all fine here"), now: Self.now)
        #expect(reply?.values["words"] == "3 words" && reply?.values["age"] == "just now")
        #expect(Hyper.fact(message: ChatMessage(id: 3, from: .agent, text: "  ")) == nil)
        let action = ActionSpec(name: "restart", label: "Restart container", fields: [
            .init(name: "host", label: "Host", kind: .text, max: 40, required: true),
        ])
        #expect(Hyper.fact(action: action).values["fields"] == "1 field")
        #expect(Hyper.fact(entity: HAEntity(entityID: "sensor.t", state: "21.4", name: "Living room", unit: "°C")).values["state"] == "21.4°C")
        #expect(Hyper.fact(server: "lab", snapshot: nil).values["name"] == "lab")
    }

    // MARK: The details

    @Test func stampsAndNumbers() {
        #expect(Hyper.stamp(Self.now.addingTimeInterval(-125), now: Self.now, calendar: Self.utc) == "2026-11-08 09:57:55 +00:00 (2 min ago)")
        #expect(Hyper.stamp(nil, now: Self.now) == "never")
        var vienna = Calendar(identifier: .gregorian)
        vienna.timeZone = TimeZone(identifier: "Europe/Vienna")!
        #expect(Hyper.stamp(Self.now, now: Self.now, calendar: vienna).hasPrefix("2026-11-08 11:00:00 +01:00"))
        #expect(Hyper.raw(3) == "3" && Hyper.raw(0.52) == "0.52" && Hyper.raw(-12.5) == "-12.5")
    }

    @Test func aHostShowsEveryField() {
        let history = HostHistory(step: 300, end: Self.now, load: [0.1, nil, 0.3], memPct: [40, 41, 42], temp: [50, 51, 52],
                                  diskPct: [80, 80, 81])
        let h = Host(id: "media", name: "media-box", kind: "linux", reachable: true, checked: Self.now.addingTimeInterval(-60),
                     load: 0.52, cpuCount: 4, memPct: 41, temp: 63, disks: ["/": 40, "/srv": 93], containersUp: 5, containersTotal: 6,
                     upgradable: 12, rebootRequired: true, backupLast: "2026-11-07", backupResult: "ok", flags: ["throttled_now"],
                     url: URL(string: "https://media.example"), history: history,
                     containerList: [ContainerInfo(name: "sonarr", state: .running, health: .healthy, restarts: 2, restartable: true)])
        let lines = Hyper.host(h, now: Self.now, calendar: Self.utc)
        let by = Dictionary(lines.map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        for key in ["id", "name", "kind", "reachable", "checked", "load", "mem_pct", "temp", "disk /", "disk /srv", "containers",
                    "container sonarr", "upgradable", "reboot_required", "backup last", "backup result", "flags", "url",
                    "history step", "history end", "history load", "history load values", "history mem_pct values",
                    "history temp values", "history disk_pct values"] {
            #expect(by[key] != nil, "missing \(key)")
        }
        #expect(by["load"] == "0.52 on 4 cores, 0.13 per core" && by["containers"] == "up 5 of 6")
        #expect(by["history load values"] == "0.1 · 0.3" || by["history load values"]?.hasPrefix("0.1") == true)
        #expect(by["history load"]?.contains("2 of 3 points") == true && by["container sonarr"] == "running · healthy · restarts 2 · restartable")
        #expect(by["history mem_pct values"] == "40 41 42")
        // A host without numbers shows what it has, and says so for the rest.
        let bare = Dictionary(Hyper.host(Host(id: "x"), now: Self.now, calendar: Self.utc).map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(bare["reachable"] == "unknown" && bare["checked"] == "never" && bare["load"] == nil)
    }

    @Test func cardsRowsDealsAndMessagesShowTheirFields() {
        let item = Card.Item(title: "Dune", subtitle: "S1E3", value: "45 %", progress: 0.45, icon: "film", url: URL(string: "https://x.example/1"),
                             tint: .orange, done: false, due: Self.now, dueIsDay: false,
                             action: ItemAction(name: "retry", arg: "7", payload: ["a": "b"]), cancelled: false)
        let labels = Hyper.item(item, now: Self.now, calendar: Self.utc).map(\.label)
        #expect(labels == ["title", "subtitle", "value", "progress", "icon", "tint", "url", "done", "due", "action", "cancelled"])
        let card = Card(id: "downloads", title: "Downloads", icon: "arrow.down", tint: .blue, style: .list, updated: "10:00",
                        text: "hello", items: [item], action: ItemAction(name: "open"), date: "2026-11-08", place: .today)
        let cl = Dictionary(Hyper.card(card, now: Self.now, calendar: Self.utc).map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(cl["id"] == "downloads" && cl["updated"] == "10:00" && cl["date"] == "2026-11-08" && cl["items"] == "1" && cl["style"] == "list")
        #expect(cl["text"] == "5 characters" && cl["place"] == "today" && cl["tint"] == "blue" && cl["action"] == "open")
        let deal = Deal(id: 9, watch: "gpu", kind: "gpu", title: "RTX", price: 140, value: 280, discount: 0.5, confidence: .high, near: true,
                        flags: ["scam?"], seen: Self.now, verdict: .act, comps: [.init(title: "Other", price: 300)])
        let dl = Hyper.deal(deal, now: Self.now, calendar: Self.utc).map(\.label)
        for key in ["id", "watch", "kind", "price", "value", "discount", "confidence", "verdict", "near", "flags", "seen", "comp"] { #expect(dl.contains(key), Comment(rawValue: key)) }
        let ml = Hyper.message(ChatMessage(id: 5, ts: Self.now, from: .agent, job: "daily", status: "ok", text: "one two\nthree"),
                               now: Self.now, calendar: Self.utc)
        #expect(ml.first { $0.label == "size" }?.value == "13 characters · 3 words · 2 lines" && ml.map(\.label).contains("job"))
    }

    @Test func settingsAndServerShowTheRawValues() throws {
        var s = AppSettings()
        s.notifyProblems = true
        s.todayDensity = .hyperdetail
        s.voice = .snarky
        let lines = Dictionary(Hyper.settings(s).map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(lines["density"] == "\"hyperdetail\"" && lines["personality"] == "\"snarky\"" && lines["notifyProblems"] == "true")
        #expect(lines["ultrakillWarned"] == nil)   // unset is not there
        let info = ServerInfo(api: 1, name: "Demo", server: "ref", version: "1.2", features: [.status, .deals], auth: "token")
        let snap = Snapshot(serverID: UUID(), serverName: "lab", state: HomelabState(status: .ok, checked: Self.now.addingTimeInterval(-30)),
                            info: info, fetched: Self.now.addingTimeInterval(-120))
        let sl = Dictionary(Hyper.server(name: "lab", snapshot: snap, info: info, failures: 2, busy: ["backup"], now: Self.now, calendar: Self.utc)
            .map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(sl["version"] == "1.2" && sl["api"] == "1" && sl["features"] == "deals, status" && sl["failures in a row"] == "2")
        #expect(sl["fetched"]?.hasSuffix("(2 min ago)") == true, "\(sl["fetched"] ?? "-")")
        #expect(sl["stale"] == "no" && sl["busy"] == "backup", "\(sl)")
    }

    // MARK: Off, and the other levels

    @MainActor @Test func onlyHyperdetailHasAContextAndOffMeansDetailsOnly() {
        let (m, _, _, _) = makeModel()
        for d in [Density.calm, .standard, .overkill] {
            m.settings.todayDensity = d
            #expect(m.hyper == nil, "\(d)")
        }
        m.settings.todayDensity = .hyperdetail
        #expect(m.hyper?.personality == .off)
        #expect(m.hyper?.remark(Hyper.fact(host: Self.hostDown, now: Self.now)) == nil)
        #expect(!Hyper.host(Self.hostDown, now: Self.now).isEmpty)   // the details are there all the same
        m.settings.voice = .ultrakill
        #expect(m.hyper?.remark(Hyper.fact(host: Self.hostDown, now: Self.now)) != nil)
    }

    @Test func notificationsGetFieldsAndARemarkOnlyWithAPersonality() {
        let p = PendingAction(id: "7", job: "nightly", action: "restart", arg: "sonarr", created: Self.now.addingTimeInterval(-600))
        let state = HomelabState(status: .ok, pending: [p])
        let alert = AlertTracker.Alert(id: "pending-7", kind: .pending, title: "lab: approve restart sonarr?", body: "Proposed by nightly.",
                                       moment: .notice(.waiting), proposal: p)
        let off = Hyper.noticeExtra(alert, state: state, deals: nil, personality: .off, now: Self.now, calendar: Self.utc)
        #expect(off?.contains("id: 7") == true && off?.contains("job: nightly") == true && off?.contains("\n") == false)
        let on = Hyper.noticeExtra(alert, state: state, deals: nil, personality: .snarky, now: Self.now, calendar: Self.utc)
        #expect(on?.hasPrefix(off ?? "?") == true && on?.contains("\n") == true && on?.contains("restart sonarr") == true)
        let summary = AlertTracker.Alert(id: "summary-1", kind: .summary, title: "lab", body: "2 more")
        #expect(Hyper.noticeExtra(summary, state: state, deals: nil, personality: .snarky) == nil)
        // The notification content: the extra is added to the body, never to a locked one.
        let shown = ProposalNotice.content(for: alert, locked: false, voice: .snarky, extra: on)
        #expect(shown.body == "Proposed by nightly.\n" + (on ?? ""))
        #expect(ProposalNotice.content(for: alert, locked: false, voice: .snarky).body == "Proposed by nightly.")
        #expect(!ProposalNotice.content(for: alert, locked: true, voice: .snarky, extra: on).body.contains("id: 7"))
    }

    // MARK: Lab, chat, results, launch

    @Test func labCardsChatAndResultsAreUnfolded() {
        let card = Card(id: "tailnet", style: .list, items: Self.items(8))
        #expect(LabRows.folds(card, density: .standard) && LabRows.shown(card, expanded: false, density: .standard).count == 3)
        #expect(!LabRows.folds(card, density: .hyperdetail) && LabRows.shown(card, expanded: false, density: .hyperdetail).count == 8)
        var s = AppSettings()
        s.chatFolding = .short
        #expect(s.shownChatFolding == .short)
        s.todayDensity = .hyperdetail
        #expect(s.shownChatFolding == .never && s.chatFolding == .short)
        let r = ActionReport(ok: true, title: "Restarted sonarr", text: "running.")
        #expect(r.hyperdetailed(nil) == r)
        let h = r.hyperdetailed(HyperContext(personality: .off, now: Self.now, calendar: Self.utc))
        #expect(h.text.hasPrefix("running.\n\nok: true\ntitle: Restarted sonarr") && h.text.contains("at: 2026-11-08 10:00:00 +00:00"))
    }

    @MainActor @Test func settingsPageLaunchArgument() {
        let (m, _, _, _) = makeModel(args: ["app", "-HomelabDemo", "YES", "-HomelabSettingsPage", "Advanced"])
        #expect(m.openSettingsPage == "advanced")
        let (n, _, _, _) = makeModel(args: ["app", "-HomelabSettingsPage", "nope"])
        #expect(n.openSettingsPage == nil)
    }
}
