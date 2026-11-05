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
