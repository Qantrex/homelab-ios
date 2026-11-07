import Foundation
import Testing
@testable import HomelabKit

@Suite struct TodayLayoutTests {
    @Test func standardShowsEverything() {
        #expect(TodayLayout.standard.visible == TodaySection.allCases)
        #expect(AppSettings().todayLayout == .standard)
    }

    @Test func toleratesOldAndOddData() {
        let l = TodayLayout(order: ["report", "nonsense", "report", "home"], hidden: ["cards", "gone"])
        #expect(l.sections == [.report, .home, .day, .waiting, .deals, .cards, .machines])      // dupes and unknown dropped, new ones last
        #expect(l.visible == [.report, .home, .day, .waiting, .deals, .machines])
    }

    @Test func hideAndShow() {
        var l = TodayLayout.standard
        l.setVisible(.waiting, false)
        l.setVisible(.waiting, false)
        #expect(l.hidden == ["waiting"] && !l.isVisible(.waiting))
        l.setVisible(.waiting, true)
        #expect(l.visible == TodaySection.allCases)
    }

    @Test func moveLikeSwiftUI() {
        var l = TodayLayout.standard                                        // day waiting deals home cards report machines
        l.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)             // home to the top
        #expect(l.sections == [.home, .day, .waiting, .deals, .cards, .report, .machines])
        l.move(fromOffsets: IndexSet(integer: 0), toOffset: 7)             // and to the end
        #expect(l.sections == [.day, .waiting, .deals, .cards, .report, .machines, .home])
        l.move(fromOffsets: IndexSet([0, 1]), toOffset: 6)                 // two at once, before "home"
        #expect(l.sections == [.deals, .cards, .report, .machines, .day, .waiting, .home])
    }

    @Test func settingsRoundTripAndOldFiles() throws {
        var s = AppSettings()
        s.todayLayout.setVisible(.report, false)
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.todayLayout.visible == [.day, .waiting, .deals, .home, .cards, .machines])
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"notifyProblems":true,"notifyPending":false,"faceIDLock":false}"#.utf8))
        #expect(old.todayLayout == .standard && old.notifyProblems)
        s.todayLayout = .standard
        #expect(s.today == nil)                                            // back to standard stores nothing
    }
}

@Suite struct DensityTests {
    @Test func whatEachDensityShows() {
        var l = TodayLayout.standard
        l.setVisible(.report, false)
        #expect(Density.calm.sections(l) == [.day, .home])
        #expect(Density.standard.sections(l) == [.day, .waiting, .deals, .home, .cards])          // no machines, report hidden
        #expect(Density.overkill.sections(l) == [.day, .waiting, .deals, .home, .cards, .report, .machines])
        #expect(AppSettings().todayDensity == .standard)
    }

    @Test func densityIsStoredOnlyWhenNotStandard() throws {
        var s = AppSettings()
        s.todayDensity = .overkill
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.todayDensity == .overkill)
        s.todayDensity = .standard
        #expect(s.density == nil)
    }

    @Test func exactTimes() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_762_400_000)          // 2025-11-06 03:33:20 UTC
        #expect(Format.when(now.addingTimeInterval(-120), exact: true, now: now, calendar: cal) == "03:31:20 (2 min ago)")
        #expect(Format.when(now.addingTimeInterval(-86400), exact: true, now: now, calendar: cal) == "05.11. 03:33:20 (yesterday)")
        #expect(Format.when(now.addingTimeInterval(-120), exact: false, now: now) == "2 min ago")
        #expect(Format.when(nil, exact: true, now: now) == "never")
    }
}

@Suite struct DensityArgumentTests {
    @MainActor @Test func launchArgumentSetsDensity() {
        let (m, _, _, _) = makeModel(args: ["app", "-HomelabDemo", "YES", "-HomelabDensity", "Overkill"])
        #expect(m.settings.todayDensity == .overkill)
        let (n, _, _, _) = makeModel(args: ["app", "-HomelabDensity", "loud"])
        #expect(n.settings.todayDensity == .standard)                        // unknown value: ignored
    }
}
