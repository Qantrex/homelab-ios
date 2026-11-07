import Foundation

/// Home Assistant at a glance: what Today's headline says when there is no Companion server, only Home Assistant
/// (docs/plans/MODULAR.md, M2.1). "Home." then the facts ("3 lights on · Front door open") and, gold, what doesn't
/// answer ("Bedroom fan unavailable", "2 unavailable"). Pure logic from `GET /api/states`, so it is tested on Linux.
public struct HomeGlance: Equatable, Sendable {
    /// Lights that answer, and how many of them are on.
    public var lights: Int
    public var lightsOn: Int
    /// Doors, windows and garage doors that are open (by name, in Home Assistant's order).
    public var open: [String]
    /// Locks that are unlocked or open.
    public var unlocked: [String]
    /// Things that don't answer: devices people switch (lights, switches, fans, covers, locks, ...) and every
    /// pinned tile. Sensors only count when pinned: a big install has many idle ones.
    public var unavailable: [String]

    /// Domains whose "unavailable" is worth a gold line: a device that can be switched or watched in the room.
    static let devices: Set<String> = ["light", "switch", "fan", "cover", "lock", "climate", "media_player", "vacuum",
                                       "humidifier", "siren", "valve", "water_heater"]
    /// Binary sensor classes that mean an opening.
    static let openings: Set<String> = ["door", "window", "garage_door", "opening"]
    /// Cover classes that are a door (a blind that is open is not news).
    static let doorCovers: Set<String> = ["door", "garage", "gate"]

    public init(lights: Int = 0, lightsOn: Int = 0, open: [String] = [], unlocked: [String] = [], unavailable: [String] = []) {
        self.lights = lights
        self.lightsOn = lightsOn
        self.open = open
        self.unlocked = unlocked
        self.unavailable = unavailable
    }

    /// From Home Assistant's states. `pinned`: the tiles on Today, which count as unavailable in any domain.
    public init(entities: [HAEntity], pinned: [String] = []) {
        let pins = Set(pinned)
        self.init()
        for e in entities {
            let state = e.state.lowercased()
            if state == "unavailable" {
                if Self.devices.contains(e.domain) || pins.contains(e.entityID) { unavailable.append(e.name) }
                continue
            }
            switch e.domain {
            case "light" where e.isAvailable:
                lights += 1
                if state == "on" { lightsOn += 1 }
            case "binary_sensor" where state == "on" && Self.openings.contains(e.deviceClass ?? ""):
                open.append(e.name)
            case "cover" where ["open", "opening"].contains(state) && Self.doorCovers.contains(e.deviceClass ?? ""):
                open.append(e.name)
            case "lock" where ["unlocked", "open", "unlocking", "opening"].contains(state):
                unlocked.append(e.name)
            default:
                break
            }
        }
    }

    /// The facts in a few words each: "3 lights on", "All lights off", "Front door open", "2 locks unlocked".
    public var facts: [String] {
        var out: [String] = []
        if lights > 0 {
            out.append(lightsOn == 0 ? "All lights off" : lightsOn == 1 ? "1 light on" : "\(lightsOn) lights on")
        }
        switch open.count {
        case 0: break
        case 1: out.append("\(open[0]) open")
        default: out.append("\(open.count) doors and windows open")
        }
        switch unlocked.count {
        case 0: break
        case 1: out.append("\(unlocked[0]) unlocked")
        default: out.append("\(unlocked.count) locks unlocked")
        }
        return out
    }

    /// The gold words after the warning glyph: one name ("Bedroom fan unavailable"), else a count ("2 unavailable").
    public var unavailableText: String? {
        switch unavailable.count {
        case 0: nil
        case 1: "\(unavailable[0]) unavailable"
        default: "\(unavailable.count) unavailable"
        }
    }
}

public extension TodayMood {
    /// Today's headline without a Companion server. `home` nil (nothing loaded yet, an error, no Home Assistant):
    /// "Home." in grey, as before. With Home Assistant's states: calm, or heads up while something is unavailable.
    init(home: HomeGlance?) {
        guard let home else {
            self.init(level: .unknown, headline: "Home.", detail: nil)
            return
        }
        let facts = home.facts
        self.init(level: home.unavailable.isEmpty ? .calm : .headsUp, headline: "Home.",
                  detail: facts.isEmpty ? nil : facts.joined(separator: " · "),
                  warnings: home.unavailable.count, warningText: home.unavailableText)
    }
}
