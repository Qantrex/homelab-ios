import Foundation

/// A first-run start for Today (docs/plans/MODULAR.md, D4 and M2.2): what the user's servers offer becomes a suggested
/// preset, and a preset becomes a `TodayLayout` and a `Density`. Only for a first run, while no server is saved
/// (`AppModel.hasServers` false), so the owner never sees one. Pure: no clock, no storage, no model.
///
/// - Home: Calm, Home tiles first; deals, the last report and the machines off.
/// - Watch: Standard, the lab first (to approve, the day, cards); deals off.
/// - Everything: Overkill, every section in the standard order.
///
/// In each preset the sections the servers offer come first, in the preset's order; the others follow in the same
/// order and stay on, so they show up by themselves once a server offers them (Today skips a section without data).
public enum StartPreset: String, CaseIterable, Sendable, Identifiable {
    case home, watch, everything

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: "Home"
        case .watch: "Watch"
        case .everything: "Everything"
        }
    }

    /// One line under the title in the "Start with" list.
    public var summary: String {
        switch self {
        case .home: "Home tiles and the day. Calm."
        case .watch: "The lab first: what waits for you, the day, cards."
        case .everything: "Every section, exact times."
        }
    }

    /// The density the preset writes.
    public var density: Density {
        switch self {
        case .home: .calm
        case .watch: .standard
        case .everything: .overkill
        }
    }

    /// The preset's section order, before what the servers offer moves to the front.
    var preferredOrder: [TodaySection] {
        switch self {
        case .home: [.home, .day, .waiting, .cards, .deals, .report, .machines]
        case .watch: [.waiting, .day, .cards, .home, .report, .deals, .machines]
        case .everything: TodaySection.allCases
        }
    }

    /// Sections the preset turns off on purpose, whatever the servers offer.
    var hiddenSections: Set<TodaySection> {
        switch self {
        case .home: [.deals, .report, .machines]
        case .watch: [.deals]
        case .everything: []
        }
    }

    /// What found servers suggest. `features` is the Companion server's `/info` features, empty when there is none;
    /// `hasHA` says whether a Home Assistant was found.
    /// - Home Assistant without a Companion server: Home.
    /// - A Companion server that only watches (status, hosts, actions, cards, chat, services: what the reference
    ///   server offers), with or without Home Assistant: Watch.
    /// - A Companion server that does more (deals, search, documents, share: an agent, or the demo): Everything.
    /// - Nothing found: Watch, the app's standard density.
    public static func suggested(features: Set<ServerInfo.Feature>, hasHA: Bool) -> StartPreset {
        if features.isEmpty { return hasHA ? .home : .watch }
        return features.isDisjoint(with: agentFeatures) ? .watch : .everything
    }

    /// Features only a server that does more than watch offers.
    static let agentFeatures: Set<ServerInfo.Feature> = [.deals, .search, .documents, .share]

    /// The layout and density this preset writes for these servers.
    public func layout(features: Set<ServerInfo.Feature>, hasHA: Bool) -> StartLayout {
        let all = TodayLayout(order: preferredOrder.map(\.rawValue), hidden: []).sections   // every section once
        let offered = all.filter { Self.offers($0, features: features, hasHA: hasHA) }
        let rest = all.filter { !offered.contains($0) }
        let order = offered + rest
        let hidden = order.filter(hiddenSections.contains)
        return StartLayout(today: TodayLayout(order: order.map(\.rawValue), hidden: hidden.map(\.rawValue)),
                           density: density)
    }

    /// Whether the servers can fill a section: the features each section reads (see the `today_sections` entries in
    /// features.toml).
    public static func offers(_ section: TodaySection, features: Set<ServerInfo.Feature>, hasHA: Bool) -> Bool {
        switch section {
        case .day, .cards: features.contains(.cards)
        case .waiting: features.contains(.actions)
        case .deals: features.contains(.deals)
        case .home: hasHA
        case .report: features.contains(.status)
        case .machines: features.contains(.hosts)
        }
    }
}

/// What a start preset writes: Today's layout and its density.
public struct StartLayout: Equatable, Sendable {
    public var today: TodayLayout
    public var density: Density

    public init(today: TodayLayout, density: Density) {
        self.today = today
        self.density = density
    }

    /// Writes the layout and density into the settings through their normalizing setters: the standard layout and
    /// Standard density are stored as nil, so a start that matches the defaults leaves `settings.json` as it was.
    /// Nothing else changes.
    public func apply(to settings: inout AppSettings) {
        settings.todayLayout = today
        settings.todayDensity = density
    }
}
