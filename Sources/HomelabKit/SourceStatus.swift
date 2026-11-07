import Foundation

/// How one source of a Homelab Bridge is doing: an entry of the optional `sources` in /info
/// (docs/API.md#source-status-sources-in-info, `SourceStatus` in server/openapi.yaml). Diagnostics lists them
/// (MODULAR.md M2.4). Read as leniently as the rest of /info: an entry without a name is dropped, everything else
/// has a fallback.
public struct SourceStatus: Codable, Sendable, Equatable {
    public enum State: String, Sendable {
        /// The last run worked.
        case ok
        /// The last run failed; `error` says why.
        case failing
        /// No run has finished yet (the bridge just started).
        case never
        /// Missing, or a state this app doesn't know.
        case unknown
    }

    public var name: String
    public var type: String?
    public var state: State
    /// Only meant while failing: "401", "timeout". One line, at most 120 characters.
    public var error: String?
    /// When the last run finished, good or not.
    public var checked: Date?
    /// When the last good run finished; kept while the source fails.
    public var lastOK: Date?
    /// The source skips the TLS certificate check (self-signed Proxmox or TrueNAS): shown as a warning.
    public var insecure: Bool

    public init(name: String, type: String? = nil, state: State, error: String? = nil, checked: Date? = nil,
                lastOK: Date? = nil, insecure: Bool = false) {
        self.name = name; self.type = type; self.state = state; self.error = error
        self.checked = checked; self.lastOK = lastOK; self.insecure = insecure
    }

    enum CodingKeys: String, CodingKey {
        case name, type, state, error, checked, insecure
        case lastOK = "last_ok"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = c.text(.name) else {
            throw DecodingError.keyNotFound(CodingKeys.name, .init(codingPath: c.codingPath, debugDescription: "no name"))
        }
        self.name = Self.line(name, max: 80)
        type = c.text(.type).map { Self.line($0, max: 40) }
        state = c.text(.state).flatMap { State(rawValue: $0.lowercased()) } ?? .unknown
        error = c.text(.error).map { Self.line($0, max: 120) }
        checked = c.date(.checked)
        lastOK = c.date(.lastOK)
        insecure = c.bool(.insecure) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encode(state.rawValue, forKey: .state)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(checked.map(ServerDate.string), forKey: .checked)
        try c.encodeIfPresent(lastOK.map(ServerDate.string), forKey: .lastOK)
        if insecure { try c.encode(true, forKey: .insecure) }
    }

    /// The first line, cut to `max` characters: a server's text never makes a row grow without end.
    static func line(_ text: String, max: Int) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return first.count > max ? String(first.prefix(max - 1)) + "…" : first
    }

    // MARK: Words (Diagnostics and its Copy report)

    /// The state in words: "ok", "failing: 401", "not yet", "unknown".
    public var stateText: String {
        switch state {
        case .ok: "ok"
        case .failing: error.map { "failing: \($0)" } ?? "failing"
        case .never: "not yet"
        case .unknown: "unknown"
        }
    }

    /// The line under the state: "checked 2 min ago" while ok, "last ok 3 h ago" (or "never ok yet") while failing,
    /// "no run has finished yet" before the first run. Nil when there is nothing to say.
    public func timeText(now: Date = Date()) -> String? {
        switch state {
        case .ok: checked.map { "checked \(Format.age($0, now: now))" }
        case .failing: lastOK.map { "last ok \(Format.age($0, now: now))" } ?? "never ok yet"
        case .never: "no run has finished yet"
        case .unknown: lastOK.map { "last ok \(Format.age($0, now: now))" }
        }
    }

    /// What the warning under an insecure source says.
    public static let insecureText = "Certificate not checked (insecure)"

    /// One line of Diagnostics' Copy report: "source Kuma (uptime-kuma): failing: 401, last ok 2 h ago, insecure".
    /// The caller masks host names (`Redact.hosts`) over the whole report.
    public func reportLine(now: Date = Date()) -> String {
        var parts = [stateText]
        if let t = timeText(now: now) { parts.append(t) }
        if insecure { parts.append("insecure") }
        return "source \(name) (\(type ?? "?")): " + parts.joined(separator: ", ")
    }
}
