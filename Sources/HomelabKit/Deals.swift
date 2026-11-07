import Foundation

// Deals (optional endpoint `GET /deals`, feature `deals`): used-market ads the server found clearly below their
// market value and judged. The models decode tolerantly, the rules (order, groups, what counts as fresh, when to ask
// the server, which deal is worth a notification, how a price reads) are plain functions here so Linux tests them.
// Foundation only.

/// One ad the server judged. Only `id` and `title` are required; the app shows what is there.
public struct Deal: Codable, Sendable, Equatable, Identifiable, Hashable {
    public enum Confidence: String, Codable, Sendable, CaseIterable {
        case high, medium, low

        /// "high", "medium", "low" as the row says it: how sure the server is about the market value.
        public var word: String { rawValue }
    }

    /// The server's judgement. `act` is a strong one (the server pushes it to the phone).
    public enum Verdict: String, Codable, Sendable, CaseIterable {
        case act, consider, skip
    }

    public struct Comp: Codable, Sendable, Equatable, Hashable {
        public var title: String?
        public var price: Double?
        public var url: URL?

        public init(title: String? = nil, price: Double? = nil, url: URL? = nil) {
            self.title = title; self.price = price; self.url = url
        }

        enum CodingKeys: String, CodingKey { case title, price, url }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let title = Deal.cut(c.text(.title), Deal.maxText)
            let price = Deal.money(c.double(.price))
            let url = c.text(.url).flatMap(Deal.link)
            // A comparable with nothing to show is dropped (the list keeps the rest).
            guard title != nil || price != nil || url != nil else {
                throw DecodingError.keyNotFound(CodingKeys.title, .init(codingPath: c.codingPath, debugDescription: "empty comp"))
            }
            self.init(title: title, price: price, url: url)
        }
    }

    /// The ad's number on the marketplace.
    public var id: Int64
    /// Which saved search found it (`any-gpu`).
    public var watch: String?
    /// What kind of thing it is (`gpu`).
    public var kind: String?
    public var title: String
    /// Asking price and the server's market value, euros.
    public var price: Double?
    public var value: Double?
    /// The server's share below value (0.5 = 50 % below); `share` falls back to price and value.
    public var discount: Double?
    public var confidence: Confidence?
    public var specs: String?
    public var location: String?
    public var state: String?
    /// In the owner's pickup area.
    public var near: Bool
    /// A private seller; nil = not said. False is a dealer.
    public var isPrivate: Bool?
    public var ships: Bool?
    /// "used", "like new", "new" (any other word is kept as the server wrote it).
    public var condition: String?
    public var url: URL?
    /// The server's warnings ("too good to be true? …"). Gold, never an error.
    public var flags: [String]
    public var seen: Date?
    public var verdict: Verdict?
    public var note: String?
    public var comps: [Comp]

    public init(id: Int64, watch: String? = nil, kind: String? = nil, title: String, price: Double? = nil,
                value: Double? = nil, discount: Double? = nil, confidence: Confidence? = nil, specs: String? = nil,
                location: String? = nil, state: String? = nil, near: Bool = false, isPrivate: Bool? = nil,
                ships: Bool? = nil, condition: String? = nil, url: URL? = nil, flags: [String] = [],
                seen: Date? = nil, verdict: Verdict? = nil, note: String? = nil, comps: [Comp] = []) {
        self.id = id; self.watch = watch; self.kind = kind; self.title = title; self.price = price; self.value = value
        self.discount = discount; self.confidence = confidence; self.specs = specs; self.location = location
        self.state = state; self.near = near; self.isPrivate = isPrivate; self.ships = ships
        self.condition = condition; self.url = url; self.flags = flags; self.seen = seen; self.verdict = verdict
        self.note = note; self.comps = comps
    }

    enum CodingKeys: String, CodingKey {
        case id, watch, kind, title, price, value, discount, specs, state, near, ships, url, flags, seen, verdict, note, comps
        case confidence = "conf"
        case location = "loc"
        case isPrivate = "private"
        case condition = "cond"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.int64(.id), id > 0, let title = Self.cut(c.text(.title), Self.maxText) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "no id/title"))
        }
        // A share (0.5). A server that sends a percent (50) is read the same; a negative or broken number is none.
        var share = c.double(.discount).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if let s = share { share = min(s > 1 ? s / 100 : s, 1) }
        let flags = c.strings(.flags).compactMap { Self.cut($0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty, Self.maxText) }
        self.init(
            id: id, watch: Self.cut(c.text(.watch), 64), kind: Self.cut(c.text(.kind), 64), title: title,
            price: Self.money(c.double(.price)), value: Self.money(c.double(.value)), discount: share,
            confidence: c.text(.confidence).flatMap { Confidence(rawValue: $0.lowercased()) },
            specs: Self.cut(c.text(.specs), Self.maxText), location: Self.cut(c.text(.location), 120),
            state: Self.cut(c.text(.state), 120), near: c.bool(.near) ?? false, isPrivate: c.bool(.isPrivate),
            ships: c.bool(.ships), condition: Self.cut(c.text(.condition)?.lowercased(), 32),
            url: c.text(.url).flatMap(Self.link), flags: Array(flags.prefix(Self.maxFlags)),
            seen: c.date(.seen), verdict: c.text(.verdict).flatMap { Verdict(rawValue: $0.lowercased()) },
            note: Self.cut(c.text(.note), 400),
            comps: Array(c.array(Comp.self, .comps).prefix(Self.maxComps)))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(watch, forKey: .watch)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(price, forKey: .price)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(discount, forKey: .discount)
        try c.encodeIfPresent(confidence, forKey: .confidence)
        try c.encodeIfPresent(specs, forKey: .specs)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encodeIfPresent(state, forKey: .state)
        try c.encode(near, forKey: .near)
        try c.encodeIfPresent(isPrivate, forKey: .isPrivate)
        try c.encodeIfPresent(ships, forKey: .ships)
        try c.encodeIfPresent(condition, forKey: .condition)
        try c.encodeIfPresent(url?.absoluteString, forKey: .url)
        try c.encode(flags, forKey: .flags)
        try c.encodeIfPresent(seen.map(ServerDate.string), forKey: .seen)
        try c.encodeIfPresent(verdict, forKey: .verdict)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encode(comps.map { CompOut(title: $0.title, price: $0.price, url: $0.url?.absoluteString) }, forKey: .comps)
    }

    private struct CompOut: Encodable { var title: String?; var price: Double?; var url: String? }

    // MARK: Limits

    public static let maxDeals = 100
    static let maxText = 240
    static let maxFlags = 8
    static let maxComps = 12
    static let maxLink = 2048
    /// Euros: 0 up to ten million; anything else is no price.
    static let moneyRange = 0.0...10_000_000.0

    static func cut(_ text: String?, _ max: Int) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text.count > max ? String(text.prefix(max - 1)) + "…" : text
    }

    static func money(_ value: Double?) -> Double? {
        guard let value, value.isFinite, moneyRange.contains(value) else { return nil }
        return value
    }

    /// An ad or comparable link: http(s) with a host, not absurdly long.
    static func link(_ text: String) -> URL? {
        text.count <= maxLink ? URLPolicy.webURL(text) : nil
    }

    // MARK: What the screens say

    /// How far below the market value, 0…1: the server's `discount`, else worked out from the two prices. Nil when
    /// neither is known (or the ad is not below its value).
    public var share: Double? {
        if let discount { return discount > 0 ? discount : nil }
        guard let price, let value, value > 0, price < value else { return nil }
        return 1 - price / value
    }

    /// The server judged it "too good to be true" (or similar): the first flag that starts that way.
    public var warnsOfScam: Bool {
        flags.contains { $0.lowercased().hasPrefix("too good") }
    }

    /// "Krems an der Donau, Niederösterreich"; one word when both are the same ("Wien").
    public var place: String? {
        switch (location, state) {
        case let (l?, s?) where l.caseInsensitiveCompare(s) != .orderedSame: "\(l), \(s)"
        case let (l?, _): l
        case let (nil, s?): s
        default: nil
        }
    }

    /// "private", "dealer" or nil.
    public var sellerWord: String? {
        guard let isPrivate else { return nil }
        return isPrivate ? "private" : "dealer"
    }

    /// What a row says to VoiceOver, in one sentence list: the title, the price and how far below the value, the
    /// server's verdict, where, who sells, and the warnings (said as warnings, not left to a colour).
    public var spoken: String {
        var parts = [title]
        if let price { parts.append(DealFormat.price(price)) }
        if let below = DealFormat.spokenDiscount(share) { parts.append(below) }
        switch verdict {
        case .act: parts.append("act now")
        case .consider: parts.append("consider")
        case .skip: parts.append("skipped")
        case nil: break
        }
        if let confidence { parts.append("\(confidence.word) confidence") }
        if let place { parts.append(near ? "\(place), near you" : place) }
        if let sellerWord { parts.append(sellerWord + " seller") }
        if ships == true { parts.append("ships") }
        if !flags.isEmpty { parts.append("warning: " + flags.joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }

    /// The condition with a capital letter ("Like new").
    public var conditionWord: String? {
        condition.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }
}

/// `GET /deals`: when the server built the list and the deals (newest first as sent).
public struct DealList: Codable, Sendable, Equatable {
    public var updated: Date?
    public var deals: [Deal]

    public init(updated: Date? = nil, deals: [Deal] = []) {
        self.updated = updated; self.deals = deals
    }

    enum CodingKeys: String, CodingKey { case updated, deals }

    public init(from decoder: any Decoder) throws {
        // {"updated", "deals": [...]} and a bare array.
        if let bare = try? decoder.singleValueContainer().decode([Lossy<Deal>].self) {
            self.init(updated: nil, deals: Self.clean(bare.compactMap(\.value)))
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(updated: c.date(.updated), deals: Self.clean(c.array(Deal.self, .deals)))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(updated.map(ServerDate.string), forKey: .updated)
        try c.encode(deals, forKey: .deals)
    }

    /// Duplicate ids keep the first; at most `Deal.maxDeals`.
    static func clean(_ deals: [Deal]) -> [Deal] {
        var ids = Set<Int64>()
        return Array(deals.filter { ids.insert($0.id).inserted }.prefix(Deal.maxDeals))
    }

    // MARK: Order and groups

    public enum Group: String, CaseIterable, Sendable {
        case act, look, skipped

        public var title: String {
            switch self {
            case .act: "Act now"
            case .look: "Worth a look"
            case .skipped: "Skipped"
            }
        }

        public init(_ deal: Deal) {
            switch deal.verdict {
            case .act: self = .act
            case .skip: self = .skipped
            case .consider, nil: self = .look
            }
        }
    }

    /// "Act" first, then "consider", then not judged, then "skip"; inside each, the newest first (no time last), then
    /// the bigger discount, then the server's order.
    public var ordered: [Deal] {
        func rank(_ d: Deal) -> Int {
            switch d.verdict {
            case .act: 0
            case .consider: 1
            case nil: 2
            case .skip: 3
            }
        }
        return deals.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if rank(x) != rank(y) { return rank(x) < rank(y) }
            if x.seen != y.seen { return (x.seen ?? .distantPast) > (y.seen ?? .distantPast) }
            if (x.share ?? 0) != (y.share ?? 0) { return (x.share ?? 0) > (y.share ?? 0) }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The ordered deals in the screen's sections; empty groups are left out.
    public var groups: [(group: Group, deals: [Deal])] {
        let all = ordered
        return Group.allCases.compactMap { g in
            let list = all.filter { Group($0) == g }
            return list.isEmpty ? nil : (g, list)
        }
    }

    /// How long a deal still counts as new for Today's card and for a notification.
    public static let freshFor: TimeInterval = 24 * 3600

    /// "Act now" deals seen in the last day (when the list says nothing about a deal's time, the list's own time
    /// stands in), best order. Today's card shows these, and only these.
    public func freshAct(now: Date = Date()) -> [Deal] {
        ordered.filter { d in
            guard d.verdict == .act, let at = d.seen ?? updated else { return false }
            return DealList.isRecent(at, now: now, within: Self.freshFor)
        }
    }

    public var actCount: Int { deals.filter { $0.verdict == .act }.count }
}

/// When to ask the server for deals (so a server without them is asked rarely and a server with them not on every
/// 30 s poll).
public enum DealsFetch {
    /// A server that has deals: at most this often.
    public static let interval: TimeInterval = 120
    /// A server that does not list `deals` and has not answered with some: the probe is repeated this often (a
    /// server can gain the endpoint without an app restart; 404 is its way to say "not here").
    public static let probeInterval: TimeInterval = 600

    /// `listed`: `deals` is in the server's features. `available`: the last answer had deals. `fetched`: the last
    /// time it was asked (any answer).
    public static func shouldFetch(listed: Bool, available: Bool, fetched: Date?, now: Date = Date()) -> Bool {
        guard let fetched else { return true }
        let wait = listed || available ? interval : probeInterval
        // A clock that went back must not stop the asking for ever.
        let age = now.timeIntervalSince(fetched)
        return age >= wait || age < 0
    }
}

/// How prices and shares read. Whole euros without cents, a non-breaking space before the number, a real minus.
public enum DealFormat {
    /// "€ 100", "€ 99.50", "€ 1250" (no thousands separator: it keeps a row short).
    public static func price(_ euros: Double) -> String {
        let whole = euros.rounded()
        if abs(euros - whole) < 0.005 { return "€\u{00A0}\(Int(clamping: whole, in: 0...10_000_000))" }
        return "€\u{00A0}" + String(format: "%.2f", euros)
    }

    /// "−50 %" for a share of 0.5; nil for nothing.
    public static func discount(_ share: Double?) -> String? {
        guard let share, share.isFinite, share > 0 else { return nil }
        let percent = Int(clamping: min(share, 1) * 100, in: 1...100)
        return "\u{2212}\(percent)\u{00A0}%"
    }

    /// For VoiceOver: "50 percent below the market value".
    public static func spokenDiscount(_ share: Double?) -> String? {
        guard let share, share.isFinite, share > 0 else { return nil }
        return "\(Int(clamping: min(share, 1) * 100, in: 1...100)) percent below the market value"
    }

    /// The asking price and, when known, the market value: "€ 100 · worth about € 200".
    public static func priceLine(_ deal: Deal) -> String? {
        switch (deal.price, deal.value) {
        case let (p?, v?): "\(price(p)) · worth about \(price(v))"
        case let (p?, nil): price(p)
        case let (nil, v?): "worth about \(price(v))"
        default: nil
        }
    }
}

extension DealList {
    /// The deals the notification diff may announce.
    static func notifiable(_ deals: [Deal], now: Date, maxAge: TimeInterval) -> [Deal] {
        deals.filter { d in
            guard d.verdict == .act else { return false }
            // A deal with no time can't be called new, and an old one was seen long ago (an offline day).
            guard let at = d.seen else { return false }
            return isRecent(at, now: now, within: maxAge)
        }
    }

    /// Seen within `within` before now. Up to an hour ahead counts as now (a server clock running a bit fast);
    /// further ahead is a wrong time, not a new deal, or it would stay "new" until a day after that time.
    static func isRecent(_ at: Date, now: Date, within: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(at)
        return age >= -3600 && age <= within
    }
}
