import Foundation

// Presence from Home Assistant (docs/plans/MODULAR.md, M3.3): the "At home" and "Away" rules read one `person.*` or
// `device_tracker.*` entity that the user picks in Settings → Advanced → Where you are. Home Assistant already knows
// where its people are (its companion app, the router): this app asks for no location and no Wi-Fi access. The
// states come with the Home Assistant refresh Today already does; an entity that is missing, unknown or older than
// `Presence.maxAge` makes presence unknown, and unknown lets both rules pass.

extension Presence {
    /// The Home Assistant domains that say where someone is.
    public static let domains: Set<String> = ["person", "device_tracker"]

    /// Whether the entity can be picked under Where you are.
    public static func canTell(_ entity: HAEntity) -> Bool { domains.contains(entity.domain) }

    /// From one entity's state: `home` is at home; `not_home` or a zone ("Work", "School") is away; `unknown`,
    /// `unavailable` or an empty state is nil (unknown).
    public init?(entity: HAEntity, fetched: Date) {
        guard Self.canTell(entity), entity.isAvailable else { return nil }
        let state = entity.state.trimmingCharacters(in: .whitespaces).lowercased()
        guard !state.isEmpty else { return nil }
        self.init(atHome: state == "home", fetched: fetched)
    }

    /// The chosen entity among Home Assistant's states, as fetched at `fetched`. Nil when nothing is chosen, nothing
    /// was fetched yet, or the entity is not there (renamed, removed) or unknown.
    public init?(entities: [HAEntity], entityID: String?, fetched: Date?) {
        guard let entityID, let fetched, let e = entities.first(where: { $0.entityID == entityID }) else { return nil }
        self.init(entity: e, fetched: fetched)
    }

    /// What Where you are offers: people first (they combine all their trackers), then device trackers, each by name.
    public static func candidates(_ entities: [HAEntity]) -> [HAEntity] {
        entities.filter(canTell).sorted { a, b in
            if (a.domain == "person") != (b.domain == "person") { return a.domain == "person" }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// The entity's state in words for the picker: "Home", "Away", "Work", "Unknown".
    public static func words(_ entity: HAEntity) -> String {
        guard entity.isAvailable else { return entity.displayState }
        switch entity.state.lowercased() {
        case "home": return "Home"
        case "not_home": return "Away"
        default: return entity.displayState
        }
    }
}

extension AppModel {
    /// Presence is set up: an entity chosen and a real Home Assistant to read it from (the demo one has nobody to
    /// follow). Only then does the rule sheet offer At home and Away (`ruleKinds(for:)`).
    public var presenceSetUp: Bool { settings.presenceEntity != nil && homeAssistant?.kind == .homeAssistant }

    /// The kinds the rule sheet offers for a section (M3.2): presence kinds once Where you are is set.
    public func ruleKinds(for section: TodaySection) -> [ShowRule.Kind] {
        ShowRule.kinds(for: section, presence: presenceSetUp)
    }

    /// Where I am, from the Home Assistant states the caller holds (Today's Home model) and when they were last
    /// fetched without an error. Nil = not set up or unknown: presence rules pass. Pass it to `showContext`.
    public func presence(in entities: [HAEntity], fetched: Date?) -> Presence? {
        guard presenceSetUp else { return nil }
        return Presence(entities: entities, entityID: settings.presenceEntity, fetched: fetched)
    }

    /// Settings → Today shows the "Where you are" row: with a real Home Assistant, or while one is chosen (so it can
    /// be turned off when Home Assistant is gone).
    public var showsPresenceRow: Bool { homeAssistant?.kind == .homeAssistant || settings.presenceEntity != nil }

    /// Sets or clears Where you are. Clearing writes nothing back (the key goes away).
    public func setPresenceEntity(_ entityID: String?) {
        settings.presenceEntity = entityID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }
}
