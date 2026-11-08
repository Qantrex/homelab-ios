import Foundation

// Show rules (docs/plans/MODULAR.md, M3): one optional rule per Today section says *when* it shows. Always (the
// default, and what a missing rule means), When it needs me, At set times, and (with presence from Home Assistant,
// M3.3) At home or Away. Pure: the clock, the calendar and presence come in through `ShowContext`, so every rule is
// tested on Linux and nothing here reads `Date()`.

/// A time window on some days, also used for quiet hours. Minutes after midnight: `to` before `from` wraps past
/// midnight (22:00–02:00), `to` equal to `from` is the whole day, `to` 1440 is midnight at the end of the day.
/// `days` are `Calendar` weekdays (1 = Sunday … 7 = Saturday) on which the window *starts*: a Friday 22:00–02:00
/// window still holds at 01:00 on Saturday. Nil = every day.
public struct TimeWindow: Codable, Equatable, Hashable, Sendable {
    public var from: Int
    public var to: Int
    public var days: [Int]?

    /// Out-of-range values are clamped, days sorted and deduplicated; no day or every day is nil.
    public init(from: Int, to: Int, days: [Int]? = nil) {
        self.from = min(max(from, 0), 1439)
        self.to = min(max(to, 0), 1440)
        let d = Array(Set((days ?? []).filter { (1...7).contains($0) })).sorted()
        self.days = d.isEmpty || d.count == 7 ? nil : d
    }

    enum CodingKeys: String, CodingKey { case from, to, days }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Unreadable `days` (a wrong type, a day list from a newer app) mean every day, so one bad key doesn't throw
        // the window away. For a show rule that errs toward shown, the safe side. For quiet hours it widens the quiet
        // to days the owner didn't pick; a window with a bad `from` or `to` still fails to decode.
        self.init(from: try c.decode(Int.self, forKey: .from), to: try c.decode(Int.self, forKey: .to),
                  days: c.lenient([Int].self, .days))
    }

    /// Whether `date` falls in the window, by the calendar's time zone.
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        let c = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let today = c.weekday ?? 1
        func on(_ day: Int) -> Bool { days?.contains(day) ?? true }
        if from == to { return on(today) }
        if from < to { return minute >= from && minute < to && on(today) }
        if minute >= from { return on(today) }                          // the evening part, started today
        if minute < to { return on(today == 1 ? 7 : today - 1) }        // the morning part, started yesterday
        return false
    }

    /// The windows the rule sheet offers by name.
    public static let mornings = TimeWindow(from: 5 * 60, to: 11 * 60)
    public static let daytime = TimeWindow(from: 11 * 60, to: 18 * 60)
    public static let evenings = TimeWindow(from: 18 * 60, to: 24 * 60)
    public static let weekdays = TimeWindow(from: 0, to: 24 * 60, days: [2, 3, 4, 5, 6])
    public static let weekends = TimeWindow(from: 0, to: 24 * 60, days: [1, 7])
    public static let named: [(name: String, window: TimeWindow)] = [
        ("Mornings", mornings), ("Daytime", daytime), ("Evenings", evenings), ("Weekdays", weekdays), ("Weekends", weekends),
    ]

    /// "Evenings", "Weekdays 6–10", "Sat, Sun 9:30–12", "22–2". `named` false gives a named window's times too
    /// ("18–24" for Evenings).
    public func words(calendar: Calendar, named: Bool = true) -> String {
        if named, let name = Self.named.first(where: { $0.window == self })?.name { return name }
        let allDay = from == to || (from == 0 && to == 1440)
        let time = allDay ? nil : "\(Self.clock(from))–\(Self.clock(to))"
        var day: String?
        if let days {
            if days == Self.weekdays.days {
                day = "Weekdays"
            } else if days == Self.weekends.days {
                day = "Weekends"
            } else {
                // Monday first, in the calendar's language.
                let names = calendar.shortWeekdaySymbols
                day = days.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { names[$0 - 1] }.joined(separator: ", ")
            }
        }
        return [day, time].compactMap { $0 }.joined(separator: " ").nonEmpty ?? "All day"
    }

    /// "6", "6:30", "24".
    static func clock(_ minutes: Int) -> String {
        let m = minutes % 60
        return m == 0 ? "\(minutes / 60)" : "\(minutes / 60):" + (m < 10 ? "0\(m)" : "\(m)")
    }
}

/// Where I am, from a Home Assistant `person.*` entity (M3.3). `fetched` is when the app last read it, not when it
/// last changed: a reading older than `maxAge` counts as unknown, and an unknown place lets every rule pass.
public struct Presence: Equatable, Sendable {
    public var atHome: Bool
    public var fetched: Date

    public static let maxAge: TimeInterval = 30 * 60

    public init(atHome: Bool, fetched: Date) {
        self.atHome = atHome
        self.fetched = fetched
    }

    /// At home or not, or nil when the reading is too old to trust.
    public func atHome(now: Date) -> Bool? { now.timeIntervalSince(fetched) > Self.maxAge ? nil : atHome }
}

/// What a rule is checked against: now, the calendar (time zone, week), which sections need me, where I am.
public struct ShowContext: Sendable {
    public var now: Date
    public var calendar: Calendar
    /// The sections that need me right now (`TodaySection.needingMe`).
    public var needsMe: Set<TodaySection>
    /// Nil = unknown or not set up: presence rules pass.
    public var presence: Presence?
    /// Sections the user asked to see anyway ("Hidden now · Show"): they pass every rule until the app closes.
    public var shownAnyway: Set<TodaySection>

    public init(now: Date, calendar: Calendar = .current, needsMe: Set<TodaySection> = [], presence: Presence? = nil,
                shownAnyway: Set<TodaySection> = []) {
        self.now = now; self.calendar = calendar; self.needsMe = needsMe; self.presence = presence
        self.shownAnyway = shownAnyway
    }
}

/// When one Today section shows. Stored as `{"kind": "times", "from": 1080, "to": 1440, "days": [2, 3]}`; a kind
/// this version doesn't know makes the rule unreadable, and `TodayLayout` drops it (the section shows Always).
public enum ShowRule: Equatable, Hashable, Sendable {
    case always
    /// Only while the section has something for me (`TodaySection.needsMe`). A section that can't need me (the day)
    /// shows Always.
    case needsMe
    case times(TimeWindow)
    /// Presence rules (M3.3): they pass while presence is unknown or stale, so nothing vanishes by mistake.
    case atHome
    case away

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case always, needsMe, times, atHome, away
    }

    public var kind: Kind {
        switch self {
        case .always: .always
        case .needsMe: .needsMe
        case .times: .times
        case .atHome: .atHome
        case .away: .away
        }
    }

    /// The kinds the rule sheet offers for a section: "When it needs me" not for the day, presence only once it's set up.
    public static func kinds(for section: TodaySection, presence: Bool) -> [Kind] {
        Kind.allCases.filter { k in
            switch k {
            case .needsMe: section.canNeedMe
            case .atHome, .away: presence
            case .always, .times: true
            }
        }
    }

    /// Whether `section` shows under this rule now.
    public func shows(_ section: TodaySection, in c: ShowContext) -> Bool {
        if c.shownAnyway.contains(section) { return true }
        switch self {
        case .always: return true
        case .needsMe: return !section.canNeedMe || c.needsMe.contains(section)
        case .times(let w): return w.contains(c.now, calendar: c.calendar)
        case .atHome: return c.presence?.atHome(now: c.now) ?? true
        case .away: return !(c.presence?.atHome(now: c.now) ?? false)
        }
    }

    /// The rule in words, for the sections editor: "Always", "When it needs me", "Evenings", "Weekdays 6–10".
    public func words(calendar: Calendar = .current) -> String {
        switch self {
        case .always: "Always"
        case .needsMe: "When it needs me"
        case .times(let w): w.words(calendar: calendar)
        case .atHome: "At home"
        case .away: "Away"
        }
    }

    /// The readable rules of a stored layout; none = nil, so nothing new is written back.
    static func lenient(_ raw: [String: Lossy<ShowRule>]?) -> [String: ShowRule]? {
        let rules = (raw ?? [:]).compactMapValues(\.value)
        return rules.isEmpty ? nil : rules
    }
}

extension ShowRule: Codable {
    enum CodingKeys: String, CodingKey { case kind, from, to, days }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .always: self = .always
        case .needsMe: self = .needsMe
        case .times: self = .times(try TimeWindow(from: decoder))
        case .atHome: self = .atHome
        case .away: self = .away
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        if case .times(let w) = self {
            try c.encode(w.from, forKey: .from)
            try c.encode(w.to, forKey: .to)
            try c.encodeIfPresent(w.days, forKey: .days)
        }
    }
}

// MARK: - Needs me

extension TodaySection {
    /// The day line is the day, not a call to act: it can't use "When it needs me".
    public var canNeedMe: Bool { self != .day }

    /// Whether this section has something for me now. The exact meaning per section:
    /// - To approve: an action waits for approval.
    /// - Deals: an "act now" deal from the last day (`DealList.freshAct`), what Today's deals card shows.
    /// - Home tiles: a pinned tile's entity is `unavailable` in Home Assistant.
    /// - Cards: a Today card (not the day card, not a Lab card) has an open row tinted red, a problem. A card's own
    ///   tint is decoration, and orange or yellow rows (a late train, a substitution) are only warnings.
    /// - Last report: the last message reports a problem (`ALERT`, `ERROR`, `PROBLEM`, …).
    /// - Machines: a host is down or has a warning (`HostHealth` with the server's problems); asleep doesn't count.
    /// - The day: never (`canNeedMe`).
    /// `home` is the pinned tiles' entities as last fetched; `deals` the server's deals, nil when it has none.
    public func needsMe(state: HomelabState?, home: [HAEntity] = [], deals: DealList? = nil, now: Date) -> Bool {
        switch self {
        case .day:
            return false
        case .waiting:
            return !(state?.pending.isEmpty ?? true)
        case .deals:
            return !(deals?.freshAct(now: now).isEmpty ?? true)
        case .home:
            return home.contains { $0.state == "unavailable" }
        case .cards:
            guard let state else { return false }
            let day = state.dayCard?.id
            return state.cards.contains { card in
                card.id != day && card.place != .lab && card.items.contains { $0.tint == .red && $0.done != true }
            }
        case .report:
            guard let m = state?.lastMessage, !m.text.isEmpty else { return false }
            return OverallStatus(lenient: m.status) == .problem
        case .machines:
            guard let state else { return false }
            return state.hosts.contains { [.problem, .warning].contains(state.health(of: $0)) }
        }
    }

    /// Every section that needs me now, for `ShowContext.needsMe`.
    public static func needingMe(state: HomelabState?, home: [HAEntity] = [], deals: DealList? = nil,
                                 now: Date) -> Set<TodaySection> {
        Set(allCases.filter { $0.needsMe(state: state, home: home, deals: deals, now: now) })
    }
}

// MARK: - The layout and the densities

extension TodayLayout {
    /// The section's stored rule; nil = none (Always; Machines then shows in Detailed only).
    public func rule(for section: TodaySection) -> ShowRule? { rules?[section.rawValue] }

    /// Sets or clears a rule. Always is the same as no rule and is not stored, except for Machines, where it means
    /// "in Standard too". The last rule removed leaves `rules` nil, so the settings file is as before.
    public mutating func setRule(_ rule: ShowRule?, for section: TodaySection) {
        var all = rules ?? [:]
        if let rule, rule != .always || section == .machines {
            all[section.rawValue] = rule
        } else {
            all[section.rawValue] = nil
        }
        rules = all.isEmpty ? nil : all
    }

    /// Whether the section's rule lets it show now (hidden or not, density aside).
    public func shows(_ section: TodaySection, _ context: ShowContext) -> Bool {
        (rule(for: section) ?? .always).shows(section, in: context)
    }
}

extension Density {
    /// The sections Today shows now: `sections(_:)` with the rules applied. Without rules it is exactly
    /// `sections(_:)`. Detailed and Hyperdetail ignore rules, not the switches. The retired Machines section never shows. Minimal shows the day
    /// and Home by their rules, plus every visible section set to "When it needs me" while it needs me.
    public func sections(_ layout: TodayLayout, _ context: ShowContext) -> [TodaySection] {
        switch self {
        case .overkill, .hyperdetail:
            return layout.visible.filter(\.isOnToday)
        case .standard:
            return layout.visible.filter { $0.isOnToday && layout.shows($0, context) }
        case .calm:
            return layout.visible.filter { s in
                guard s.isOnToday else { return false }
                if s == .day || s == .home { return layout.shows(s, context) }
                return layout.rule(for: s) == .needsMe && context.needsMe.contains(s)
            }
        }
    }

    /// The sections this density would show but a time or presence rule hides now, for "Hidden now: Deals
    /// (Evenings) · Show". "When it needs me" isn't listed: such a section is there as soon as it has something.
    public func hiddenNow(_ layout: TodayLayout, _ context: ShowContext) -> [TodaySection] {
        let candidates: [TodaySection] = switch self {
        case .overkill, .hyperdetail: []
        case .standard: layout.visible.filter(\.isOnToday)
        case .calm: layout.visible.filter { $0 == .day || $0 == .home }
        }
        return candidates.filter { s in
            guard let rule = layout.rule(for: s), rule != .needsMe else { return false }
            return !rule.shows(s, in: context)
        }
    }
}

// MARK: - From the app's state

extension AppModel {
    /// The context Today checks its rules against: the selected server's state and deals, the pinned Home tiles
    /// among `homeEntities` (Home Assistant states the caller holds), and the clock it is given.
    public func showContext(now: Date, calendar: Calendar = .current, homeEntities: [HAEntity] = [],
                            presence: Presence? = nil, shownAnyway: Set<TodaySection> = []) -> ShowContext {
        let pinned = Set(homeAssistant?.pinnedEntities ?? [])
        let status = selectedStatus   // empty when no server is selected
        let needs = TodaySection.needingMe(state: status.snapshot?.state,
                                           home: homeEntities.filter { pinned.contains($0.entityID) },
                                           deals: status.deals?.chosen(settings.dealCategories), now: now)
        return ShowContext(now: now, calendar: calendar, needsMe: needs, presence: presence, shownAnyway: shownAnyway)
    }
}
