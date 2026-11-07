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
        let tally = ProblemTally(state)
        switch state.status {
        case .ok:
            // Calm, but not silent about hosts that carry a gold note (an accepted under-voltage): the same count
            // as Lab's header, so Today says it even with the personality off.
            let noted = hosts.filter { state.health(of: $0) == .warning }.count
            let detail = machines.map { noted == 0 ? $0 : "\($0) · \(noted) with a warning" }
            self.init(level: .calm, headline: "All quiet.", detail: detail)
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

    public init(_ state: HomelabState) {
        let p = state.problems.filter { $0.severity != .warning }.count
        self.init(problems: state.status == .problem ? max(p, 1) : p, warnings: state.problems.count - p)
    }
}

/// What one answer said about problems, to feel a new one (research #10): a warning tap when a refresh lists a
/// problem the last answer from the same server didn't have.
public struct ProblemWatch: Equatable, Sendable {
    /// The server the answer came from; another server's problems are not new.
    public var server: String?
    /// The listed problems' ids (warnings too); nil before the first answer.
    public var ids: Set<String>?
    /// The mood was alarm.
    public var alarm: Bool

    public init(server: String?, state: HomelabState?) {
        self.server = server
        ids = state.map { Set($0.problems.map(\.id)) }
        alarm = state.map { TodayMood(state: $0).level == .alarm } ?? false
    }

    /// True when `new` lists a problem `old` didn't, on the same server, after a first answer. Not when the lab just
    /// turned to alarm: Today taps an error for that, and two taps for one change feel like a bug.
    public static func warns(from old: ProblemWatch, to new: ProblemWatch) -> Bool {
        guard old.server == new.server, let before = old.ids, let now = new.ids else { return false }
        if new.alarm && !old.alarm { return false }
        return !now.isSubset(of: before)
    }
}
