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

    /// `state` nil means nothing loaded yet.
    public init(state: HomelabState?) {
        guard let state else {
            self.init(level: .unknown, headline: "No signal.", detail: nil)
            return
        }
        let hosts = state.hosts.filter { HostHealth($0) != .asleep }   // a sleeping PC is not "down"
        let up = hosts.filter { $0.reachable == true }.count
        let machines = hosts.isEmpty ? nil : "\(up) of \(hosts.count) machines up"
        let problems = state.problems.filter { $0.severity != .warning }
        let first = (problems.first ?? state.problems.first)?.text
        switch state.status {
        case .ok:
            self.init(level: .calm, headline: "All quiet.", detail: machines)
        case .warning where problems.isEmpty:
            self.init(level: .headsUp, headline: "Heads up.", detail: first ?? machines, warnings: state.problems.count)
        case .warning, .problem:
            let n = max(problems.count, state.problems.isEmpty ? 1 : 0)
            let headline = n <= 1 ? "1 problem." : "\(n) problems."
            self.init(level: .alarm, headline: headline, detail: first ?? machines,
                      warnings: state.problems.count - problems.count)
        case .unknown:
            self.init(level: .unknown, headline: "Status unknown.", detail: machines)
        }
    }
}
