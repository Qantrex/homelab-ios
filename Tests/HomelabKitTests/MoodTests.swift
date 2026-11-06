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

    @Test func checkingWhileTheFirstFetchRuns() {
        let m = TodayMood(state: nil, checking: true)
        #expect(m.level == .unknown && m.headline == "Checking…" && m.detail == nil)
        // Once there is data, checking doesn't matter.
        #expect(TodayMood(state: HomelabState(status: .ok), checking: true).headline == "All quiet.")
    }

    @Test func tallyCountsProblemsAndWarningsApart() throws {
        let s = try #require(Fixtures.decode(HomelabState.self, "state-problem.json"))
        #expect(ProblemTally(s) == ProblemTally(problems: 1, warnings: 1))
        let warnings = HomelabState(status: .warning, problems: [Problem(text: "a", severity: .warning), Problem(text: "b", severity: .warning)])
        #expect(ProblemTally(warnings) == ProblemTally(problems: 0, warnings: 2))
        // A problem status always counts at least one problem.
        #expect(ProblemTally(HomelabState(status: .problem)) == ProblemTally(problems: 1, warnings: 0))
        #expect(ProblemTally(HomelabState(status: .problem, problems: [Problem(text: "a", severity: .warning)]))
                == ProblemTally(problems: 1, warnings: 1))
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

    @Test func liveHostFlagsAreWarningsEvenWhenTheServerSaysOk() {
        // Live 2026-11-06: pi-media throttled now, the server's status ok, Today said "All quiet.".
        let throttled = Host(id: "pi-media", name: "pi-media", reachable: true, flags: ["undervoltage_now", "throttled_now"])
        let sinceBoot = Host(id: "pi-two", name: "pi-two", reachable: true, flags: ["undervoltage_since_boot"])
        let s = HomelabState(status: .ok, hosts: [throttled, sinceBoot])
        #expect(s.hostAlerts == ["pi-media: under-voltage now, throttled now"])
        #expect(ProblemTally(s) == ProblemTally(problems: 0, warnings: 1))
        let m = TodayMood(state: s)
        #expect(m.level == .headsUp && m.headline == "Heads up." && m.detail == "pi-media: under-voltage now, throttled now")
        // Informational flags alone stay calm; a host the server already lists is not counted twice.
        #expect(TodayMood(state: HomelabState(status: .ok, hosts: [sinceBoot])).headline == "All quiet.")
        let listed = HomelabState(status: .warning, problems: [Problem(text: "pi-media: throttled", host: "pi-media", severity: .warning)],
                                  hosts: [throttled])
        #expect(ProblemTally(listed) == ProblemTally(problems: 0, warnings: 1))
    }

    @Test func demoFixture() throws {
        let s = try #require(Fixtures.decode(HomelabState.self, "state-problem.json"))
        let m = TodayMood(state: s)
        #expect(m.level == .alarm && m.headline == "1 problem." && m.warnings == 1)
    }
}
