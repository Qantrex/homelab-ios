import Foundation

/// Custom names for the pinned Home tiles on Today: short, set in the app only (Home Assistant keeps its names, so
/// voice commands and the HA app don't change). Empty means Home Assistant's friendly name.
public enum TileName {
    public static let maxLength = 24
    public static let maxPins = 12

    /// Trimmed, newlines and control characters turned into spaces, runs of spaces collapsed, at most 24
    /// characters. nil when nothing is left (the tile then shows HA's name).
    public static func clean(_ raw: String) -> String? {
        let spaced = String(raw.unicodeScalars.map { $0.properties.generalCategory == .control || $0.properties.isWhitespace ? " " : Character($0) })
        let collapsed = spaced.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let cut = String(collapsed.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? nil : cut
    }

    /// Keeps only cleaned, non-empty names of pinned entities.
    public static func cleaned(_ names: [String: String], pinned: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for id in pinned { if let n = names[id].flatMap(clean) { out[id] = n } }
        return out
    }

    /// An entity id as `-HomelabPins` accepts it.
    static func isEntityID(_ s: String) -> Bool {
        s.wholeMatch(of: /[a-z_]{1,32}\.[a-z0-9_]{1,96}/) != nil
    }

    /// `light.a=Living room,script.b=Alarm off`. Names can't contain a comma. A bad id, a missing `=`, an empty or
    /// control-character name, or more than 12 entries drops the whole argument (nil).
    static func parse(_ s: String) -> [String: String]? {
        let parts = s.split(separator: ",", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= maxPins else { return nil }
        var out: [String: String] = [:]
        for part in parts {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2, isEntityID(String(kv[0])), let name = clean(String(kv[1])),
                  !kv[1].unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
            out[String(kv[0])] = name
        }
        return out
    }

    /// What the tile shows: the custom name, else HA's.
    public static func shown(custom: String?, haName: String) -> String { custom ?? haName }

    /// What VoiceOver says: the custom name plus HA's name when they differ, so the tile stays understandable.
    public static func spoken(custom: String?, haName: String) -> String {
        guard let custom, custom.caseInsensitiveCompare(haName) != .orderedSame else { return haName }
        return "\(custom), \(haName)"
    }
}
