import Foundation
import Testing
@testable import HomelabKit

@Suite struct VoiceTests {
    static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
    let day = Date(timeIntervalSince1970: 1_793_923_200)   // 2026-11-06 00:00 UTC

    @Test func offSaysNothing() {
        for m in Voice.Moment.allCases {
            #expect(Voice.line(m, .off, on: day, calendar: Self.utc) == nil)
            #expect(Voice.lines(m, .off).isEmpty)
        }
    }

    @Test func dryAndSnarkyHaveALineForEveryMoment() {
        for p in [Personality.dry, .snarky] {
            for m in Voice.Moment.allCases {
                let lines = Voice.lines(m, p)
                #expect(!lines.isEmpty, "\(p) \(m)")
                #expect(Set(lines).count == lines.count, "duplicate in \(p) \(m)")
                // One line on a small phone, a full sentence.
                for l in lines { #expect(l.count <= 48 && (l.hasSuffix(".") || l.hasSuffix("?")), "\(l)") }
                #expect(lines.contains(Voice.line(m, p, on: day, calendar: Self.utc)!))
            }
        }
        // The two personalities don't share lines.
        let dry = Set(Voice.Moment.allCases.flatMap { Voice.lines($0, .dry) })
        #expect(dry.isDisjoint(with: Voice.Moment.allCases.flatMap { Voice.lines($0, .snarky) }))
    }

    @Test func sameLineAllDayNextDayAnother() {
        let morning = Voice.line(.calm, .snarky, on: day.addingTimeInterval(6 * 3600), calendar: Self.utc)
        let night = Voice.line(.calm, .snarky, on: day.addingTimeInterval(23 * 3600 + 59 * 60), calendar: Self.utc)
        let tomorrow = Voice.line(.calm, .snarky, on: day.addingTimeInterval(30 * 3600), calendar: Self.utc)
        #expect(morning == night && morning != tomorrow)
        // Over a few days every calm line comes up.
        let week = Set((0..<7).compactMap { Voice.line(.calm, .dry, on: day.addingTimeInterval(Double($0) * 86400), calendar: Self.utc) })
        #expect(week == Set(Voice.lines(.calm, .dry)))
    }

    @Test func moodLevelsMapToMoments() {
        #expect(Voice.moment(.calm) == .calm && Voice.moment(.headsUp) == .headsUp)
        #expect(Voice.moment(.alarm) == .alarm && Voice.moment(.unknown) == .unknown)
    }

    @Test func settingIsOffByDefaultAndStoredOnlyWhenOn() throws {
        var s = AppSettings()
        #expect(s.voice == .off && s.personality == nil)
        s.voice = .snarky
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.voice == .snarky)
        s.voice = .off
        #expect(s.personality == nil)
        // Settings from before the setting existed.
        let file = #"{"notifyProblems": true, "notifyPending": false, "faceIDLock": false, "density": "overkill"}"#
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(file.utf8))
        #expect(old.voice == .off && old.notifyProblems)
    }

    @MainActor @Test func launchArgumentSetsPersonality() {
        let (m, _, _, _) = makeModel(args: ["app", "-HomelabDemo", "YES", "-HomelabPersonality", "Snarky"])
        #expect(m.settings.voice == .snarky)
        let (n, _, _, _) = makeModel(args: ["app", "-HomelabPersonality", "rude"])
        #expect(n.settings.voice == .off)                                     // unknown value: ignored
    }

    @Test func alertsCarryTheirMoment() {
        let now = Date(timeIntervalSince1970: 1_762_291_800)
        var t = AlertTracker()
        _ = t.update(with: HomelabState(status: .ok), server: "lab", now: now)
        let state = HomelabState(status: .problem,
                                 problems: [Problem(text: "disk 91%", severity: .warning), Problem(text: "sonarr down")],
                                 pending: [PendingAction(id: "p1", action: "restart", arg: "sonarr")])
        let alerts = t.update(with: state, server: "lab", now: now + 60)
        #expect(alerts.map(\.moment) == [.headsUp, .alarm, .waiting])
        // The summary line has none.
        var u = AlertTracker()
        _ = u.update(with: HomelabState(status: .ok), server: "lab", now: now)
        let many = HomelabState(status: .problem, problems: (1...5).map { Problem(text: "p\($0)") })
        #expect(u.update(with: many, server: "lab", now: now + 60).last?.moment == nil)
    }
}
