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
        #expect(l.sections == [.report, .home, .day, .waiting, .cards])      // dupes and unknown dropped, new ones last
        #expect(l.visible == [.report, .home, .day, .waiting])
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
        var l = TodayLayout.standard                                        // day waiting home cards report
        l.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)             // home to the top
        #expect(l.sections == [.home, .day, .waiting, .cards, .report])
        l.move(fromOffsets: IndexSet(integer: 0), toOffset: 5)             // and to the end
        #expect(l.sections == [.day, .waiting, .cards, .report, .home])
        l.move(fromOffsets: IndexSet([0, 1]), toOffset: 4)                 // two at once, before "home"
        #expect(l.sections == [.cards, .report, .day, .waiting, .home])
    }

    @Test func settingsRoundTripAndOldFiles() throws {
        var s = AppSettings()
        s.todayLayout.setVisible(.report, false)
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.todayLayout.visible == [.day, .waiting, .home, .cards])
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"notifyProblems":true,"notifyPending":false,"faceIDLock":false}"#.utf8))
        #expect(old.todayLayout == .standard && old.notifyProblems)
        s.todayLayout = .standard
        #expect(s.today == nil)                                            // back to standard stores nothing
    }
}
