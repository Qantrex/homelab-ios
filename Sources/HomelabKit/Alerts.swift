import Foundation

/// Decides which local notifications a background refresh may send. Rules:
/// - only NEW things: a problem id or pending action id not seen before;
/// - a problem that went away and comes back counts as new again (after it was gone for one refresh);
/// - the first refresh after setup (or after a long gap offline) only learns, it never alerts (no storm);
/// - at most `maxPerRun` alerts per refresh; the rest are summarised in one line;
/// - deals (feature `deals`): only an "act now" deal that is new to the tracker and was seen in the last
///   `maxDealAge`; the first time the tracker sees a deal list it only learns it (turning the toggle on later
///   doesn't announce the week's deals); a failed or missing list changes nothing, so a lost connection can't make
///   old deals look new.
public struct AlertTracker: Codable, Sendable, Equatable {
    public var seenProblems: Set<String> = []
    public var seenPending: Set<String> = []
    /// Ids of the "act now" deals already announced (or learned).
    public var seenDeals: Set<String> = []
    /// When each announced or learned act deal was last in a list. A deal that leaves the list for a while (or goes
    /// act → consider → act) stays known until it has been gone longer than it could still alert; then it's dropped.
    public var seenDealsAt: [String: Date] = [:]
    /// The tracker has seen a deal list once: from then on a new act deal alerts.
    public var dealsLearned = false
    public var lastRun: Date?
    /// The server these sets belong to. Another server means: learn first, alert nothing.
    public var serverID: UUID?

    public static let fileName = "alerts.json"
    public static let maxPerRun = 3
    /// After this long without a refresh, the next one only learns.
    public static let relearnAfter: TimeInterval = 24 * 3600

    public init() {}

    enum CodingKeys: String, CodingKey { case seenProblems, seenPending, seenDeals, seenDealsAt, dealsLearned, lastRun, serverID }

    /// Files from before deals have no `seenDeals` or `dealsLearned`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seenProblems = try c.decodeIfPresent(Set<String>.self, forKey: .seenProblems) ?? []
        seenPending = try c.decodeIfPresent(Set<String>.self, forKey: .seenPending) ?? []
        seenDeals = try c.decodeIfPresent(Set<String>.self, forKey: .seenDeals) ?? []
        dealsLearned = try c.decodeIfPresent(Bool.self, forKey: .dealsLearned) ?? false
        lastRun = try c.decodeIfPresent(Date.self, forKey: .lastRun)
        // Files from before the times: every known deal counts as seen at the last run.
        seenDealsAt = try c.decodeIfPresent([String: Date].self, forKey: .seenDealsAt)
            ?? Dictionary(seenDeals.map { ($0, lastRun ?? Date()) }, uniquingKeysWith: { a, _ in a })
        serverID = try c.decodeIfPresent(UUID.self, forKey: .serverID)
    }

    /// An "act now" deal older than this never alerts (the app was off for a day; the server's own push came then).
    public static let maxDealAge: TimeInterval = 6 * 3600

    public struct Alert: Sendable, Equatable {
        public enum Kind: String, Sendable { case problem, pending, deal, summary }
        public var id: String
        public var kind: Kind
        public var title: String
        public var body: String
        /// Where the personality's line for the notification's subtitle comes from (`Voice.line(_:_:)`; none for the
        /// summary).
        public var moment: Voice.Spot?
        /// The proposal of a `pending` alert: its buttons decide the notification's Approve / Deny buttons.
        public var proposal: PendingAction? = nil
    }

    public struct Options: Sendable, Equatable {
        public var problems: Bool
        public var pending: Bool
        public var deals: Bool
        /// The deal categories the owner chose (`AppSettings.dealCategories`); nil = all.
        public var dealCategories: [String]?
        public init(problems: Bool = true, pending: Bool = true, deals: Bool = false, dealCategories: [String]? = nil) {
            self.problems = problems; self.pending = pending; self.deals = deals; self.dealCategories = dealCategories
        }
    }

    /// `deals`: the server's list, nil when the server has none or the request failed (then nothing about deals changes).
    public mutating func update(with state: HomelabState, deals: DealList? = nil, server: String, serverID: UUID? = nil,
                                options: Options = Options(), now: Date = Date()) -> [Alert] {
        let serverChanged = serverID != self.serverID
        let learnOnly = (lastRun.map { now.timeIntervalSince($0) > Self.relearnAfter } ?? true) || serverChanged
        // Another server's deals are not this one's: what was learned is forgotten (before the new list is learned).
        let dealsKnown = dealsLearned && !serverChanged
        defer {
            seenProblems = Set(state.problems.map(\.id))
            seenPending = Set(state.pending.map(\.id))
            if serverChanged { seenDeals = []; seenDealsAt = [:]; dealsLearned = false }
            if let deals {
                // Added to, not replaced: a deal that drops out of one list and comes back isn't announced twice.
                for d in deals.deals where d.verdict == .act { seenDealsAt[String(d.id)] = now }
                let keep = Self.maxDealAge + DealList.freshFor
                seenDealsAt = seenDealsAt.filter { now.timeIntervalSince($0.value) <= keep }
                seenDeals = Set(seenDealsAt.keys)
                dealsLearned = true
            }
            lastRun = now
            self.serverID = serverID
        }
        if learnOnly { return [] }

        var alerts: [Alert] = []
        if options.problems {
            for p in state.problems where !seenProblems.contains(p.id) {
                alerts.append(Alert(id: "problem-\(p.id)", kind: .problem,
                                    title: p.severity == .warning ? "\(server): warning" : "\(server): problem",
                                    body: p.text, moment: .notice(p.severity == .warning ? .warning : .problem)))
            }
        }
        if options.pending {
            for a in state.pending where !seenPending.contains(a.id) {
                alerts.append(Alert(id: "pending-\(a.id)", kind: .pending, title: "\(server): approve \(a.title)?",
                                    body: a.reason ?? "Proposed by \(a.job ?? "the agent").", moment: .notice(.waiting),
                                    proposal: a))
            }
        }
        if options.deals, dealsKnown, let deals {
            for d in DealList.notifiable(deals.chosen(options.dealCategories).ordered, now: now, maxAge: Self.maxDealAge) where !seenDeals.contains(String(d.id)) {
                alerts.append(Alert(id: "deal-\(d.id)", kind: .deal, title: Self.dealTitle(d, server: server),
                                    body: Self.dealBody(d), moment: .notice(.deal)))
            }
        }
        if alerts.count > Self.maxPerRun {
            let rest = alerts.count - (Self.maxPerRun - 1)
            alerts = Array(alerts.prefix(Self.maxPerRun - 1))
            alerts.append(Alert(id: "summary-\(Int(clamping: now.timeIntervalSince1970, rounding: .down))", kind: .summary,
                                title: server, body: "\(rest) more new items. Open the app to see them."))
        }
        return alerts
    }

    /// "homelab: deal at € 100 (−50 %)"
    static func dealTitle(_ d: Deal, server: String) -> String {
        let facts = [d.price.map(DealFormat.price).map { "at " + $0 }, DealFormat.discount(d.share).map { "(\($0))" }]
            .compactMap { $0 }.joined(separator: " ")
        return facts.isEmpty ? "\(server): deal" : "\(server): deal \(facts)"
    }

    /// The ad's title and where it is.
    static func dealBody(_ d: Deal) -> String {
        [d.title, d.place].compactMap { $0 }.joined(separator: " · ")
    }
}
