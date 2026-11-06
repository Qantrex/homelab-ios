import Foundation
import Testing
@testable import HomelabKit

@Suite struct TakeTests {
    static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
    let noon = Date(timeIntervalSince1970: 1_793_923_200 + 12 * 3600)   // 2026-11-06 12:00 UTC
    static let voiced: [Personality] = [.dry, .snarky, .ultrakill]
    typealias Fact = Take.Fact

    // MARK: Personality

    @Test func ultrakillIsTheFourthLevelAndDecodes() throws {
        #expect(Personality.allCases == [.off, .dry, .snarky, .ultrakill])
        #expect(Personality.ultrakill.title == "Ultrakill" && Personality.ultrakill.rawValue == "ultrakill")
        for p in Personality.allCases {
            let back = try JSONDecoder().decode(Personality.self, from: JSONEncoder().encode(p))
            #expect(back == p)
        }
        // Values stored by older versions, and one from a newer version this one doesn't know.
        #expect(try decode(Personality.self, #""snarky""#) == .snarky)
        #expect(try decode(Personality.self, #""dry""#) == .dry)
        #expect(try decode(Personality.self, #""Ultrakill""#) == .ultrakill)
        #expect(try decode(Personality.self, #""unhinged""#) == .off)
        var s = AppSettings()
        s.voice = .ultrakill
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s)).voice == .ultrakill)
        let newer = #"{"notifyProblems": true, "notifyPending": false, "faceIDLock": false, "personality": "unhinged"}"#
        let settings = try decode(AppSettings.self, newer)
        #expect(settings.voice == .off && settings.notifyProblems)
    }

    @MainActor @Test func launchArgumentTakesUltrakill() {
        let (m, _, _, _) = makeModel(args: ["app", "-HomelabDemo", "YES", "-HomelabPersonality", "Ultrakill"])
        #expect(m.settings.voice == .ultrakill)
    }

    // MARK: Templates

    /// The placeholders every template of a kind must show: the fact stays visible whatever the attitude.
    static func required(_ kind: Fact.Kind) -> [[String]] {
        switch kind {
        case .hostDown, .backupFailed: [["host"]]
        case .container: [["host"], ["container"], ["state"]]
        case .disk: [["host"], ["pct"]]
        case .hot: [["host"], ["temp"]]
        case .load: [["host"], ["load"], ["cores"]]
        case .power: [["host"], ["flag"]]
        case .problem: [["text"]]
        case .overdue: [["title"], ["todos", "more"]]
        case .deadline: [["title"], ["when"]]
        case .waiting: [["actions"]]
        case .parcel: [["title"]]
        case .allFine: [["machines", "containers"]]
        }
    }

    static let known: Set<String> = ["host", "container", "state", "mount", "pct", "temp", "load", "cores", "flag",
                                     "text", "todos", "more", "title", "when", "actions", "first", "machines",
                                     "containers", "quiet"]

    /// The longest value each placeholder can get.
    static let worst: [String: String] = [
        "host": String(repeating: "h", count: Voice.hostMax),
        "container": String(repeating: "c", count: Voice.containerMax),
        "state": "not running", "mount": String(repeating: "m", count: Voice.mountMax), "pct": "100%",
        "temp": "105°C", "load": "12.34", "cores": "16 cores", "flag": "under-voltage since boot",
        "text": String(repeating: "t", count: Voice.textMax), "todos": "99 to-dos", "more": "98 others",
        "title": String(repeating: "T", count: Voice.titleMax), "when": "tomorrow", "actions": "99 actions",
        "first": String(repeating: "f", count: Voice.firstMax), "machines": "12 machines",
        "containers": "250 containers", "quiet": String(repeating: "q", count: Voice.hostMax),
    ]

    @Test func everyTemplateIsWellFormedAndFitsOneLine() {
        for p in Self.voiced {
            for kind in Fact.Kind.allCases {
                let all = Voice.templates(kind, p)
                let minimum = [.allFine, .disk, .problem, .waiting, .container].contains(kind) ? 6 : 4
                #expect(all.count >= minimum, "\(p) \(kind): \(all.count)")
                #expect(Set(all).count == all.count, "duplicate in \(p) \(kind)")
                for t in all {
                    let keys = Voice.placeholders(in: t)
                    #expect(Set(keys).isSubset(of: Self.known), "unknown placeholder: \(t)")
                    for group in Self.required(kind) {
                        #expect(group.contains { keys.contains($0) }, "\(p) \(kind) misses {\(group[0])}: \(t)")
                    }
                    let filled = Voice.fill(t, Self.worst)
                    #expect(!filled.contains("{") && !filled.contains("}"), "\(filled)")
                    #expect(filled.count <= 90, "\(filled.count): \(filled)")
                    #expect(t.hasSuffix(".") || t.hasSuffix("?") || t.hasSuffix("!"), "\(t)")
                    for tic in ["Ah,", "Well, well", "Oh look", "Let's", "—", "–", "  "] {
                        #expect(!t.contains(tic), "\(tic) in \(t)")
                    }
                }
            }
        }
        // No two personalities share a template.
        let sets = Self.voiced.map { p in Set(Fact.Kind.allCases.flatMap { Voice.templates($0, p) }) }
        #expect(sets[0].isDisjoint(with: sets[1]) && sets[0].isDisjoint(with: sets[2]) && sets[1].isDisjoint(with: sets[2]))
        #expect(Fact.Kind.allCases.allSatisfy { Voice.templates($0, .off).isEmpty })
    }

    /// One sample fact of every kind, plus the sparse variants (no mount, one to-do, no host, no containers).
    static let samples: [Fact] = [
        .hostDown(host: "nas"),
        .container(host: "media", name: "sonarr", state: "unhealthy"),
        .container(host: "media", name: "gluetun", state: "exited"),
        .disk(host: "media", mount: "/srv/media", percent: 93),
        .disk(host: "media", mount: nil, percent: 93),
        .hot(host: "pi", celsius: 78),
        .load(host: "media", load: 8.4, cores: 4),
        .load(host: "tiny", load: 2.5, cores: 1),
        .power(host: "pi", flag: "under-voltage since boot"),
        .power(host: "pi", flag: "throttled now"),
        .backupFailed(host: "media"),
        .problem(host: "server", text: "12 updates, 3 security"),
        .problem(host: nil, text: "a problem the server won't name"),
        .overdue(count: 3, oldest: "Call the plumber"),
        .overdue(count: 1, oldest: "Renew the bike lock code before the end of the month"),
        .deadline(title: "Project hand-in", tomorrow: true),
        .deadline(title: "Tax return", tomorrow: false),
        .waiting(count: 2, first: "restart media sonarr"),
        .waiting(count: 1, first: nil),
        .parcel(title: "Keyboard"),
        .allFine(up: 3, containers: 31, quietest: "pi"),
        .allFine(up: 1, containers: 0, quietest: nil),
    ]

    /// What must be readable in the take: the real values.
    static func visible(_ fact: Fact) -> [String] {
        switch fact {
        case let .hostDown(h), let .backupFailed(h): [h]
        case let .container(h, n, s): [h, n, s]
        case let .disk(h, _, p): [h, "\(p)%"]
        case let .hot(h, c): [h, "\(c)°C"]
        case let .load(h, l, c): [h, String(format: "%.2f", l), c == 1 ? "1 core" : "\(c) cores"]
        case let .power(h, f): [h, f]
        case let .problem(_, t): [t]
        case let .overdue(_, t): [String(t.prefix(12))]
        case let .deadline(t, tomorrow): [t, tomorrow ? "tomorrow" : "today"]
        case let .waiting(n, _): [n == 1 ? "1 action" : "\(n) actions"]
        case let .parcel(t): [t]
        case .allFine: []   // machines or containers: checked by the template test
        }
    }

    @Test func everySampleFillsCleanlyWithItsValues() {
        for p in Self.voiced {
            for fact in Self.samples {
                let n = Voice.eligible(fact, p).count
                #expect(n >= 2, "\(p) \(fact): only \(n)")
                for variant in 0..<n {
                    guard let take = Self.take(fact, p, noon, variant) else { Issue.record("no take"); continue }
                    #expect(!take.text.contains("{") && !take.text.contains("}"), "\(take.text)")
                    #expect(take.text.count <= 90, "\(take.text)")
                    for value in Self.visible(fact) {
                        #expect(take.text.lowercased().contains(value.lowercased()), "\(value) missing: \(take.text)")
                    }
                }
            }
        }
    }

    /// A take for a single fact, through the public path where possible.
    static func take(_ fact: Fact, _ p: Personality, _ now: Date, _ variant: Int) -> Take? {
        let options = Voice.eligible(fact, p)
        guard !options.isEmpty else { return nil }
        return Take(text: Voice.fill(options[((variant % options.count) + options.count) % options.count], fact.values),
                    fact: fact, mood: .calm)
    }

    @Test func numbersShowInTheTake() throws {
        var state = HomelabState(status: .warning, hosts: [
            Host(id: "media", reachable: true, load: 0.4, cpuCount: 4, disks: ["/": 40, "/srv/media": 93]),
            Host(id: "pi", reachable: true, load: 0.2, cpuCount: 4, temp: 50),
        ])
        for p in Self.voiced {
            let take = try #require(Voice.take(for: state, personality: p, now: noon, calendar: Self.utc))
            #expect(take.fact == .disk(host: "media", mount: "/srv/media", percent: 93))
            #expect(take.text.contains("93%") && take.text.contains("media"), "\(take.text)")
            #expect(take.mood == .headsUp)
        }
        state.hosts[0].disks = ["/": 40]
        state.hosts[1].temp = 78.4
        let hot = try #require(Voice.take(for: state, personality: .ultrakill, now: noon, calendar: Self.utc))
        #expect(hot.text.contains("78°C") && hot.text.contains("pi"), "\(hot.text)")
        state.hosts[1].temp = 50
        state.hosts[0].load = 8.4
        let busy = try #require(Voice.take(for: state, personality: .dry, now: noon, calendar: Self.utc))
        #expect(busy.text.contains("8.40") && busy.text.contains("4 cores"), "\(busy.text)")
    }

    // MARK: Picking

    @Test func offAndNothingToSayGiveNil() throws {
        let demo = try fixture(HomelabState.self, "state-problem.json")
        #expect(Voice.take(for: demo, personality: .off, now: noon, calendar: Self.utc) == nil)
        #expect(Voice.takeCount(for: demo, personality: .off, now: noon, calendar: Self.utc) == 0)
        #expect(Voice.take(for: demo.problems[0], host: nil, personality: .off, now: noon) == nil)
        #expect(Voice.take(for: nil, personality: .ultrakill, now: noon, calendar: Self.utc) == nil)
        #expect(Voice.take(for: HomelabState(status: .unknown), personality: .dry, now: noon, calendar: Self.utc) == nil)
        #expect(Voice.take(for: HomelabState(status: .ok), personality: .dry, now: noon, calendar: Self.utc) == nil)
        // The lab answers but the server doesn't know: no "all fine".
        let unknown = HomelabState(status: .unknown, hosts: [Host(id: "pi", reachable: true)])
        #expect(Voice.take(for: unknown, personality: .snarky, now: noon, calendar: Self.utc) == nil)
    }

    @Test func sameTakeAllDayNextDayAnotherVariantsCycle() throws {
        let demo = try fixture(HomelabState.self, "state-problem.json")
        for p in Self.voiced {
            let day = Date(timeIntervalSince1970: 1_793_923_200)
            func text(_ d: Date, _ v: Int = 0) -> String? {
                Voice.take(for: demo, personality: p, now: d, calendar: Self.utc, variant: v)?.text
            }
            let morning = text(day + 6 * 3600), night = text(day + 23 * 3600 + 59 * 60)
            #expect(morning != nil && morning == night)
            #expect(text(day + 30 * 3600) != morning)
            let n = Voice.takeCount(for: demo, personality: p, now: day, calendar: Self.utc)
            #expect(n >= 6)
            let variants = (0..<n).compactMap { text(day + 3600, $0) }
            #expect(Set(variants).count == n)                                  // every variant is another template
            #expect(text(day + 3600, n) == text(day + 3600, 0) && text(day + 3600, -1) == text(day + 3600, n - 1))
            let days = Set((0..<n).compactMap { text(day + Double($0) * 86400) })
            #expect(days == Set(variants))                                     // over n days, every one comes up
        }
    }

    @Test func priorityOrder() throws {
        func todo(_ title: String, _ due: Date) -> Card.Item { Card.Item(title: title, due: due) }
        var hosts = [
            Host(id: "nas", reachable: false),
            Host(id: "gpu", name: "gaming-pc", reachable: false, flags: ["asleep"]),   // asleep: never "down"
            Host(id: "media", reachable: true, load: 0.5, cpuCount: 4, disks: ["/srv/media": 93]),
            Host(id: "box", reachable: true, load: 0.3, cpuCount: 4, temp: 78),
            Host(id: "pi", reachable: true, load: 9, cpuCount: 4),
            Host(id: "pi2", reachable: true, load: 0.1, cpuCount: 4, flags: ["undervoltage_now"]),
        ]
        var problems = [
            Problem(text: "media: container sonarr is unhealthy", host: "media", severity: .problem),
            Problem(text: "media: backup failed", host: "media", severity: .warning),
        ]
        var cards = [
            Card(id: "todos", style: .checklist, items: [todo("Call the plumber", noon - 2 * 86400),
                                                         todo("Milk", noon - 3600), Card.Item(title: "Done", done: true, due: noon - 86400 * 9)]),
            Card(id: "deadlines", style: .countdown, items: [Card.Item(title: "Project hand-in", due: noon + 86400),
                                                             Card.Item(title: "Gone", due: noon - 86400)]),
            Card(id: "parcels", style: .list, items: [Card.Item(title: "Keyboard", subtitle: "DHL · out for delivery", value: "today")]),
        ]
        var pending = [PendingAction(id: "p1", action: "restart", arg: "media sonarr"), PendingAction(id: "p2", action: "apt-upgrade")]
        func state() -> HomelabState {
            let status: OverallStatus = problems.contains { $0.severity == .problem } ? .problem : problems.isEmpty ? .ok : .warning
            return HomelabState(status: status, problems: problems, hosts: hosts, pending: pending, cards: cards)
        }
        func top() -> (Fact, TodayMood.Level)? {
            Voice.notableFact(in: state(), now: noon, calendar: Self.utc).map { ($0.fact, $0.mood) }
        }
        #expect(top()?.0 == .hostDown(host: "nas") && top()?.1 == .alarm)
        hosts.remove(at: 0)
        #expect(top()?.0 == .container(host: "media", name: "sonarr", state: "unhealthy") && top()?.1 == .alarm)
        problems.remove(at: 0)
        #expect(top()?.0 == .disk(host: "media", mount: "/srv/media", percent: 93) && top()?.1 == .headsUp)
        hosts[1].disks = ["/srv/media": 89]
        #expect(top()?.0 == .hot(host: "box", celsius: 78))
        hosts[2].temp = 75   // over 75 only
        #expect(top()?.0 == .load(host: "pi", load: 9, cores: 4))
        hosts[3].load = 8    // twice the cores is not over
        #expect(top()?.0 == .power(host: "pi2", flag: "under-voltage now"))
        hosts[4].flags = []
        #expect(top()?.0 == .backupFailed(host: "media"))
        problems.removeAll()
        #expect(top()?.0 == .overdue(count: 2, oldest: "Call the plumber") && top()?.1 == .headsUp)
        cards[0].items.removeAll { $0.done != true }
        #expect(top()?.0 == .deadline(title: "Project hand-in", tomorrow: true))
        cards[1].items.removeFirst()
        #expect(top()?.0 == .waiting(count: 2, first: "restart media sonarr"))
        pending.removeAll()
        #expect(top()?.0 == .parcel(title: "Keyboard") && top()?.1 == .calm)
        cards[2].items[0].subtitle = "DHL · in transit"
        #expect(top()?.0 == .allFine(up: 4, containers: 0, quietest: "pi2") && top()?.1 == .calm)
    }

    @Test func dayOnlyDuesCountByDay() throws {
        let card = Card(id: "t", style: .checklist, items: [
            Card.Item(title: "Today", due: Self.utc.startOfDay(for: noon), dueIsDay: true),
            Card.Item(title: "Yesterday", due: Self.utc.startOfDay(for: noon) - 86400, dueIsDay: true),
        ])
        let deadlines = Card(id: "d", style: .countdown, items: [
            Card.Item(title: "Earlier today", due: noon - 3600),                          // passed: not "due today"
            Card.Item(title: "Hand-in", due: Self.utc.startOfDay(for: noon), dueIsDay: true),
        ])
        var s = HomelabState(status: .ok, hosts: [Host(id: "pi", reachable: true)], cards: [card, deadlines])
        #expect(Voice.notableFact(in: s, now: noon, calendar: Self.utc)?.fact == .overdue(count: 1, oldest: "Yesterday"))
        s.cards.removeFirst()
        #expect(Voice.notableFact(in: s, now: noon, calendar: Self.utc)?.fact == .deadline(title: "Hand-in", tomorrow: false))
    }

    @Test func numbersAloneNeverReadAsAllFine() {
        let host = Host(id: "media", reachable: true, containersUp: 10, containersTotal: 11,
                        containerList: [ContainerInfo(name: "gluetun", state: .exited)])
        let s = HomelabState(status: .warning, hosts: [host])
        #expect(Voice.notableFact(in: s, now: noon, calendar: Self.utc)?.fact
                == .container(host: "media", name: "gluetun", state: "exited"))
        let quiet = HomelabState(status: .warning, hosts: [Host(id: "pi", reachable: true)])
        #expect(Voice.notableFact(in: quiet, now: noon, calendar: Self.utc)?.fact.kind == .problem)
        let unnamed = HomelabState(status: .problem, hosts: [Host(id: "pi", reachable: true)])
        #expect(Voice.notableFact(in: unnamed, now: noon, calendar: Self.utc)?.mood == .alarm)
    }

    @Test func problemsAreReadForWhatTheySay() {
        let media = Host(id: "media", reachable: true, temp: 71, disks: ["/": 44, "/srv/media": 93],
                         containerList: [ContainerInfo(name: "sonarr", health: .unhealthy),
                                         ContainerInfo(name: "gluetun", state: .exited)])
        func fact(_ text: String, _ host: HomelabKit.Host? = media, id: String? = "media") -> Fact {
            Voice.fact(for: Problem(text: text, host: id), host: host)
        }
        #expect(fact("media: container sonarr is unhealthy") == .container(host: "media", name: "sonarr", state: "unhealthy"))
        #expect(fact("gluetun keeps dying") == .container(host: "media", name: "gluetun", state: "exited"))
        #expect(fact("media: disk /srv/media at 93%") == .disk(host: "media", mount: "/srv/media", percent: 93))
        #expect(fact("disk almost full") == .disk(host: "media", mount: "/srv/media", percent: 93))
        #expect(fact("media: CPU temperature 82.6°C") == .hot(host: "media", celsius: 83))
        #expect(fact("running hot") == .hot(host: "media", celsius: 71))
        #expect(fact("pi: under-voltage since boot", nil, id: "pi") == .power(host: "pi", flag: "under-voltage since boot"))
        #expect(fact("throttled now", nil, id: "pi") == .power(host: "pi", flag: "throttled now"))
        #expect(fact("media: backup failed") == .backupFailed(host: "media"))
        #expect(fact("nas is unreachable", nil, id: "nas") == .hostDown(host: "nas"))
        #expect(fact("server: 12 updates, 3 security", nil, id: "server") == .problem(host: "server", text: "12 updates, 3 security"))
        #expect(fact("something odd", nil, id: nil) == .problem(host: nil, text: "something odd"))
        // A download is not "down".
        #expect(fact("download queue stuck", nil, id: "media").kind == Fact.Kind.problem)
    }

    @Test func demoStateTakes() throws {
        let demo = try fixture(HomelabState.self, "state-problem.json")
        let ok = try fixture(HomelabState.self, "state-ok.json")
        for p in Self.voiced {
            let t = try #require(Voice.take(for: demo, personality: p, now: noon, calendar: Self.utc))
            #expect(t.fact == .container(host: "media", name: "sonarr", state: "unhealthy") && t.mood == .alarm)
            // The problem card under it says something else about the same fact.
            let card = try #require(Voice.take(for: demo.problems[0], host: demo.hosts.first { $0.id == "media" },
                                               personality: p, now: noon, calendar: Self.utc))
            #expect(card.fact == t.fact && card.text != t.text)
            let calm = try #require(Voice.take(for: ok, personality: p, now: noon, calendar: Self.utc))
            #expect(calm.fact == .allFine(up: 2, containers: 20, quietest: "nas") && calm.mood == .calm)
            let pi = try #require(Voice.take(for: demo.problems[1], host: demo.hosts.first { $0.id == "pi" },
                                             personality: p, now: noon, calendar: Self.utc))
            #expect(pi.fact == .power(host: "pi", flag: "under-voltage since boot") && pi.mood == .headsUp)
            #expect(pi.text.contains("under-voltage since boot"))
            #expect(Voice.takeCount(for: demo.problems[1], host: nil, personality: p) >= 4)
            let v1 = Voice.take(for: demo.problems[1], host: nil, personality: p, now: noon, calendar: Self.utc, variant: 1)
            #expect(v1 != nil && v1?.text != Voice.take(for: demo.problems[1], host: nil, personality: p, now: noon,
                                                          calendar: Self.utc)?.text)
        }
    }

    @Test func longValuesAreCutNeatly() {
        #expect(Voice.cut("Renew the bike lock code before the end of the month", 24) == "Renew the bike lock…")
        #expect(Voice.cut("Milk.", 24) == "Milk")
        #expect(Voice.cut("supercalifragilisticexpialidocious", 10) == "supercali…")
        let t = Voice.fill("{title} is overdue, plus {more}.", ["title": "Renew the bike lock…", "more": "1 other"])
        #expect(t == "Renew the bike lock… is overdue, plus 1 other.")
        #expect(Voice.fill("{text}. Duly noted.", ["text": "memory at 96%"]) == "Memory at 96%. Duly noted.")
        #expect(Voice.fill("{when}: {title}.", ["when": "tomorrow", "title": "Long…"]) == "Tomorrow: Long…")
    }

    // MARK: Tone

    /// Slurs, hate and other off-limits words, ROT13 so the source stays clean. Matched as whole words.
    static let banned: [String] = [
        "ergneq", "snttbg", "snt", "avttre", "avttn", "genaal", "fcnfgvp", "fcnm", "xvxr", "puvax", "qlxr", "phag",
        "juber", "fyhg", "xvyy lbhefrys", "xlf", "fhvpvqr", "frys-unez", "encr", "cbea", "frk", "frkl", "ahqr", "tnl",
        "wrj", "zhfyvz", "puevfgvna", "vzzvtenag", "jbzra", "tlcfl", "nhgvfgvp", "uvgyre", "anmv",
    ].map(Self.rot13)

    static func rot13(_ s: String) -> String {
        String(s.unicodeScalars.map { c -> Character in
            switch c.value {
            case 97...122: Character(UnicodeScalar((c.value - 97 + 13) % 26 + 97)!)
            default: Character(c)
            }
        })
    }

    static func words(_ s: String) -> String {
        " " + s.lowercased().map { $0.isLetter || $0 == "-" ? String($0) : " " }.joined() + " "
    }

    static let swears = ["shit", "damn", "hell", "crap", "bloody", "bugger", "idiot", "sod"]

    static func allText(_ p: Personality) -> [String] {
        Fact.Kind.allCases.flatMap { Voice.templates($0, p) } + Voice.Moment.allCases.flatMap { Voice.lines($0, p) }
            + samples.flatMap { f in (0..<Voice.eligible(f, p).count).compactMap { take(f, p, Date(), $0)?.text } }
    }

    @Test func ultrakillSwearsButNeverCrossesTheLine() {
        let ultra = Self.allText(.ultrakill)
        for line in ultra {
            let w = Self.words(line)
            for bad in Self.banned { #expect(!w.contains(" \(bad) "), "banned word in: \(line)") }
        }
        // It does go all the way…
        let sweary = ultra.filter { line in Self.swears.contains { Self.words(line).contains(" \($0) ") } }
        #expect(sweary.count >= 40)
        // …and the other levels don't.
        for p in [Personality.dry, .snarky] {
            for line in Self.allText(p) {
                let w = Self.words(line)
                for bad in Self.banned + Self.swears { #expect(!w.contains(" \(bad) "), "\(p): \(line)") }
            }
        }
    }
}
