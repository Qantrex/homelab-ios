import Foundation

/// The sections of Today under the mood hero. The hero always stays on top.
public enum TodaySection: String, Codable, CaseIterable, Sendable, Identifiable {
    case day       // the day's numbers (the server's "today" card)
    case waiting   // actions waiting for approval
    case deals     // "act now" deals the server found in the last day (only when there is one)
    case home      // Home Assistant tiles
    case cards     // the other cards (media, downloads, school, …)
    case report    // the last report
    case machines  // retired: Today no longer shows the machines (they are in Lab). Kept so stored layouts decode and save back unchanged.

    public var id: String { rawValue }

    /// Whether Today can show this section. Machines are retired (Lab has them; the headline's "3 of 3 machines up"
    /// still opens Lab): the case stays in the model so old settings files keep their order, hidden list and rules.
    public var isOnToday: Bool { self != .machines }

    public var title: String {
        switch self {
        case .day: "The day in numbers"
        case .waiting: "To approve"
        case .deals: "Deals"
        case .home: "Home tiles"
        case .cards: "Cards"
        case .report: "Last report"
        case .machines: "Machines"
        }
    }
}

/// Which Today sections show, in which order. Stored in the settings; tolerant of old or odd data: unknown names
/// are dropped, missing sections are added at the end (so a new section appears after an update).
public struct TodayLayout: Codable, Equatable, Sendable {
    public var order: [String]
    public var hidden: [String]
    /// When a section shows, by section name (`ShowRule.swift`). Nil or missing = Always; written only once a rule is
    /// set, so older settings save back unchanged. A rule that can't be read (from a newer version) is dropped.
    public var rules: [String: ShowRule]?

    public static let standard = TodayLayout(order: TodaySection.allCases.map(\.rawValue), hidden: [])

    public init(order: [String], hidden: [String], rules: [String: ShowRule]? = nil) {
        self.order = order
        self.hidden = hidden
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey { case order, hidden, rules }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decode([String].self, forKey: .order)
        hidden = try c.decode([String].self, forKey: .hidden)
        rules = ShowRule.lenient(c.lenient([String: Lossy<ShowRule>].self, .rules))
    }

    /// Every section once, in the stored order, new ones last.
    public var sections: [TodaySection] {
        var seen = Set<TodaySection>()
        var out: [TodaySection] = []
        for name in order {
            if let s = TodaySection(rawValue: name), seen.insert(s).inserted { out.append(s) }
        }
        return out + TodaySection.allCases.filter { !seen.contains($0) }
    }

    public var visible: [TodaySection] { sections.filter { !hidden.contains($0.rawValue) } }

    /// The sections Settings lists and Today can draw: `sections` without the retired ones.
    public var listed: [TodaySection] { sections.filter(\.isOnToday) }

    /// How many of the listed sections are on.
    public var listedVisibleCount: Int { visible.filter(\.isOnToday).count }

    public func isVisible(_ s: TodaySection) -> Bool { !hidden.contains(s.rawValue) }

    public mutating func setVisible(_ s: TodaySection, _ on: Bool) {
        hidden.removeAll { $0 == s.rawValue }
        if !on { hidden.append(s.rawValue) }
    }

    /// Like `Array.move(fromOffsets:toOffset:)` (a SwiftUI extension, so not on Linux), on the normalized order.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var list = sections
        let moving = source.sorted().filter { $0 < list.count }.map { list[$0] }
        let before = source.filter { $0 < destination }.count
        for i in source.sorted(by: >) where i < list.count { list.remove(at: i) }
        let at = min(max(destination - before, 0), list.count)
        list.insert(contentsOf: moving, at: at)
        order = list.map(\.rawValue)
    }

    /// `move` for what Settings lists (`listed`): the offsets count the listed sections only, and a retired section
    /// (Machines) keeps its place after them.
    public mutating func moveListed(fromOffsets source: IndexSet, toOffset destination: Int) {
        var list = TodayLayout(order: listed.map(\.rawValue), hidden: [])
        list.move(fromOffsets: source, toOffset: destination)
        order = (list.listed + sections.filter { !$0.isOnToday }).map(\.rawValue)
    }
}

/// How much Today shows. Shown as Minimal / Standard / Detailed / Hyperdetail (owner 2026-11-08, review row 29); the
/// stored words stay `calm` and `overkill` so settings files and goldens do not change. Minimal: the headline, the
/// day's numbers and Home (Lab is compact too). Standard: every section I turned on. Detailed: the same sections, plus
/// every machine's numbers and exact times. A section switched off in Settings stays off at every level.
/// Hyperdetail (owner 2026-11-08): Detailed and then some: nothing folded anywhere, every field the server sent,
/// and (with a personality on) a remark on every fact (`Hyper`, Hyperdetail.swift). The UX is allowed to suffer.
public enum Density: String, Codable, CaseIterable, Sendable, Identifiable {
    case calm, standard, overkill, hyperdetail

    public var id: String { rawValue }

    /// The level a word names, old or new, any case: "calm" or "minimal", "overkill" or "detailed" (the stored and the
    /// shown words), "standard", "hyperdetail". Nil for anything else.
    public static func parse(_ word: String) -> Density? {
        let w = word.trimmingCharacters(in: .whitespaces).lowercased()
        if let d = Density(rawValue: w) { return d }
        switch w {
        case "minimal": return .calm
        case "detailed": return .overkill
        default: return nil
        }
    }

    /// Case-insensitive like `Personality`: a hand-edited "Overkill" reads as overkill ("Detailed" too). A word this
    /// version does not know throws, so the caller's lenient decode drops it (the rest of the file survives).
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = Density.parse(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown detail level \(raw)"))
        }
        self = value
    }

    public var title: String {
        switch self {
        case .calm: "Minimal"
        case .standard: "Standard"
        case .overkill: "Detailed"
        case .hyperdetail: "Hyperdetail"
        }
    }

    /// One short line of what this detail shows (Settings → Today lists all three under the picker).
    public var summary: String {
        switch self {
        case .calm: "The day and your Home tiles. One screen, in Lab too."
        case .standard: "Folds long lists; urgent things stay open. About two screens."
        case .overkill: "The same sections, with more detail in every line."
        case .hyperdetail: "Everything on, unfolded; commentary with a personality. Not recommended."
        }
    }

    /// "Minimal: The day and …", one line per detail, for the footer under the picker.
    public static var explanation: String {
        allCases.map { "\($0.title): \($0.summary)" }.joined(separator: "\n")
    }

    /// The sections Today shows, from my layout (order and hidden ones) and this density.
    public func sections(_ layout: TodayLayout) -> [TodaySection] {
        switch self {
        case .calm: layout.visible.filter { $0 == .day || $0 == .home }
        // A section switched off in Settings stays off at every level (review row 38); Detailed and Hyperdetail only
        // show more of what is on.
        case .standard, .overkill, .hyperdetail: layout.visible.filter(\.isOnToday)
        }
    }

    /// "23:41" instead of "2 min ago" (Hyperdetail says both, with the date).
    public var exactTimes: Bool { atLeastOverkill }

    /// Overkill or Hyperdetail: everything Overkill shows, Hyperdetail on top of it.
    public var atLeastOverkill: Bool { self == .overkill || self == .hyperdetail }

    /// Hyperdetail: no folding, every field, a remark on every fact.
    public var isHyper: Bool { self == .hyperdetail }
}
