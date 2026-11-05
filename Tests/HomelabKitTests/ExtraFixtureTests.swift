import Foundation
import Testing
@testable import HomelabKit

/// The stress fixtures: a huge state, a pending-only state, and a state full of fields the app doesn't know.
@Suite struct ExtraFixtureTests {
    // MARK: state-huge.json

    @Test func hugeCounts() throws {
        let s = try fixture(HomelabState.self, "state-huge.json")
        #expect(s.status == .problem)
        #expect(s.hosts.count == 30)
        #expect(s.problems.count == 25)
        #expect(s.pending.count == 12)
        #expect(s.cards.count == 10)
        #expect(s.busy == ["chat", "watchdog", "morning"])
        #expect(s.lastMessage?.id == 1_762_290_600_000_000_001)
        #expect(s.lastMessage?.text.count ?? 0 > 300)
    }

    @Test func hugeHostsHaveEveryField() throws {
        let s = try fixture(HomelabState.self, "state-huge.json")
        #expect(Set(s.hosts.map(\.id)).count == 30)
        for h in s.hosts {
            #expect(h.name.count > 40, "\(h.id) long name")
            #expect(h.kind != nil && h.reachable != nil && h.checked != nil, "\(h.id)")
            #expect(h.load != nil && h.cpuCount != nil && h.memPct != nil && h.temp != nil, "\(h.id)")
            #expect(h.disks.count == 3, "\(h.id) disks")
            #expect(h.disks.values.allSatisfy { (0...100).contains($0) }, "\(h.id) disk range")
            #expect(h.containersUp != nil && h.containersTotal == 20, "\(h.id) containers")
            #expect(h.upgradable != nil && h.rebootRequired != nil, "\(h.id) updates")
            #expect(h.backupLast != nil && h.backupResult != nil, "\(h.id) backup")
            #expect(h.url?.scheme == "https", "\(h.id) url")
        }
        #expect(s.hosts.filter { $0.reachable == false }.count == 4)   // every 7th
        #expect(s.hosts[4].flags == ["undervoltage_now", "throttled_now", "undervoltage_since_boot"])
    }

    @Test func hugeProblemsAndPending() throws {
        let s = try fixture(HomelabState.self, "state-huge.json")
        #expect(s.problems.filter { $0.severity == .problem }.count == 13)
        #expect(s.problems.filter { $0.severity == .warning }.count == 12)
        #expect(s.problems.map(\.text).max { $0.count < $1.count }?.count ?? 0 > 300)
        #expect(s.problems.allSatisfy { $0.since != nil && $0.host != nil })
        #expect(s.pending.filter { $0.buttons.count == 3 }.count == 6)
        #expect(s.pending.filter { $0.buttons.keys.sorted { $0.rawValue < $1.rawValue } == [.approve, .deny] }.count == 6)
        #expect(s.pending.allSatisfy { $0.created != nil && $0.reason != nil && $0.arg != nil })
    }

    @Test func hugeCardsCoverEveryStyle() throws {
        let s = try fixture(HomelabState.self, "state-huge.json")
        #expect(Set(s.cards.map(\.style)) == [.list, .metrics, .text])
        #expect(s.cards.allSatisfy { ($0.title?.count ?? 0) > 60 })
        for c in s.cards {
            if c.style == .text {
                #expect(c.items.isEmpty && (c.text?.count ?? 0) > 300, "\(c.id)")
            } else {
                #expect(c.items.count == 12, "\(c.id)")
                #expect(c.items.allSatisfy { p in p.progress.map { (0...1).contains($0) } ?? false }, "\(c.id)")
                #expect(c.items.allSatisfy { $0.url != nil && $0.tint != nil }, "\(c.id)")
            }
        }
        #expect(c(s, "card-10")?.icon == "no.such.symbol")   // unknown symbol names are kept; the UI falls back
    }

    // MARK: state-pending.json

    @Test func pendingButtonVariants() throws {
        let s = try fixture(HomelabState.self, "state-pending.json")
        #expect(s.status == .warning)
        #expect(s.hosts.map(\.id) == ["server"])
        #expect(s.problems.count == 1 && s.problems[0].severity == .warning)
        #expect(s.cards.isEmpty && s.busy.isEmpty)
        #expect(s.pending.map(\.id) == ["pa01", "pa02", "pa03", "pa04"])
        #expect(Set(s.pending[0].buttons.keys) == [.approve, .always, .deny])
        #expect(Set(s.pending[1].buttons.keys) == [.approve, .deny])
        #expect(Set(s.pending[2].buttons.keys) == [.approve, .deny])
        #expect(s.pending[3].buttons.isEmpty)
        #expect(s.pending[0].buttons[.always] == "HOMELAB_ALWAYS_pa01_a000000000000002")
        #expect(s.pending[2].arg == nil)                          // "-" means no argument
        #expect(s.pending[2].title == "prune")
        #expect(s.pending[0].title == "restart server jellyfin")
    }

    // MARK: state-unknown-fields.json

    @Test func unknownFieldsTopLevel() throws {
        let s = try fixture(HomelabState.self, "state-unknown-fields.json")
        #expect(s.status == .warning)
        #expect(s.time != nil && s.checked != nil)
        #expect(s.busy == ["chat", "3"])   // object dropped, number turned into text
        let m = try #require(s.lastMessage)
        #expect(m.id == 1_762_290_600_000_000_002)
        #expect(m.from == .agent && m.status == "ALERT" && m.text == "hello")
    }

    @Test func unknownFieldsProblems() throws {
        let s = try fixture(HomelabState.self, "state-unknown-fields.json")
        #expect(s.problems.map(\.id) == ["p1", "p2"])
        #expect(s.problems[0].severity == .problem)   // unknown severity counts as a problem
        #expect(s.problems[0].host == "nas" && s.problems[0].since != nil)
        #expect(s.problems[1].severity == .warning)
        #expect(s.problems[1].host == nil && s.problems[1].since == nil)   // objects where strings belong
    }

    @Test func unknownFieldsHosts() throws {
        let s = try fixture(HomelabState.self, "state-unknown-fields.json")
        #expect(s.hosts.map(\.id) == ["nas", "pi"])   // no-id host, a string and a number dropped
        let nas = s.hosts[0]
        #expect(nas.name == "nas")                    // object name → falls back to the id
        #expect(nas.kind == "quantum-computer")       // free text, kept
        #expect(nas.reachable == nil && nas.load == nil && nas.temp == nil && nas.url == nil)
        #expect(nas.cpuCount == 8)
        #expect(nas.memPct == 100)                    // 140 clamped
        #expect(nas.disks == ["/": 92, "/negative": 0, "/over": 100])   // object dropped, range clamped
        #expect(nas.containersUp == 3 && nas.containersTotal == 4)
        #expect(nas.upgradable == 5 && nas.rebootRequired == false)
        #expect(nas.backupResult == "success" && nas.backupLast == "2026-11-04T04:00:00")
        #expect(nas.flags == ["undervoltage_now", "flux_capacitor_low"])
        let pi = s.hosts[1]
        #expect(pi.memPct == 55 && pi.temp == 48.5 && pi.load == 0.3)   // numbers as strings
        #expect(pi.containersUp == nil && pi.containersTotal == nil)      // scalar where an object belongs
        #expect(pi.upgradable == nil && pi.backupLast == nil)
        #expect(pi.flags == ["throttled_now"])
        #expect(pi.url == nil)                                            // ftp is not a web URL
    }

    @Test func unknownFieldsPendingAndCards() throws {
        let s = try fixture(HomelabState.self, "state-unknown-fields.json")
        #expect(s.pending.map(\.id) == ["u1", "u2"])
        #expect(Set(s.pending[0].buttons.keys) == [.approve, .deny])   // unknown verb + object value ignored
        let u2 = s.pending[1]
        #expect(u2.action == nil && u2.reason == nil && u2.job == nil && u2.buttons.isEmpty)
        #expect(u2.title == "Action u2")

        #expect(s.cards.map(\.id) == ["c1", "c2"])
        let c1 = s.cards[0]
        #expect(c1.style == .list && c1.tint == .gray)   // unknown style and tint
        #expect(c1.items.map(\.title) == ["a", "b", "c"])
        #expect(c1.items.map(\.progress) == [1, 0, nil])  // clamped; object dropped
        #expect(c1.items[0].url == nil && c1.items[0].tint == .gray)
        #expect(c1.items[1].url?.host == "example.com" && c1.items[1].value == "12")
        let c2 = s.cards[1]
        #expect(c2.title == nil && c2.style == .metrics && c2.tint == .teal && c2.items.isEmpty)
    }

    // MARK: Round trip

    @Test(arguments: ["state-huge.json", "state-pending.json", "state-unknown-fields.json"])
    func roundTrip(name: String) throws {
        let s = try fixture(HomelabState.self, name)
        let again = try JSONDecoder().decode(HomelabState.self, from: JSONEncoder().encode(s))
        #expect(again == s)
    }

    private func c(_ s: HomelabState, _ id: String) -> Card? { s.cards.first { $0.id == id } }
}
