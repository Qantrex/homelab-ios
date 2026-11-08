import Foundation
import Testing
@testable import HomelabKit

/// Owner review of build 7, 2026-11-08, rows 25, 26, 29, 38, 41, 42: remarks rotate inside a list, a scene says when it
/// ran, the detail levels have their new names, a switched-off section stays off, Minimal makes Lab compact, Standard
/// is the default.
@Suite struct Round2ReviewTests {
    static let now = Date(timeIntervalSince1970: 1_794_132_000)   // Sunday 2026-11-08, 10:00 UTC
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    static let voiced: [Personality] = [.dry, .snarky, .ultrakill]

    // MARK: Remarks (rows 25, 26)

    /// Every kind filled the way a list of `n` rows would be, one fact per row.
    static func facts(_ kind: Hyper.Kind, _ n: Int) -> [Hyper.Fact] {
        (0..<n).map { i in
            var values: [String: String] = [:]
            for key in kind.placeholders { values[key] = "\(key) \(i)" }
            values["pct"] = "9\(i % 10)%"
            return Hyper.Fact(kind, values, seed: "row \(i)")
        }
    }

    @Test func noRemarkRepeatsNextToItselfInAnyList() {
        for p in Self.voiced {
            for kind in Hyper.Kind.allCases {
                let ledger = Hyper.Ledger()
                let remarks = Self.facts(kind, 40).compactMap { Hyper.remark($0, p, now: Self.now, calendar: Self.utc, ledger: ledger) }
                #expect(remarks.count == 40)
                for pair in zip(remarks, remarks.dropFirst()) {
                    // Facts differ in their numbers, so compare the line, not the filled text: strip the digits.
                    #expect(Self.shape(pair.0) != Self.shape(pair.1), "\(p) \(kind): \(pair.0) / \(pair.1)")
                }
            }
        }
    }

    @Test func aListNoLongerThanTheLinesOfItsKindHasNoDuplicate() {
        for p in Self.voiced {
            for kind in Hyper.Kind.allCases {
                let n = Hyper.eligible(Self.facts(kind, 1)[0], p).count
                #expect(n >= 5, "\(p) \(kind) has only \(n) lines")
                let ledger = Hyper.Ledger()
                let remarks = Self.facts(kind, n).compactMap { Hyper.remark($0, p, now: Self.now, calendar: Self.utc, ledger: ledger) }
                #expect(Set(remarks.map(Self.shape)).count == n, "\(p) \(kind): \(remarks)")
            }
        }
    }

    @Test func sevenDeparturesNeverShareALine() {
        let card = Card(id: "departures", title: "U6", style: .departures, items: (0..<7).map {
            .init(title: ["Siebenhirten", "Floridsdorf", "Siebenhirten", "Floridsdorf", "Siebenhirten", "Floridsdorf", "Siebenhirten"][$0],
                  value: "21:\(10 + $0 * 4)")
        })
        for p in Self.voiced {
            let ledger = Hyper.Ledger()
            let remarks = card.items.compactMap {
                Hyper.remark(Hyper.fact(item: $0, in: card, now: Self.now, calendar: Self.utc), p, now: Self.now, calendar: Self.utc, ledger: ledger)
            }
            #expect(remarks.count == 7 && Set(remarks.map(Self.shape)).count == 7, "\(p): \(remarks)")
        }
    }

    @Test func aFactKeepsItsRemarkForTheDayWhateverIsAskedBetween() {
        let ledger = Hyper.Ledger()
        let all = Self.facts(.row, 12)
        let first = all.map { Hyper.remark($0, .snarky, now: Self.now, calendar: Self.utc, ledger: ledger) }
        let again = all.reversed().map { Hyper.remark($0, .snarky, now: Self.now, calendar: Self.utc, ledger: ledger) }
        #expect(first == again.reversed())
        // A poke (variant) moves on from there.
        #expect(Hyper.remark(all[0], .snarky, now: Self.now, calendar: Self.utc, variant: 1, ledger: ledger) != first[0])
    }

    /// The line behind a filled remark: digits are what tell facts apart in these fixtures.
    static func shape(_ text: String) -> String { text.filter { !$0.isNumber } }

    @Test func aSceneSaysWhenItRanAndKeepsItsWholeName() {
        let ran = Self.now.addingTimeInterval(-3 * 3600)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let scene = HAEntity(entityID: "scene.wohnzimmer_entspannung", state: f.string(from: ran), name: "Wohnzimmer Entspannung")
        let fact = Hyper.fact(entity: scene, now: Self.now)
        #expect(fact.kind == .homeScene && fact.values["when"] == "3 h ago" && fact.values["name"] == "Wohnzimmer Entspannung")
        for p in Self.voiced {
            let text = Hyper.remark(fact, p, now: Self.now, calendar: Self.utc, ledger: Hyper.Ledger()) ?? ""
            #expect(text.contains("3 h ago") && text.contains("Wohnzimmer Entspannung"), "\(p): \(text)")
            #expect(!text.contains("2026") && !text.contains("T0") && !text.contains("…"), "\(text)")
        }
        // A plain sensor is still a tile.
        #expect(Hyper.fact(entity: HAEntity(entityID: "light.x", state: "on", name: "Lamp"), now: Self.now).kind == .homeTile)
        #expect(Hyper.timestamp("2026-11-08T09:03:11+00:00") != nil && Hyper.timestamp("21.4") == nil && Hyper.timestamp("unavailable") == nil)
    }

    @Test func noRemarkEverShowsARawTimestamp() {
        let raw = try! NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}"#)
        let stamped = HAEntity(entityID: "button.doorbell", state: "2026-11-08T09:03:11.482+00:00", name: "Doorbell")
        let facts = [Hyper.fact(entity: stamped, now: Self.now)] + Hyper.Kind.allCases.flatMap { Self.facts($0, 10) }
        for p in Self.voiced {
            let ledger = Hyper.Ledger()
            for fact in facts {
                let text = Hyper.remark(fact, p, now: Self.now, calendar: Self.utc, ledger: ledger) ?? ""
                #expect(raw.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil, "\(text)")
            }
        }
    }

    @Test func theDemoHomeTilesAndCardsNeverRepeatNeighbours() async throws {
        let demo = DemoBackend(delay: .zero, now: Self.now)
        let entities = try await demo.states()
        let state = try await demo.state()
        for p in Self.voiced {
            let ledger = Hyper.Ledger()
            let tiles = entities.compactMap { Hyper.remark(Hyper.fact(entity: $0, now: Self.now), p, now: Self.now, calendar: Self.utc, ledger: ledger) }
            for pair in zip(tiles, tiles.dropFirst()) { #expect(pair.0 != pair.1, "\(p): \(pair.0)") }
            for card in state.cards {
                let remarks = card.items.compactMap {
                    Hyper.remark(Hyper.fact(item: $0, in: card, now: Self.now, calendar: Self.utc), p, now: Self.now, calendar: Self.utc, ledger: ledger)
                }
                for pair in zip(remarks, remarks.dropFirst()) { #expect(pair.0 != pair.1, "\(p) \(card.id): \(pair.0)") }
            }
        }
    }

    // MARK: Names (row 29)

    @Test func detailLevelsHaveTheirNewNamesAndKeepTheirStoredWords() throws {
        #expect(Density.allCases.map(\.title) == ["Minimal", "Standard", "Detailed", "Hyperdetail"])
        #expect(Density.allCases.map(\.rawValue) == ["calm", "standard", "overkill", "hyperdetail"])
        for (word, level) in [("calm", Density.calm), ("minimal", .calm), ("Minimal", .calm), ("overkill", .overkill), ("Detailed", .overkill),
                              (" standard ", .standard), ("HYPERDETAIL", .hyperdetail)] {
            #expect(Density.parse(word) == level, "\(word)")
        }
        #expect(Density.parse("ultrakill") == nil && Density.parse("") == nil)
        for word in ["minimal", "detailed"] {
            let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"density":"\#(word)"}"#.utf8))
            #expect(s.todayDensity == (word == "minimal" ? .calm : .overkill))
        }
        // Stored as ever.
        var s = AppSettings()
        s.todayDensity = .overkill
        #expect(String(decoding: try JSONEncoder().encode(s), as: UTF8.self).contains(#""density":"overkill""#))
        // Nothing user-facing says the old words.
        let shown = Density.explanation + Density.allCases.map(\.title).joined() + StartPreset.allCases.map(\.summary).joined()
        #expect(!shown.contains("Overkill") && !shown.contains("Calm"))
        let argument = LaunchArguments(["app", "-HomelabDensity", "Detailed"])
        #expect(argument.density == .overkill)
        #expect(LaunchArguments(["app", "-HomelabDensity", "calm"]).density == .calm)
    }

    // MARK: Switched off stays off (row 38)

    @Test func aSwitchedOffSectionStaysOffAtEveryLevel() {
        var layout = TodayLayout.standard
        layout.setVisible(.deals, false)
        layout.setVisible(.cards, false)
        for d in Density.allCases {
            let shown = d.sections(layout)
            #expect(!shown.contains(.deals) && !shown.contains(.cards), "\(d)")
            let context = ShowContext(now: Self.now, calendar: Self.utc, needsMe: [])
            #expect(d.sections(layout, context).allSatisfy { shown.contains($0) }, "\(d) with rules")
        }
        #expect(Density.overkill.sections(layout) == Density.standard.sections(layout))
        #expect(Density.hyperdetail.sections(layout) == [.day, .waiting, .home, .report])
    }

    // MARK: Lab in Minimal (row 41)

    @Test func onlyMinimalMakesLabCompact() {
        #expect(Density.allCases.filter(LabCompact.applies) == [.calm])
    }

    @Test func compactHostLinesSayWhyOrUp() {
        func host(_ patch: (inout HomelabKit.Host) -> Void) -> HomelabKit.Host { var h = HomelabKit.Host(id: "a", name: "a", reachable: true); patch(&h); return h }
        #expect(LabCompact.hostNote(host { _ in }) == "up")
        #expect(LabCompact.hostNote(host { $0.reachable = false }) == "down")
        #expect(LabCompact.hostNote(host { $0.reachable = nil }) == "unknown")
        #expect(LabCompact.hostNote(host { $0.flags = ["asleep"] }) == "asleep")
        #expect(LabCompact.hostNote(host { $0.disks = ["/": 93] }) == "disk 93%")
        #expect(LabCompact.hostNote(host { $0.temp = 78 }) == "78°C")
        #expect(LabCompact.hostNote(host { $0.load = 5; $0.cpuCount = 4 }) == "busy")
        #expect(LabCompact.hostNote(host { $0.flags = ["undervoltage"] }) != "up")
    }

    @Test func foldedCardsAreATitleAndACount() {
        let rows = Card(id: "backups", title: "Backups", style: .list, items: [.init(title: "a"), .init(title: "b"), .init(title: "c")])
        #expect(LabCompact.cardFold(rows) == (title: "Backups", count: "3"))
        #expect(LabCompact.cardFold(Card(id: "tailnet", style: .text)) == (title: "tailnet", count: nil))
        #expect(LabCompact.servicesFold(6) == (title: "Services", count: "6"))
        #expect(LabCompact.servicesFold(0).count == nil)
    }

    // MARK: Standard is the default (row 42)

    @Test func standardIsTheDefaultForANewUserAndEveryPreset() {
        #expect(AppSettings().todayDensity == .standard && AppSettings().density == nil)
        for preset in StartPreset.allCases {
            #expect(preset.density == .standard, "\(preset)")
            for (features, hasHA) in [(Set<ServerInfo.Feature>(), true), (Set<ServerInfo.Feature>(), false), (Set(ServerInfo.Feature.allCases), true)] {
                var s = AppSettings()
                preset.layout(features: features, hasHA: hasHA).apply(to: &s)
                #expect(s.todayDensity == .standard && s.density == nil, "\(preset)")
            }
        }
    }
}
