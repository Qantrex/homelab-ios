import Foundation
import Testing
@testable import HomelabKit

/// Step 4: a host's 24 h history (sparklines) and its containers (with restart from Lab).
@Suite struct HostHistoryTests {
    func host(_ json: String) throws -> HomelabKit.Host { try decode(HomelabKit.Host.self, json) }
    func problemState() throws -> HomelabState { try fixture(HomelabState.self, "state-problem.json") }
    func specs() throws -> [ActionSpec] { try fixture(ActionList.self, "actions.json").actions }
    func spec(_ name: String) throws -> ActionSpec { try #require(try specs().first { $0.name == name }) }

    // MARK: Fixtures

    @Test func problemFixtureHasHistoryAndContainers() throws {
        let s = try problemState()
        for id in ["server", "media", "pi"] {
            let h = try #require(s.hosts.first { $0.id == id })
            let hist = try #require(h.history, "\(id)")
            #expect(hist.step == 300)
            #expect(hist.end == ServerDate.parse("2026-11-04T21:25:00"))
            for series in HostHistory.Series.allCases { #expect(hist[series].count == 288, "\(id) \(series)") }
            // The last point is the value the host shows now.
            #expect(hist.last(.load) == h.load && hist.last(.temp) == h.temp)
            #expect(hist.last(.memPct) == h.memPct.map(Double.init))
            #expect(hist.last(.diskPct) == Format.worstDisk(h.disks).map { Double($0.percent) })
            // The list agrees with the counts.
            #expect(h.containerList.count == h.containersTotal)
            #expect(h.containerList.filter { $0.state == .running }.count == h.containersUp)
        }
        let gpu = try #require(s.hosts.first { $0.id == "gpu" })
        #expect(gpu.history == nil && gpu.containerList.isEmpty)

        let media = try #require(s.hosts.first { $0.id == "media" })
        let problems = media.containerList.filter(\.isProblem)
        #expect(problems.map(\.name).sorted() == ["gluetun", "sonarr"])
        #expect(media.containerList.first { $0.name == "sonarr" }?.health == .unhealthy)
        #expect(media.containerList.first { $0.name == "gluetun" }?.state == .exited)
        #expect(ContainerInfo.ordered(media.containerList).prefix(2).map(\.name) == ["gluetun", "sonarr"])
        // 25 minutes without data three hours ago.
        #expect(media.history?[.load].filter { $0 == nil }.count == 5)
        #expect(media.history?.points(.load).count == 283)
    }

    @Test func hugeFixtureHasHistoryEverywhere() throws {
        let s = try fixture(HomelabState.self, "state-huge.json")
        for h in s.hosts {
            let hist = try #require(h.history, "\(h.id)")
            #expect(hist[.load].count == 288)
            #expect(h.containerList.count == 20)
            #expect(h.containerList.filter { $0.state == .running }.count == h.containersUp, "\(h.id)")
            if h.reachable == false {
                // Unreachable for the last hour: the newest slots are gaps, "now" is the last value there is.
                #expect(hist[.load].suffix(12).allSatisfy { $0 == nil })
                #expect(hist.last(.load) != nil)
            }
        }
        #expect(s.hosts.contains { $0.containerList.contains { $0.health == .unhealthy } })
        #expect(s.hosts.contains { $0.containerList.contains { $0.state == .dead } })
    }

    @Test func roundTripsThroughTheCache() throws {
        for name in ["state-problem.json", "state-huge.json"] {
            let s = try fixture(HomelabState.self, name)
            let again = try JSONDecoder().decode(HomelabState.self, from: JSONEncoder().encode(s))
            #expect(again == s, "\(name)")
            #expect(again.hosts.contains { $0.history != nil && !$0.containerList.isEmpty })
        }
        let plain = HomelabKit.Host(id: "nas")
        let data = try JSONEncoder().encode(plain)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("history") && !text.contains("container_list"))
        #expect(try JSONDecoder().decode(HomelabKit.Host.self, from: data) == plain)
    }

    // MARK: Tolerant decoding

    @Test func oddHistoryIsReadLeniently() throws {
        let h = try host("""
        {"id": "nas", "checked": "2026-11-04T21:28:00",
         "history": {"step": "60", "load": [0.5, "0.7", null, "x", true, {"a": 1}, -2, 1.25],
                     "mem_pct": [150, -5, 50], "temp": "hot", "disk_pct": 80}}
        """)
        let hist = try #require(h.history)
        #expect(hist.step == 60)
        #expect(hist.end == ServerDate.parse("2026-11-04T21:28:00"))   // no end: when the host was checked
        #expect(hist[.load] == [0.5, 0.7, nil, nil, nil, nil, 0, 1.25])
        #expect(hist[.memPct] == [100, 0, 50])
        #expect(hist[.temp].isEmpty && hist[.diskPct].isEmpty)
        #expect(hist.min(.load) == 0 && hist.max(.load) == 1.25 && hist.last(.load) == 1.25)
        #expect(hist.min(.temp) == nil && hist.last(.temp) == nil)
    }

    @Test func historyEdgeCases() throws {
        let long = (0..<300).map { String($0) }.joined(separator: ", ")
        let capped = try host(#"{"id": "a", "history": {"step": 0, "end": "2026-11-04T21:25:00", "load": [\#(long)]}}"#)
        let hist = try #require(capped.history)
        #expect(hist.step == 300)
        #expect(hist[.load].count == 288 && hist[.load].first == 12 && hist[.load].last == 299)   // newest kept
        #expect(try host(#"{"id": "a", "history": {"load": [null, null], "temp": []}}"#).history == nil)
        #expect(try host(#"{"id": "a", "history": [1, 2, 3]}"#).history == nil)
        #expect(try host(#"{"id": "a", "history": "none"}"#).history == nil)
        // Neither an end nor a check time: values, but no times.
        let undated = try #require(try host(#"{"id": "a", "history": {"load": [1, 2]}}"#).history)
        #expect(undated.end == nil && undated.points(.load).isEmpty && undated.last(.load) == 2)
    }

    @Test func pointsHaveTheirTimes() throws {
        let end = try #require(ServerDate.parse("2026-11-04T21:25:00"))
        let hist = HostHistory(step: 300, end: end, load: [1, nil, 3], temp: [40])
        let p = hist.points(.load)
        #expect(p.map(\.value) == [1, 3])
        #expect(p.map(\.date) == [end.addingTimeInterval(-600), end])
        #expect(hist.points(.temp).map(\.date) == [end])   // a shorter series also ends at `end`
        #expect(hist.points(.memPct).isEmpty)
    }

    @Test func oddContainersAreReadLeniently() throws {
        let h = try host("""
        {"id": "media", "container_list": [
          {"name": "sonarr", "state": "running", "health": "unhealthy", "restarts": 2, "restartable": true},
          {"name": "radarr", "state": "Up 3 hours", "health": "none", "restarts": "-1", "restartable": "yes"},
          {"name": "gluetun", "state": "Exited (1) 2 hours ago", "restarts": "3"},
          {"name": "odd", "state": "Migrating", "health": "STARTING"},
          {"name": "sonarr", "state": "exited"},
          {"state": "running"}, "nope", 42]}
        """)
        #expect(h.containerList.map(\.name) == ["sonarr", "radarr", "gluetun", "odd"])
        let c = Dictionary(uniqueKeysWithValues: h.containerList.map { ($0.name, $0) })
        #expect(c["sonarr"]?.health == .unhealthy && c["sonarr"]?.restartable == true && c["sonarr"]?.isProblem == true)
        #expect(c["radarr"]?.state == .running && c["radarr"]?.health == nil && c["radarr"]?.restarts == 0)
        #expect(c["radarr"]?.restartable == true && c["radarr"]?.isProblem == false)
        #expect(c["gluetun"]?.state == .exited && c["gluetun"]?.restarts == 3 && c["gluetun"]?.restartable == false)
        #expect(c["odd"]?.state == .unknown && c["odd"]?.health == .starting && c["odd"]?.isProblem == false)
        #expect(try host(#"{"id": "a", "container_list": {"name": "x"}}"#).containerList.isEmpty)
    }

    @Test func containerProblemsComeFirst() {
        let list = [ContainerInfo(name: "b"), ContainerInfo(name: "loop", state: .restarting),
                    ContainerInfo(name: "A"), ContainerInfo(name: "sick", health: .unhealthy),
                    ContainerInfo(name: "dead", state: .dead), ContainerInfo(name: "paused", state: .paused),
                    ContainerInfo(name: "new", state: .created), ContainerInfo(name: "warm", health: .starting)]
        #expect(ContainerInfo.ordered(list).map(\.name) == ["dead", "sick", "loop", "A", "b", "new", "paused", "warm"])
        #expect(ContainerInfo(name: "x", state: .restarting).severity == .warning)
        #expect(ContainerInfo(name: "x", state: .restarting, health: .unhealthy).severity == .problem)
        #expect(ContainerInfo(name: "x", state: .exited).severity == .problem)
        #expect(ContainerInfo(name: "x", state: .paused).severity == nil)
    }

    // MARK: Sparklines

    @Test func sparklineShape() {
        let s = SparklineShape([0, 5, nil, 10, nil], range: 0...10)
        #expect(s.runs == [[.init(x: 0, y: 0), .init(x: 0.25, y: 0.5)], [.init(x: 0.75, y: 1)]])
        #expect(s.last == .init(x: 0.75, y: 1))
        #expect(s.min == 0 && s.max == 10 && s.lastValue == 10)

        let auto = SparklineShape([2, 4])               // no range: smallest to largest
        #expect(auto.runs == [[.init(x: 0, y: 0), .init(x: 1, y: 1)]])
        let flat = SparklineShape([3, 3, 3])            // a flat line sits in the middle
        #expect(flat.runs.first?.allSatisfy { $0.y == 0.5 } == true)
        let clipped = SparklineShape([-5, 50], range: 0...10)
        #expect(clipped.runs.first?.map(\.y) == [0, 1])
        let one = SparklineShape([7])
        #expect(one.last == .init(x: 1, y: 0.5))
        #expect(SparklineShape([]).isEmpty && SparklineShape([nil, nil]).isEmpty)
        #expect(SparklineShape([nil, nil]).last == nil && SparklineShape([nil]).lastValue == nil)
    }

    @Test func seriesScalesAndLimits() {
        #expect(HostHistory.Series.memPct.range([40, 42]) == 0...100)
        #expect(HostHistory.Series.load.range([0.1, 0.3]) == 0...1)          // a quiet host stays low
        #expect(HostHistory.Series.load.range([0.5, 3.2, nil]) == 0...3.2)
        #expect(HostHistory.Series.temp.range([48, 50]) == 44...54)          // at least 10 °C
        #expect(HostHistory.Series.temp.range([40, 70]) == 40...70)
        let limits = [HostHistory.Series.load.limits(cores: 4), HostHistory.Series.load.limits(cores: nil),
                      HostHistory.Series.temp.limits(cores: 4), HostHistory.Series.diskPct.limits(cores: 4)]
        #expect(limits.map(\.warning) == [4, 1, 80, 75])
        #expect(limits.map(\.problem) == [8, 2, 90, 90])
        #expect(HostHistory.Series.load.format(1.849) == "1.85")
        #expect(HostHistory.Series.memPct.format(70.6) == "71%")
        #expect(HostHistory.Series.temp.format(63.2) == "63\u{202F}°C")
    }

    // MARK: Restart from Lab

    @Test func formsCanBeFilledFromAnArgument() throws {
        let restart = try #require(ActionForm.prefilled(try spec("restart-container"), arg: "media:sonarr"))
        #expect(restart.values[0] == ["media", "", "sonarr"] && restart.arg == "media:sonarr" && restart.isReady)
        #expect(ActionForm.prefilled(try spec("restart-container"), arg: "gpu:steam") == nil)        // host not offered
        #expect(ActionForm.prefilled(try spec("restart-container"), arg: "media:a b") == nil)        // not a word
        #expect(ActionForm.prefilled(try spec("restart-container"), arg: "media:") == nil)
        #expect(ActionForm.prefilled(try spec("restart-container"), arg: "") == nil)
        let off = try #require(ActionForm.prefilled(try spec("wake-set"), arg: "2026-11-07:off"))
        #expect(off.variant == 1 && off.arg == "2026-11-07:off")
        let wake = try #require(ActionForm.prefilled(try spec("wake-set"), arg: "2026-11-07T07:30"))
        #expect(wake.variant == 0 && wake.value(part: 2) == "07:30")
        #expect(ActionForm.prefilled(try spec("commute-mode"), arg: "2026-11-07:u6")?.arg == "2026-11-07:u6")
        #expect(ActionForm.prefilled(try spec("commute-mode"), arg: "2026-11-07:car") == nil)
        #expect(ActionForm.prefilled(try spec("todo-add"), arg: "x") == nil)                          // takes no argument
    }

    @Test func restartOnlyWhenTheServerOffersIt() throws {
        let s = try problemState()
        let media = try #require(s.hosts.first { $0.id == "media" })
        let sonarr = try #require(media.containerList.first { $0.name == "sonarr" })
        let jellyfin = try #require(media.containerList.first { $0.name == "jellyfin" })
        var status = ServerStatus(snapshot: nil)
        status.info = ServerInfo(features: [.status, .hosts, .runActions])
        status.actions = try specs()
        let form = try #require(status.restartForm(host: media, container: sonarr))
        #expect(form.spec.name == "restart-container" && form.arg == "media:sonarr")
        #expect(status.restartForm(host: media, container: jellyfin) != nil)

        var notListed = sonarr
        notListed.restartable = false
        #expect(status.restartForm(host: media, container: notListed) == nil)
        #expect(status.restartForm(host: HomelabKit.Host(id: "gpu"), container: sonarr) == nil)   // the form can't name the host
        var noFeature = status
        noFeature.info = ServerInfo(features: [.status, .hosts, .actions])
        #expect(noFeature.restartForm(host: media, container: sonarr) == nil)
        var noAction = status
        noAction.actions = try specs().filter { $0.name != "restart-container" }
        #expect(noAction.restartForm(host: media, container: sonarr) == nil)
    }

    @MainActor @Test func hostLinksAndLaunchArgument() throws {
        let (m, _, _, _) = makeModel(args: ["app", "-HomelabDemo", "YES", "-HomelabHost", "media"])
        #expect(m.tab == .lab && m.openHost == "media")
        let (bad, _, _, _) = makeModel(args: ["app", "-HomelabDemo", "YES", "-HomelabHost", "../state"])
        #expect(bad.openHost == nil && bad.tab == .today)
        m.openHost = nil
        m.tab = .today
        m.open(URL(string: "homelab://lab/pi")!)
        #expect(m.tab == .lab && m.openHost == "pi")
        m.openHost = nil
        m.open(URL(string: "homelab://lab/a%20b")!)
        #expect(m.tab == .lab && m.openHost == nil)
        m.open(URL(string: "homelab://lab")!)
        #expect(m.openHost == nil)
    }

    @Test func demoHistoryEndsNowAndRestartsWork() async throws {
        let now = Date()
        let demo = DemoBackend(delay: .zero, now: now)
        let before = try await demo.state()
        let media = try #require(before.hosts.first { $0.id == "media" })
        #expect(media.history?.end == now)
        #expect(media.containerList.first { $0.name == "gluetun" }?.state == .exited)
        let r = try await demo.run("restart-container", arg: "media:gluetun", payload: [:])
        #expect(r.ok)
        let after = try #require(try await demo.state().hosts.first { $0.id == "media" })
        let gluetun = try #require(after.containerList.first { $0.name == "gluetun" })
        #expect(gluetun.state == .running && gluetun.restarts == 4)
        #expect(after.containersUp == (media.containersUp ?? 0) + 1)
        _ = try await demo.run("restart-container", arg: "media:sonarr", payload: [:])
        let sonarr = try #require(try await demo.state().hosts.first { $0.id == "media" }?.containerList.first { $0.name == "sonarr" })
        #expect(sonarr.health == .healthy && sonarr.state == .running)
    }

    // MARK: Review fixes

    @Test func sparklineXFollowsTime() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // 12 points (one hour at 5 min) sit in the right 1/24 of a 24 h line, the newest at the right edge.
        let hour = HostHistory(step: 300, end: now, load: Array(repeating: 1.0, count: 12))
        #expect(hour.windowSlots == 288)
        let shape = hour.shape(.load, now: now)
        let xs = try #require(shape.runs.first).map(\.x)
        #expect(xs.count == 12 && xs.allSatisfy { $0 >= 23.0 / 24 } && xs.last == 1)
        // Two series of different length end at the same x.
        let mixed = HostHistory(step: 300, end: now.addingTimeInterval(-600), load: [1, 2, 3], memPct: Array(repeating: 50, count: 100))
        let a = try #require(mixed.shape(.load, now: now).last), b = try #require(mixed.shape(.memPct, now: now).last)
        #expect(abs(a.x - b.x) < 1e-9 && abs(a.x - (1 - 2.0 / 287)) < 1e-9)
        // A full day that ended an hour ago: its first hour falls off the left edge.
        let full = HostHistory(step: 300, end: now.addingTimeInterval(-3600), load: Array(repeating: 1.0, count: 288))
        let fullShape = full.shape(.load, now: now)
        #expect(fullShape.runs.flatMap { $0 }.count == 276 && fullShape.runs.flatMap { $0 }.allSatisfy { $0.x >= 0 })
        // A longer step spans fewer slots; an end in the future counts as now.
        #expect(HostHistory(step: 3600).windowSlots == 24)
        #expect(HostHistory(step: 300, end: now.addingTimeInterval(60)).slotsBehind(now: now) == 0)
        // Without slots the index layout stays.
        #expect(SparklineShape([0, 5, 10], range: 0...10).runs == [[.init(x: 0, y: 0), .init(x: 0.5, y: 0.5), .init(x: 1, y: 1)]])
    }

    @Test func oldHistoryHasNoCurrentValue() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = HostHistory(step: 300, end: now.addingTimeInterval(-240), load: [1, 9])
        #expect(fresh.recentLast(.load, now: now) == 9)
        let old = HostHistory(step: 300, end: now.addingTimeInterval(-3 * 3600), load: [1, 9])
        #expect(old.recentLast(.load, now: now) == nil && old.last(.load) == 9)
        // The last value counts from its own time: a trailing gap makes it older.
        let gap = HostHistory(step: 300, end: now, load: [9] + Array(repeating: nil, count: 4))
        #expect(gap.recentLast(.load, now: now) == nil)
        #expect(HostHistory(step: 300, load: [1]).recentLast(.load, now: now) == nil)   // no end, no time
    }

    @Test func removingIsNoProblem() throws {
        let c = try decode(ContainerInfo.self, #"{"name": "old", "state": "removing"}"#)
        #expect(c.state == .removing && !c.isProblem && c.severity == nil)
    }

    @Test func restartWaitsForTheNextCheck() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AppModel.waitsForCheck(restarted: t, checked: t.addingTimeInterval(-60), now: t.addingTimeInterval(120)))
        #expect(AppModel.waitsForCheck(restarted: t, checked: nil, now: t.addingTimeInterval(120)))
        #expect(!AppModel.waitsForCheck(restarted: t, checked: t.addingTimeInterval(30), now: t.addingTimeInterval(120)))
        #expect(!AppModel.waitsForCheck(restarted: t, checked: nil, now: t.addingTimeInterval(AppModel.restartWait)))
    }

    @MainActor @Test func restartedContainersWaitPerServer() throws {
        let (m, _, _, _) = makeModel(args: ["app", "-HomelabDemo", "YES"])
        let now = Date()
        let media = HomelabKit.Host(id: "media", checked: now.addingTimeInterval(-120))
        let sonarr = ContainerInfo(name: "sonarr", restartable: true)
        #expect(m.restartWaiting(host: media, container: sonarr, now: now) == nil)
        m.noteRestart(host: "media", container: "sonarr", at: now)
        #expect(m.restartWaiting(host: media, container: sonarr, now: now.addingTimeInterval(60)) == now)
        #expect(m.restartWaiting(host: media, container: ContainerInfo(name: "radarr"), now: now) == nil)
        var checked = media
        checked.checked = now.addingTimeInterval(30)
        #expect(m.restartWaiting(host: checked, container: sonarr, now: now.addingTimeInterval(60)) == nil)
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        m.select(lab.id)
        #expect(m.restartWaiting(host: media, container: sonarr, now: now.addingTimeInterval(60)) == nil)
    }

    @MainActor @Test func requestedHostOpensOrIsDropped() async throws {
        let (m, _, _, _) = makeModel(args: ["app", "-HomelabDemo", "YES", "-HomelabHost", "media"])
        #expect(m.takeOpenHost() == nil && m.openHost == "media")   // no data yet: it waits
        await m.refresh()
        #expect(m.takeOpenHost()?.id == "media" && m.openHost == nil)
        m.openHost = "nope"
        #expect(m.takeOpenHost() == nil && m.openHost == "nope")    // the data predates the request
        await m.refresh()
        #expect(m.takeOpenHost() == nil && m.openHost == nil)       // newer data without it: dropped
    }

    @MainActor @Test func hostLinkWithoutLab() {
        // No server: no Lab, so the link opens Today and doesn't keep the host for later.
        let (m, _, _, _) = makeModel()
        m.open(URL(string: "homelab://lab/media")!)
        #expect(m.tab == .today && m.requestedTab == nil && m.openHost == nil)
        // While another tab waits for the server's info, a host link still opens Lab at once.
        let (w, _, _, _) = makeModel(args: ["app", "-HomelabResetState", "YES", "-HomelabServer", "https://lab.example.ts.net",
                                            "-HomelabTab", "chat"])
        #expect(w.requestedTab == .chat)
        w.open(URL(string: "homelab://lab/pi")!)
        #expect(w.tab == .lab && w.requestedTab == nil && w.openHost == "pi")
    }

    @MainActor @Test func widgetCopyLeavesOutHistory() async throws {
        let (m, _, storage, _) = makeModel()
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        await m.refresh()
        let full = try #require(storage.read(Snapshot.self, Snapshot.fileName(lab.id)))
        #expect(full.state.hosts.contains { $0.history != nil && !$0.containerList.isEmpty })
        let widget = try #require(storage.read(Snapshot.self, Snapshot.widgetFileName))
        #expect(widget.state.hosts.count == full.state.hosts.count)
        #expect(widget.state.hosts.allSatisfy { $0.history == nil && $0.containerList.isEmpty })
    }

    @Test func demoRestartChecksTheHost() async throws {
        let demo = DemoBackend(delay: .zero, now: Date())
        let before = Date()
        _ = try await demo.run("restart-container", arg: "media:gluetun", payload: [:])
        let media = try #require(try await demo.state().hosts.first { $0.id == "media" })
        #expect((media.checked ?? .distantPast) >= before)
    }
}
