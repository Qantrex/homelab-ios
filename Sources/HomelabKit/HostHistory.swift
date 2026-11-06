import Foundation

// Lab history and containers (GET /state, hosts[].history and hosts[].container_list). Both are optional: a server
// without them shows the Lab as before.

/// The last 24 h of one host: one point per `step` seconds, oldest first, the last point at `end`. A nil value is a
/// slot without data (the host was unreachable). Every series ends at `end`; they may differ in length.
public struct HostHistory: Codable, Sendable, Equatable, Hashable {
    /// 24 h at one point per 5 min. Longer series keep their newest points.
    public static let maxPoints = 288

    public enum Series: String, CaseIterable, Sendable, Hashable {
        case load, memPct = "mem_pct", temp, diskPct = "disk_pct"
    }

    /// Seconds between two points (> 0; 300 when the server sends nothing usable).
    public var step: Int
    /// Time of the last point. Nil only when neither the history nor the host says when it was checked.
    public var end: Date?
    public private(set) var load: [Double?]
    /// 0…100.
    public private(set) var memPct: [Double?]
    /// °C.
    public private(set) var temp: [Double?]
    /// The fullest disk, 0…100.
    public private(set) var diskPct: [Double?]

    public init(step: Int = 300, end: Date? = nil, load: [Double?] = [], memPct: [Double?] = [], temp: [Double?] = [],
                diskPct: [Double?] = []) {
        self.step = step > 0 ? Swift.min(step, 86400) : 300
        self.end = end
        self.load = []; self.memPct = []; self.temp = []; self.diskPct = []
        self[.load] = load; self[.memPct] = memPct; self[.temp] = temp; self[.diskPct] = diskPct
    }

    /// One series. Setting it caps it to `maxPoints` (newest kept), drops non-finite values and clamps percentages.
    public subscript(series: Series) -> [Double?] {
        get {
            switch series {
            case .load: load
            case .memPct: memPct
            case .temp: temp
            case .diskPct: diskPct
            }
        }
        set {
            var values = Array(newValue.suffix(Self.maxPoints)).map { v in v.flatMap { $0.isFinite ? $0 : nil } }
            switch series {
            case .memPct, .diskPct: values = values.map { $0.map { Swift.min(Swift.max($0, 0), 100) } }
            case .load: values = values.map { $0.map { Swift.max($0, 0) } }
            case .temp: break
            }
            switch series {
            case .load: load = values
            case .memPct: memPct = values
            case .temp: temp = values
            case .diskPct: diskPct = values
            }
        }
    }

    /// No series has a single value.
    public var isEmpty: Bool { Series.allCases.allSatisfy { self[$0].allSatisfy { $0 == nil } } }

    /// The values with their times, gaps left out. Empty without `end`.
    public func points(_ series: Series) -> [(date: Date, value: Double)] {
        guard let end else { return [] }
        let values = self[series]
        let n = values.count
        return values.enumerated().compactMap { i, v in
            v.map { (date: end.addingTimeInterval(-Double((n - 1 - i) * step)), value: $0) }
        }
    }

    public func min(_ series: Series) -> Double? { self[series].compactMap { $0 }.min() }
    public func max(_ series: Series) -> Double? { self[series].compactMap { $0 }.max() }
    /// The newest value there is (the last slot may be a gap).
    public func last(_ series: Series) -> Double? { self[series].last { $0 != nil } ?? nil }

    /// How long a last value counts as "now": two steps, at least 15 min (the watchdog runs every 5–9 min).
    public var freshFor: TimeInterval { Double(Swift.max(step * 2, 15 * 60)) }

    /// The newest value, only when it is recent (`freshFor`); nil when the history stopped hours ago. Colours and
    /// "now" use this, so an old value doesn't look current.
    public func recentLast(_ series: Series, now: Date = Date()) -> Double? {
        guard let p = points(series).last, now.timeIntervalSince(p.date) <= freshFor else { return nil }
        return p.value
    }

    /// The slots a sparkline spans: 24 h, at most `maxPoints`.
    public var windowSlots: Int { Swift.max(Swift.min(86400 / step, Self.maxPoints), 2) }

    /// How many slots the last point lies before `now` (0 without `end` or when `end` is ahead).
    public func slotsBehind(now: Date = Date()) -> Double {
        guard let end else { return 0 }
        return Swift.max(0, now.timeIntervalSince(end)) / Double(step)
    }

    /// One series as a sparkline on a 24 h time axis ending `now`: points sit by their time, not their index, so
    /// series of different length line up and an old history ends left of the right edge.
    public func shape(_ series: Series, now: Date = Date(), range: ClosedRange<Double>? = nil) -> SparklineShape {
        SparklineShape(self[series], range: range ?? series.range(self[series]), slots: windowSlots,
                       offset: slotsBehind(now: now))
    }

    enum CodingKeys: String, CodingKey { case step, end, load, memPct = "mem_pct", temp, diskPct = "disk_pct" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Non-numbers (and null) are gaps; a value that isn't a list is no series.
        func series(_ key: CodingKeys) -> [Double?] {
            (c.lenient([Lossy<Scalar>].self, key) ?? []).map { $0.value?.double }
        }
        self.init(step: c.int(.step) ?? 300, end: c.date(.end), load: series(.load), memPct: series(.memPct),
                  temp: series(.temp), diskPct: series(.diskPct))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(step, forKey: .step)
        try c.encodeIfPresent(end.map(ServerDate.string), forKey: .end)
        if !load.isEmpty { try c.encode(load, forKey: .load) }
        if !memPct.isEmpty { try c.encode(memPct, forKey: .memPct) }
        if !temp.isEmpty { try c.encode(temp, forKey: .temp) }
        if !diskPct.isEmpty { try c.encode(diskPct, forKey: .diskPct) }
    }
}

/// How a value stands against its limits: the row's number, the sparkline's dot and the detail chart all use this
/// (`Series.level`), so they cannot disagree.
public enum ValueLevel: Sendable, Equatable {
    case normal, warning, problem

    /// Over a limit (VoiceOver says "high").
    public var isHigh: Bool { self != .normal }
}

public extension Host {
    /// Where the host's current numbers stand against the series limits (the same rule as the sparkline's dot).
    var loadLevel: ValueLevel { HostHistory.Series.load.level(of: load, cores: cpuCount) }
    var ramLevel: ValueLevel { HostHistory.Series.memPct.level(of: memPct.map(Double.init), cores: nil) }
    /// The fullest disk.
    var diskLevel: ValueLevel {
        HostHistory.Series.diskPct.level(of: Format.worstDisk(disks).map { Double($0.percent) }, cores: nil)
    }
    var tempLevel: ValueLevel { HostHistory.Series.temp.level(of: temp, cores: nil) }
}

public extension HostHistory.Series {
    /// Where `value` stands: warning from `limits.warning`, problem from `limits.problem` (both inclusive). Nil = normal.
    func level(of value: Double?, cores: Int?) -> ValueLevel {
        guard let value else { return .normal }
        let l = limits(cores: cores)
        return value >= l.problem ? .problem : value >= l.warning ? .warning : .normal
    }

    /// From where on the last value is a warning (gold) and a problem (love). Load counts per core.
    func limits(cores: Int?) -> (warning: Double, problem: Double) {
        let cores = Double(Swift.max(cores ?? 1, 1))
        switch self {
        case .load: return (cores, cores * 2)
        case .memPct: return (90, 95)
        case .temp: return (Format.hotCelsius, Format.hotCelsius + 10)
        case .diskPct: return (75, 90)
        }
    }

    /// The vertical scale for a sparkline: percentages 0…100, load from 0 to at least 1 (a quiet host stays a low
    /// line instead of noise blown up to full height), temperature around its values with at least 10 °C.
    func range(_ values: [Double?]) -> ClosedRange<Double> {
        let known = values.compactMap { $0 }
        let lo = known.min() ?? 0, hi = known.max() ?? 0
        switch self {
        case .memPct, .diskPct: return 0...100
        case .load: return 0...Swift.max(hi, 1)
        case .temp:
            let mid = (lo + hi) / 2, half = Swift.max((hi - lo) / 2, 5)
            return (mid - half)...(mid + half)
        }
    }

    /// "1.85", "71%", "63°C".
    func format(_ value: Double) -> String {
        switch self {
        case .load: Format.load(value)
        case .memPct, .diskPct: Format.percent(Int(value.rounded()))
        case .temp: Format.temperature(value)
        }
    }
}

/// A sparkline's shape in unit coordinates (x 0…1 from the oldest to the newest slot, y 0…1 from bottom to top), split
/// into runs at gaps. Kept here so the drawing rules are tested; the view only scales it.
public struct SparklineShape: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public let runs: [[Point]]
    /// Where the newest value is (the dot).
    public let last: Point?
    public let min: Double?
    public let max: Double?
    public let lastValue: Double?

    /// `range` nil: from the smallest to the largest value. Values outside the range are drawn at its edge.
    /// `slots`: how many slots the width spans (nil: exactly the values, oldest at the left edge); the newest value
    /// sits `offset` slots left of the right edge. Points that would lie left of the edge are left out.
    public init(_ values: [Double?], range: ClosedRange<Double>? = nil, slots: Int? = nil, offset: Double = 0) {
        let known = values.compactMap { $0 }.filter(\.isFinite)
        min = known.min(); max = known.max()
        lastValue = values.last { $0 != nil } ?? nil
        var lo = range?.lowerBound ?? min ?? 0, hi = range?.upperBound ?? max ?? 1
        if hi - lo < 1e-9 { lo -= 1; hi += 1 }   // a flat line sits in the middle
        let n = values.count
        let window = Double(Swift.max(slots ?? n, 2))
        let offset = offset.isFinite ? Swift.max(offset, 0) : 0
        func x(_ i: Int) -> Double {
            if slots == nil && n <= 1 { return 1 }
            return 1 - (offset + Double(n - 1 - i)) / (window - 1)
        }
        func point(_ i: Int, _ v: Double) -> Point {
            Point(x: x(i), y: Swift.min(Swift.max((v - lo) / (hi - lo), 0), 1))
        }
        var runs: [[Point]] = []
        var current: [Point] = []
        var last: Point?
        for (i, v) in values.enumerated() where x(i) >= -1e-9 {
            if let v, v.isFinite {
                let p = point(i, v)
                current.append(p)
                last = p
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        self.runs = runs
        self.last = last
    }

    public var isEmpty: Bool { runs.isEmpty }
}

/// One container of a host (`container_list`).
public struct ContainerInfo: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// Docker's state.
    public enum State: String, Codable, Sendable, CaseIterable {
        case running, exited, restarting, paused, created, removing, dead, unknown

        /// "running", also docker ps' "Up 3 hours" and "Exited (1) 2 hours ago".
        public init(lenient raw: String?) {
            let word = raw?.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
            self = word == "up" ? .running : State(rawValue: word) ?? .unknown
        }
    }

    public enum Health: String, Codable, Sendable, CaseIterable { case healthy, unhealthy, starting }

    public var name: String
    public var state: State
    /// Nil: the container has no health check.
    public var health: Health?
    /// Docker's RestartCount.
    public var restarts: Int?
    /// On the host's restart list: `restart-container <host>:<name>` would be accepted.
    public var restartable: Bool

    public var id: String { name }

    public init(name: String, state: State = .running, health: Health? = nil, restarts: Int? = nil, restartable: Bool = false) {
        self.name = name; self.state = state; self.health = health
        self.restarts = restarts.map { Swift.max($0, 0) }; self.restartable = restartable
    }

    /// Down, dead, restarting in a loop or failing its health check.
    public var isProblem: Bool {
        [.exited, .dead, .restarting].contains(state) || health == .unhealthy
    }

    /// Its colour: restarting is a warning (it may come back), the rest of the problems are problems.
    public var severity: Problem.Severity? {
        guard isProblem else { return nil }
        return state == .restarting && health != .unhealthy ? .warning : .problem
    }

    /// Problems first (worst first), then the others; by name inside each group.
    public static func ordered(_ list: [ContainerInfo]) -> [ContainerInfo] {
        func rank(_ c: ContainerInfo) -> Int {
            switch c.severity {
            case .problem: 0
            case .warning: 1
            case nil: 2
            }
        }
        return list.sorted { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : a.name.lowercased() < b.name.lowercased()
        }
    }

    enum CodingKeys: String, CodingKey { case name, state, health, restarts, restartable }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = c.text(.name) else {
            throw DecodingError.keyNotFound(CodingKeys.name, .init(codingPath: c.codingPath, debugDescription: "no name"))
        }
        self.init(name: name, state: State(lenient: c.text(.state)),
                  health: c.text(.health).flatMap { Health(rawValue: $0.lowercased()) },
                  restarts: c.int(.restarts), restartable: c.bool(.restartable) ?? false)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(health, forKey: .health)
        try c.encodeIfPresent(restarts, forKey: .restarts)
        try c.encode(restartable, forKey: .restartable)
    }
}

// MARK: Restarting a container from Lab

public extension ServerStatus {
    /// The step-2 action that restarts a container; its argument is `<host>:<name>`.
    static let restartAction = "restart-container"

    /// The ready form that restarts `container` on `host`, or nil when the server doesn't offer it: the container
    /// isn't on the restart list, the server has no `run-actions` or no `restart-container`, or its form can't name
    /// this host and container.
    func restartForm(host: Host, container: ContainerInfo) -> ActionForm? {
        guard container.restartable, features.contains(.runActions),
              let spec = actions.first(where: { $0.name == Self.restartAction }),
              let form = ActionForm.prefilled(spec, arg: "\(host.id):\(container.name)"), form.isReady else { return nil }
        return form
    }
}
