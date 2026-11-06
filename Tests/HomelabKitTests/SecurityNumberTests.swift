import Foundation
import Testing
@testable import HomelabKit

// Fixes from the security review of 2026-11-06 (its probe tests, turned into real ones).

/// Out-of-range server numbers are put into range when decoded, so no Double → Int conversion can trap.
struct ServerNumberTests {
    @Test func clampingConversion() {
        #expect(Int(clamping: 2.5) == 3 && Int(clamping: -2.5) == -3 && Int(clamping: 2.4) == 2)
        #expect(Int(clamping: .nan) == 0)
        #expect(Int(clamping: .infinity) == Int.max && Int(clamping: -.infinity) == Int.min)
        #expect(Int(clamping: Double(Float.greatestFiniteMagnitude)) == Int.max)
        #expect(Int(clamping: 1e30, in: 0...100) == 100 && Int(clamping: -1e30, in: 0...100) == 0)
        #expect(Int(clamping: .nan, in: 5...10) == 5)
        #expect(Int(clamping: 9.99, rounding: .down) == 9)
        #expect(Int(clamping: Double(Int.max)) == Int.max && Int(clamping: Double(Int.min)) == Int.min)
        #expect(Format.temperature(Double(Float.greatestFiniteMagnitude)).hasSuffix("°C"))
        #expect(Format.temperature(.nan) == "–")
        #expect(Format.ringPercent(1e30) == 100 && Format.ringPercent(-.infinity) == 0)
        #expect(Format.age(Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 1e15)).hasSuffix("d ago"))
    }

    static let hostile = """
    {"status": "ok", "time": 1e30,
     "hosts": [
      {"id": "flt", "temp": 3.4028234663852886e+38, "load": 3.4028234663852886e+38, "mem_pct": 3.4028234663852886e+38,
       "cpu_count": 1e30, "disks": {"/": 3.4028234663852886e+38, "/a": -1e30, "/b": "nan", "/c": "-inf", "/d": 63.4},
       "containers": {"up": 1e30, "total": "inf"}, "updates": {"upgradable": -1e30}, "checked": "1000000000000000000000000000000",
       "history": {"step": 1e30, "load": [1e30, "nan", -5, 1.5], "mem_pct": [1e30, "-inf", 50],
                   "temp": [3.4e38, 41, "inf", -1e30, 250], "disk_pct": ["1e400", 101, -3]}},
      {"id": "big", "temp": 1e30, "load": "1e30", "mem_pct": "nan"},
      {"id": "nan", "temp": "nan", "load": "-inf", "mem_pct": -1e30},
      {"id": "cold", "temp": "-inf", "load": -2},
      {"id": "fine", "temp": 41.5, "load": 0.42, "mem_pct": 38, "cpu_count": 4, "disks": {"/": 31}}
     ],
     "cards": [{"id": "c", "title": "C", "items": [{"title": "a", "progress": 1e30}, {"title": "b", "progress": "nan"},
                                                  {"title": "c", "progress": -1e30}, {"title": "d", "progress": 0.5}]}]}
    """

    func check(_ s: HomelabState) throws {
        func host(_ id: String) throws -> HomelabKit.Host { try #require(s.hosts.first { $0.id == id }) }
        let flt = try host("flt")
        #expect(flt.temp == nil && flt.load == 10_000 && flt.memPct == 100 && flt.cpuCount == 100_000)
        #expect(flt.disks == ["/": 100, "/a": 0, "/d": 63])
        #expect(flt.containersUp == 1_000_000_000 && flt.containersTotal == nil && flt.upgradable == -1_000_000_000)
        #expect(flt.checked == nil)
        let h = try #require(flt.history)
        #expect(h.step == 86400)
        #expect(h[.load] == [10_000, nil, 0, 1.5])
        #expect(h[.memPct] == [100, nil, 50])
        #expect(h[.temp] == [nil, 41, nil, nil, nil])
        #expect(h[.diskPct] == [nil, 100, 0])
        let big = try host("big")
        #expect(big.temp == nil && big.load == 10_000 && big.memPct == nil)
        let nan = try host("nan")
        #expect(nan.temp == nil && nan.load == nil && nan.memPct == 0)
        let cold = try host("cold")
        #expect(cold.temp == nil && cold.load == 0)
        let fine = try host("fine")
        #expect(fine.temp == 41.5 && fine.load == 0.42 && fine.memPct == 38 && fine.cpuCount == 4 && fine.disks == ["/": 31])
        #expect(s.cards[0].items.map(\.progress) == [1, nil, 0, 0.5])
        // Everything that formats or rates these numbers runs without a trap.
        for host in s.hosts {
            _ = Format.temperature(host.temp)
            _ = [host.loadLevel, host.ramLevel, host.diskLevel, host.tempLevel]
            for series in HostHistory.Series.allCases {
                for v in host.history?[series].compactMap({ $0 }) ?? [] { _ = series.format(v) }
                _ = host.history?.shape(series)
            }
        }
        _ = Voice.notableFact(in: s)
        for host in s.hosts { _ = Voice.fact(for: Problem(text: "\(host.id) is too hot"), host: host) }
    }

    @Test func hostileNumbersDecodeIntoRange() throws {
        try check(try decode(HomelabState.self, Self.hostile))
    }

    @Test func andSurviveTheSnapshotRoundTrip() throws {
        let state = try decode(HomelabState.self, Self.hostile)
        let storage = Storage(directory: temporaryDirectory())
        let id = UUID()
        try storage.write(Snapshot(serverID: id, serverName: "x", state: state), Snapshot.fileName(id))
        let back = try #require(storage.read(Snapshot.self, Snapshot.fileName(id)))
        #expect(back.state == state)
        try check(back.state)
    }

    @Test func farFutureEpochsAreDropped() {
        #expect(ServerDate.fromEpoch(1e30) == nil)
        #expect(ServerDate.fromEpoch(1_793_827_800) != nil)
        #expect(ServerDate.fromEpoch(1_793_827_800_000_000_000) != nil)   // nanoseconds
        #expect(ServerDate.parse("1000000000000000000000000000000") == nil)
    }
}
