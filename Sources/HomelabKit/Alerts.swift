import Foundation

/// Decides which local notifications a background refresh may send. Rules:
/// - only NEW things: a problem id or pending action id not seen before;
/// - a problem that went away and comes back counts as new again (after it was gone for one refresh);
/// - the first refresh after setup (or after a long gap offline) only learns, it never alerts (no storm);
/// - at most `maxPerRun` alerts per refresh; the rest are summarised in one line.
public struct AlertTracker: Codable, Sendable, Equatable {
    public var seenProblems: Set<String> = []
    public var seenPending: Set<String> = []
    public var lastRun: Date?
    /// The server these sets belong to. Another server means: learn first, alert nothing.
    public var serverID: UUID?

    public static let fileName = "alerts.json"
    public static let maxPerRun = 3
    /// After this long without a refresh, the next one only learns.
    public static let relearnAfter: TimeInterval = 24 * 3600

    public init() {}

    public struct Alert: Sendable, Equatable {
        public enum Kind: String, Sendable { case problem, pending, summary }
        public var id: String
        public var kind: Kind
        public var title: String
        public var body: String
        /// For the personality line in the notification's subtitle (none for the summary).
        public var moment: Voice.Moment?
    }

    public struct Options: Sendable, Equatable {
        public var problems: Bool
        public var pending: Bool
        public init(problems: Bool = true, pending: Bool = true) {
            self.problems = problems; self.pending = pending
        }
    }

    public mutating func update(with state: HomelabState, server: String, serverID: UUID? = nil,
                                options: Options = Options(), now: Date = Date()) -> [Alert] {
        let learnOnly = (lastRun.map { now.timeIntervalSince($0) > Self.relearnAfter } ?? true)
            || serverID != self.serverID
        defer {
            seenProblems = Set(state.problems.map(\.id))
            seenPending = Set(state.pending.map(\.id))
            lastRun = now
            self.serverID = serverID
        }
        if learnOnly { return [] }

        var alerts: [Alert] = []
        if options.problems {
            for p in state.problems where !seenProblems.contains(p.id) {
                alerts.append(Alert(id: "problem-\(p.id)", kind: .problem,
                                    title: p.severity == .warning ? "\(server): warning" : "\(server): problem",
                                    body: p.text, moment: p.severity == .warning ? .headsUp : .alarm))
            }
        }
        if options.pending {
            for a in state.pending where !seenPending.contains(a.id) {
                alerts.append(Alert(id: "pending-\(a.id)", kind: .pending, title: "\(server): approve \(a.title)?",
                                    body: a.reason ?? "Proposed by \(a.job ?? "the agent").", moment: .waiting))
            }
        }
        if alerts.count > Self.maxPerRun {
            let rest = alerts.count - (Self.maxPerRun - 1)
            alerts = Array(alerts.prefix(Self.maxPerRun - 1))
            alerts.append(Alert(id: "summary-\(Int(now.timeIntervalSince1970))", kind: .summary,
                                title: server, body: "\(rest) more new items. Open the app to see them."))
        }
        return alerts
    }
}
