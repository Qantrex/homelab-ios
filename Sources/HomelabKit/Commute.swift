import Foundation

/// `commute` in `/state` (step 6c): the way to school today, worked out by the server. Optional and lenient: a value
/// the app can't read is dropped, never an error. Times carry a zone (ISO 8601).
public struct CommutePlan: Codable, Sendable, Equatable, Hashable {
    /// The day it is for, "2026-11-07". The app only uses a plan whose day is today.
    public var date: String
    /// "u6" or "bike"; nil = not sent (a train plan if it has a train).
    public var mode: String?
    public var line: String?
    public var firstLesson: Date?
    public var leaveBy: Date?
    public var train: Date?
    /// The train after it.
    public var next: Date?
    /// The next one would be too late for the first lesson.
    public var nextTooLate: Bool
    public var disruptions: [String]
    /// Bike day: the ride in minutes.
    public var ride: Int?
    public var updated: Date?
    /// The server could not work it out ("no data from Wiener Linien").
    public var error: String?
    /// `false`: there is no commute today (holiday, no school); `why` says why.
    public var active: Bool?
    public var why: String?

    public init(date: String, mode: String? = nil, line: String? = nil, firstLesson: Date? = nil, leaveBy: Date? = nil,
                train: Date? = nil, next: Date? = nil, nextTooLate: Bool = false, disruptions: [String] = [],
                ride: Int? = nil, updated: Date? = nil, error: String? = nil, active: Bool? = nil, why: String? = nil) {
        self.date = date; self.mode = mode; self.line = line; self.firstLesson = firstLesson; self.leaveBy = leaveBy
        self.train = train; self.next = next; self.nextTooLate = nextTooLate; self.disruptions = disruptions
        self.ride = ride; self.updated = updated; self.error = error; self.active = active; self.why = why
    }

    enum CodingKeys: String, CodingKey {
        case date, mode, line, train, next, disruptions, ride, updated, error, active, why
        case firstLesson = "first_lesson", leaveBy = "leave_by", nextTooLate = "next_too_late"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let date = c.text(.date), Card.Item.isPlainDay(date) else {
            throw DecodingError.keyNotFound(CodingKeys.date, .init(codingPath: c.codingPath, debugDescription: "no day"))
        }
        self.init(date: date, mode: c.text(.mode)?.lowercased(), line: c.text(.line), firstLesson: c.date(.firstLesson),
                  leaveBy: c.date(.leaveBy), train: c.date(.train), next: c.date(.next),
                  nextTooLate: c.bool(.nextTooLate) ?? false, disruptions: c.strings(.disruptions),
                  ride: c.int(.ride).flatMap { $0 > 0 ? $0 : nil }, updated: c.date(.updated), error: c.text(.error),
                  active: c.bool(.active), why: c.text(.why))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encodeIfPresent(mode, forKey: .mode)
        try c.encodeIfPresent(line, forKey: .line)
        try c.encodeIfPresent(firstLesson.map(ServerDate.string), forKey: .firstLesson)
        try c.encodeIfPresent(leaveBy.map(ServerDate.string), forKey: .leaveBy)
        try c.encodeIfPresent(train.map(ServerDate.string), forKey: .train)
        try c.encodeIfPresent(next.map(ServerDate.string), forKey: .next)
        if nextTooLate { try c.encode(true, forKey: .nextTooLate) }
        if !disruptions.isEmpty { try c.encode(disruptions, forKey: .disruptions) }
        try c.encodeIfPresent(ride, forKey: .ride)
        try c.encodeIfPresent(updated.map(ServerDate.string), forKey: .updated)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(active, forKey: .active)
        try c.encodeIfPresent(why, forKey: .why)
    }

    public var isBike: Bool { mode == "bike" }
}

/// What the "Leave by" Live Activity shows. It is the activity's `ContentState` (small: ActivityKit allows 4 KB).
public struct LeaveContent: Codable, Sendable, Equatable, Hashable {
    /// When to walk out of the door.
    public var leaveBy: Date
    /// "U6", or "Bike".
    public var line: String
    /// The train it is for (bike: the same time as `leaveBy`).
    public var departure: Date
    public var next: Date?
    /// The next one is too late for the first lesson.
    public var nextTooLate: Bool
    /// The first disruption ("U6: Schadhaftes Fahrzeug"), nil when there is none.
    public var disruption: String?
    /// More disruptions than the one shown.
    public var moreDisruptions: Int
    public var bike: Bool
    /// Bike day: the ride in minutes.
    public var ride: Int?
    /// The day it belongs to and when the first lesson begins (the activity ends then).
    public var day: String
    public var firstLesson: Date

    /// When the activity is out of date on its own: the first lesson begins (never before the train).
    public var staleDate: Date { max(firstLesson, departure) }
    /// Less than 5 minutes to go: the countdown turns gold (as an addition to the numbers).
    public func isUrgent(now: Date) -> Bool { leaveBy.timeIntervalSince(now) < 300 }
    /// The moments the lock-screen view has to redraw: now, when it turns urgent and when it is stale.
    public func redrawDates(now: Date) -> [Date] {
        ([now, leaveBy.addingTimeInterval(-300), leaveBy, staleDate]).filter { $0 >= now }.sorted()
    }

    public init(leaveBy: Date, line: String, departure: Date, next: Date? = nil, nextTooLate: Bool = false,
                disruption: String? = nil, moreDisruptions: Int = 0, bike: Bool = false, ride: Int? = nil,
                day: String, firstLesson: Date) {
        self.leaveBy = leaveBy; self.line = line; self.departure = departure; self.next = next
        self.nextTooLate = nextTooLate; self.disruption = disruption; self.moreDisruptions = moreDisruptions
        self.bike = bike; self.ride = ride; self.day = day; self.firstLesson = firstLesson
    }
}

extension CommutePlan {
    /// The line's name when the server sends none: neutral, never a particular city's line.
    public static let defaultLine = "Train"

    /// The example in Settings → Leave-by: "Leave by 07:26 · U6 07:31", with the line of the server's own plan or
    /// departures (the neutral word when it sends none).
    public static func leaveByExample(plan: CommutePlan?, departures: Card?) -> String {
        let line = plan?.line ?? departures?.title ?? defaultLine
        return "Leave by 07:26 · \(line) 07:31"
    }

    /// The activity's content, or nil when the plan has nothing to show (error, not active, no leave-by or train,
    /// no first lesson).
    public var leaveContent: LeaveContent? {
        guard error == nil, active != false, let leaveBy, let firstLesson else { return nil }
        let first = disruptions.first
        let more = max(disruptions.count - 1, 0)
        if isBike {
            return LeaveContent(leaveBy: leaveBy, line: "Bike", departure: leaveBy, disruption: first, moreDisruptions: more,
                                bike: true, ride: ride, day: date, firstLesson: firstLesson)
        }
        guard let train else { return nil }
        return LeaveContent(leaveBy: leaveBy, line: line ?? Self.defaultLine, departure: train, next: next, nextTooLate: nextTooLate,
                            disruption: first, moreDisruptions: more, day: date, firstLesson: firstLesson)
    }

    /// "2026-11-07" for `now`'s calendar day.
    static func dayString(_ now: Date, calendar: Calendar) -> String {
        let d = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }
}

/// When the Live Activity starts, changes and ends. Pure, so it is tested on Linux; `LeaveActivityController` carries
/// the answer out.
public enum LeavePlan {
    public enum Decision: Equatable, Sendable {
        case start(LeaveContent)
        case update(LeaveContent)
        case end
        case none
    }

    /// It may start this long before the leave-by time.
    public static let startBefore: TimeInterval = 90 * 60

    /// - plan: the selected server's `commute` (nil = none).
    /// - running: the content of the activity that is on the screen (today's or an older one).
    /// - foreground: the app is open. A start needs it (iOS refuses `Activity.request` from the background); an
    ///   update or an end does not.
    /// - enabled: the Settings toggle.
    public static func decide(plan: CommutePlan?, now: Date, running: LeaveContent?, foreground: Bool,
                              enabled: Bool = true, calendar: Calendar = .current) -> Decision {
        let off: Decision = running == nil ? .none : .end
        guard enabled, let plan, plan.date == CommutePlan.dayString(now, calendar: calendar),
              let content = plan.leaveContent, now < content.firstLesson else { return off }
        if let running {
            // Yesterday's activity: end it; today's may start later (in the foreground).
            guard running.day == content.day else { return .end }
            return running == content ? .none : .update(content)
        }
        guard foreground, now >= content.leaveBy.addingTimeInterval(-startBefore) else { return .none }
        return .start(content)
    }
}
