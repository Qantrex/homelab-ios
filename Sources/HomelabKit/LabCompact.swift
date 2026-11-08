import Foundation

/// Minimal makes Lab fit about one screen too (owner review 2026-11-08, row 41; Today's Minimal already does). Lab keeps
/// its header and every problem, shows one short line per host, and folds each server card and the services to a title
/// with a count that opens on a tap. Standard, Detailed and Hyperdetail keep the full Lab. The words are decided here,
/// pure and tested on Linux; `LabView` only draws them.
public enum LabCompact {
    /// Whether Lab is compact at this detail level: Minimal only.
    public static func applies(_ density: Density) -> Bool { density == .calm }

    /// What a host's one line says next to its name: why it is not fine ("down", "asleep", "disk 93%", "78°C", "busy",
    /// a flag in words), else "up". Unknown reachability: "unknown".
    public static func hostNote(_ host: Host) -> String {
        let health = HostHealth(host)
        if health == .asleep { return "asleep" }
        switch host.reachable {
        case nil: return "unknown"
        case false?: return "down"
        case true?: break
        }
        if let worst = Format.worstDisk(host.disks), worst.percent >= 85 { return "disk \(worst.percent)%" }
        if let temp = host.temp, temp >= 70 { return Format.temperature(temp) }
        if let load = host.load, let cores = host.cpuCount, load > Double(cores) { return "busy" }
        if health == .warning || health == .problem, let flag = host.flags.first(where: { $0 != "asleep" }) { return Format.flag(flag) }
        return "up"
    }

    /// A folded server card: its title and how many rows it holds (nil when it has none, or a text only).
    public static func cardFold(_ card: Card) -> (title: String, count: String?) {
        let title = (card.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? card.id : title, card.items.isEmpty ? nil : String(card.items.count))
    }

    /// The services' folded line: "Services" and how many.
    public static func servicesFold(_ count: Int) -> (title: String, count: String?) { ("Services", count > 0 ? String(count) : nil) }
}
