import Foundation
import Testing
@testable import HomelabKit

/// Review 2026-11-08 rows 30-32: News summaries, newest first, EN / DE; deals by category.
@Suite struct NewsDealsReviewTests {
    func date(_ s: String) -> Date { ServerDate.parse(s)! }

    // MARK: News

    @Test func newsItemFieldsDecodeAndStayOutWhenAbsent() throws {
        let json = """
        {"id":"news","subtitle":"Digest","subtitle_de":"Überblick","items":[
          {"title":"A","title_de":"Ä","summary":"One. Two.","summary_de":"Eins. Zwei.","published":"2026-11-08T19:30:00+01:00"},
          {"title":"B"}]}
        """
        let card = try JSONDecoder().decode(Card.self, from: Data(json.utf8))
        #expect(card.subtitleDE == "Überblick")
        #expect(card.items[0].titleDE == "Ä" && card.items[0].summaryDE == "Eins. Zwei.")
        #expect(card.items[0].published == date("2026-11-08T18:30:00Z"))
        #expect(card.items[1].summary == nil && card.items[1].published == nil)
        // Cards without the new fields encode as before (no new keys).
        let plain = try JSONEncoder().encode(Card(id: "x", items: [.init(title: "T")]))
        let text = String(decoding: plain, as: UTF8.self)
        #expect(!text.contains("_de") && !text.contains("summary") && !text.contains("published"))
        // And the new ones round trip.
        let again = try JSONDecoder().decode(Card.self, from: JSONEncoder().encode(card))
        #expect(again == card)
    }

    func news() -> Card {
        Card(id: "news", subtitle: "Digest", icon: "newspaper", items: [
            .init(title: "Old", titleDE: "Alt", summary: "Old sum", summaryDE: "Alte Summe", published: date("2026-11-08T08:00:00Z")),
            .init(title: "New", titleDE: nil, summary: "New sum", summaryDE: nil, published: date("2026-11-08T10:00:00Z")),
            .init(title: "Undated", titleDE: "Undatiert"),
            .init(title: "Mid", titleDE: "Mitte", summary: "  ", summaryDE: "Mitte Summe", published: date("2026-11-08T09:00:00Z")),
        ], subtitleDE: "Überblick")
    }

    @Test func newsSortsNewestFirstByPublishedAndKeepsUndatedLast() {
        let list = NewsList(card: news())
        #expect(list.rows.map(\.title) == ["New", "Mid", "Old", "Undated"])
        #expect(list.rows.map(\.id) == [0, 1, 2, 3])
        // Without a single date the server's order stands.
        var plain = news()
        plain.items = plain.items.map { var i = $0; i.published = nil; return i }
        #expect(NewsList(card: plain).rows.map(\.title) == ["Old", "New", "Undated", "Mid"])
    }

    @Test func newsLanguageAndFallbacks() {
        let en = NewsList(card: news())
        #expect(en.digest == "Digest" && en.rows[0].summary == "New sum")
        #expect(en.rows[1].summary == "Mitte Summe")          // blank English summary falls back to German
        let de = NewsList(card: news(), language: .de)
        #expect(de.digest == "Überblick")
        #expect(de.rows.map(\.title) == ["New", "Mitte", "Alt", "Undatiert"])   // "New" has no German headline
        #expect(de.rows[0].summary == "New sum")             // no German summary: English
        #expect(de.rows[2].summary == "Alte Summe")
        #expect(de.rows[3].summary == nil)
        var onlyDE = news()
        onlyDE.subtitle = nil
        #expect(NewsList(card: onlyDE).digest == "Überblick")
        onlyDE.subtitleDE = nil
        #expect(NewsList(card: onlyDE).digest == nil)
    }

    @Test func newsLanguageSettingIsOptionalAndOmittedAtDefault() throws {
        var s = AppSettings()
        #expect(s.newsLang == .en)
        let before = try Storage.encoder.encode(s)
        s.newsLang = .de
        #expect(s.newsLanguage == "de")
        let back = try JSONDecoder().decode(AppSettings.self, from: Storage.encoder.encode(s))
        #expect(back.newsLang == .de)
        s.newsLang = .en
        #expect(try Storage.encoder.encode(s) == before)
        #expect(!String(decoding: before, as: UTF8.self).contains("newsLanguage"))
    }

    @Test func demoNewsHasGermanAndSummaries() throws {
        let state = try fixture(HomelabState.self, "demo-today.json")
        let card = try #require(state.cards.first { $0.id == "news" })
        let de = NewsList(card: card, language: .de)
        #expect(de.rows.count == 5 && de.rows.allSatisfy { $0.summary != nil })
        #expect(de.digest?.hasPrefix("Das Parlament") == true)
        #expect(de.rows.map(\.published) == de.rows.map(\.published).sorted { ($0 ?? .distantPast) > ($1 ?? .distantPast) })
    }

    // MARK: Deals

    func deal(_ id: Int64, _ category: String?, _ verdict: Deal.Verdict? = .act) -> Deal {
        Deal(id: id, title: "Deal \(id)", price: 100, value: 200, seen: Date(timeIntervalSince1970: 1_794_044_400 - 600),
             verdict: verdict, category: category)
    }

    let now = Date(timeIntervalSince1970: 1_794_044_400)
    let cats = [DealCategory(id: "gpu", name: "Graphics cards"), DealCategory(id: "ram", name: "Memory")]

    func list() -> DealList {
        DealList(updated: now, deals: [deal(1, "gpu"), deal(2, "ram"), deal(3, "other"), deal(4, nil)], categories: cats)
    }

    @Test func dealCategoriesDecode() throws {
        let json = """
        {"updated":"2026-11-07T09:50:51Z","categories":[{"id":"GPU","name":"Graphics cards"},{"id":"gpu"},{"id":"other","name":"x"},{"name":"no id"}],
         "deals":[{"id":5,"title":"A","category":"GPU"},{"id":6,"title":"B"}]}
        """
        let l = try JSONDecoder().decode(DealList.self, from: Data(json.utf8))
        #expect(l.categories == [DealCategory(id: "gpu", name: "Graphics cards")])   // lower case, no duplicate, no "other"
        #expect(l.deals.map(\.category) == ["gpu", nil])
        // The demo fixture has categories; a plain list has none and encodes without the key.
        let demo = try fixture(DealList.self, "deals.json")
        #expect(demo.categories.map(\.id) == ["gpu", "ram", "ssd"] && demo.deals.last?.category == "other")
        let plain = try JSONEncoder().encode(DealList(deals: [Deal(id: 1, title: "T")]))
        #expect(!String(decoding: plain, as: UTF8.self).contains("categor"))
    }

    @Test func chosenCategoriesFilterTheList() {
        let l = list()
        #expect(l.chosen(nil).deals.count == 4)
        #expect(l.chosen(["gpu"]).deals.map(\.id) == [1])
        #expect(l.others(["gpu"]).map(\.id).sorted() == [2, 3, 4])
        #expect(l.chosen([]).deals.isEmpty && l.others([]).count == 4)
        #expect(l.others(nil).isEmpty)
        // A server without categories: the choice means nothing.
        var bare = l
        bare.categories = []
        #expect(bare.chosen(["gpu"]).deals.count == 4 && bare.others(["gpu"]).isEmpty)
    }

    @Test func tileAndTodayCountUseChosenCategories() {
        let l = list()
        #expect(l.freshAct(now: now).count == 4)
        #expect(l.freshAct(now: now, categories: ["ram"]).map(\.id) == [2])
        let tiles = TodayFold.tiles(cards: [], deals: l.freshAct(now: now, categories: ["gpu", "ram"]), density: .standard)
        #expect(tiles.first?.kind == .deals && tiles.first?.count == 2)
        #expect(TodayFold.tiles(cards: [], deals: l.freshAct(now: now, categories: []), density: .standard).isEmpty)
    }

    @Test func notificationsOnlyForChosenCategories() {
        let calm = HomelabState(status: .ok)
        let server = UUID()
        let opts = AlertTracker.Options(problems: true, pending: true, deals: true, dealCategories: ["gpu"])
        var t = AlertTracker()
        _ = t.update(with: calm, deals: DealList(updated: now, deals: [], categories: cats), server: "lab", serverID: server,
                     options: opts, now: now.addingTimeInterval(-300))
        let out = t.update(with: calm, deals: list(), server: "lab", serverID: server, options: opts, now: now)
        #expect(out.map(\.id) == ["deal-1"])
        // Every deal was learned all the same: choosing more categories later does not announce old deals.
        let more = AlertTracker.Options(problems: true, pending: true, deals: true, dealCategories: nil)
        #expect(t.update(with: calm, deals: list(), server: "lab", serverID: server, options: more, now: now + 60).isEmpty)
    }

    @Test func categoryChoiceToggles() {
        let all = ["gpu", "ram"]
        #expect(DealCategoryChoice.isOn("gpu", chosen: nil))
        #expect(DealCategoryChoice.setting("gpu", on: false, chosen: nil, all: all) == ["ram"])
        #expect(DealCategoryChoice.setting("gpu", on: true, chosen: ["ram"], all: all) == nil)   // all on = nothing stored
        #expect(DealCategoryChoice.setting("ram", on: false, chosen: ["ram"], all: all) == [])
        #expect(!DealCategoryChoice.isOn("gpu", chosen: ["ram"]))
    }

    @Test func dealSettingIsOptionalAndLenient() throws {
        var s = AppSettings()
        let before = try Storage.encoder.encode(s)
        s.dealCategories = ["gpu"]
        let back = try JSONDecoder().decode(AppSettings.self, from: Storage.encoder.encode(s))
        #expect(back.dealCategories == ["gpu"])
        s.dealCategories = nil
        #expect(try Storage.encoder.encode(s) == before)
        // A wrong type falls back to "all" without losing the rest.
        let odd = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"faceIDLock":true,"dealCategories":"gpu"}"#.utf8))
        #expect(odd.faceIDLock && odd.dealCategories == nil)
    }
}
