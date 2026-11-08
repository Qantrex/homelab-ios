import Foundation

/// The first run (docs/plans/MODULAR.md, D4 and M2.3), for someone with no server saved:
///
/// 1. Welcome: "Add Home Assistant", "Add a Homelab server", "Try the demo" (one tap, no run).
/// 2. The server editor (`.adding`). Cancel goes back to where the run was; with nothing saved yet, out of the run.
/// 3. Found (`.found`): what the saved servers offer, and "Start with" the three presets (`StartPreset`), the
///    suggested one picked. "Add Home Assistant too" (or a Homelab server) opens the editor again.
/// 4. With Home Assistant tiles to pick: the tile picker (`.tiles`).
/// 5. Today, with a line pointing to Settings → Advanced → Sections (`AppModel.showsStartTip`).
///
/// Every step can be skipped. A run only starts while no server is saved (`AppModel.beginFirstRun`), so the owner
/// never sees one. Nothing of it is stored: the run lives in memory, and a preset writes only Today's layout and
/// density (`StartLayout.apply`).
public struct FirstRun: Equatable, Sendable {
    /// One line on the welcome screen, under the add buttons (the first run only).
    public static let vpnNote = "Turn on Tailscale (or your VPN) first: the app talks to your servers directly."

    /// Found: /info didn't answer but /state did. The row under what the data itself shows.
    public static let unreadableOffers = "Couldn't read what it offers"

    /// Where sections are changed now (Settings → Advanced → Sections). The first-run tip on Today and the footer under
    /// "Start with" use these.
    public static let sectionsPath = "Settings → Advanced → Sections"
    public static let startTipText = "Change what Today shows in \(sectionsPath)"
    public static let startWithFooter = "Sets which sections Today shows and how much. Change it any time in \(sectionsPath)."

    public enum Step: Equatable, Sendable {
        /// The server editor is open for a new server of this kind.
        case adding(ServerConfig.Kind)
        /// What was found, and "Start with".
        case found
        /// Home Assistant's tile picker.
        case tiles
    }

    public internal(set) var step: Step
    /// The servers saved in this run, in order.
    public internal(set) var added: [UUID] = []
    /// The preset picked in "Start with"; nil follows the suggestion, which can change once the server's /info answers.
    public internal(set) var picked: StartPreset?

    public init(adding kind: ServerConfig.Kind) {
        step = .adding(kind)
    }

    /// A run that starts at Found for servers that are already there (`-HomelabFirstRun` over the demo, screenshots).
    init(found servers: [UUID]) {
        step = .found
        added = servers
    }

    /// The kind the editor is open for, nil when it isn't.
    public var adding: ServerConfig.Kind? {
        if case .adding(let kind) = step { return kind }
        return nil
    }

    /// Found shows once a server was saved: also while the editor is open again for a second one.
    public var showsFound: Bool { !added.isEmpty }

    /// The editor saved a server: on to Found.
    mutating func saved(_ id: UUID) {
        if !added.contains(id) { added.append(id) }
        step = .found
    }

    /// The editor closed. After a save the step is already Found; a cancel goes back to Found, or ends the run (back
    /// to the welcome) when nothing was saved yet. False when the run ends.
    mutating func editorClosed() -> Bool {
        guard adding != nil else { return true }
        guard !added.isEmpty else { return false }
        step = .found
        return true
    }

    /// The preset "Start with" shows as picked.
    public func preset(features: Set<ServerInfo.Feature>, hasHA: Bool) -> StartPreset {
        picked ?? StartPreset.suggested(features: features, hasHA: hasHA)
    }

    /// What comes after "Start" or "Skip" on Found: the tile picker when Home Assistant has something to pin, else the
    /// end of the run (nil).
    static func afterFound(canPickTiles: Bool) -> Step? {
        canPickTiles ? .tiles : nil
    }

    // MARK: What was found

    /// One line of Found: an SF Symbol, what it is, and a detail when there is one.
    public struct Offer: Equatable, Sendable, Identifiable {
        public var id: String
        public var symbol: String
        public var title: String
        public var detail: String?

        public init(id: String, symbol: String, title: String, detail: String? = nil) {
            self.id = id
            self.symbol = symbol
            self.title = title
            self.detail = detail
        }
    }

    /// What a Homelab server offers, in words, in the order Today and the tabs use them.
    public static func offers(features: Set<ServerInfo.Feature>) -> [Offer] {
        let all: [(ServerInfo.Feature, String, String, String?)] = [
            (.status, "checkmark.circle", "Status and problems", "The headline on Today"),
            (.hosts, "server.rack", "Machines", "Load, memory and disk in Lab"),
            (.cards, "rectangle.stack", "Cards", "The day, to-dos, parcels"),
            (.actions, "checkmark.shield", "Proposals to approve", nil),
            (.runActions, "play.circle", "Actions you start", nil),
            (.chat, "bubble.left.and.bubble.right", "Chat", nil),
            (.services, "square.grid.2x2", "Service links", nil),
            (.documents, "doc.viewfinder", "Scans and documents", nil),
            (.share, "square.and.arrow.up", "Sharing links", nil),
            (.search, "magnifyingglass", "Search", nil),
            (.deals, "tag", "Deals", nil),
        ]
        return all.filter { features.contains($0.0) }
            .map { Offer(id: $0.0.rawValue, symbol: $0.1, title: $0.2, detail: $0.3) }
    }

    /// Home Assistant's line: its tiles in words ("12 lights, 3 switches and 2 scenes"). Nil entities: still loading.
    public static func homeOffer(entities: [HAEntity]?) -> Offer {
        Offer(id: "home", symbol: "house", title: "Home tiles", detail: entities.map(homeSummary))
    }

    /// The entity kinds a Home tile can show (the tile picker lists these).
    static let tileDomains: Set<String> = ["light", "switch", "fan", "input_boolean", "scene", "script", "button",
                                           "input_button", "sensor", "binary_sensor", "automation"]

    /// "12 lights, 3 switches and 2 scenes": the four most common of the main kinds, or what there is to pin at all.
    static func homeSummary(_ entities: [HAEntity]) -> String {
        let kinds: [(String, String, String)] = [
            ("light", "light", "lights"), ("switch", "switch", "switches"), ("scene", "scene", "scenes"),
            ("script", "script", "scripts"), ("fan", "fan", "fans"), ("sensor", "sensor", "sensors"),
        ]
        var counts: [String: Int] = [:]
        for e in entities { counts[e.domain, default: 0] += 1 }
        let parts = kinds.compactMap { domain, one, many -> (Int, String)? in
            guard let n = counts[domain], n > 0 else { return nil }
            return (n, "\(n) \(n == 1 ? one : many)")
        }
        // Most first; the same count keeps the order above. At most four, so it stays one or two lines.
        let shown = parts.enumerated().sorted { a, b in
            a.element.0 != b.element.0 ? a.element.0 > b.element.0 : a.offset < b.offset
        }.prefix(4).map(\.element.1)
        if !shown.isEmpty { return joined(Array(shown)) }
        let other = entities.filter { tileDomains.contains($0.domain) }.count
        return other > 0 ? "\(other) things to pin" : "Nothing to pin yet"
    }

    /// Whether the tile picker has something to offer.
    public static func canPickTiles(hasHA: Bool, entities: [HAEntity]?) -> Bool {
        hasHA && (entities ?? []).contains { tileDomains.contains($0.domain) }
    }

    /// "a", "a and b", "a, b and c".
    static func joined(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }
}

// MARK: The run in the app model

public extension AppModel {
    /// RootView shows the first run instead of the tabs: with no server yet (the welcome), or while a run that started
    /// that way goes on after its first save. Always false for someone with servers who didn't just start a run.
    var showsFirstRun: Bool { firstRun != nil || !hasServers }

    /// "Add Home Assistant" or "Add a Homelab server": on the welcome it starts a run; on Found it opens the editor
    /// for another server. Does nothing for someone with servers and no run.
    func beginFirstRun(adding kind: ServerConfig.Kind) {
        guard kind != .demo else { return }
        if firstRun != nil {
            firstRun?.step = .adding(kind)
        } else if !hasServers {
            firstRun = FirstRun(adding: kind)
        }
    }

    /// The editor saved this server.
    func firstRunSaved(_ server: ServerConfig) {
        firstRun?.saved(server.id)
    }

    /// The editor closed (saved or cancelled).
    func firstRunEditorClosed() {
        guard var run = firstRun else { return }
        firstRun = run.editorClosed() ? run : nil
    }

    /// What the run's Homelab server offers: its features once known, else what its data shows; empty without one.
    var firstRunFeatures: Set<ServerInfo.Feature> {
        selected == nil ? [] : selectedStatus.features
    }

    /// The preset "Start with" shows as picked: the user's pick, or the suggestion for what was found.
    var firstRunPreset: StartPreset {
        (firstRun ?? FirstRun(found: [])).preset(features: firstRunFeatures, hasHA: homeAssistant != nil)
    }

    /// The suggestion for what was found.
    var firstRunSuggested: StartPreset {
        StartPreset.suggested(features: firstRunFeatures, hasHA: homeAssistant != nil)
    }

    func pickStart(_ preset: StartPreset) {
        firstRun?.picked = preset
    }

    /// "Start" (a preset) or "Skip" (nil) on Found: the preset writes Today's layout and density, then the tile
    /// picker opens, or the run ends.
    func startFirstRun(with preset: StartPreset?, canPickTiles: Bool) {
        guard firstRun != nil else { return }
        if let preset {
            preset.layout(features: firstRunFeatures, hasHA: homeAssistant != nil).apply(to: &settings)
        }
        if let next = FirstRun.afterFound(canPickTiles: canPickTiles) {
            firstRun?.step = next
        } else {
            finishFirstRun()
        }
    }

    /// The run is over: Today, with the line pointing to Settings → Advanced → Sections until the app quits.
    func finishFirstRun() {
        guard firstRun != nil else { return }
        firstRun = nil
        showsStartTip = true
        tab = .today
        validateTab()
    }

    /// The line under Today was tapped: Settings, and the line goes.
    func openStartTip() {
        showsStartTip = false
        pick(.settings)
    }
}
