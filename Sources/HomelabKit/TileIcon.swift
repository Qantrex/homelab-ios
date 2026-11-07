import Foundation

/// Custom icons for the pinned Home tiles on Today, chosen from a short fixed list of SF Symbols (the app only shows
/// symbols from this list, so a bad setting or launch argument can't show an empty icon). No entry = the icon by
/// Home Assistant domain.
public enum TileIcon {
    public struct Choice: Sendable, Equatable, Identifiable {
        /// The SF Symbol, outline form.
        public let symbol: String
        /// The filled form for a tile that is on, or nil when the outline is used for both.
        public let filled: String?
        /// The word in the picker.
        public let label: String
        public var id: String { symbol }
    }

    public static let choices: [Choice] = [
        Choice(symbol: "lightbulb", filled: "lightbulb.fill", label: "Bulb"),
        Choice(symbol: "lamp.floor", filled: "lamp.floor.fill", label: "Floor lamp"),
        Choice(symbol: "lamp.table", filled: "lamp.table.fill", label: "Table lamp"),
        Choice(symbol: "lamp.ceiling", filled: "lamp.ceiling.fill", label: "Ceiling light"),
        Choice(symbol: "sofa", filled: "sofa.fill", label: "Relax"),
        Choice(symbol: "sparkles", filled: nil, label: "Party"),
        Choice(symbol: "book", filled: "book.fill", label: "Reading"),
        Choice(symbol: "moon.stars", filled: "moon.stars.fill", label: "Night"),
        Choice(symbol: "bed.double", filled: "bed.double.fill", label: "Bed"),
        Choice(symbol: "sun.horizon", filled: "sun.horizon.fill", label: "Wake-up"),
        Choice(symbol: "alarm", filled: "alarm.fill", label: "Alarm"),
        Choice(symbol: "music.note", filled: nil, label: "Music"),
        Choice(symbol: "speaker.slash", filled: "speaker.slash.fill", label: "Silence"),
        Choice(symbol: "radio", filled: "radio.fill", label: "Radio"),
        Choice(symbol: "tv", filled: "tv.fill", label: "TV"),
        Choice(symbol: "power", filled: nil, label: "Power"),
    ]

    public static func choice(_ symbol: String) -> Choice? { choices.first { $0.symbol == symbol } }

    /// The symbol to draw: the filled form when the tile is on and one exists.
    public static func shown(_ symbol: String, on: Bool) -> String? {
        guard let c = choice(symbol) else { return nil }
        return on ? (c.filled ?? c.symbol) : c.symbol
    }

    /// Keeps only known symbols of pinned entities.
    public static func cleaned(_ icons: [String: String], pinned: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for id in pinned { if let s = icons[id], choice(s) != nil { out[id] = s } }
        return out
    }

    /// `light.a=lamp.floor,script.b=moon.stars`. A bad id, a symbol not in `choices` or more than 12 entries drops
    /// the whole argument (nil).
    static func parse(_ s: String) -> [String: String]? {
        let parts = s.split(separator: ",", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= TileName.maxPins else { return nil }
        var out: [String: String] = [:]
        for part in parts {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2, TileName.isEntityID(String(kv[0])), choice(String(kv[1])) != nil else { return nil }
            out[String(kv[0])] = String(kv[1])
        }
        return out
    }
}
