import Foundation

/// The big line at the top of Today: how the lab is doing, in a few words. Calm when everything is fine, loud when
/// something is wrong. Pure logic, so it is tested on Linux; the app picks colours and motion from `level`.
public struct TodayMood: Equatable, Sendable {
    public enum Level: Sendable, Equatable {
        case calm      // all fine
        case headsUp   // warnings only
        case alarm     // at least one problem
        case unknown   // no data, or the server doesn't know
    }

    public var level: Level
    /// "All quiet.", "Heads up.", "2 problems."
    public var headline: String
    /// The first problem, or "4 of 4 machines up".
    public var detail: String?
    /// Warnings next to the counted problems ("and 1 warning").
    public var warnings: Int

    public init(level: Level, headline: String, detail: String?, warnings: Int = 0) {
        self.level = level
        self.headline = headline
        self.detail = detail
        self.warnings = warnings
    }

    /// `state` nil means nothing loaded yet: `checking` while the first fetch is still on its way ("Checking…"),
    /// else the fetch failed ("No signal.").
    public init(state: HomelabState?, checking: Bool = false) {
        guard let state else {
            self.init(level: .unknown, headline: checking ? "Checking…" : "No signal.", detail: nil)
            return
        }
        let hosts = state.hosts.filter { HostHealth($0) != .asleep }   // a sleeping PC is not "down"
        let up = hosts.filter { $0.reachable == true }.count
        let machines = hosts.isEmpty ? nil : "\(up) of \(hosts.count) machines up"
        let first = (state.problems.first { $0.severity != .warning } ?? state.problems.first)?.text
            ?? state.hostAlerts.first
        let tally = ProblemTally(state)
        switch state.status {
        case .ok where tally.warnings > 0:
            // The server says ok, but a host reports under-voltage or throttling right now (live, 2026-11-06:
            // pi-media throttled while Today said "All quiet.").
            self.init(level: .headsUp, headline: "Heads up.", detail: first ?? machines, warnings: tally.warnings)
        case .ok:
            self.init(level: .calm, headline: "All quiet.", detail: machines)
        case .warning where tally.problems == 0:
            self.init(level: .headsUp, headline: "Heads up.", detail: first ?? machines, warnings: tally.warnings)
        case .warning, .problem:
            let headline = tally.problems == 1 ? "1 problem." : "\(tally.problems) problems."
            self.init(level: .alarm, headline: headline, detail: first ?? machines, warnings: tally.warnings)
        case .unknown:
            self.init(level: .unknown, headline: "Status unknown.", detail: machines)
        }
    }
}

/// The lab's problems and warnings, counted the same way on Today (the mood) and in Lab (the header).
public struct ProblemTally: Equatable, Sendable {
    /// Listed problems (severity problem). At least 1 when the server's status is `problem`, even if it lists
    /// only warnings or nothing.
    public var problems: Int
    /// Listed warnings.
    public var warnings: Int

    public init(problems: Int, warnings: Int) {
        self.problems = problems
        self.warnings = warnings
    }

    /// Hosts with an alarming flag now (under-voltage, throttled) and no listed problem of their own count as
    /// warnings too, so the headline never says "All quiet." next to a yellow dot.
    public init(_ state: HomelabState) {
        let p = state.problems.filter { $0.severity != .warning }.count
        self.init(problems: state.status == .problem ? max(p, 1) : p,
                  warnings: state.problems.count - p + state.hostAlerts.count)
    }
}

public extension HomelabState {
    /// "pi-media: under-voltage now, throttled now" for each reachable host with an alarming flag that the server
    /// doesn't already list as a problem.
    var hostAlerts: [String] {
        hosts.compactMap { host in
            guard host.reachable == true, !problems.contains(where: { $0.host == host.id }) else { return nil }
            let alarming = host.flags.filter(Format.isAlarming)
            guard !alarming.isEmpty else { return nil }
            return "\(host.name): " + alarming.map { Format.flag($0).lowercased() }.joined(separator: ", ")
        }
    }
}
