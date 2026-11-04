import Foundation
import Testing
@testable import HomelabKit

@Suite struct AlertTrackerTests {
    let now = Date(timeIntervalSince1970: 1_762_291_800)

    func state(problems: [String] = [], pending: [String] = []) -> HomelabState {
        HomelabState(status: problems.isEmpty ? .ok : .problem,
                     problems: problems.map { Problem(text: $0) },
                     pending: pending.map { PendingAction(id: $0, action: "restart", arg: $0) })
    }

    @Test func firstRunOnlyLearns() {
        var t = AlertTracker()
        #expect(t.update(with: state(problems: ["a"], pending: ["p1"]), server: "lab", now: now).isEmpty)
        #expect(t.seenProblems == ["a"] && t.seenPending == ["p1"])
    }

    @Test func newThingsAlertOnce() {
        var t = AlertTracker()
        _ = t.update(with: state(), server: "lab", now: now)
        let first = t.update(with: state(problems: ["disk full"], pending: ["p1"]), server: "lab", now: now + 60)
        #expect(first.map(\.kind) == [.problem, .pending])
        #expect(first[0].body == "disk full" && first[0].title == "lab: problem")
        #expect(first[1].title == "lab: approve restart p1?")
        #expect(t.update(with: state(problems: ["disk full"], pending: ["p1"]), server: "lab", now: now + 120).isEmpty)
    }

    @Test func goneAndBackAlertsAgain() {
        var t = AlertTracker()
        _ = t.update(with: state(problems: ["x"]), server: "lab", now: now)
        _ = t.update(with: state(), server: "lab", now: now + 60)
        #expect(t.update(with: state(problems: ["x"]), server: "lab", now: now + 120).count == 1)
    }

    @Test func noStormAfterALongGap() {
        var t = AlertTracker()
        _ = t.update(with: state(), server: "lab", now: now)
        let later = now + AlertTracker.relearnAfter + 1
        #expect(t.update(with: state(problems: ["a", "b"]), server: "lab", now: later).isEmpty)
    }

    @Test func capWithSummary() {
        var t = AlertTracker()
        _ = t.update(with: state(), server: "lab", now: now)
        let alerts = t.update(with: state(problems: ["a", "b", "c", "d", "e"]), server: "lab", now: now + 60)
        #expect(alerts.count == AlertTracker.maxPerRun)
        #expect(alerts.last?.kind == .summary && alerts.last?.body.hasPrefix("3 more") == true)
    }

    @Test func optionsSwitchKindsOff() {
        var t = AlertTracker()
        _ = t.update(with: state(), server: "lab", now: now)
        let a = t.update(with: state(problems: ["a"], pending: ["p"]), server: "lab",
                         options: .init(problems: false, pending: true), now: now + 60)
        #expect(a.map(\.kind) == [.pending])
    }

    @Test func warningsAreLabelled() {
        var t = AlertTracker()
        _ = t.update(with: state(), server: "lab", now: now)
        var s = state()
        s.problems = [Problem(text: "hot", severity: .warning)]
        #expect(t.update(with: s, server: "lab", now: now + 60).first?.title == "lab: warning")
    }

    @Test func persists() throws {
        var t = AlertTracker()
        _ = t.update(with: state(problems: ["a"]), server: "lab", now: now)
        let storage = Storage(directory: temporaryDirectory())
        try storage.write(t, AlertTracker.fileName)
        #expect(storage.read(AlertTracker.self, AlertTracker.fileName) == t)
    }
}

@Suite struct ChatTimelineTests {
    func m(_ id: Int64, _ from: ChatMessage.Sender = .agent, _ text: String = "t") -> ChatMessage {
        ChatMessage(id: id, from: from, text: text)
    }

    @Test func mergesSortedWithoutDuplicates() {
        var t = ChatTimeline()
        t.merge(MessagePage(messages: [m(3), m(1)], busy: []))
        t.merge(MessagePage(messages: [m(2), m(3, .agent, "edited")], busy: ["chat"]))
        #expect(t.messages.map(\.id) == [1, 2, 3])
        #expect(t.messages[2].text == "edited")
        #expect(t.cursor == 3 && t.isWorking)
    }

    @Test func optimisticSendIsReplacedByTheServerCopy() {
        var t = ChatTimeline()
        t.merge(MessagePage(messages: [m(1)]))
        let local = t.begin("hi")
        #expect(t.outgoing.count == 1 && t.outgoing[0].state == .sending)
        t.confirm(local, serverID: 5)
        #expect(t.outgoing[0].state == .sent(5) && t.isWorking)
        t.merge(MessagePage(messages: [m(5, .me, "hi")]))
        #expect(t.outgoing.isEmpty)
        #expect(t.messages.map(\.id) == [1, 5])
    }

    @Test func confirmWithoutIDMatchesByText() {
        var t = ChatTimeline()
        t.merge(MessagePage(messages: [m(1)]))
        let local = t.begin("hi")
        t.confirm(local, serverID: nil)
        t.merge(MessagePage(messages: [m(2, .me, "hi")]))
        #expect(t.outgoing.isEmpty)
    }

    @Test func failedSendStaysUntilDiscarded() {
        var t = ChatTimeline()
        let local = t.begin("hi")
        t.fail(local, message: "offline")
        t.merge(MessagePage(messages: [m(1)]))
        #expect(t.outgoing.first?.state == .failed("offline"))
        t.discard(local)
        #expect(t.outgoing.isEmpty)
    }

    @Test func keepsTheNewest() {
        var t = ChatTimeline()
        t.merge(MessagePage(messages: (1...(Int64(ChatTimeline.keep) + 50)).map { m($0) }))
        #expect(t.messages.count == ChatTimeline.keep && t.messages.first?.id == 51)
        t.reset()
        #expect(t.messages.isEmpty && t.cursor == 0)
    }

    @Test func polling() {
        #expect(PollPolicy.chatInterval(working: true, visible: true) == .seconds(2))
        #expect(PollPolicy.chatInterval(working: false, visible: true) == .seconds(15))
        #expect(PollPolicy.chatInterval(working: true, visible: false) == nil)
        #expect(PollPolicy.stateInterval(visible: true) == .seconds(30))
        #expect(PollPolicy.backoff(failures: 1) == .seconds(5))
        #expect(PollPolicy.backoff(failures: 3) == .seconds(20))
        #expect(PollPolicy.backoff(failures: 30) == .seconds(120))
    }
}

@Suite struct StorageTests {
    @Test func serverListRoundTripAndSelection() throws {
        let storage = Storage(directory: temporaryDirectory())
        var list = ServerList()
        let ha = ServerConfig(name: "HA", kind: .homeAssistant, baseURL: base, auth: .token, pinnedEntities: ["light.a"])
        list.upsert(ha)
        #expect(list.selected == nil && list.selectedServer == nil && list.homeAssistant == ha)
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: base, auth: .identity)
        let other = ServerConfig(name: "other", kind: .companion, baseURL: base, auth: .token)
        list.upsert(lab)
        list.upsert(other)
        #expect(list.selectedServer == lab)
        list.selected = other.id
        try storage.write(list, ServerList.fileName)
        var again = try #require(storage.read(ServerList.self, ServerList.fileName))
        #expect(again == list && again.selectedServer == other)
        again.remove(other.id)
        #expect(again.selectedServer == lab)
        var renamed = lab
        renamed.name = "renamed"
        again.upsert(renamed)
        #expect(again.servers.count == 2 && again.selectedServer?.name == "renamed")
    }

    @Test func snapshotAge() throws {
        let storage = Storage(directory: temporaryDirectory())
        let s = try fixture(HomelabState.self, "state-problem.json")
        let fetched = Date(timeIntervalSince1970: 1_762_291_800)
        let snap = Snapshot(serverID: UUID(), serverName: "lab", state: s, fetched: fetched)
        try storage.write(snap, Snapshot.widgetFileName)
        let back = try #require(storage.read(Snapshot.self, Snapshot.widgetFileName))
        #expect(back.state.pending == s.pending && back.fetched == fetched)
        #expect(!back.isStale(now: fetched + 60) && back.isStale(now: fetched + 3600))
        storage.remove(Snapshot.widgetFileName)
        #expect(storage.read(Snapshot.self, Snapshot.widgetFileName) == nil)
    }

    @Test func removeAll() throws {
        let storage = Storage(directory: temporaryDirectory())
        try storage.write(ServerList(), "a.json")
        try storage.write(ServerList(), "b.json")
        storage.removeAll()
        #expect(storage.read(ServerList.self, "a.json") == nil)
    }

    @Test func demoServers() {
        let d = ServerConfig.demo()
        let h = ServerConfig.demoHomeAssistant()
        #expect(d.speaksCompanionAPI && !d.showsHomeTab)
        #expect(h.showsHomeTab && !h.speaksCompanionAPI && h.isDemoHomeAssistant)
        #expect(ServerConfig.demoURL.host?.hasSuffix(".invalid") == true)
    }

    @Test func tokenStore() throws {
        let t = MemoryTokenStore()
        let id = UUID()
        try t.setToken("a", for: id)
        #expect(t.token(for: id) == "a")
        try t.setToken("", for: id)
        #expect(t.token(for: id) == nil)
    }
}

@Suite struct FormatTests {
    let now = Date(timeIntervalSince1970: 1_762_291_800)

    @Test func ages() {
        #expect(Format.age(nil) == "never")
        #expect(Format.age(now - 10, now: now) == "just now")
        #expect(Format.age(now - 120, now: now) == "2 min ago")
        #expect(Format.age(now - 7200, now: now) == "2 h ago")
        #expect(Format.age(now - 90000, now: now) == "yesterday")
        #expect(Format.age(now - 4 * 86400, now: now) == "4 d ago")
        #expect(Format.age(now + 3600, now: now) == "in the future")
    }

    @Test func numbers() {
        #expect(Format.percent(nil) == "–" && Format.percent(42) == "42%")
        #expect(Format.temperature(52.6) == "53 °C")
        #expect(Format.load(0.4) == "0.40")
        #expect(Format.loadShare(2, cores: 4) == 0.5 && Format.loadShare(2, cores: nil) == 2)
        #expect(Format.containers(up: 3, total: 4) == "3/4" && Format.containers(up: nil, total: nil) == "–")
        #expect(Format.worstDisk(["/": 30, "/a": 90, "/b": 90])?.mount == "/a")
        #expect(Format.worstDisk([:]) == nil)
    }

    @Test func flagsAndBackups() {
        #expect(Format.flag("undervoltage_now") == "Under-voltage now")
        #expect(Format.flag("fan_failed") == "Fan failed")
        #expect(Format.backup(last: nil, result: nil) == nil)
        #expect(Format.backup(last: ServerDate.string(now - 7200), result: "success", now: now) == "ok 2 h ago")
        #expect(Format.backup(last: "last Tuesday", result: "failed", now: now) == "failed last Tuesday")
        #expect(Format.backupFailed("failed") && !Format.backupFailed("success") && !Format.backupFailed(nil))
    }

    @Test func hostHealth() throws {
        let s = try fixture(HomelabState.self, "state-problem.json")
        let h = Dictionary(uniqueKeysWithValues: s.hosts.map { ($0.id, HostHealth($0)) })
        #expect(h["server"] == .ok)
        #expect(h["media"] == .warning)     // 10/11 containers, disk 93%
        #expect(h["pi"] == .warning)        // under-voltage since boot is informational
        #expect(h["gpu"] == .asleep)
        #expect(HostHealth(Host(id: "x", reachable: false)) == .problem)
        #expect(HostHealth(Host(id: "x")) == .unknown)
        #expect(HostHealth(Host(id: "x", reachable: true, flags: ["undervoltage_now"])) == .problem)
    }
}

@Suite struct AppGroupTests {
    @Test func teamSuffixFromSideStoreBundleIDs() {
        #expect(AppGroup.teamSuffix(bundleID: "com.qantrex.homelab.AB12CD34EF") == "AB12CD34EF")
        #expect(AppGroup.teamSuffix(bundleID: "com.qantrex.homelab.AB12CD34EF.HomelabWidget") == "AB12CD34EF")
        #expect(AppGroup.teamSuffix(bundleID: "com.qantrex.homelab") == nil)
        #expect(AppGroup.teamSuffix(bundleID: "com.qantrex.homelab.HomelabWidget") == nil)
        #expect(AppGroup.teamSuffix(bundleID: "com.qantrex.homelab.ab12cd34ef") == nil)
    }

    @Test func candidates() {
        #expect(AppGroup.candidates(bundleID: "com.qantrex.homelab.AB12CD34EF.HomelabWidget",
                                    provisioned: ["group.com.qantrex.homelab.AB12CD34EF"])
                == ["group.com.qantrex.homelab.AB12CD34EF", "group.com.qantrex.homelab"])
        #expect(AppGroup.candidates(bundleID: "com.qantrex.homelab") == ["group.com.qantrex.homelab"])
    }

    @Test func provisioningParse() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Name</key><string>P</string>
        <key>TeamIdentifier</key><array><string>AB12CD34EF</string></array>
        <key>Entitlements</key><dict><key>com.apple.security.application-groups</key>
        <array><string>group.x</string></array></dict></dict></plist>
        """
        var blob = Data([0x30, 0x82])
        blob.append(Data(xml.utf8))
        let p = try #require(Provisioning.parse(blob))
        #expect(p.appGroups == ["group.x"] && p.teamIDs == ["AB12CD34EF"])
        #expect(Provisioning.parse(Data("x".utf8)) == nil)
    }
}
