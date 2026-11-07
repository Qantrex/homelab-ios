import Foundation

/// Text formatting shared by the app and the widget. Pure functions, so they are tested on Linux.
public enum Format {
    /// "just now", "2 min ago", "3 h ago", "yesterday", "4 d ago".
    public static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let s = now.timeIntervalSince(date)
        if s < -60 { return "in the future" }
        if s < 45 { return "just now" }
        if s < 3600 { return "\(max(Int(clamping: s / 60), 1)) min ago" }
        if s < 86400 { return "\(Int(clamping: s / 3600, rounding: .towardZero)) h ago" }
        if s < 2 * 86400 { return "yesterday" }
        return "\(Int(clamping: s / 86400, rounding: .towardZero)) d ago"
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

    // Spoken twins (VoiceOver): the screen shows "26 min", "3 h ago", "+3"; VoiceOver reads "26 minutes", "3 hours
    // ago", "3 minutes late". English, like the rest of the app's text.

    /// "1 minute", "26 minutes", "1 hour", "3 days".
    public static func spokenAmount(_ n: Int, _ unit: SpokenUnit) -> String {
        "\(n) \(n == 1 ? unit.one : unit.many)"
    }

    public enum SpokenUnit: Sendable {
        case minute, hour, day
        var one: String { switch self { case .minute: "minute"; case .hour: "hour"; case .day: "day" } }
        var many: String { one + "s" }
    }

    /// `age` for VoiceOver: "just now", "2 minutes ago", "3 hours ago", "yesterday", "4 days ago".
    public static func spokenAge(_ date: Date?, now: Date = Date()) -> String {
        spoken(age(date, now: now))
    }

    /// `countdown(minutes:)` for VoiceOver: "now", "in 26 minutes", "in 1 hour", "in 2 hours 5 minutes".
    public static func spokenCountdown(minutes: Int) -> String {
        spoken(countdown(minutes: minutes))
    }

    /// A delay for VoiceOver: "3 minutes late"; "late" without a number.
    public static func spokenDelay(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "late" }
        return spokenAmount(minutes, .minute) + " late"
    }

    /// Any short text with "26 min", "3 h", "2 d", "+3 min" in it, with the units in words: "in 2 h 5 min" →
    /// "in 2 hours 5 minutes", "4 d ago" → "4 days ago", "+3 min" → "3 minutes late". Other text stays as it is.
    public static func spoken(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        let pattern = /(\+)?\b([0-9]+)[ \u{202F}\u{00A0}](min|h|d)\b/
        while let m = rest.firstMatch(of: pattern) {
            out += rest[rest.startIndex..<m.range.lowerBound]
            let n = Int(m.output.2) ?? 0
            let unit: SpokenUnit = switch m.output.3 { case "min": .minute; case "h": .hour; default: .day }
            out += spokenAmount(n, unit) + (m.output.1 != nil ? " late" : "")
            rest = rest[m.range.upperBound...]
        }
        return out + rest
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
            if s < 3600 { return ("\(max(Int(clamping: s / 60, rounding: .towardZero), 1)) min", .soon) }
            if s < 86400 { return ("\(Int(clamping: s / 3600, rounding: .towardZero)) h", .soon) }
            return ("\(max(days, 1)) d", .later)
        }
        let ago = -s
        if ago < 3600 { return ("\(max(Int(clamping: ago / 60, rounding: .towardZero), 1)) min ago", .past) }
        if ago < 86400 { return ("\(Int(clamping: ago / 3600, rounding: .towardZero)) h ago", .past) }
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
        return Int(clamping: min(max(progress, 0), 1) * 100 + 1e-9, in: 0...100, rounding: .down)
    }

    /// Same default as the reference server's `temp_warning`.
    public static let hotCelsius = 80.0

    public static func percent(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "–"
    }

    /// "63°C", without a space: any space (even U+202F) renders as a full cell in the mono font.
    public static func temperature(_ celsius: Double?) -> String {
        guard let celsius, celsius.isFinite else { return "–" }
        return "\(Int(clamping: celsius))°C"
    }

    /// Between a number and its unit ("21.4 kWh"). Percent and degrees go without a space ("71%", "63°C").
    public static func withUnit(_ value: String, _ unit: String) -> String {
        ["%", "°C", "°F", "°"].contains(unit) ? value + unit : value + unitSpace + unit
    }

    /// Narrow no-break space (U+202F) for the other units.
    public static let unitSpace = "\u{202F}"

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

/// The level of one host, for its colour. On its own an unreachable host is a problem; flags, hot or full are warnings.
/// Only the server decides what else is a problem (`init(_:problems:)`).
public enum HostHealth: Sendable, Equatable {
    case ok, warning, problem, asleep, unknown

    public init(_ host: Host) {
        if host.flags.contains("asleep") { self = .asleep; return }
        guard let reachable = host.reachable else { self = .unknown; return }
        if !reachable { self = .problem; return }
        if host.flags.contains(where: Format.isAlarming) { self = .warning; return }
        if let up = host.containersUp, let total = host.containersTotal, up < total { self = .warning; return }
        if let d = Format.worstDisk(host.disks), d.percent >= 90 { self = .warning; return }
        if let t = host.temp, t >= Format.hotCelsius { self = .warning; return }
        if let m = host.memPct, m >= 95 { self = .warning; return }
        if Format.backupFailed(host.backupResult) { self = .warning; return }
        if !host.flags.isEmpty { self = .warning; return }
        self = .ok
    }

    /// The host's own level, raised by the server's problems for it (`Problem.host == host.id`): the worst of both.
    /// A down container is only a warning by the numbers, but when the server calls it a problem, so does the tile.
    public init(_ host: Host, problems: [Problem]) {
        let own = HostHealth(host)
        let mine = problems.filter { $0.host == host.id }
        guard !mine.isEmpty else { self = own; return }
        let listed: HostHealth = mine.contains { $0.severity != .warning } ? .problem : .warning
        self = listed.rank > own.rank ? listed : own
    }

    /// Worse is higher; asleep, unknown and ok are all below a warning.
    private var rank: Int {
        switch self {
        case .problem: 2
        case .warning: 1
        case .ok, .asleep, .unknown: 0
        }
    }
}

public extension HomelabState {
    /// A host's level with this state's problems (`HostHealth.init(_:problems:)`).
    func health(of host: Host) -> HostHealth { HostHealth(host, problems: problems) }
}

/// Text that may leave the phone (Diagnostics → Copy report, pasted into an issue): the tailnet part of `.ts.net`
/// names, Tailscale `100.x` addresses, LAN addresses (RFC 1918, link-local, IPv6 ULA/link-local), every other IPv4
/// address and the server hosts you pass in (`knownHosts`: names that are not `.ts.net`) masked, so a report doesn't
/// give away the tailnet or the home network.
public enum Redact {
    public static func hosts(_ text: String, knownHosts: [String] = []) -> String {
        var out = text
        // Longest first, so "nas.example.lan" goes before "example.lan". Names under .ts.net keep their own rule below.
        for h in knownHosts.map({ $0.trimmingCharacters(in: .whitespaces) })
            .filter({ !$0.isEmpty && !$0.lowercased().hasSuffix(".ts.net") })
            .sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: h, with: "<host>", options: .caseInsensitive)
        }
        out = out.replacing(/\.[A-Za-z0-9-]+\.ts\.net/) { _ in ".<tailnet>.ts.net" }
        out = out.replacing(/\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b/) { _ in "100.x.x.x" }
        out = out.replacing(/\b(10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])|192\.168|169\.254)\.[0-9]{1,3}\.[0-9]{1,3}\b/) { _ in "<lan-ip>" }
        out = out.replacing(/\b(fe[89ab][0-9a-fA-F]|f[cd][0-9a-fA-F]{2}):[0-9a-fA-F:]*[0-9a-fA-F]/) { _ in "<lan-ip6>" }
        out = out.replacing(/\b(?!127\.)[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b/) { _ in "<ip>" }
        return out
    }

    /// The host of a server for the report: `.ts.net` names keep their machine name, anything else is left out.
    public static func host(_ host: String) -> String {
        let masked = hosts(host)
        return masked == host ? "<host>" : masked   // nothing masked by the address rules: a plain name, left out
    }
}
