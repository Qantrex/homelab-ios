import Foundation

// What the rule editor (Settings → Advanced → Sections) and Today's "Hidden now" line need from the show rules
// (docs/plans/MODULAR.md, M3.2). Pure where it can be; the views only show these words.

/// One choice in a section's rule sheet.
public enum RuleOption: Hashable, Sendable, Identifiable {
    /// Machines without a rule: it shows in Detailed only (as before rules).
    case overkillOnly
    case always
    case needsMe
    /// One of `TimeWindow.named`, by its index.
    case named(Int)
    /// Own times and days.
    case custom
    case atHome
    case away

    public var id: String {
        switch self {
        case .overkillOnly: "overkillOnly"
        case .always: "always"
        case .needsMe: "needsMe"
        case .named(let i): "named-\(i)"
        case .custom: "custom"
        case .atHome: "atHome"
        case .away: "away"
        }
    }

    /// What the sheet offers for `section`, from `ShowRule.kinds` (presence only once it's set up).
    public static func options(for section: TodaySection, presence: Bool) -> [RuleOption] {
        options(for: section, kinds: ShowRule.kinds(for: section, presence: presence))
    }

    /// What the sheet offers for `section` from the kinds the app allows (`AppModel.ruleKinds(for:)`).
    public static func options(for section: TodaySection, kinds: [ShowRule.Kind]) -> [RuleOption] {
        var out: [RuleOption] = section == .machines ? [.overkillOnly] : []
        for kind in kinds {
            switch kind {
            case .always: out.append(.always)
            case .needsMe: out.append(.needsMe)
            case .times: out += TimeWindow.named.indices.map { .named($0) } + [.custom]
            case .atHome: out.append(.atHome)
            case .away: out.append(.away)
            }
        }
        return out
    }

    /// The option a stored rule shows as: a window with a name is that name, any other window Custom.
    public static func current(_ rule: ShowRule?, for section: TodaySection) -> RuleOption {
        switch rule {
        case nil: section == .machines ? .overkillOnly : .always
        case .always: .always
        case .needsMe: .needsMe
        case .times(let w): TimeWindow.named.firstIndex { $0.window == w }.map { .named($0) } ?? .custom
        case .atHome: .atHome
        case .away: .away
        }
    }

    /// The rule this option sets. Custom keeps the window of `current` (a named one included), else starts at the
    /// evening, 18–22 every day.
    public func rule(from current: ShowRule?) -> ShowRule? {
        switch self {
        case .overkillOnly: nil
        case .always: .always
        case .needsMe: .needsMe
        case .named(let i): .times(TimeWindow.named[i].window)
        case .custom:
            if case .times(let w) = current { .times(w) } else { .times(TimeWindow(from: 18 * 60, to: 22 * 60)) }
        case .atHome: .atHome
        case .away: .away
        }
    }

    public var title: String {
        switch self {
        case .overkillOnly: "Only in Detailed"
        case .always: "Always"
        case .needsMe: "When it needs me"
        case .named(let i): TimeWindow.named[i].name
        case .custom: "Custom"
        case .atHome: "At home"
        case .away: "Away"
        }
    }

    /// The meta line under the title in the sheet; nil = none.
    public func detail(for section: TodaySection) -> String? {
        switch self {
        case .overkillOnly: "Standard and Minimal leave it out"
        case .always: nil
        case .needsMe: section.needsMeWords
        case .named(let i): ["5–11", "11–18", "18–24", "Monday to Friday", "Saturday and Sunday"][i]
        case .custom: nil
        case .atHome, .away: "From Home Assistant"
        }
    }
}

/// What the rule sheet holds while it is open: the rule, and whether Custom is the chosen option. Custom is its own
/// state, not read back from the window: choosing Custom while Evenings is chosen keeps 18–24 to start from and shows
/// the pickers, and Custom edited into a named window's times (18 to 0:00) stays Custom. Opened again, a stored
/// window shows as its name (`RuleOption.current`).
public struct RuleChoice: Equatable, Sendable {
    public let section: TodaySection
    public private(set) var rule: ShowRule?
    public private(set) var isCustom: Bool

    public init(_ rule: ShowRule?, for section: TodaySection) {
        self.section = section
        self.rule = rule
        isCustom = RuleOption.current(rule, for: section) == .custom
    }

    /// The option with the checkmark.
    public var chosen: RuleOption { isCustom ? .custom : RuleOption.current(rule, for: section) }

    /// An option tapped.
    public mutating func choose(_ option: RuleOption) {
        rule = option.rule(from: rule)
        isCustom = option == .custom
    }

    /// The window the pickers and day chips edit, while Custom is chosen.
    public var custom: TimeWindow? {
        if isCustom, case .times(let w) = rule { return w }
        return nil
    }

    /// A picker or day chip changed the Custom window (ignored unless Custom is chosen).
    public mutating func edit(_ window: TimeWindow) {
        guard isCustom else { return }
        rule = .times(window)
    }

    /// The meta line under Custom while it is chosen: its times, also when they match a named window ("18–24").
    public func customWords(calendar: Calendar) -> String? {
        custom?.words(calendar: calendar, named: false)
    }
}

extension TodaySection {
    /// What "When it needs me" means for this section, in the rule sheet (`needsMe(state:home:deals:now:)`).
    public var needsMeWords: String? {
        switch self {
        case .day: nil
        case .waiting: "While an action waits for you"
        case .deals: "While there is a new deal to act on"
        case .home: "While a pinned tile is unavailable"
        case .cards: "While a card shows a problem"
        case .report: "While the last report is a problem"
        case .machines: "While a machine is down or has a warning"
        }
    }

    /// The section's name in a sentence ("Hidden now: Machines (evenings)").
    public var shortTitle: String { self == .machines ? "Machines" : title }
}

extension TimeWindow {
    /// The minutes after midnight of `date`, for a time picker.
    public static func minutes(of date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// `minutes` on the day of `day` (24:00 is 0:00). On the day the clocks go forward a time in the gap moves on
    /// (2:30 becomes 3:30): a time picker uses `pickerDate(minutes:calendar:)`.
    public static func date(minutes: Int, on day: Date, calendar: Calendar) -> Date {
        let m = ((minutes % 1440) + 1440) % 1440
        return calendar.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day) ?? day
    }

    /// `minutes` as a time picker's date (24:00 shows as 0:00), on a fixed day without a clock change (15 January
    /// 2001), so every time of the day reads back as itself whatever today is: 2:30 stays 2:30 on the day the clocks
    /// go forward. Read back with `minutes(of:calendar:)`.
    public static func pickerDate(minutes: Int, calendar: Calendar) -> Date {
        let day = calendar.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: 12))
            ?? Date(timeIntervalSinceReferenceDate: 14 * 86_400 + 12 * 3600)
        return date(minutes: minutes, on: day, calendar: calendar)
    }

    /// With a new start from a time picker.
    public func with(from minutes: Int) -> TimeWindow { TimeWindow(from: minutes, to: to, days: days) }

    /// With a new end from a time picker: 0:00 is midnight at the end of the day (24), so "18 to 0:00" is Evenings.
    public func with(to minutes: Int) -> TimeWindow {
        TimeWindow(from: from, to: minutes == 0 ? 1440 : minutes, days: days)
    }

    /// Whether the window starts on `weekday` (1 = Sunday … 7 = Saturday).
    public func includes(day weekday: Int) -> Bool { days?.contains(weekday) ?? true }

    /// A day chip tapped: on or off. The last day can't be turned off (no day would mean every day).
    public func toggling(day weekday: Int) -> TimeWindow {
        var on = Set(days ?? Array(1...7))
        if on.contains(weekday) {
            guard on.count > 1 else { return self }
            on.remove(weekday)
        } else {
            on.insert(weekday)
        }
        return TimeWindow(from: from, to: to, days: Array(on))
    }

    /// The weekdays Monday first, for the day chips.
    public static let mondayFirst = [2, 3, 4, 5, 6, 7, 1]
}

extension ShowRule {
    /// The rule inside a sentence: "evenings", "weekdays 6–10", "at home"; weekday names stay as the calendar
    /// writes them ("Sat, Sun 9–12").
    public func inlineWords(calendar: Calendar = .current) -> String {
        let w = words(calendar: calendar)
        let ours = TimeWindow.named.map(\.name) + ["Always", "When it needs me", "At home", "Away", "All day"]
        guard ours.contains(where: { w.hasPrefix($0) }), let first = w.first else { return w }
        return first.lowercased() + w.dropFirst()
    }
}

extension TodayLayout {
    /// The rule of a section in words, for the sections editor: "Always", "Evenings", "Only in Detailed" (Machines
    /// without a rule).
    public func ruleWords(for section: TodaySection, calendar: Calendar = .current) -> String {
        guard let rule = rule(for: section) else { return section == .machines ? "Only in Detailed" : "Always" }
        return rule.words(calendar: calendar)
    }
}

/// Today's line under the sections while a rule hides something: "Hidden now: Deals (evenings)".
public enum HiddenNow {
    /// Sections with the same rule share it: "Hidden now: Deals and Cards (evenings), Last report (weekdays)".
    /// Nil when nothing is hidden.
    public static func text(_ sections: [TodaySection], layout: TodayLayout, calendar: Calendar = .current) -> String? {
        var groups: [(words: String, names: [String])] = []
        for s in sections {
            let words = (layout.rule(for: s) ?? .always).inlineWords(calendar: calendar)
            if let i = groups.firstIndex(where: { $0.words == words }) {
                groups[i].names.append(s.shortTitle)
            } else {
                groups.append((words, [s.shortTitle]))
            }
        }
        guard !groups.isEmpty else { return nil }
        let parts = groups.map { g in "\(ListWords.join(g.names)) (\(g.words))" }
        return "Hidden now: " + parts.joined(separator: ", ")
    }

    /// For VoiceOver: "18–22" read as "18 to 22".
    public static func spoken(_ text: String) -> String { text.replacingOccurrences(of: "–", with: " to ") }
}

/// "A", "A and B", "A, B and C".
enum ListWords {
    static func join(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}

// MARK: - From the app's state

extension AppModel {
    /// The context Today checks its rules against: `showContext` with where I am (`presence(in:fetched:)`, nil when
    /// not set up), this run's "Show" taps (`shownAnyway`), and the clock time of `-HomelabTime` (screenshots) in place
    /// of `now`'s. Needs-me checks keep the real `now`.
    public func todayContext(now: Date, calendar: Calendar = .current, homeEntities: [HAEntity] = [],
                             presence: Presence? = nil) -> ShowContext {
        var c = showContext(now: now, calendar: calendar, homeEntities: homeEntities, presence: presence,
                            shownAnyway: shownAnyway)
        if let m = fixedTime { c.now = TimeWindow.date(minutes: m, on: now, calendar: calendar) }
        return c
    }

    /// Whether Today would show anything for `section` now (what `TodayView.section(for:)` checks). A rule hiding an
    /// empty section isn't worth a "Hidden now".
    public func todayHasContent(_ section: TodaySection, now: Date) -> Bool {
        let status = selectedStatus
        let state = status.snapshot?.state
        let server = selected != nil
        switch section {
        case .day: return state?.dayCard != nil
        case .waiting: return server && !(state?.pending.isEmpty ?? true)
        case .deals: return server && !(status.deals?.freshAct(now: now).isEmpty ?? true)
        case .home: return homeAssistant != nil
        case .cards:
            let day = state?.dayCard?.id
            return server && (state?.cards.contains { $0.id != day && $0.place != .lab } ?? false)
        case .report: return server && !(state?.lastMessage?.text.isEmpty ?? true)
        case .machines: return server && !(state?.hosts.isEmpty ?? true)
        }
    }

    /// The sections a rule hides from Today now that would have something to show, for "Hidden now".
    public func hiddenOnToday(_ context: ShowContext, now: Date) -> [TodaySection] {
        settings.todayDensity.hiddenNow(settings.todayLayout, context).filter { todayHasContent($0, now: now) }
    }

    /// "Show" on the "Hidden now" line: these sections pass their rules until the app closes (never stored).
    public func showAnyway(_ sections: [TodaySection]) {
        shownAnyway.formUnion(sections)
    }

    /// Whether any server could fill the section: Home tiles need a Home Assistant, the rest a Homelab server. The
    /// sections editor says "Not on your servers" otherwise.
    public func serversCanFill(_ section: TodaySection) -> Bool {
        section == .home ? homeAssistant != nil : selected != nil
    }
}

// MARK: - Launch arguments

/// `-HomelabRules` and `-HomelabTime`, for screenshots and device tests of a rule.
enum ShowRuleArgument {
    /// "deals=evenings,cards=18:00-22:00,machines=always,report=needs-me": a section (its stored name) and a rule:
    /// `always`, `needs-me`, a window's name (`mornings` … `weekends`), `at-home`, `away`, `HH:MM-HH:MM` (every day),
    /// or `none` (no rule). Anything odd drops the whole argument.
    static func parse(_ text: String) -> [(TodaySection, ShowRule?)]? {
        guard text.count <= 400 else { return nil }
        var out: [(TodaySection, ShowRule?)] = []
        for pair in text.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard kv.count == 2, let section = TodaySection(rawValue: kv[0]) else { return nil }
            let rule: ShowRule?
            switch kv[1] {
            case "none": rule = nil
            case "always": rule = .always
            case "needs-me", "needsme": rule = .needsMe
            case "at-home", "athome": rule = .atHome
            case "away": rule = .away
            case let v:
                if let named = TimeWindow.named.first(where: { $0.name.lowercased() == v }) {
                    rule = .times(named.window)
                } else {
                    let ends = v.split(separator: "-").map(String.init)
                    guard ends.count == 2, let from = minutes(ends[0]), let to = minutes(ends[1]) else { return nil }
                    rule = .times(TimeWindow(from: from, to: to == 0 ? 1440 : to))
                }
            }
            out.append((section, rule))
        }
        return out.isEmpty ? nil : out
    }

    /// "14:00", "9:30", "24:00" in minutes after midnight; nil for anything else.
    static func minutes(_ text: String) -> Int? {
        guard let m = text.wholeMatch(of: /([0-9]{1,2}):([0-9]{2})/), let h = Int(m.1), let min = Int(m.2),
              min < 60, h < 24 || (h == 24 && min == 0) else { return nil }
        return h * 60 + min
    }
}
