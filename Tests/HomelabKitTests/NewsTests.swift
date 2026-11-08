import Foundation
import Testing
@testable import HomelabKit

/// News (docs/API.md "News"): the catalog and prefs decode tolerantly, the prefs rules mirror the server's, the tile
/// says the top headline (Overkill the digest), the sheet keeps the server's order, and Settings shows News only when
/// `GET /news/sources` answers.
@Suite struct NewsTests {
    static let base = URL(string: "https://lab.example")!

    static func card(_ n: Int = 3, digest: String? = "Budget debate and a kernel release.") -> Card {
        Card(id: "news", title: "News", subtitle: digest, icon: "newspaper", style: .list, updated: "21:30",
             items: (0..<n).map { .init(title: "Story \($0)", subtitle: "ORF · \($0 + 1) h",
                                         url: URL(string: "https://orf.at/s/\($0)")) })
    }

    // MARK: Decoding

    @Test func catalogDecodesAndIgnoresUnknownFields() throws {
        let json = """
        {"countries":[{"id":"AT","name":"Austria","flag":"x"},{"name":"no id"}],
         "sources":[{"id":"orf","name":"ORF","country":"at","topic":"general","extra":1},{"id":"heise","name":"heise","country":"de","topic":"tech"},{"x":1}],
         "prefs":{"enabled":true,"country":"at","sources":["orf","heise","orf"],"summary":true,"count":"6","window_h":30,"future":true},
         "can_summarize":false,"new_field":[1,2]}
        """
        let c = try JSONDecoder().decode(NewsCatalog.self, from: Data(json.utf8))
        #expect(c.countries.map(\.id) == ["at"])
        #expect(c.sources.map(\.id) == ["orf", "heise"])
        #expect(c.prefs.sources == ["orf", "heise"])      // duplicate dropped
        #expect(c.prefs.count == 5 && c.prefs.windowH == 24)   // nearest allowed (6 -> 5, 30 -> 24)
        #expect(c.prefs.summary == false)                  // can_summarize is false
        #expect(c.canSummarize == false)
    }

    @Test func demoFixtureDecodes() throws {
        let c = try fixture(NewsCatalog.self, "news-sources.json")
        #expect(c.canSummarize && c.prefs.country == "at" && c.prefs.sources == ["orf", "heise"])
        #expect(c.sources(for: "at").map(\.id).contains("heise"))
        let state = try fixture(HomelabState.self, "demo-today.json")
        let news = try #require(state.cards.first { $0.id == "news" })
        #expect(TodayFold.tileKind(news) == .news && news.items.count == 5)
    }

    @Test func clientAsksAndPuts() async throws {
        let t = FakeTransport { r in
            if r.httpMethod == "PUT" {
                return .init(body: Data(#"{"ok":true,"prefs":{"enabled":true,"country":"de","sources":["heise"],"summary":false,"count":3,"window_h":12}}"#.utf8))
            }
            return .init(body: Fixtures.data("news-sources.json") ?? Data())
        }
        let api = CompanionClient(baseURL: Self.base, token: "tok", transport: t)
        let catalog = try await api.newsSources()
        #expect(t.last?.url?.path == "/api/v1/news/sources")
        let stored = try await api.setNewsPrefs(catalog.prefs)
        #expect(t.last?.httpMethod == "PUT" && t.last?.url?.path == "/api/v1/news/prefs")
        #expect(t.last?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let body = try JSONSerialization.jsonObject(with: try #require(t.last?.httpBody)) as? [String: Any]
        #expect(body?["window_h"] as? Int == 24 && body?["count"] as? Int == 5 && body?["sources"] as? [String] == ["orf", "heise"])
        #expect(stored.country == "de" && stored.count == 3)   // what the server stored
    }

    @Test func putErrorShowsTheServersWords() async {
        let t = FakeTransport(status: 400, json: #"{"error":"sources must be a list"}"#)
        let api = CompanionClient(baseURL: Self.base, token: nil, transport: t)
        do {
            _ = try await api.setNewsPrefs(NewsPrefs())
            Issue.record("expected an error")
        } catch {
            #expect((error as? APIError)?.message.contains("sources must be a list") == true)
        }
    }

    // MARK: Prefs rules

    @Test func prefsValidationMirrorsTheServer() {
        let p = NewsPrefs(enabled: true, country: "at", sources: ["a", "a", "b"], summary: true, count: 100, windowH: 1)
        let v = p.validated(canSummarize: true)
        #expect(v.sources == ["a", "b"] && v.count == 8 && v.windowH == 12 && v.summary)
        #expect(p.validated(canSummarize: false).summary == false)
        #expect(NewsPrefs(count: 4).validated(canSummarize: true).count == 3)
        for c in NewsPrefs.counts { #expect(NewsPrefs(count: c).validated(canSummarize: true).count == c) }
        for w in NewsPrefs.windows { #expect(NewsPrefs(windowH: w).validated(canSummarize: true).windowH == w) }
    }

    @Test func countryAndSourceToggles() throws {
        let c = try fixture(NewsCatalog.self, "news-sources.json")
        // Austria: its own sources plus tech/international; not Germany's general news.
        let at = c.sources(for: "at").map(\.id)
        #expect(at.contains("orf") && at.contains("heise") && at.contains("bbc") && !at.contains("tagesschau"))
        // Switching to Germany drops ORF, keeps heise.
        let de = c.prefs(c.prefs, country: "DE")
        #expect(de.country == "de" && de.sources == ["heise"])
        // Toggling keeps the catalog's order.
        let on = c.prefs(c.prefs, toggling: "derstandard")
        #expect(on.sources == ["orf", "derstandard", "heise"])
        #expect(c.prefs(on, toggling: "orf").sources == ["derstandard", "heise"])
    }

    // MARK: Tile and sheet

    @Test func tileLinesPerDensity() {
        func tile(_ card: Card, _ d: Density) -> TodayFold.Tile? { TodayFold.tiles(cards: [card], deals: [], density: d).first }
        #expect(tile(Self.card(), .standard)?.line == "Story 0")
        #expect(tile(Self.card(), .standard)?.count == 3)
        #expect(tile(Self.card(), .overkill)?.line == "Budget debate and a kernel release.")
        #expect(tile(Self.card(digest: nil), .overkill)?.line == "Story 0")
        #expect(tile(Self.card(0), .standard) == nil)
        #expect(tile(Self.card(), .standard)?.kind == .news && tile(Self.card(), .standard)?.urgent == false)
        let long = Card(id: "news", style: .list, items: [.init(title: String(repeating: "x", count: 300))])
        #expect(tile(long, .standard)!.line.count <= 60)
        #expect(TodayFold.TileKind.news.symbol == "newspaper" && TodayFold.TileKind.news.title == "News")
    }

    @Test func newsIsTheFourthTileAndLaysOutTwoByTwo() {
        let tiles = TodayFold.tiles(cards: [Self.card(), TodayFoldTests.grades(2), TodayFoldTests.downloads(3)],
                                    deals: Array(TodayFoldTests.deals.prefix(2)), density: .standard)
        #expect(tiles.map(\.kind) == [.deals, .downloads, .grades, .news])
        #expect(TodayFold.tileRows(count: tiles.count, stacked: false) == [2, 2])
        let plan = TodayFold.plan([Self.card()], dayCardID: nil)
        #expect(plan.blocks.isEmpty && plan.tileCards.count == 1)
    }

    @Test func sheetKeepsTheServersOrderAndOnlyOpensWebLinks() {
        var card = Self.card(4)
        card.items[1].title = "  "                                   // no title: no row
        card.items[2].url = URL(string: "javascript:alert(1)")      // not a web link: shown, not tappable
        let list = NewsList(card: card)
        #expect(list.digest == "Budget debate and a kernel release.")
        #expect(list.rows.map(\.title) == ["Story 0", "Story 2", "Story 3"])
        #expect(list.rows[0].meta == "ORF · 1 h" && list.rows[0].url?.host == "orf.at")
        #expect(list.rows[1].url == nil && list.rows[2].url != nil)
        #expect(NewsList(card: Self.card(digest: "  ")).digest == nil)
    }

    // MARK: Settings visibility

    @Test func settingsShowNewsOnlyWhenTheEndpointAnswers() async {
        let ok = CompanionClient(baseURL: Self.base, token: nil, transport: FakeTransport(fixture: "news-sources.json"))
        #expect(await NewsAvailability.catalog(ok) != nil)
        let missing = CompanionClient(baseURL: Self.base, token: nil, transport: FakeTransport(status: 404, json: "{}"))
        #expect(await NewsAvailability.catalog(missing) == nil)
        let broken = CompanionClient(baseURL: Self.base, token: nil, transport: FakeTransport(status: 500, json: "{}"))
        #expect(await NewsAvailability.catalog(broken) == nil)
        let html = CompanionClient(baseURL: Self.base, token: nil, transport: FakeTransport { _ in
            .init(body: Data("<html>".utf8), headers: ["Content-Type": "text/html"]) })
        #expect(await NewsAvailability.catalog(html) == nil)
        let empty = CompanionClient(baseURL: Self.base, token: nil, transport: FakeTransport(json: #"{"sources":[]}"#))
        #expect(await NewsAvailability.catalog(empty) == nil)
    }

    @Test func demoBackendAnswersAndAppliesPrefs() async throws {
        let demo = DemoBackend(delay: .milliseconds(1))
        #expect(await NewsAvailability.catalog(demo) != nil)
        func newsCard() async throws -> Card? { try await demo.state().cards.first { $0.id == "news" } }
        #expect(try await newsCard() != nil)
        var p = try await demo.newsSources().prefs
        p.count = 3
        _ = try await demo.setNewsPrefs(p)
        #expect(try await newsCard()?.items.count == 3)
        p.enabled = false
        _ = try await demo.setNewsPrefs(p)
        #expect(try await newsCard() == nil)
    }
}
