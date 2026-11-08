import Foundation

// News (optional: card `news` in /state, `GET /news/sources`, `PUT /news/prefs`; docs/API.md "News"). The server
// fetches the feeds and summarises; the app shows the card as a Today tile and a sheet and edits the server's prefs.
// The prefs live on the server (settings.json stores nothing). Models decode tolerantly; the rules are plain
// functions so Linux tests them. Foundation only.

/// What the server offers: countries, sources, the stored prefs, and whether it can summarise.
public struct NewsCatalog: Codable, Sendable, Equatable {
    public struct Country: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
        enum CodingKeys: String, CodingKey { case id, name }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let id = c.text(.id)?.lowercased() else {
                throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "no id"))
            }
            self.init(id: id, name: c.text(.name) ?? id.uppercased())
        }
    }

    public struct Source: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        /// Country id; empty for an international source.
        public var country: String
        /// "general", "tech", ...
        public var topic: String
        public init(id: String, name: String, country: String = "", topic: String = "general") {
            self.id = id; self.name = name; self.country = country; self.topic = topic
        }
        enum CodingKeys: String, CodingKey { case id, name, country, topic }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let id = c.text(.id) else {
                throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "no id"))
            }
            self.init(id: id, name: c.text(.name) ?? id, country: c.text(.country)?.lowercased() ?? "",
                      topic: c.text(.topic)?.lowercased() ?? "general")
        }
    }

    public var countries: [Country]
    public var sources: [Source]
    public var prefs: NewsPrefs
    public var canSummarize: Bool

    public init(countries: [Country] = [], sources: [Source] = [], prefs: NewsPrefs = NewsPrefs(), canSummarize: Bool = false) {
        self.countries = countries; self.sources = sources; self.prefs = prefs; self.canSummarize = canSummarize
    }

    enum CodingKeys: String, CodingKey { case countries, sources, prefs, canSummarize = "can_summarize" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let can = c.bool(.canSummarize) ?? false
        let prefs = (c.lenient(NewsPrefs.self, .prefs) ?? NewsPrefs()).validated(canSummarize: can)
        self.init(countries: c.array(Country.self, .countries), sources: c.array(Source.self, .sources),
                  prefs: prefs, canSummarize: can)
    }

    /// The sources to offer for a country: its own, plus every non-"general" topic (tech) and international source,
    /// so "Austria" lists ORF and heise. In the server's order.
    public func sources(for country: String) -> [Source] {
        let c = country.lowercased()
        return sources.filter { $0.country == c || $0.country.isEmpty || $0.topic != "general" }
    }

    /// The prefs after the owner picks a country: sources that don't belong to it any more are dropped.
    public func prefs(_ prefs: NewsPrefs, country: String) -> NewsPrefs {
        var p = prefs
        p.country = country.lowercased()
        let offered = Set(sources(for: p.country).map(\.id))
        p.sources = p.sources.filter(offered.contains)
        return p
    }

    /// The prefs after switching one source on or off (kept in the catalog's order).
    public func prefs(_ prefs: NewsPrefs, toggling source: String) -> NewsPrefs {
        var p = prefs
        var on = Set(p.sources)
        if on.remove(source) == nil { on.insert(source) }
        p.sources = sources.map(\.id).filter(on.contains)
        return p
    }
}

/// The owner's news choices, as the server stores them.
public struct NewsPrefs: Codable, Sendable, Equatable {
    public static let counts = [3, 5, 8]
    public static let windows = [12, 24, 48]

    public var enabled: Bool
    public var country: String
    public var sources: [String]
    /// A digest and one-line summaries (needs `can_summarize`); false = the original headlines.
    public var summary: Bool
    public var count: Int
    public var windowH: Int

    public init(enabled: Bool = true, country: String = "", sources: [String] = [], summary: Bool = false,
                count: Int = 5, windowH: Int = 24) {
        self.enabled = enabled; self.country = country; self.sources = sources; self.summary = summary
        self.count = count; self.windowH = windowH
    }

    enum CodingKeys: String, CodingKey { case enabled, country, sources, summary, count, windowH = "window_h" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: c.bool(.enabled) ?? true, country: c.text(.country)?.lowercased() ?? "",
                  sources: c.strings(.sources), summary: c.bool(.summary) ?? false,
                  count: c.int(.count) ?? 5, windowH: c.int(.windowH) ?? 24)
    }

    /// The server's rules, mirrored: count in 3/5/8 and window in 12/24/48 h (else the nearest), no duplicate
    /// sources, no summary when the server can't summarise.
    public func validated(canSummarize: Bool) -> NewsPrefs {
        var p = self
        p.count = Self.nearest(count, in: Self.counts)
        p.windowH = Self.nearest(windowH, in: Self.windows)
        var seen = Set<String>()
        p.sources = sources.filter { seen.insert($0).inserted }
        if !canSummarize { p.summary = false }
        return p
    }

    static func nearest(_ value: Int, in allowed: [Int]) -> Int {
        allowed.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    /// The body of `PUT /news/prefs`.
    public func body() -> Data {
        let object: [String: Any] = ["enabled": enabled, "country": country, "sources": sources, "summary": summary,
                                     "count": count, "window_h": windowH]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

struct NewsPrefsReply: Decodable {
    var prefs: NewsPrefs?
    enum CodingKeys: String, CodingKey { case prefs }
    init(from decoder: any Decoder) throws {
        prefs = try decoder.container(keyedBy: CodingKeys.self).lenient(NewsPrefs.self, .prefs)
    }
}

/// Whether Settings offers News: only when `GET /news/sources` answers. A 404 (no news here), an error or a
/// catalog without a single source all hide it, without a word.
public enum NewsAvailability {
    public static func catalog(_ api: any CompanionAPI) async -> NewsCatalog? {
        guard let catalog = try? await api.newsSources(), !catalog.sources.isEmpty else { return nil }
        return catalog
    }
}

/// The language of the News sheet: Settings → Advanced → Today → News sets the default, the switch at the top left of
/// the sheet changes it for the session. A missing `_de` field falls back to English and the other way round.
public enum NewsLanguage: String, Codable, Sendable, CaseIterable, Identifiable {
    case en, de
    public var id: String { rawValue }
    public var label: String { rawValue.uppercased() }

    /// The text in this language, else the other one; blank counts as missing.
    public func pick(en: String?, de: String?) -> String? {
        func clean(_ t: String?) -> String? {
            let t = t?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty ?? true) ? nil : t
        }
        let (e, d) = (clean(en), clean(de))
        return self == .de ? (d ?? e) : (e ?? d)
    }
}

/// The News card as the sheet shows it: the digest, then the rows newest first (by `published`; items without one
/// keep the server's order after the dated ones).
public struct NewsList: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var title: String
        /// "ORF · 2 h"
        public var meta: String
        /// The 2-3 sentence summary under the headline; nil when the server sent none.
        public var summary: String?
        public var url: URL?
        public var published: Date?
        /// The card item this row was made from (Hyperdetail's notes read it).
        public var item: Card.Item
        public var id: Int
    }

    public var digest: String?
    public var rows: [Row]

    public init(card: Card, language: NewsLanguage = .en) {
        self.digest = language.pick(en: card.subtitle, de: card.subtitleDE)
        var rows: [Row] = []
        for item in card.items {
            guard let title = language.pick(en: item.title, de: item.titleDE) else { continue }
            rows.append(Row(title: title, meta: item.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                            summary: language.pick(en: item.summary, de: item.summaryDE),
                            url: item.url.flatMap { URLPolicy.webURL($0.absoluteString) }, published: item.published,
                            item: item, id: 0))
        }
        // Stable: equal or missing times keep the server's order.
        let sorted = rows.enumerated().sorted { a, b in
            switch (a.element.published, b.element.published) {
            case let (x?, y?): x == y ? a.offset < b.offset : x > y
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.element)
        self.rows = sorted.enumerated().map { var r = $0.element; r.id = $0.offset; return r }
    }
}
