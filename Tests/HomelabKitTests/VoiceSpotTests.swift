import Foundation
import Testing
@testable import HomelabKit

/// The personality outside Today's take (VoiceLines.swift): Lab's header, problem asides, empty lists, action alerts,
/// notifications. And the content rules for every line and take, hard limits included.
@Suite struct VoiceSpotTests {
    static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
    let noon = Date(timeIntervalSince1970: 1_793_923_200 + 12 * 3600)   // 2026-11-06 12:00 UTC
    static let voiced: [Personality] = [.dry, .snarky, .ultrakill]
    typealias Place = Voice.Place

    /// One spot for every place, with its placeholders filled where it has any.
    static let spots: [Voice.Spot] = [
        .today(.calm), .today(.headsUp), .today(.alarm), .today(.unknown),
        .lab(.allGood), .lab(.warnings(2)), .lab(.problems(1)), .lab(.unknown),
    ] + Take.Fact.Kind.allCases.map { .reason($0, host: "media") }
      + Voice.Empty.allCases.map { .empty($0) }
      + [.actionDone(ok: true), .actionDone(ok: false)]
      + Voice.Notice.allCases.map { .notice($0) }

    /// The longest value each placeholder can get.
    static let worst: [String: String] = ["count": "99 problems", "host": String(repeating: "h", count: Voice.hostMax)]

    // MARK: Content

    @Test func everyPlaceHasWellFormedLines() {
        #expect(Set(Self.spots.map(\.place)) == Set(Place.allCases))
        for p in Self.voiced {
            for place in Place.allCases {
                let all = VoiceLines.all(place, p)
                #expect(all.count >= (p == .ultrakill ? 3 : 2), "\(p) \(place): \(all.count)")
                #expect(Set(all).count == all.count, "duplicate in \(p) \(place)")
                // A spot without its values (no host, a count of 0) still has something to say.
                #expect(all.contains { Voice.placeholders(in: $0).isEmpty }, "\(p) \(place) needs a plain line")
                for line in all {
                    let keys = Set(Voice.placeholders(in: line))
                    #expect(keys.isSubset(of: place.placeholders), "unknown placeholder in \(place): \(line)")
                    let filled = Voice.fill(line, Self.worst)
                    #expect(!filled.contains("{") && !filled.contains("}"), "\(filled)")
                    #expect(filled.count <= place.maxLength, "\(filled.count) > \(place.maxLength): \(filled)")
                    #expect(line.hasSuffix(".") || line.hasSuffix("?") || line.hasSuffix("!"), "\(line)")
                    #expect(line.first?.isUppercase == true || line.hasPrefix("{"), "\(line)")
                    for tic in ["Ah,", "Well, well", "Oh look", "Let's", "—", "–", "  "] {
                        #expect(!line.contains(tic), "\(tic) in \(line)")
                    }
                    // Some lines go through LocalizedStringKey, which reads markdown.
                    for c in ["*", "_", "`", "[", "]", "#", "%", "\\"] { #expect(!line.contains(c), "\(c) in \(line)") }
                    if place == .done { #expect(line.hasPrefix("Done. "), "\(line)") }
                }
            }
        }
        #expect(Place.allCases.allSatisfy { VoiceLines.all($0, .off).isEmpty })
    }

    @Test func personalitiesDontShareLines() {
        let sets = Self.voiced.map { p in Set(Place.allCases.flatMap { VoiceLines.all($0, p) }) }
        #expect(sets[0].isDisjoint(with: sets[1]) && sets[0].isDisjoint(with: sets[2]) && sets[1].isDisjoint(with: sets[2]))
    }

    /// The places beyond Today and the three that existed before (the approve screen, the chat, a waiting action)
    /// carry plenty of lines: the owner should hear the personality everywhere.
    @Test func newPlacesHaveEnoughLines() {
        let old: Set<Place> = [.todayCalm, .todayHeadsUp, .todayAlarm, .todayUnknown, .emptyApprovals, .emptyChat, .noticeWaiting]
        func count(_ p: Personality) -> Int { Place.allCases.filter { !old.contains($0) }.map { VoiceLines.all($0, p).count }.reduce(0, +) }
        #expect(count(.ultrakill) >= 60 && count(.dry) >= 40 && count(.snarky) >= 40)
    }

    // MARK: Hard limits

    /// Slurs, ROT13 so the list itself doesn't print them. Matched as whole words (and plurals).
    static let slurs = ("ergneq ergneqrq snttbg snt avttre avttn genaal fcnfgvp fcnm xvxr puvax tbbx jrgonpx qlxr pevccyr "
        + "zbatbybvq tlcfl tlc fpujhpugry oruvaqreg fcnfg xnanxr artre mvtrhare ghagr ubzb cnxv")
        .split(separator: " ").map { rot13(String($0)) }

    /// Protected groups as people: no line is about any of them.
    static let groups = ["muslim", "jew", "jewish", "christian", "catholic", "islam", "islamic", "hindu", "buddhist",
                         "atheist", "gay", "lesbian", "trans", "transgender", "queer", "lgbt", "lgbtq", "woman", "women",
                         "girl", "feminist", "men", "migrant", "immigrant", "refugee", "foreigner", "asylum", "black",
                         "white", "asian", "african", "arab", "roma", "disabled", "autistic", "blind", "deaf",
                         "wheelchair", "boomer", "zoomer", "turk", "german", "austrians", "american", "russian",
                         "ukrainian", "israeli", "palestinian", "chinese", "serb", "pole", "romanian", "ethnic", "race",
                         "racial"]
    static let sexual = ["sex", "sexy", "sexual", "porn", "nude", "naked", "horny", "orgasm", "fetish", "dick", "cock",
                         "pussy", "boob", "tits", "genital", "erotic", "viagra", "onlyfans", "hooker", "stripper", "bdsm",
                         "kinky", "slut", "whore", "bang", "screw"]
    static let selfHarm = ["suicide", "suicidal", "kys", "overdose", "slit", "noose", "self-harm",
                           "kill yourself", "kill myself", "killing yourself", "hang yourself", "end it all", "cut yourself",
                           "jump off", "not worth living"]
    static let violence = ["shoot", "shooting", "stab", "bomb", "bombing", "lynch", "behead", "guillotine", "assassinate",
                           "assassination", "massacre", "genocide", "terrorist", "terrorism", "rape", "punch", "torch",
                           "molotov", "riot", "exterminate", "execute them", "hang them", "burn them", "string them up",
                           "eat the rich", "kill them"]
    /// Real named living people (politicians, executives, activists): not one, from anywhere.
    static let people = ["trump", "musk", "elon", "bezos", "zuckerberg", "putin", "biden", "harris", "vance", "obama",
                         "merkel", "scholz", "merz", "macron", "meloni", "orban", "orbán", "kickl", "nehammer", "stocker",
                         "babler", "leyen", "ursula", "altman", "gates", "thunberg", "greta", "sobotka", "kurz", "strache",
                         "ludwig", "erdogan", "erdoğan", "netanyahu", "zelensky", "starmer", "sunak", "milei", "modi", "xi",
                         "lagarde", "draghi", "pope", "king charles", "bernie", "aoc", "farage", "le pen", "wagenknecht",
                         "weidel", "söder", "habeck", "van der bellen", "gewessler", "edtstadler"]

    static func rot13(_ s: String) -> String {
        String(s.unicodeScalars.map { c -> Character in
            switch c.value {
            case 97...122: Character(UnicodeScalar((c.value - 97 + 13) % 26 + 97)!)
            case 65...90: Character(UnicodeScalar((c.value - 65 + 13) % 26 + 65)!)
            default: Character(c)
            }
        })
    }

    /// Every line and every take template of every personality.
    static var everything: [String] {
        Personality.allCases.flatMap { p in
            Place.allCases.flatMap { VoiceLines.all($0, p) } + Take.Fact.Kind.allCases.flatMap { Voice.templates($0, p) }
        }
    }

    /// A banned term in `text`: a phrase anywhere, a word as a whole word (or its plural).
    static func hit(_ text: String, _ terms: [String]) -> String? {
        let lower = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let words = Set(lower.split { !($0.isLetter || $0 == "-") }.map(String.init))
        return terms.first { term in
            term.contains(" ") || term.contains("-") ? lower.contains(term)
                : words.contains(term) || words.contains(term + "s") || words.contains(term + "es")
        }
    }

    @Test func hardLimitsHoldForEveryLine() {
        #expect(Self.everything.count > 350)
        #expect(Self.slurs.contains("cripple") && Self.rot13(Self.rot13("abc")) == "abc")
        for line in Self.everything {
            for (what, list) in [("slur", Self.slurs), ("protected group", Self.groups), ("sexual", Self.sexual),
                                 ("self-harm", Self.selfHarm), ("violence", Self.violence), ("real person", Self.people)] {
                let found = Self.hit(line, list)
                #expect(found == nil, "\(what) '\(found ?? "")' in: \(line)")
            }
        }
    }

    @Test func theBannedListsCatchWhatTheyShould() {
        #expect(Self.hit("Blame the women.", Self.groups) == "women")
        #expect(Self.hit("Transitory, like inflation.", Self.groups) == nil)       // whole words only
        #expect(Self.hit("Musk would approve.", Self.people) == "musk")
        #expect(Self.hit("Then kill yourself.", Self.selfHarm) == "kill yourself")
        #expect(Self.hit("Mercy-kill it.", Self.violence) == nil)       // a machine, not a person
        #expect(Self.hit("Bombs away.", Self.violence) == "bomb")
    }

    // MARK: Picking

    @Test func offSaysNothingAnywhere() throws {
        for spot in Self.spots { #expect(Voice.line(for: spot, personality: .off, now: noon, calendar: Self.utc) == nil) }
        let state = HomelabState(status: .warning,
                                 problems: [Problem(text: "media: disk 93% full", host: "media", severity: .warning)],
                                 hosts: [Host(id: "media", reachable: true, disks: ["/": 93])])
        #expect(Voice.aside(for: state.problems[0], in: state, personality: .off, now: noon) == nil)
        #expect(Voice.preview(for: state, personality: .off, now: noon).isEmpty)
        let report = ActionReport(ok: true, title: "Restarted sonarr", text: "ok")
        #expect(report.voiced(.off, now: noon) == report)
    }

    @Test func everySpotSpeaksAndIsFilled() throws {
        for p in Self.voiced {
            for spot in Self.spots {
                let line = try #require(Voice.line(for: spot, personality: p, now: noon, calendar: Self.utc), "\(p) \(spot)")
                #expect(!line.contains("{") && line.count <= spot.place.maxLength, "\(line)")
                #expect(Voice.lineCount(for: spot, personality: p) == VoiceLines.all(spot.place, p).count)
            }
        }
        // Without a count or a host, only the plain lines.
        for p in Self.voiced {
            let none = Voice.Spot.reason(.disk, host: nil)
            #expect(Voice.lineCount(for: none, personality: p) == VoiceLines.all(.reasonDisk, p).filter { !$0.contains("{") }.count)
            let zero = Voice.Spot.lab(.warnings(0))
            for v in 0..<5 { #expect(!(Voice.line(for: zero, personality: p, now: noon, variant: v) ?? "{").contains("{")) }
        }
    }

    @Test func sameLineAllDayVariantsCycleSeedsSpread() {
        let day = Date(timeIntervalSince1970: 1_793_923_200)
        let spot = Voice.Spot.lab(.problems(3))
        func text(_ d: Date, _ v: Int = 0, seed: String = "") -> String? {
            Voice.line(for: spot, personality: .ultrakill, now: d, calendar: Self.utc, variant: v, seed: seed)
        }
        #expect(text(day + 6 * 3600) == text(day + 23 * 3600 + 59 * 60))
        #expect(text(day + 30 * 3600) != text(day + 6 * 3600))
        let n = Voice.lineCount(for: spot, personality: .ultrakill)
        let variants = (0..<n).compactMap { text(day, $0) }
        #expect(Set(variants).count == n)
        #expect(text(day, n) == text(day, 0) && text(day, -1) == text(day, n - 1))
        #expect(Set((0..<n).compactMap { text(day + Double($0) * 86400) }) == Set(variants))
        // Different seeds (two problems, two actions) don't all say the same thing.
        let seeds = Set((0..<20).compactMap { text(day, seed: "problem-\($0)") })
        #expect(seeds.count > 1)
        #expect(variants.contains { $0.hasPrefix("3 problems.") })   // {count} filled
    }

    // MARK: Places

    @Test func labMoodReadsLikeTheHeader() {
        #expect(Voice.LabMood(nil) == nil)
        #expect(Voice.LabMood(HomelabState(status: .ok)) == .allGood)
        #expect(Voice.LabMood(HomelabState(status: .unknown)) == .unknown)
        let warn = HomelabState(status: .warning, problems: [Problem(text: "a", severity: .warning), Problem(text: "b", severity: .warning)])
        #expect(Voice.LabMood(warn) == .warnings(2))
        let bad = HomelabState(status: .problem, problems: [Problem(text: "a", severity: .warning), Problem(text: "b")])
        #expect(Voice.LabMood(bad) == .problems(1))
        #expect(Voice.LabMood(HomelabState(status: .problem)) == .problems(1))   // the server says problem, lists none
        #expect(Voice.Spot.lab(.warnings(2)).values["count"] == "2 warnings")
        #expect(Voice.Spot.lab(.problems(1)).values["count"] == "1 problem")
        #expect(Voice.Spot.lab(.warnings(0)).values.isEmpty)
    }

    @Test func emptyCardsByKind() {
        #expect(Voice.Empty(card: Card(id: "todos", style: .checklist)) == .todos)
        #expect(Voice.Empty(card: Card(id: "x", style: .countdown)) == .deadlines)
        #expect(Voice.Empty(card: Card(id: "parcels", title: "Parcels")) == .parcels)
        #expect(Voice.Empty(card: Card(id: "dhl", title: "Deliveries")) == .parcels)
        #expect(Voice.Empty(card: Card(id: "weather", title: "Weather")) == nil)
        #expect(Voice.Empty(card: Card(id: "u6", title: "U6", style: .metrics)) == nil)
    }

    @Test func asideFitsTheProblemAndNamesNoWrongHost() throws {
        let state = HomelabState(status: .problem, problems: [
            Problem(text: "media: disk /srv/media 93% full", host: "media", severity: .warning),
            Problem(text: "nas unreachable", host: "nas"),
            Problem(text: "12 updates, 3 security"),
        ], hosts: [
            Host(id: "media", name: "media-box", reachable: true, disks: ["/srv/media": 93]),
            Host(id: "nas", reachable: false),
        ])
        for p in Self.voiced {
            for v in 0..<6 {
                let disk = try #require(Voice.aside(for: state.problems[0], in: state, personality: p, now: noon,
                                                    calendar: Self.utc, variant: v))
                let options = VoiceLines.all(.reasonDisk, p).map { Voice.fill($0, ["host": "media-box"]) }
                #expect(options.contains(disk), "\(disk)")
                let down = try #require(Voice.aside(for: state.problems[1], in: state, personality: p, now: noon, variant: v))
                #expect(VoiceLines.all(.reasonDown, p).map { Voice.fill($0, ["host": "nas"]) }.contains(down), "\(down)")
                // No host: a plain line from the general set, no {host} left over.
                let other = try #require(Voice.aside(for: state.problems[2], in: state, personality: p, now: noon, variant: v))
                #expect(VoiceLines.all(.reasonOther, p).contains(other), "\(other)")
            }
            // Fixed for the day.
            #expect(Voice.aside(for: state.problems[0], in: state, personality: p, now: noon, calendar: Self.utc)
                    == Voice.aside(for: state.problems[0], in: state, personality: p, now: noon + 3600, calendar: Self.utc))
        }
    }

    @Test func actionReportGetsARemark() throws {
        let ok = ActionReport(ok: true, title: "Restarted sonarr", text: "sonarr is running.")
        for p in Self.voiced {
            let voiced = ok.voiced(p, now: noon, calendar: Self.utc)
            #expect(voiced.ok && voiced.title == ok.title)
            #expect(voiced.text.hasPrefix("sonarr is running.\n\nDone. "), "\(voiced.text)")
            let remark = String(voiced.text.dropFirst("sonarr is running.\n\n".count))
            #expect(VoiceLines.all(.done, p).contains(remark))
            let failed = ActionReport(ok: false, title: "Restart of sonarr failed", text: "").voiced(p, now: noon)
            #expect(VoiceLines.all(.failed, p).contains(failed.text), "\(failed.text)")   // no server text: the remark alone
        }
    }

    @Test func previewShowsTheOtherPlaces() {
        let state = HomelabState(status: .ok, hosts: [Host(id: "pi", reachable: true)])
        for p in Self.voiced {
            let lines = Voice.preview(for: state, personality: p, now: noon, calendar: Self.utc)
            #expect(lines.count == 3)
            #expect(lines[0].hasPrefix("In Lab: ") && lines[1].hasPrefix("After an action: Done. "))
            #expect(lines[2].hasPrefix("Nothing to do: "))
            #expect(Voice.preview(for: nil, personality: p, now: noon).count == 2)   // nothing loaded: no Lab line
            #expect(Voice.preview(for: state, personality: p, now: noon, calendar: Self.utc, variant: 1) != lines)
        }
    }
}
