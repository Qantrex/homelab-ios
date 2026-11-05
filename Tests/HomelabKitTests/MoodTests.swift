import Foundation
import Testing
@testable import HomelabKit

@Suite struct MoodTests {
    let up = Host(id: "a", reachable: true)
    let down = Host(id: "b", reachable: false)
    let asleep = Host(id: "pc", reachable: false, flags: ["asleep"])

    @Test func nothingLoaded() {
        let m = TodayMood(state: nil)
        #expect(m.level == .unknown && m.headline == "No signal." && m.detail == nil)
    }

    @Test func calmCountsMachinesButNotSleepingOnes() {
        let m = TodayMood(state: HomelabState(status: .ok, hosts: [up, up, asleep]))
        #expect(m.level == .calm && m.headline == "All quiet." && m.detail == "2 of 2 machines up")
        #expect(TodayMood(state: HomelabState(status: .ok)).detail == nil)   // no hosts: no machine line
    }

    @Test func problemsAreLoudAndWarningsCountedApart() {
        let s = HomelabState(status: .problem, problems: [Problem(text: "pi: under-voltage", severity: .warning),
                                                         Problem(text: "media: sonarr unhealthy")], hosts: [up, down])
        let m = TodayMood(state: s)
        #expect(m.level == .alarm && m.headline == "1 problem." && m.detail == "media: sonarr unhealthy" && m.warnings == 1)
        let two = HomelabState(status: .problem, problems: [Problem(text: "x"), Problem(text: "y")])
        #expect(TodayMood(state: two).headline == "2 problems.")
        // A problem status without a list still says something sensible.
        #expect(TodayMood(state: HomelabState(status: .problem, hosts: [up, down])).headline == "1 problem.")
    }

    @Test func warningsOnlyIsHeadsUp() {
        let s = HomelabState(status: .warning, problems: [Problem(text: "disk 91%", severity: .warning)])
        let m = TodayMood(state: s)
        #expect(m.level == .headsUp && m.headline == "Heads up." && m.detail == "disk 91%" && m.warnings == 1)
    }

    @Test func demoFixture() throws {
        let s = try #require(Fixtures.decode(HomelabState.self, "state-problem.json"))
        let m = TodayMood(state: s)
        #expect(m.level == .alarm && m.headline == "1 problem." && m.warnings == 1)
    }
}
