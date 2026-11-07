import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HomelabKit

/// Step 6d: `place` on cards, the `poster-grid` style and item `image`, the search endpoint, pictures (client,
/// loader, cache) and the search link.
@Suite struct SearchTests {
    let png = PlaceholderPoster.png(seed: "x")

    // MARK: Card.place, style and image

    @Test func placeIsLenient() throws {
        func place(_ json: String) throws -> Card.Place { try decode(Card.self, #"{"id": "c"\#(json)}"#).place }
        #expect(try place("") == .today)
        #expect(try place(#", "place": "lab""#) == .lab)
        #expect(try place(#", "place": "LAB""#) == .lab)
        #expect(try place(#", "place": "moon""#) == .today)
        #expect(try place(#", "place": 3"#) == .today)
        #expect(try place(#", "place": ["lab"]"#) == .today)
        // The cache keeps it; today is not written.
        let lab = Card(id: "t", place: .lab)
        let back = try JSONDecoder().decode(Card.self, from: JSONEncoder().encode(lab))
        #expect(back.place == .lab)
        #expect(!String(decoding: try JSONEncoder().encode(Card(id: "t")), as: UTF8.self).contains("place"))
    }

    @Test func labCardsFixture() throws {
        let s = try fixture(HomelabState.self, "state-lab-cards.json")
        #expect(s.cards.map(\.id) == ["tailnet", "dns", "dns-top", "backups", "mystery"])
        #expect(s.cards.map(\.place) == [.lab, .lab, .lab, .lab, .today])    // "moon" is Today
        #expect(s.cards[1].style == .metrics && s.cards[1].items[2].action?.name == "dns-pause")
        #expect(s.cards[3].items[1].progress == 0.03)
        // A lab metrics card is not the day card.
        #expect(s.dayCard == nil)
        let withToday = Card(id: "x", style: .metrics)
        #expect(HomelabState(cards: [Card(id: "dns", style: .metrics, place: .lab), withToday]).dayCard?.id == "x")
    }

    @Test func posterGridStyleAndImages() throws {
        let c = try decode(Card.self, """
        {"id": "s", "style": "poster-grid", "items": [
          {"title": "A", "image": "/api/v1/poster/w342/abcdefghij.jpg"},
          {"title": "B", "image": "https://elsewhere.example/p.jpg"},
          {"title": "C", "image": "//evil.example/p.jpg"},
          {"title": "D", "image": "javascript:alert(1)"},
          {"title": "E", "image": 5},
          {"title": "F", "image": ["/x"]},
          {"title": "G", "image": "  /api/v1/poster/w154/a.png \\n"},
          {"title": "H", "image": "/a\\\\b.png"}]}
        """)
        #expect(c.style == .posterGrid)
        #expect(c.items.map(\.image) == ["/api/v1/poster/w342/abcdefghij.jpg", "https://elsewhere.example/p.jpg", nil, nil, nil, nil,
                                        "/api/v1/poster/w154/a.png", nil])
        // Older style names the app doesn't know still mean list.
        #expect(try decode(Card.self, #"{"id": "s", "style": "poster-wall"}"#).style == .list)
        // The cache round trip keeps style and image.
        let back = try JSONDecoder().decode(Card.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }

    @Test func imageURLOnlyOnTheServersOwnHost() {
        let server = URL(string: "https://homelab.example.ts.net")!
        func url(_ s: String, _ base: URL? = nil) -> String? { URLPolicy.imageURL(s, server: base ?? server)?.absoluteString }
        #expect(url("/api/v1/poster/w342/ab.jpg") == "https://homelab.example.ts.net/api/v1/poster/w342/ab.jpg")
        #expect(url("https://homelab.example.ts.net/api/v1/poster/w342/ab.jpg") == "https://homelab.example.ts.net/api/v1/poster/w342/ab.jpg")
        #expect(url("HTTPS://HOMELAB.example.ts.net/p.png") == "https://homelab.example.ts.net/p.png")
        #expect(url("/p.png?v=2#frag") == "https://homelab.example.ts.net/p.png?v=2")
        // Other host, scheme, port, userinfo, or a trick to look like the server.
        #expect(url("https://image.tmdb.org/t/p/w342/ab.jpg") == nil)
        #expect(url("http://homelab.example.ts.net/p.png") == nil)
        #expect(url("https://homelab.example.ts.net:8443/p.png") == nil)
        #expect(url("https://homelab.example.ts.net@evil.example/p.png") == nil)
        #expect(url("https://evil.example/@homelab.example.ts.net/p.png") == nil)
        #expect(url("https://homelab.example.ts.net.evil.example/p.png") == nil)
        #expect(url("//evil.example/p.png") == nil)
        #expect(url("ftp://homelab.example.ts.net/p.png") == nil)
        #expect(url("file:///etc/passwd") == nil)
        #expect(url("p.png") == nil)
        #expect(url("") == nil)
        // Dot segments, encoded slashes, backslashes, control characters.
        #expect(url("/api/../secret.png") == nil)
        #expect(url("/api/%2e%2e/secret.png") == nil)
        #expect(url("/api%2f..%2fx.png") == nil)
        #expect(url("/a\\b.png") == nil)
        #expect(url("/a\u{0}b.png") == nil)
        #expect(url("/" + String(repeating: "a", count: 600)) == nil)
        // A server below a path keeps it; a path that already has it isn't prefixed twice.
        let sub = URL(string: "https://h.example/homelab")!
        #expect(url("/api/v1/poster/w154/a.jpg", sub) == "https://h.example/homelab/api/v1/poster/w154/a.jpg")
        #expect(url("/homelab/api/v1/poster/w154/a.jpg", sub) == "https://h.example/homelab/api/v1/poster/w154/a.jpg")
        let port = URL(string: "http://192.168.1.5:8791")!
        #expect(url("/p.png", port) == "http://192.168.1.5:8791/p.png")
        #expect(url("http://192.168.1.5:8791/p.png", port) == "http://192.168.1.5:8791/p.png")
        #expect(url("http://192.168.1.5/p.png", port) == nil)
    }

    // MARK: Query

    @Test func queryRules() {
        #expect(SearchQuery.clean("  dune  ") == "dune")
        #expect(SearchQuery.clean("the\n\tlong   quiet") == "the long quiet")
        #expect(SearchQuery.clean("a") == nil)
        #expect(SearchQuery.clean("  a  ") == nil)
        #expect(SearchQuery.clean("ab") == "ab")
        #expect(SearchQuery.clean(String(repeating: "x", count: 100)) != nil)
        #expect(SearchQuery.clean(String(repeating: "x", count: 101)) == nil)
        #expect(SearchQuery.clean("a\u{0}b") == "a b")
        #expect(SearchQuery.prefill(String(repeating: "x", count: 150)).count == 100)
        #expect(SearchQuery.prefill("  a ") == "a")
    }

    @Test func textFromALinkWaitsForTheUser() {
        #expect(SearchQuery.runsOnItsOwn("dune", held: nil))              // typed: searches after the pause
        #expect(!SearchQuery.runsOnItsOwn("dune", held: "dune"))          // a link's text: waits for submit
        #expect(!SearchQuery.runsOnItsOwn("  dune ", held: "dune"))
        #expect(SearchQuery.runsOnItsOwn("dune 2", held: "dune"))         // edited: back to the debounced search
        #expect(SearchQuery.runsOnItsOwn("", held: ""))
    }

    // MARK: Client

    @Test func searchSendsTheQueryAndReadsCards() async throws {
        let t = FakeTransport(fixture: "search.json")
        let r = try await CompanionClient(baseURL: base, token: "tok", transport: t).search(q: "  the  quiet ")
        let req = try #require(t.last)
        #expect(req.httpMethod == "GET" && req.url?.path == "/api/v1/search")
        #expect(URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "q", value: "the quiet")])
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(r.cards.count == 1 && r.cards[0].style == .posterGrid && r.cards[0].items.count == 8)
        #expect(r.cards[0].items[1].action == ItemAction(name: "seerr-request", label: "Request", arg: "tv:9102"))
        #expect(r.cards[0].items[0].image == "/api/v1/poster/w342/demoposter01.png")
    }

    @Test func searchEncodesSpecialCharacters() async throws {
        let t = FakeTransport(json: #"{"query": "a&b=c", "cards": []}"#)
        let r = try await CompanionClient(baseURL: base, token: nil, transport: t).search(q: "a&b=c #é")
        #expect(r.shown.isEmpty)
        let items = URLComponents(url: try #require(t.last?.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.count == 1 && items?.first?.value == "a&b=c #é")
    }

    @Test func searchChecksTheLengthBeforeAsking() async {
        let t = FakeTransport(json: "{}")
        let client = CompanionClient(baseURL: base, token: nil, transport: t)
        await #expect(throws: APIError.self) { try await client.search(q: "a") }
        await #expect(throws: APIError.self) { try await client.search(q: String(repeating: "x", count: 101)) }
        #expect(t.requests.isEmpty)
    }

    @Test func searchErrors() async {
        func error(_ status: Int, _ body: String) async -> APIError? {
            let t = FakeTransport(status: status, json: body)
            do { _ = try await CompanionClient(baseURL: base, token: nil, transport: t).search(q: "dune"); return nil }
            catch { return error as? APIError }
        }
        #expect(await error(502, #"{"error": "Seerr did not answer"}"#) == .serverSaid(status: 502, text: "Seerr did not answer"))
        #expect(await error(502, "") == .server(status: 502))
        #expect(await error(400, #"{"error": "q must be 2-100 characters"}"#) == .badRequest("q must be 2-100 characters"))
        #expect(await error(429, "{}") == .tooManyRequests)
        #expect(await error(404, "{}") == .notFound)
        #expect(await error(401, "{}") == .unauthorized)
        #expect(await error(200, "[1]") != nil)   // wrong shape
    }

    @Test func searchAnswerIsTolerant() throws {
        let r = try decode(SearchResult.self, """
        {"query": "dune", "extra": 1, "cards": [{"id": "a", "style": "poster-grid", "items": [{"title": "X"}]},
          {"id": "a", "items": []}, {"nope": 1}, {"id": "empty", "style": "poster-grid", "items": []},
          {"id": "note", "style": "text", "text": "Nothing."}]}
        """)
        #expect(r.query == "dune" && r.cards.map(\.id) == ["a", "empty", "note"])
        #expect(r.shown.map(\.id) == ["a", "note"])
        #expect(try decode(SearchResult.self, "{}").cards.isEmpty)
        #expect(try decode(SearchResult.self, #"{"cards": "x"}"#).cards.isEmpty)
    }

    @Test func imageRequestCarriesTheLoginAndOnlyGoesToTheServer() async throws {
        let t = FakeTransport { _ in .init(body: PlaceholderPoster.png(seed: "a"), headers: ["Content-Type": "image/png"]) }
        let client = CompanionClient(baseURL: base, token: "tok", transport: t)
        let data = try await client.image(path: "/api/v1/poster/w342/abcdefghij.png")
        #expect(ImageKind(sniffing: data) == .png)
        let req = try #require(t.last)
        #expect(req.url?.absoluteString == "https://homelab.example.ts.net/api/v1/poster/w342/abcdefghij.png")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(req.value(forHTTPHeaderField: "Origin") == nil && req.httpShouldHandleCookies == false)
        // Anything but this server: refused before a request exists.
        for foreign in ["https://image.tmdb.org/t/p/w342/a.jpg", "http://homelab.example.ts.net/a.png", "//x.example/a.png", "a.png", "/a/../b.png"] {
            await #expect(throws: APIError.self) { try await client.image(path: foreign) }
        }
        #expect(t.requests.count == 1)
        // The same-host absolute URL is fine.
        _ = try await client.image(path: "https://homelab.example.ts.net/api/v1/poster/w154/zzzzzzzzzz.png")
        #expect(t.requests.count == 2)
    }

    @Test func imageSizeAndTypeChecks() async throws {
        func load(_ body: Data, status: Int = 200, type: String? = "image/png") async -> Result<Data, APIError> {
            let headers: [String: String] = type.map { ["Content-Type": $0] } ?? [:]
            let t = FakeTransport { _ in .init(status: status, body: body, headers: headers) }
            do { return .success(try await CompanionClient(baseURL: base, token: nil, transport: t).image(path: "/p.png")) }
            catch { return .failure(error as? APIError ?? .other("?")) }
        }
        #expect(try await load(png).get() == png)
        #expect(try await load(png, type: nil).get() == png)                                    // no header: the bytes decide
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0, count: 20))
        #expect(try await load(jpeg, type: "image/jpeg").get() == jpeg)
        let webp = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WEBPVP8 ".utf8)
        #expect(try await load(webp, type: "image/webp").get() == webp)
        // Not a picture: HTML or JSON or text, whatever the header says; or a picture with the wrong header.
        #expect(await load(Data("<html>login</html>".utf8), type: "text/html") == .failure(.invalidResponse))
        #expect(await load(Data("<html>".utf8), type: "image/png") == .failure(.invalidResponse))
        #expect(await load(Data(#"{"a":1}"#.utf8), type: "application/json") == .failure(.invalidResponse))
        #expect(await load(png, type: "application/json") == .failure(.invalidResponse))
        #expect(await load(Data(), type: "image/png") == .failure(.invalidResponse))
        #expect(await load(Data("GIF89a....".utf8), type: "image/gif") == .failure(.invalidResponse))
        // Size cap: 1 MB exactly is fine, one byte more is not.
        let big = png + Data(repeating: 0, count: CompanionClient.maxImageBytes - png.count)
        #expect(big.count == 1024 * 1024)
        #expect(try await load(big).get().count == 1024 * 1024)
        #expect(await load(big + Data([0])) == .failure(.tooLarge))
        // Status codes.
        #expect(await load(Data(), status: 404) == .failure(.notFound))
        #expect(await load(png, status: 302) == .failure(.redirected(status: 302)))
        #expect(await load(Data(), status: 401) == .failure(.unauthorized))
    }

    // MARK: Loader

    private func loader(_ t: FakeTransport, scope: String = "s", directory: URL? = nil) -> ImageLoader {
        ImageLoader(api: CompanionClient(baseURL: base, token: nil, transport: t), scope: scope, directory: directory)
    }

    @Test func loaderCachesInMemoryAndAskesOnce() async throws {
        let t = FakeTransport { _ in .init(body: PlaceholderPoster.png(seed: "a"), headers: ["Content-Type": "image/png"]) }
        let l = loader(t)
        let a = await l.data(for: "/api/v1/poster/w342/aaaaaaaaaa.png")
        let b = await l.data(for: " /api/v1/poster/w342/aaaaaaaaaa.png ")
        #expect(a != nil && a == b)
        #expect(t.requests.count == 1)
        _ = await l.data(for: "/api/v1/poster/w342/bbbbbbbbbb.png")
        #expect(t.requests.count == 2)
        // Concurrent asks for one picture share one request.
        let t2 = FakeTransport { _ in .init(body: PlaceholderPoster.png(seed: "a"), headers: ["Content-Type": "image/png"]) }
        let l2 = loader(t2)
        async let x = l2.data(for: "/p/one.png")
        async let y = l2.data(for: "/p/one.png")
        async let z = l2.data(for: "/p/one.png")
        let all = await [x, y, z]
        #expect(all.allSatisfy { $0 != nil })
        #expect(t2.requests.count == 1)
    }

    @Test func loaderRefusesForeignAndBrokenAnswersAndRetriesLater() async {
        let t = FakeTransport { _ in .init(body: Data("<html>".utf8), headers: ["Content-Type": "text/html"]) }
        let l = loader(t)
        let now = Date()
        #expect(await l.data(for: "https://image.tmdb.org/a.jpg", now: now) == nil)
        #expect(t.requests.isEmpty)                                                 // never even asked
        #expect(await l.data(for: "/a.png", now: now) == nil)
        #expect(await l.data(for: "/a.png", now: now.addingTimeInterval(30)) == nil)
        #expect(t.requests.count == 1)                                              // a failure rests for a minute
        #expect(await l.data(for: "/a.png", now: now.addingTimeInterval(61)) == nil)
        #expect(t.requests.count == 2)
    }

    @Test func loaderDiskCacheSurvivesAndKeepsServersApart() async throws {
        let dir = temporaryDirectory().appendingPathComponent("images")
        let t = FakeTransport { _ in .init(body: PlaceholderPoster.png(seed: "d"), headers: ["Content-Type": "image/png"]) }
        let first = loader(t, scope: "one", directory: dir)
        let data = try #require(await first.data(for: "/p/a.png"))
        #expect(t.requests.count == 1)
        // A new loader (the app started again) reads the file, no request.
        let again = loader(t, scope: "one", directory: dir)
        #expect(await again.data(for: "/p/a.png") == data)
        #expect(t.requests.count == 1)
        // Another server's id asks again.
        let other = loader(t, scope: "two", directory: dir)
        #expect(await other.data(for: "/p/a.png") == data)
        #expect(t.requests.count == 2)
        // Old files are not used: a month later it asks again.
        let later = loader(t, scope: "one", directory: dir)
        _ = await later.data(for: "/p/a.png", now: Date().addingTimeInterval(ImageLoader.maxAge + 60))
        #expect(t.requests.count == 3)
        // A damaged file is not used.
        for f in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            try Data("garbage".utf8).write(to: f)
        }
        let damaged = loader(t, scope: "one", directory: dir)
        #expect(await damaged.data(for: "/p/a.png") == data)
        #expect(t.requests.count == 4)
    }

    @Test func diskCachePrunesOldestFirst() throws {
        let dir = temporaryDirectory()
        let now = Date()
        for i in 0..<5 {
            let url = dir.appendingPathComponent("f\(i).img")
            try Data(repeating: 1, count: 100).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(i) * 10 - 100)], ofItemAtPath: url.path)
        }
        let ancient = dir.appendingPathComponent("ancient.img")
        try Data(repeating: 1, count: 10).write(to: ancient)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-ImageLoader.maxAge - 10)], ofItemAtPath: ancient.path)
        ImageLoader.prune(dir, now: now, limit: 250)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == ["f3.img", "f4.img"])                                        // 250 B limit: the newest two stay
    }

    // MARK: Posters

    @Test func placeholderPostersAreValidPNGs() throws {
        let a = PlaceholderPoster.png(seed: "demoposter01")
        #expect(ImageKind(sniffing: a) == .png)
        #expect(a == PlaceholderPoster.png(seed: "demoposter01"))
        #expect(a != PlaceholderPoster.png(seed: "demoposter02"))
        #expect(a.count < 20_000)
        // IHDR: 80 x 120 (2:3), 8 bit grayscale; the chunks end with IEND.
        let b = [UInt8](a)
        #expect(Array(b[12..<16]) == Array("IHDR".utf8))
        #expect(Array(b[16..<20]) == [0, 0, 0, 80] && Array(b[20..<24]) == [0, 0, 0, 120])
        #expect(b[24] == 8 && b[25] == 0)
        #expect(Array(b.suffix(8).prefix(4)) == Array("IEND".utf8))
        // Every chunk's CRC matches.
        var i = 8
        var chunks = 0
        while i + 12 <= b.count {
            let len = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            let body = Array(b[(i + 4)..<(i + 8 + len)])
            let crc = UInt32(b[i + 8 + len]) << 24 | UInt32(b[i + 9 + len]) << 16 | UInt32(b[i + 10 + len]) << 8 | UInt32(b[i + 11 + len])
            #expect(PlaceholderPoster.crc32(body) == crc)
            i += 12 + len
            chunks += 1
        }
        #expect(chunks == 3 && i == b.count)
        // The IDAT is one stored zlib block holding every scanline, closed by the right Adler-32.
        let idat = Array(b[41..<(b.count - 12 - 4)])                    // after the 8 + 25 byte IHDR chunk and IDAT's length/type
        let rows = (80 + 1) * 120
        #expect(Array(b[33..<37]) == [0, 0, UInt8(((rows + 11) >> 8) & 0xFF), UInt8((rows + 11) & 0xFF)] && Array(b[37..<41]) == Array("IDAT".utf8))
        #expect(idat[0] == 0x78 && idat[2] == 1)                        // zlib header, final stored block
        #expect(Int(idat[3]) | Int(idat[4]) << 8 == rows)
        let data = Array(idat[7..<(7 + rows)])
        var x: UInt32 = 1, y: UInt32 = 0
        for byte in data { x = (x + UInt32(byte)) % 65521; y = (y + x) % 65521 }
        let tail = Array(idat.suffix(4))
        #expect(UInt32(tail[0]) << 24 | UInt32(tail[1]) << 16 | UInt32(tail[2]) << 8 | UInt32(tail[3]) == y << 16 | x)
        #expect(PlaceholderPoster.crc32(Array("123456789".utf8)) == 0xCBF43926)
    }

    // MARK: Demo

    @Test func demoSearchAndRequest() async throws {
        let demo = DemoBackend(delay: .zero)
        let all = try await demo.search(q: "garden")
        #expect(all.shown.count == 1)
        let titles = all.cards[0].items.compactMap(\.title)
        #expect(titles == ["The Quiet Garden"])
        let quiet = try await demo.search(q: "QUIET")
        #expect(quiet.cards[0].items.compactMap(\.title) == ["The Long Quiet", "The Quiet Garden"])
        let item = try #require(quiet.cards[0].items.last)
        let action = try #require(item.action)
        #expect(action.name == "seerr-request" && action.arg == "movie:9106")
        #expect(try await demo.search(q: "zzzz").shown.isEmpty)
        await #expect(throws: APIError.self) { try await demo.search(q: "z") }
        // Requesting it makes the next search show "requested", without the button.
        _ = try await demo.run(action.name, arg: action.arg, payload: [:])
        let again = try await demo.search(q: "quiet garden")
        #expect(again.cards[0].items[0].value == "requested" && again.cards[0].items[0].action == nil)
        // Posters: PNGs for the demo's own paths, nothing else.
        let img = try await demo.image(path: try #require(item.image))
        #expect(ImageKind(sniffing: img) == .png)
        await #expect(throws: APIError.self) { try await demo.image(path: "https://elsewhere.example/a.png") }
        await #expect(throws: APIError.self) { try await demo.image(path: "/etc/passwd") }
        // The demo has the feature, the actions and the Lab cards.
        #expect(try await demo.info().features.contains(.search))
        #expect(try await demo.actions().contains { $0.name == "seerr-request" && !$0.start })
        let state = try await demo.state()
        #expect(state.cards.filter { $0.place == .lab }.map(\.id) == ["tailnet", "dns", "dns-top", "backups"])
    }

    @Test func demoPausesBlocking() async throws {
        let demo = DemoBackend(delay: .zero)
        _ = try await demo.run("dns-pause", arg: "15", payload: [:])
        var blocking = try #require(try await demo.state().cards.first { $0.id == "dns" }?.items.last)
        #expect(blocking.value == "paused · 15 min" && blocking.tint == .yellow && blocking.action?.arg == "on")
        _ = try await demo.run("dns-pause", arg: "on", payload: [:])
        blocking = try #require(try await demo.state().cards.first { $0.id == "dns" }?.items.last)
        #expect(blocking.value == "on" && blocking.tint == nil && blocking.action?.arg == "5")
    }

    // MARK: Link

    @MainActor @Test func searchLinkWaitsForTheFeatureAndOpensOnce() async throws {
        let (m, _, _, _) = makeModel(FakeServer())
        try m.save(ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity), token: nil)
        m.open(URL(string: "homelab://search?q=the%20long%20quiet")!)
        #expect(m.openSearch?.query == "the long quiet")
        #expect(m.openSearch?.held == true)                             // a link only fills the field
        #expect(m.takeOpenSearch() == nil)                             // features unknown: waits
        await m.refresh()                                              // info.json has "search"
        m.validateTab()
        #expect(m.tab == .actions)
        let request = try #require(m.takeOpenSearch())
        #expect(request.query == "the long quiet")
        #expect(m.openSearch == nil && m.takeOpenSearch() == nil)      // once
        // Without a query, or with nonsense: the screen opens with an empty field.
        m.open(URL(string: "homelab://search")!)
        #expect(m.takeOpenSearch()?.query == "")
        m.open(URL(string: "homelab://search?q=%0A%20x%20&other=1")!)
        #expect(m.takeOpenSearch()?.query == "x")
    }

    @MainActor @Test func searchLinkIsDroppedWithoutTheFeature() async throws {
        let server = FakeServer()
        server.info = Data(#"{"api": 1, "features": ["status", "hosts", "chat"]}"#.utf8)
        let (m, _, _, _) = makeModel(server)
        try m.save(ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity), token: nil)
        await m.refresh()
        m.open(URL(string: "homelab://search?q=dune")!)
        #expect(m.takeOpenSearch() == nil && m.openSearch == nil)
    }

    @MainActor @Test func searchLinkEndsWhenAnotherTabIsPicked() async throws {
        let (m, _, _, _) = makeModel(FakeServer())
        try m.save(ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity), token: nil)
        await m.refresh()
        m.open(URL(string: "homelab://search?q=dune")!)
        m.pick(.chat)
        #expect(m.openSearch == nil)
    }

    @MainActor @Test func actionsTabShowsForSearchAlone() async throws {
        let server = FakeServer()
        server.info = Data(#"{"api": 1, "features": ["status", "search"]}"#.utf8)
        let (m, _, _, _) = makeModel(server)
        try m.save(ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity), token: nil)
        await m.refresh()
        #expect(m.availableTabs.contains(.actions))
    }

    @MainActor @Test func modelSearchUsesTheServer() async throws {
        let demo = ServerConfig(name: "Demo", kind: .demo, baseURL: URL(string: "https://demo.invalid")!, auth: .identity)
        let (m, _, _, _) = makeModel(FakeServer())
        let r = await m.search("quiet", on: demo)
        #expect((try r.get()).shown.count == 1)
        let loader = m.imageLoader(for: demo)
        #expect(await loader.data(for: "/api/v1/poster/w342/demoposter01.png") != nil)
        #expect(await loader.data(for: "https://elsewhere.example/a.png") == nil)
    }
}
