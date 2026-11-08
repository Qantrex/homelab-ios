import Foundation

/// A user's order and hidden items for a list the server or the app fills (Start tiles, Lab cards, tabs). Items are
/// named by a stable id (an action's `name`, a card's `id`, a tab's name). What the list does not know yet appears at
/// the end and visible, so a new server tile or card shows up after an update. Stored in `settings.json` only once
/// something differs from the default, so older files save back unchanged (docs/plans/MODULAR.md, owner invariance).
public struct ItemOrder: Codable, Equatable, Sendable {
    public var order: [String]
    public var hidden: [String]

    public static let standard = ItemOrder(order: [], hidden: [])
    public var isStandard: Bool { order.isEmpty && hidden.isEmpty }

    public init(order: [String] = [], hidden: [String] = []) {
        self.order = order
        self.hidden = hidden
    }

    enum CodingKeys: String, CodingKey { case order, hidden }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = c.lenient([String].self, .order) ?? []
        hidden = c.lenient([String].self, .hidden) ?? []
    }

    /// Every id once: the stored order first (ids that are no longer there are skipped), the new ones last.
    public func ordered(_ ids: [String]) -> [String] {
        let present = Set(ids)
        var seen = Set<String>()
        var out = order.filter { present.contains($0) && seen.insert($0).inserted }
        out += ids.filter { seen.insert($0).inserted }
        return out
    }

    /// The ids to draw: ordered, without the hidden ones.
    public func visible(_ ids: [String]) -> [String] { ordered(ids).filter { !hidden.contains($0) } }

    /// `items` ordered, and only the visible ones when `onlyVisible`.
    public func arrange<T>(_ items: [T], id: (T) -> String, onlyVisible: Bool = true) -> [T] {
        var byID: [String: T] = [:]
        for item in items where byID[id(item)] == nil { byID[id(item)] = item }
        let ids = onlyVisible ? visible(items.map(id)) : ordered(items.map(id))
        return ids.compactMap { byID[$0] }
    }

    public func isVisible(_ id: String) -> Bool { !hidden.contains(id) }

    public mutating func setVisible(_ id: String, _ on: Bool) {
        hidden.removeAll { $0 == id }
        if !on { hidden.append(id) }
    }

    /// Like `Array.move(fromOffsets:toOffset:)` (SwiftUI, so not on Linux) on the ordered `ids` (what the editor
    /// lists). Stored ids that are not in `ids` right now keep their place after them.
    public mutating func move(_ ids: [String], fromOffsets source: IndexSet, toOffset destination: Int) {
        var list = ordered(ids)
        let moving = source.sorted().filter { $0 < list.count }.map { list[$0] }
        let before = source.filter { $0 < destination }.count
        for i in source.sorted(by: >) where i < list.count { list.remove(at: i) }
        list.insert(contentsOf: moving, at: min(max(destination - before, 0), list.count))
        order = list + order.filter { !list.contains($0) }
    }

    /// Moves one id a step up (-1) or down (+1), for the VoiceOver actions "Move up" / "Move down"; false at the ends.
    @discardableResult
    public mutating func nudge(_ id: String, in ids: [String], by step: Int) -> Bool {
        let list = ordered(ids)
        guard let i = list.firstIndex(of: id), list.indices.contains(i + step) else { return false }
        move(ids, fromOffsets: IndexSet(integer: i), toOffset: step > 0 ? i + step + 1 : i + step)
        return true
    }
}

// MARK: Start tiles

public enum StartTiles {
    /// The Start tiles to draw: the server's actions in the owner's order, hidden ones left out, new ones last.
    public static func arrange(_ actions: [ActionSpec], _ order: ItemOrder?) -> [ActionSpec] {
        (order ?? .standard).arrange(actions, id: \.name)
    }

    /// All of them for the editor: ordered, hidden ones included.
    public static func editable(_ actions: [ActionSpec], _ order: ItemOrder?) -> [ActionSpec] {
        (order ?? .standard).arrange(actions, id: \.name, onlyVisible: false)
    }
}

// MARK: Lab

/// What Lab draws between the problems and the diagnostics link: the Hosts block, the server's lab cards and the
/// Services block. Problems stay on top and can't be hidden (a problem you can't see is the worst kind). Cards are
/// named by their id; the two built-in blocks have ids a card can't have.
public enum LabBlocks {
    public static let hosts = "@hosts"
    public static let services = "@services"

    /// The standard order: hosts, the cards as the server sends them, services.
    public static func standardIDs(cards: [Card]) -> [String] { [hosts] + cards.map(\.id) + [services] }

    /// All ids in the owner's order (for the editor); a card the order doesn't know comes last, after Services.
    public static func ids(cards: [Card], _ order: ItemOrder?) -> [String] {
        (order ?? .standard).ordered(standardIDs(cards: cards))
    }

    public static func visibleIDs(cards: [Card], _ order: ItemOrder?) -> [String] {
        (order ?? .standard).visible(standardIDs(cards: cards))
    }

    /// The title Settings shows for an id.
    public static func title(_ id: String, cards: [Card]) -> String {
        switch id {
        case hosts: "Hosts"
        case services: "Services"
        default: cards.first { $0.id == id }.map { $0.title ?? $0.id } ?? id
        }
    }
}

// MARK: Tabs

public extension AppTab {
    var title: String {
        switch self {
        case .today: "Today"
        case .actions: "Actions"
        case .chat: "Chat"
        case .lab: "Lab"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.horizon"
        case .actions: "checkmark.shield"
        case .chat: "bubble.left.and.bubble.right"
        case .lab: "server.rack"
        case .settings: "gearshape"
        }
    }
}

/// Which tabs the bar shows, in which order. Settings can never be hidden (it is the way back), also not by a hand
/// edited file. The first shown tab is where the app opens and where a hidden or gone tab falls back to.
public enum TabBar {
    public static func canHide(_ tab: AppTab) -> Bool { tab != .settings }

    /// The tabs to draw out of the `available` ones: the owner's order, hidden ones left out.
    public static func shown(available: Set<AppTab>, _ order: ItemOrder?) -> [AppTab] {
        let order = order ?? .standard
        return order.ordered(AppTab.allCases.filter(available.contains).map(\.rawValue))
            .compactMap(AppTab.init(rawValue:))
            .filter { !canHide($0) || order.isVisible($0.rawValue) }
    }

    /// The tabs the editor lists: every available one, in order.
    public static func editable(available: Set<AppTab>, _ order: ItemOrder?) -> [AppTab] {
        (order ?? .standard).arrange(AppTab.allCases.filter(available.contains), id: \.rawValue, onlyVisible: false)
    }
}

// MARK: Chat

/// Chat text size, relative to the system's Dynamic Type: one step smaller or larger than the user's size.
public enum ChatTextSize: String, Codable, CaseIterable, Sendable, Identifiable {
    case small, standard, large
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .small: "Small"
        case .standard: "Default"
        case .large: "Large"
        }
    }

    /// Steps along `DynamicTypeSize` (xSmall ... accessibility5).
    public var step: Int {
        switch self {
        case .small: -1
        case .standard: 0
        case .large: 1
        }
    }

    /// The index to use in a list of `count` sizes, from `index`: shifted by `step`, never off either end.
    public func shifted(_ index: Int, count: Int) -> Int { min(max(index + step, 0), max(count - 1, 0)) }
}

/// How long a chat message gets before "Show more".
public enum ChatFoldMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case short, standard, never
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .short: "Short"
        case .standard: "Default"
        case .never: "Never fold"
        }
    }

    /// Lines a folded message shows; nil = no folding.
    public var shownLines: Int? {
        switch self {
        case .short: 6
        case .standard: ChatFold.shownLines
        case .never: nil
        }
    }
}

public extension ChatFold {
    /// Whether a message of `lines` lines folds in this mode: only when folding hides at least `minHidden` lines.
    static func folds(lines: Int, mode: ChatFoldMode) -> Bool {
        guard let shown = mode.shownLines else { return false }
        return lines >= shown + minHidden
    }

    static func folds(height: Double, lineHeight: Double, mode: ChatFoldMode) -> Bool {
        folds(lines: lines(height: height, lineHeight: lineHeight), mode: mode)
    }

    static func foldedHeight(lineHeight: Double, mode: ChatFoldMode) -> Double {
        Double(mode.shownLines ?? shownLines) * lineHeight
    }
}

// MARK: Settings accessors

public extension AppSettings {
    var startTileOrder: ItemOrder {
        get { startTiles ?? .standard }
        set { startTiles = newValue.isStandard ? nil : newValue }
    }

    var labOrder: ItemOrder {
        get { labBlocks ?? .standard }
        set { labBlocks = newValue.isStandard ? nil : newValue }
    }

    var tabOrder: ItemOrder {
        get { tabs ?? .standard }
        set { tabs = newValue.isStandard ? nil : newValue }
    }

    var chatSize: ChatTextSize {
        get { chatText ?? .standard }
        set { chatText = newValue == .standard ? nil : newValue }
    }

    var chatFolding: ChatFoldMode {
        get { chatFold ?? .standard }
        set { chatFold = newValue == .standard ? nil : newValue }
    }

    /// How long chat replies fold on screen: never in Hyperdetail, else the owner's choice (`chatFolding`).
    var shownChatFolding: ChatFoldMode { todayDensity.isHyper ? .never : chatFolding }

    /// Whether anything customized here differs from the default (Settings → Advanced says "Customized").
    var customizedElsewhere: Bool {
        startTiles != nil || labBlocks != nil || tabs != nil || chatText != nil || chatFold != nil
    }
}

// MARK: The Advanced page

/// The title of Settings → Advanced follows the personality (owner idea 2026-11-09). Its own table, not VoiceLines.
public enum AdvancedTitle {
    public static func text(_ personality: Personality) -> String {
        switch personality {
        case .off, .dry: "Advanced"
        case .snarky: "Nerd section"
        case .ultrakill: "Nerd shit"
        }
    }
}
