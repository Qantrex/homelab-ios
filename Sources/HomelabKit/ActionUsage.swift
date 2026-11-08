import Foundation

/// How often the owner started each action, per server, and the Start actions each server offered last. It decides
/// the Home-screen quick actions (`HomeShortcuts`): the three most used Start actions of the shown server. Kept in the
/// App Group (`action-usage.json`) so the background refresh can update the quick actions too. Only names, counts
/// and the labels the server sent: no arguments, no payloads.
public struct ActionUsage: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var count: Int
        public var last: Date
        public init(count: Int, last: Date) { self.count = count; self.last = last }
    }

    /// A Start action as the quick action shows it.
    public struct Offered: Codable, Sendable, Equatable, Hashable {
        public var name: String
        public var label: String
        public var icon: String?
        /// Marked destructive by the server. Nil = an older cache that didn't record it (the widget then opens the app).
        public var destructive: Bool?
        /// Needs input: it has fields or a way to build an argument. Nil = unknown, like `destructive`.
        public var needsInput: Bool?
        public init(name: String, label: String, icon: String? = nil, destructive: Bool? = nil, needsInput: Bool? = nil) {
            self.name = name; self.label = label; self.icon = icon
            self.destructive = destructive; self.needsInput = needsInput
        }
    }

    /// Server id (lowercased UUID string) → action name → use.
    public var counts: [String: [String: Entry]] = [:]
    /// Server id → the Start actions it offered at its last fetch, in the server's order.
    public var offered: [String: [Offered]] = [:]

    public static let fileName = "action-usage.json"
    /// Names kept per server; the least used beyond this are forgotten.
    public static let maxNames = 64

    public init() {}

    static func key(_ server: UUID) -> String { server.uuidString.lowercased() }

    /// One start of `name` on `server`.
    public mutating func record(_ name: String, server: UUID, at date: Date = Date()) {
        guard ActionSpec.isValidName(name) else { return }
        let k = Self.key(server)
        var list = counts[k] ?? [:]
        let old = list[name]
        list[name] = Entry(count: (old?.count ?? 0) + 1, last: date)
        if list.count > Self.maxNames {
            let keep = list.sorted { Self.before($0.value, $1.value) }.prefix(Self.maxNames)
            list = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        counts[k] = list
    }

    /// The actions `server` offers now (`GET /actions`). Only Start actions count: a card-only one needs its card.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func setOffered(_ specs: [ActionSpec], server: UUID) -> Bool {
        let list = specs.filter(\.start).map {
            Offered(name: $0.name, label: $0.label, icon: $0.icon, destructive: $0.destructive,
                    needsInput: !$0.fields.isEmpty || !$0.variants.isEmpty)
        }
        let k = Self.key(server)
        guard offered[k] != list else { return false }
        offered[k] = list.isEmpty ? nil : list
        return true
    }

    /// Forgets servers that are gone.
    public mutating func keep(servers: [UUID]) {
        let keys = Set(servers.map(Self.key))
        counts = counts.filter { keys.contains($0.key) }
        offered = offered.filter { keys.contains($0.key) }
    }

    /// The `limit` actions of `server` to offer first: most started, then most recently started, then the server's
    /// order. Never one the server doesn't offer (any more).
    public func top(server: UUID, limit: Int = 3) -> [Offered] {
        Self.ranked(offered[Self.key(server)] ?? [], counts: counts[Self.key(server)] ?? [:], limit: limit)
    }

    public static func ranked(_ offered: [Offered], counts: [String: Entry], limit: Int) -> [Offered] {
        let indexed = offered.enumerated().map { (index: $0.offset, item: $0.element, use: counts[$0.element.name]) }
        let sorted = indexed.sorted { a, b in
            switch (a.use, b.use) {
            case let (x?, y?) where x != y: return before(x, y)
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.index < b.index
            }
        }
        return Array(sorted.prefix(max(limit, 0)).map(\.item))
    }

    static func before(_ a: Entry, _ b: Entry) -> Bool {
        a.count != b.count ? a.count > b.count : a.last > b.last
    }
}

/// The dynamic Home-screen quick actions (long-press the app icon). The static "Scan document" stays in
/// App-Info.plist; these come after it: the shown server's three most used Start actions, each opening
/// `homelab://actions/<name>`. They show only the action's label (the server's list, not its state), and the form
/// they open is behind the app lock like every link.
public enum HomeShortcuts {
    public static let actionType = "com.qantrex.homelab.action"
    public static let scanType = "com.qantrex.homelab.scan"
    public static let limit = 3

    public struct Item: Sendable, Equatable {
        public var type: String
        public var title: String
        /// An SF Symbol the server sent; the app checks that it exists.
        public var icon: String?
        public var link: URL
    }

    /// The quick actions for `server` (nil: none), from what it offered last and how often each was started.
    public static func items(_ usage: ActionUsage, server: UUID?) -> [Item] {
        guard let server else { return [] }
        return usage.top(server: server, limit: limit).compactMap { a in
            guard let link = ActionLink(name: a.name).url else { return nil }
            return Item(type: actionType, title: a.label, icon: a.icon, link: link)
        }
    }

    /// The link a quick action opens: `homelab://scan`, or an action's link (checked again, it comes from the system).
    public static func link(type: String, userInfo: [String: Any]?) -> URL? {
        switch type {
        case scanType: return URL(string: "homelab://scan")
        case actionType:
            guard let s = userInfo?["link"] as? String, let url = URL(string: s), let a = ActionLink(url) else { return nil }
            return ActionLink(name: a.name).url
        default: return nil
        }
    }
}
