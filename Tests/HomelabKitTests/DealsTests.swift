import Foundation
import Testing
@testable import HomelabKit

/// Deals (`GET /deals`, feature `deals`): decoding, order, the client, when to ask, and the screen's text. The model
/// tests with a server are in `DealsModelTests`, the notification diff in `DealAlertTests`.
@Suite struct DealsTests {
    let now = Date(timeIntervalSince1970: 1_794_044_400)   // 2026-11-07 10:20 UTC

    // MARK: Decoding

    @Test func fixtureDecodes() throws {
        let list = try fixture(DealList.self, "deals.json")
        #expect(list.deals.count == 5 && list.updated != nil)
        let gpu = try #require(list.deals.first)
        #expect(gpu.id == 1310779339 && gpu.watch == "any-gpu" && gpu.kind == "gpu")
        #expect(gpu.price == 140 && gpu.value == 280 && gpu.discount == 0.5 && gpu.confidence == .high)
        #expect(gpu.specs == "8 GB · GDDR6 · 2 fans" && gpu.place == "Krems an der Donau, Niederösterreich")
        #expect(gpu.near && gpu.isPrivate == true && gpu.ships == true && gpu.condition == "like new")
        #expect(gpu.verdict == .act && gpu.note?.hasPrefix("Half the usual price") == true && gpu.flags.isEmpty)
        #expect(gpu.url?.host == "www.willhaben.at" && gpu.comps.count == 3 && gpu.comps[0].price == 265)
        #expect(gpu.comps[0].url?.host == "www.willhaben.at" && gpu.seen != nil)
        let scam = try #require(list.deals.first { $0.id == 1310441906 })
        #expect(scam.warnsOfScam && scam.flags.count == 2 && scam.verdict == .skip && !scam.near && scam.ships == false)
        let dealer = try #require(list.deals.first { $0.id == 1310555871 })
        #expect(dealer.near == false && dealer.isPrivate == false && dealer.sellerWord == "dealer")
        let plain = try #require(list.deals.last)
        #expect(plain.verdict == nil && plain.note == nil && plain.condition == nil)
    }

    @Test func contractExampleDecodes() throws {
        let json = """
        {"updated": "2026-11-07T09:50:51Z",
         "deals": [{"id": 1310779339, "watch": "any-gpu", "kind": "gpu", "title": "G Skill Trident Z RGB 32GB 3200Mhz",
           "price": 100.0, "value": 200.0, "discount": 0.5, "conf": "high", "specs": "ddr4 · dimm · 2x16 · 3200 MHz",
           "loc": "Krems an der Donau", "state": "Niederösterreich", "near": true, "private": true, "ships": true,
           "cond": "used", "url": "https://www.willhaben.at/iad/kaufen-und-verkaufen/d/x-1310779339/",
           "flags": ["too good to be true? price far below every comparable", "urgent sale (Notverkauf)", "dealer"],
           "seen": "2026-11-07T09:50:51Z", "verdict": "act", "note": "one line from the agent",
           "comps": [{"title": "Trident Z 32GB", "price": 185.0, "url": "https://www.willhaben.at/iad/kaufen-und-verkaufen/d/c/"}]}]}
        """
        let list = try decode(DealList.self, json)
        let d = try #require(list.deals.first)
        #expect(list.updated == Date(timeIntervalSince1970: 1_794_045_051))
        #expect(d.title == "G Skill Trident Z RGB 32GB 3200Mhz" && d.share == 0.5 && d.flags.count == 3 && d.warnsOfScam)
        #expect(DealFormat.discount(d.share) == "\u{2212}50\u{00A0}%" && DealFormat.priceLine(d) == "€\u{00A0}100 · worth about €\u{00A0}200")
    }

    @Test func oddAnswerKeepsWhatItCan() throws {
        let list = try fixture(DealList.self, "deals-odd.json")
        #expect(list.deals.map(\.id) == [1310000001, 1310000002, 1310000004])   // dupes, no id, id 0, no title: dropped
        let text = list.deals[0]
        #expect(text.title == "Everything as text" && text.price == 99.5 && text.value == 200)
        #expect(text.share == 0.5)                                              // "50" is a percent: read as a share
        #expect(text.confidence == .high && text.near && text.isPrivate == false && text.ships == true)
        #expect(text.condition == "like new" && text.verdict == .act && text.seen != nil)
        #expect(text.flags == ["a single flag, not a list"])
        #expect(text.comps.map(\.title) == ["kept", nil, "javascript link"])    // "not an object" dropped
        #expect(text.comps[1].url?.host == "www.willhaben.at" && text.comps[2].url == nil)   // javascript: dropped
        let unknown = list.deals[1]
        #expect(unknown.confidence == nil && unknown.verdict == nil && unknown.condition == "refurbished")
        #expect(unknown.price == nil && unknown.value == nil && unknown.discount == nil)   // 1e30, -5, -0.2: no price
        #expect(unknown.specs == "12" && unknown.flags == ["3", "real flag"] && unknown.url == nil && unknown.comps.isEmpty)
        let nulls = list.deals[2]
        #expect(!nulls.near && nulls.isPrivate == nil && nulls.verdict == nil && nulls.flags.isEmpty && nulls.comps.isEmpty)
        #expect(list.updated != nil)                                            // epoch seconds
    }

    @Test func wrongShapesDontThrowAwayTheList() throws {
        #expect(try decode(DealList.self, "{}").deals.isEmpty)
        #expect(try decode(DealList.self, #"{"deals": "none"}"#).deals.isEmpty)
        #expect(try decode(DealList.self, #"{"deals": {"id": 1}}"#).deals.isEmpty)
        let bare = try decode(DealList.self, #"[{"id": 1, "title": "a"}, {"id": 2, "title": "b"}]"#)
        #expect(bare.deals.map(\.id) == [1, 2])
    }

    @Test func atMostOneHundredAndTextIsCut() throws {
        let many = (1...150).map { #"{"id": \#($0), "title": "ad \#($0)"}"# }.joined(separator: ",")
        #expect(try decode(DealList.self, "{\"deals\": [\(many)]}").deals.count == 100)
        let long = String(repeating: "x", count: 1000)
        let d = try decode(Deal.self, #"{"id": 5, "title": "\#(long)", "note": "\#(long)", "flags": ["\#(long)"]}"#)
        #expect(d.title.count <= 240 && d.note!.count <= 400 && d.flags[0].count <= 240)
        let many12 = (1...20).map { _ in #"{"title": "c", "price": 1}"# }.joined(separator: ",")
        #expect(try decode(Deal.self, #"{"id": 5, "title": "t", "comps": [\#(many12)], "flags": ["a","b","c","d","e","f","g","h","i","j"]}"#).comps.count == 12)
        #expect(try decode(Deal.self, #"{"id": 5, "title": "t", "flags": ["a","b","c","d","e","f","g","h","i","j"]}"#).flags.count == 8)
    }

    @Test func linksAreWebLinksOnly() throws {
        for bad in ["javascript:alert(1)", "file:///etc/passwd", "homelab://actions", "https://user:pw@www.willhaben.at/x",
                    "//www.willhaben.at/x", "not a url", "https://" + String(repeating: "a", count: 3000) + ".at/"] {
            let d = try decode(Deal.self, #"{"id": 5, "title": "t", "url": "\#(bad)"}"#)
            #expect(d.url == nil, "\(bad.prefix(40))")
        }
        #expect(try decode(Deal.self, #"{"id": 5, "title": "t", "url": "http://www.willhaben.at/x"}"#).url != nil)
    }

    @Test func encodesTheSameShapeBack() throws {
        let list = try fixture(DealList.self, "deals.json")
        let again = try JSONDecoder().decode(DealList.self, from: JSONEncoder().encode(list))
        #expect(again == list)
    }

    // MARK: Share and words

    @Test func shareFallsBackToThePrices() {
        #expect(Deal(id: 1, title: "t", price: 100, value: 200).share == 0.5)
        #expect(Deal(id: 1, title: "t", price: 100, value: 200, discount: 0.3).share == 0.3)   // the server's number wins
        #expect(Deal(id: 1, title: "t", price: 200, value: 100).share == nil)                 // above its value
        #expect(Deal(id: 1, title: "t", price: 100).share == nil && Deal(id: 1, title: "t").share == nil)
        #expect(Deal(id: 1, title: "t", price: 0, value: 100).share == 1)
        #expect(Deal(id: 1, title: "t", discount: 0).share == nil)
    }

    @Test func pricesAndSharesRead() {
        let nb = "\u{00A0}"
        #expect(DealFormat.price(100) == "€\(nb)100" && DealFormat.price(99.5) == "€\(nb)99.50" && DealFormat.price(0) == "€\(nb)0")
        #expect(DealFormat.price(1250) == "€\(nb)1250" && DealFormat.price(99.999) == "€\(nb)100")
        #expect(DealFormat.discount(0.5) == "\u{2212}50\(nb)%" && DealFormat.discount(0.004) == "\u{2212}1\(nb)%")
        #expect(DealFormat.discount(1) == "\u{2212}100\(nb)%" && DealFormat.discount(0) == nil && DealFormat.discount(nil) == nil)
        #expect(DealFormat.discount(.nan) == nil && DealFormat.discount(7) == "\u{2212}100\(nb)%")
        #expect(DealFormat.spokenDiscount(0.5) == "50 percent below the market value" && DealFormat.spokenDiscount(nil) == nil)
        #expect(DealFormat.priceLine(Deal(id: 1, title: "t", price: 5)) == "€\(nb)5")
        #expect(DealFormat.priceLine(Deal(id: 1, title: "t", value: 5)) == "worth about €\(nb)5")
        #expect(DealFormat.priceLine(Deal(id: 1, title: "t")) == nil)
    }

    @Test func placeAndWords() {
        #expect(Deal(id: 1, title: "t", location: "Wien", state: "Wien").place == "Wien")
        #expect(Deal(id: 1, title: "t", location: "Linz", state: "Oberösterreich").place == "Linz, Oberösterreich")
        #expect(Deal(id: 1, title: "t", state: "Tirol").place == "Tirol" && Deal(id: 1, title: "t").place == nil)
        #expect(Deal(id: 1, title: "t", isPrivate: true).sellerWord == "private" && Deal(id: 1, title: "t").sellerWord == nil)
        #expect(Deal(id: 1, title: "t", condition: "like new").conditionWord == "Like new")
        #expect(Deal(id: 1, title: "t", flags: ["Too good to be true? x"]).warnsOfScam)
        #expect(!Deal(id: 1, title: "t", flags: ["dealer"]).warnsOfScam)
    }

    @Test func spokenSentence() throws {
        let d = try #require(try fixture(DealList.self, "deals.json").deals.first { $0.id == 1310441906 })
        let said = d.spoken
        #expect(said.hasPrefix("Gaming card, never opened, €\u{00A0}90, 78 percent below the market value, skipped, low confidence"))
        #expect(said.contains("private seller") && said.contains("warning: too good to be true?") && !said.contains("ships"))
        let near = Deal(id: 1, title: "t", location: "Wien", state: "Wien", near: true, ships: true, verdict: .act)
        #expect(near.spoken == "t, act now, Wien, near you, ships")
        #expect(Deal(id: 1, title: "t").spoken == "t")
    }

    // MARK: Order and groups

    func deal(_ id: Int64, _ verdict: Deal.Verdict?, hoursAgo: Double?, price: Double? = nil, value: Double? = nil) -> Deal {
        Deal(id: id, title: "d\(id)", price: price, value: value, seen: hoursAgo.map { now.addingTimeInterval(-$0 * 3600) }, verdict: verdict)
    }

    @Test func actComesFirstThenNewest() {
        let list = DealList(updated: now, deals: [
            deal(1, .skip, hoursAgo: 1), deal(2, nil, hoursAgo: 2), deal(3, .consider, hoursAgo: 30),
            deal(4, .act, hoursAgo: 40), deal(5, .act, hoursAgo: 3), deal(6, .consider, hoursAgo: 5), deal(7, nil, hoursAgo: nil)])
        #expect(list.ordered.map(\.id) == [5, 4, 6, 3, 2, 7, 1])   // act (newest first), consider, unjudged (no time last), skip
    }

    @Test func sameTimeGoesByDiscountThenServerOrder() {
        let list = DealList(deals: [deal(1, .act, hoursAgo: 1, price: 90, value: 100), deal(2, .act, hoursAgo: 1, price: 50, value: 100),
                                    deal(3, .act, hoursAgo: 1, price: 50, value: 100)])
        #expect(list.ordered.map(\.id) == [2, 3, 1])
    }

    @Test func groupsLeaveOutEmptyOnes() {
        let list = DealList(deals: [deal(1, .skip, hoursAgo: 1), deal(2, nil, hoursAgo: 2), deal(3, .consider, hoursAgo: 1)])
        #expect(list.groups.map(\.group) == [.look, .skipped])
        #expect(list.groups[0].deals.map(\.id) == [3, 2] && list.groups[0].group.title == "Worth a look")
        #expect(DealList().groups.isEmpty && DealList.Group.act.title == "Act now")
        #expect(DealList(deals: [deal(1, .act, hoursAgo: 1)]).groups.map(\.group) == [.act])
    }

    @Test func freshActIsActSeenInTheLastDay() {
        let list = DealList(updated: now, deals: [
            deal(1, .act, hoursAgo: 2), deal(2, .act, hoursAgo: 23), deal(3, .act, hoursAgo: 25), deal(4, .consider, hoursAgo: 1),
            deal(5, .act, hoursAgo: nil)])
        #expect(list.freshAct(now: now).map(\.id) == [1, 2, 5])   // 5 has no time: the list's own time (now) stands in
        #expect(DealList(deals: [deal(5, .act, hoursAgo: nil)]).freshAct(now: now).isEmpty)   // no time anywhere
        #expect(list.actCount == 4)
        // The list is the same one day later: nothing is fresh any more.
        #expect(DealList(updated: now, deals: [deal(1, .act, hoursAgo: 2)]).freshAct(now: now.addingTimeInterval(23 * 3600)).isEmpty)
    }

    // MARK: When to ask

    @Test func askingPolicy() {
        let t = Date(timeIntervalSince1970: 1_794_000_000)
        #expect(DealsFetch.shouldFetch(listed: false, available: false, fetched: nil, now: t))            // never asked
        #expect(DealsFetch.shouldFetch(listed: true, available: true, fetched: nil, now: t))
        // A server that has deals: every two minutes, not on each 30 s poll.
        #expect(!DealsFetch.shouldFetch(listed: true, available: true, fetched: t.addingTimeInterval(-30), now: t))
        #expect(DealsFetch.shouldFetch(listed: true, available: true, fetched: t.addingTimeInterval(-121), now: t))
        #expect(!DealsFetch.shouldFetch(listed: false, available: true, fetched: t.addingTimeInterval(-60), now: t))
        // One that doesn't list them and answered 404: a probe every ten minutes.
        #expect(!DealsFetch.shouldFetch(listed: false, available: false, fetched: t.addingTimeInterval(-599), now: t))
        #expect(DealsFetch.shouldFetch(listed: false, available: false, fetched: t.addingTimeInterval(-601), now: t))
        // A listed one that failed to answer is asked again after two minutes.
        #expect(DealsFetch.shouldFetch(listed: true, available: false, fetched: t.addingTimeInterval(-121), now: t))
        // A clock that went back doesn't silence it.
        #expect(DealsFetch.shouldFetch(listed: false, available: false, fetched: t.addingTimeInterval(3600), now: t))
    }

    // MARK: Client

    @Test func clientAsksForDealsWithTheLogin() async throws {
        let t = FakeTransport(fixture: "deals.json")
        let list = try await CompanionClient(baseURL: base, token: "tok", transport: t).deals()
        let req = try #require(t.last)
        #expect(req.httpMethod == "GET" && req.url?.path == "/api/v1/deals" && req.url?.query == nil)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok" && req.value(forHTTPHeaderField: "Origin") == nil)
        #expect(list.deals.count == 5)
    }

    @Test func clientAnswersNotFoundFor404() async {
        func error(_ status: Int, _ body: String = "{}") async -> APIError? {
            let t = FakeTransport(status: status, json: body)
            do { _ = try await CompanionClient(baseURL: base, token: nil, transport: t).deals(); return nil }
            catch { return error as? APIError }
        }
        #expect(await error(404, #"{"error": "not found"}"#) == .notFound)
        #expect(await error(401) == .unauthorized)
        #expect(await error(403) == .forbidden)
        #expect(await error(500) == .server(status: 500))
        #expect(await error(429) == .tooManyRequests)
        #expect(await error(200, "<html></html>") != nil)         // a page instead of JSON
        #expect(await error(200, "[1]") == nil)                    // a list of junk is an empty list, not an error
    }

    @Test func tokenNeverGoesOverPlainHttp() async {
        let t = FakeTransport(fixture: "deals.json")
        let client = CompanionClient(baseURL: URL(string: "http://192.168.1.10:8080")!, token: "tok", transport: t)
        await #expect(throws: APIError.self) { try await client.deals() }
        #expect(t.requests.isEmpty)
    }

    @Test func demoServesDealsThatAreCurrent() async throws {
        let demo = DemoBackend(delay: .zero)
        let list = try await demo.deals()
        #expect(list.deals.count == 5 && list.updated != nil)
        let newest = try #require(list.deals.compactMap(\.seen).max())
        #expect(abs(newest.timeIntervalSinceNow + 40 * 60) < 60)
        #expect(!list.freshAct().isEmpty)
        #expect(try await demo.info().features.contains(.deals))
    }
}
