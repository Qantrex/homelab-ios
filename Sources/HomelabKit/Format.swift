import Foundation

/// Text formatting shared by the app and the widget. Pure functions, so they are tested on Linux.
public enum Format {
    /// "just now", "2 min ago", "3 h ago", "yesterday", "4 d ago".
    public static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let s = now.timeIntervalSince(date)
        if s < -60 { return "in the future" }
        if s < 45 { return "just now" }
        if s < 3600 { return "\(max(Int((s / 60).rounded()), 1)) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        if s < 2 * 86400 { return "yesterday" }
        return "\(Int(s / 86400)) d ago"
    }

    /// Overkill: the exact time ("23:41:07", with the day when it isn't today) and the age; else just the age.
    public static func when(_ date: Date?, exact: Bool, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard exact, let date else { return age(date, now: now) }
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        let clock = String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        if calendar.isDate(date, inSameDayAs: now) { return "\(clock) (\(age(date, now: now)))" }
        let d = calendar.dateComponents([.day, .month], from: date)
        return String(format: "%02d.%02d. ", d.day ?? 0, d.month ?? 0) + clock + " (\(age(date, now: now)))"
    }

    /// Time to the next stop of the day: "now", "in 26 min", "in 1 h", "in 2 h 5 min".
    public static func countdown(minutes: Int) -> String {
        guard minutes > 0 else { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "in \(h) h" : "in \(h) h \(m) min"
    }

    /// How close a `due` is, for its colour: past (love), under 24 h ahead or today (gold), later (plain).
    public enum Level: String, Sendable, Equatable, CaseIterable {
        case past, soon, later
    }

    /// The start of the calendar day a day-only due names. It was local midnight when it was read; the nearest
    /// midnight keeps it on that day after a time-zone change of up to 12 h (the cache stores the day itself).
    public static func dueDay(_ due: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: due.addingTimeInterval(12 * 3600))
    }

    /// A day-only due as the server writes it: "2026-11-09".
    public static func dayString(_ due: Date, calendar: Calendar = .current) -> String {
        let d = calendar.dateComponents([.year, .month, .day], from: dueDay(due, calendar: calendar))
        return String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }

    /// A countdown card's big value: "40 min", "5 h", "2 d", "today" (a day-only due on today), "3 h ago",
    /// "3 d ago". Whole days count calendar days; hours and minutes are rounded down, but a due still ahead never
    /// shows "0 min". `dayOnly`: `due` names a day (`Card.Item.dueIsDay`), not a time.
    public static func countdown(_ due: Date, dayOnly: Bool, now: Date = Date(),
                                 calendar: Calendar = .current) -> (text: String, level: Level) {
        let start = dayOnly ? dueDay(due, calendar: calendar) : calendar.startOfDay(for: due)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: start).day ?? 0
        if dayOnly {
            if days == 0 { return ("today", .soon) }
            return days > 0 ? ("\(days) d", .later) : ("\(-days) d ago", .past)
        }
        let s = due.timeIntervalSince(now)
        if s >= 0 {
            if s < 3600 { return ("\(max(Int(s / 60), 1)) min", .soon) }
            if s < 86400 { return ("\(Int(s / 3600)) h", .soon) }
            return ("\(max(days, 1)) d", .later)
        }
        let ago = -s
        if ago < 3600 { return ("\(max(Int(ago / 60), 1)) min ago", .past) }
        if ago < 86400 { return ("\(Int(ago / 3600)) h ago", .past) }
        return ("\(max(-days, 1)) d ago", .past)
    }

    /// A checklist item's due, short: "today", "today 18:00", "tomorrow 09:00", "Mon", "Mon 18:00" within a week,
    /// "12.11." or "12.11. 18:00" further out, "yesterday" / "3 d ago" when it's past (with the time on the same day).
    /// `dayOnly`: `due` names a day, shown without a clock.
    public static func due(_ due: Date, dayOnly: Bool, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day0 = dayOnly ? dueDay(due, calendar: calendar) : due
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: day0)).day ?? 0
        let t = calendar.dateComponents([.hour, .minute], from: due)
        let clock = dayOnly ? nil : String(format: "%02d:%02d", t.hour ?? 0, t.minute ?? 0)
        let day: String
        switch days {
        case 0: day = "today"
        case 1: day = "tomorrow"
        case -1: day = "yesterday"
        case 2...6:
            let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            day = weekdays[(calendar.component(.weekday, from: day0) - 1 + 7) % 7]
        case ..<(-1): return "\(-days) d ago"
        default:
            let d = calendar.dateComponents([.day, .month], from: day0)
            day = String(format: "%02d.%02d.", d.day ?? 0, d.month ?? 0)
        }
        return clock.map { "\(day) \($0)" } ?? day
    }

    /// The number inside a progress ring, 0…100. Rounded down, so 100 only shows when it's really done.
    public static func ringPercent(_ progress: Double) -> Int {
        guard progress.isFinite else { return 0 }
        return Int((min(max(progress, 0), 1) * 100 + 1e-9).rounded(.down))
    }

    /// Same default as the reference server's `temp_warning`.
    public static let hotCelsius = 80.0

    public static func percent(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "–"
    }

    public static func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return "–" }
        return "\(Int(celsius.rounded())) °C"
    }

    public static func load(_ load: Double?) -> String {
        guard let load else { return "–" }
        return String(format: "%.2f", load)
    }

    /// Load as a share of the cores, 0…1+, for gauges. Without a core count, 1 core.
    public static func loadShare(_ load: Double?, cores: Int?) -> Double? {
        guard let load else { return nil }
        return load / Double(max(cores ?? 1, 1))
    }

    public static func containers(up: Int?, total: Int?) -> String {
        switch (up, total) {
        case let (u?, t?): "\(u)/\(t)"
        case let (u?, nil): "\(u)"
        default: "–"
        }
    }

    /// The fullest disk: (mount, percent).
    public static func worstDisk(_ disks: [String: Int]) -> (mount: String, percent: Int)? {
        disks.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }.map { ($0.key, $0.value) }
    }

    /// "Under-voltage now", "Throttled", … for known flags; unknown ones are shown as they are, prettified.
    public static func flag(_ flag: String) -> String {
        switch flag {
        case "undervoltage_now": "Under-voltage now"
        case "throttled_now": "Throttled now"
        case "undervoltage_since_boot": "Under-voltage since boot"
        case "asleep": "Asleep"
        default: flag.replacingOccurrences(of: "_", with: " ").capitalizedFirst
        }
    }

    /// Flags that mean something is wrong right now (vs. informational).
    public static func isAlarming(flag: String) -> Bool {
        ["undervoltage_now", "throttled_now"].contains(flag)
    }

    /// Backup line: "ok 4 h ago", "failed yesterday".
    public static func backup(last: String?, result: String?, now: Date = Date()) -> String? {
        guard last != nil || result != nil else { return nil }
        let when = last.flatMap { ServerDate.parse($0) }.map { age($0, now: now) } ?? last
        let what = result.map { ["success", "ok", "0"].contains($0.lowercased()) ? "ok" : $0 }
        return [what, when].compactMap { $0 }.joined(separator: " ")
    }

    public static func backupFailed(_ result: String?) -> Bool {
        guard let r = result?.lowercased() else { return false }
        return !["success", "ok", "0", "running", "active"].contains(r)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// The level of one host, for its colour: an unreachable host or an alarming flag is a problem, hot or full is a warning.
public enum HostHealth: Sendable, Equatable {
    case ok, warning, problem, asleep, unknown

    public init(_ host: Host) {
        if host.flags.contains("asleep") { self = .asleep; return }
        guard let reachable = host.reachable else { self = .unknown; return }
        if !reachable { self = .problem; return }
        if host.flags.contains(where: Format.isAlarming) { self = .problem; return }
        if let up = host.containersUp, let total = host.containersTotal, up < total { self = .warning; return }
        if let d = Format.worstDisk(host.disks), d.percent >= 90 { self = .warning; return }
        if let t = host.temp, t >= Format.hotCelsius { self = .warning; return }
        if let m = host.memPct, m >= 95 { self = .warning; return }
        if Format.backupFailed(host.backupResult) { self = .warning; return }
        if !host.flags.isEmpty { self = .warning; return }
        self = .ok
    }
}
