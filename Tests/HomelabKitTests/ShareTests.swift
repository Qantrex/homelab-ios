import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HomelabKit

@Suite struct ShareRouterTests {
    @Test func firstURLInText() {
        #expect(ShareRouter.firstURL(in: "Look: https://example.org/a?b=1, nice")?.absoluteString == "https://example.org/a?b=1")
        #expect(ShareRouter.firstURL(in: "(see http://example.org/x.)")?.absoluteString == "http://example.org/x")
        #expect(ShareRouter.firstURL(in: "https://en.wikipedia.org/wiki/Foo_(bar)")?.absoluteString == "https://en.wikipedia.org/wiki/Foo_(bar)")
        #expect(ShareRouter.firstURL(in: "(https://en.wikipedia.org/wiki/Foo_(bar))")?.absoluteString == "https://en.wikipedia.org/wiki/Foo_(bar)")
        #expect(ShareRouter.firstURL(in: "HTTPS://Example.org/p")?.host?.lowercased() == "example.org")
        #expect(ShareRouter.firstURL(in: "ftp://x.org mailto:a@b.c no link") == nil)
        #expect(ShareRouter.firstURL(in: "https:// ") == nil)
    }

    @Test func willhabenAdID() throws {
        func id(_ s: String) -> String? { ShareRouter.willhabenAdID(URL(string: s)!) }
        #expect(id("https://www.willhaben.at/iad/kaufen-und-verkaufen/d/iphone-12-1234567890/") == "1234567890")
        #expect(id("https://willhaben.at/iad/x/d/thing-987654321") == "987654321")
        #expect(id("https://www.willhaben.at/iad/object?adId=4455667788&x=1") == "4455667788")
        #expect(id("https://www.willhaben.at/iad/object?adId=12") == nil)
        #expect(id("https://www.willhaben.at/iad/kaufen-und-verkaufen/marktplatz") == nil)
        #expect(id("https://evil.example/iad/x-1234567890/") == nil)
        #expect(id("https://www.willhaben.at.evil.example/iad/x-1234567890/") == nil)
        #expect(id("https://www.willhaben.at/other/x-1234567890/") == nil)
    }

    @Test func destinations() throws {
        let wh = try ShareRouter.item(url: URL(string: "https://www.willhaben.at/iad/d/x-1234567890/")!)
        #expect(ShareRouter.destination(for: wh) == .willhaben(adID: "1234567890"))
        #expect(ShareRouter.destination(for: wh).label == "Price check on willhaben")
        let other = try ShareRouter.item(text: "Read this https://example.org/post", title: "  A\u{0}  title\n")
        #expect(ShareRouter.destination(for: other) == .readLater)
        #expect(other.title == "A title")
        let pdf = try ShareRouter.item(pdf: Data("%PDF-1.4 x".utf8))
        #expect(ShareRouter.destination(for: pdf) == .paperless)
        #expect(ShareDestination.paperless.feature == .documents && ShareDestination.readLater.feature == .share)
    }

    @Test func refusals() throws {
        #expect(throws: ShareRefusal.notWeb(scheme: "file")) { try ShareRouter.item(url: URL(string: "file:///etc/passwd")!) }
        #expect(throws: ShareRefusal.notWeb(scheme: "javascript")) { try ShareRouter.item(text: "javascript:alert(1)") }
        #expect(throws: ShareRefusal.notWeb(scheme: "file")) { try ShareRouter.item(text: "file:///private/x.txt") }
        #expect(throws: ShareRefusal.noLink) { try ShareRouter.item(text: "buy milk, eggs") }
        #expect(throws: ShareRefusal.noLink) { try ShareRouter.item(text: "Note: buy milk") }
        #expect(throws: ShareRefusal.credentials) { try ShareRouter.item(url: URL(string: "https://user:pw@example.org/")!) }
        #expect(throws: ShareRefusal.tooLong) {
            try ShareRouter.item(url: URL(string: "https://example.org/" + String(repeating: "a", count: 2100))!)
        }
        #expect(throws: ShareRefusal.notPDF) { try ShareRouter.item(pdf: Data("GIF89a".utf8)) }
        let big = Data("%PDF-".utf8) + Data(count: ShareLimits.maxPDFBytes)
        #expect(throws: ShareRefusal.tooLarge(bytes: big.count)) { try ShareRouter.item(pdf: big) }
    }

    @Test func titles() {
        #expect(ShareRouter.cleanTitle(nil, max: 5) == nil)
        #expect(ShareRouter.cleanTitle(" \n ", max: 5) == nil)
        #expect(ShareRouter.cleanTitle("abcdefgh", max: 5) == "abcde")
        #expect(ShareRouter.cleanTitle("Äpfel\tund\u{7}Birnen", max: 50) == "Äpfel und Birnen")
        let vienna = TimeZone(identifier: "Europe/Vienna")!
        let when = Date(timeIntervalSince1970: 1_793_973_600 - 3600 + 300)   // 2026-11-06 14:05 Vienna
        #expect(ShareRouter.defaultScanTitle(now: when, timeZone: vienna) == "Scan 2026-11-06 14:05")
    }
}

@Suite struct ShareRequestTests {
    func client(_ t: FakeTransport) -> CompanionClient { CompanionClient(baseURL: base, token: "tok", transport: t) }

    @Test func uploadIsRawPDFWithHeaders() async throws {
        let t = FakeTransport(json: #"{"ok": true, "id": "abc", "text": "Sent to Paperless."}"#)
        let pdf = Data("%PDF-1.4 body".utf8)
        let id = "0b9c2f3e-3b1a-4d6f-8e0a-2f6f1f6a9c11"
        let reply = try await client(t).upload(pdf: pdf, title: "Rechnung März / Äpfel & Co", id: id)
        #expect(reply.text == "Sent to Paperless." && reply.ok)
        let r = try #require(t.last)
        #expect(r.url?.absoluteString == "https://homelab.example.ts.net/api/v1/documents")
        #expect(r.httpMethod == "POST" && r.httpBody == pdf)
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/pdf")
        #expect(r.value(forHTTPHeaderField: "X-Homelab-Id") == id)
        #expect(r.value(forHTTPHeaderField: "X-Homelab-Title") == "Rechnung%20M%C3%A4rz%20%2F%20%C3%84pfel%20%26%20Co")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(r.value(forHTTPHeaderField: "Origin") == nil)
    }

    @Test func uploadWithoutTitleSendsNoTitleHeader() async throws {
        let t = FakeTransport(json: #"{"ok": true, "text": "ok"}"#)
        _ = try await client(t).upload(pdf: Data("%PDF-".utf8), title: "  ", id: "x")
        #expect(t.last?.value(forHTTPHeaderField: "X-Homelab-Title") == nil)
    }

    @Test func shareIsJSON() async throws {
        let t = FakeTransport(json: #"{"ok": true, "id": "i", "route": "willhaben", "text": "Checking the ad."}"#)
        let reply = try await client(t).share(url: URL(string: "https://www.willhaben.at/iad/d/x-1234567890/")!, title: "Ad", id: "i")
        #expect(reply.route == "willhaben")
        let r = try #require(t.last)
        #expect(r.url?.path == "/api/v1/share" && r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true)
        #expect(bodyJSON(r) == ["id": "i", "kind": "url", "url": "https://www.willhaben.at/iad/d/x-1234567890/", "title": "Ad"])
    }

    @Test func clientRefusesBeforeSending() async {
        let t = FakeTransport(json: "{}")
        await #expect(throws: APIError.self) { try await client(t).share(url: URL(string: "file:///x")!, title: nil, id: "i") }
        let big = Data(count: ShareLimits.maxPDFBytes + 1)
        await #expect(throws: APIError.self) { try await client(t).upload(pdf: big, title: nil, id: "i") }
        #expect(t.requests.isEmpty)
    }

    @Test func errorsAreClassified() async {
        func call(_ status: Int, _ body: String = #"{"error": "nope"}"#) async -> APIError? {
            let t = FakeTransport(status: status, json: body)
            do { _ = try await client(t).upload(pdf: Data("%PDF-".utf8), title: nil, id: "i"); return nil } catch { return error as? APIError }
        }
        #expect(await call(400) == .badRequest("nope"))
        #expect(await call(413) == .badRequest("nope"))
        #expect(await call(415) == .badRequest("nope"))
        #expect(await call(429) == .tooManyRequests)
        #expect(await call(409) == .serverSaid(status: 409, text: "nope"))
        #expect(await call(500) == .server(status: 500))
        #expect(await call(403, "{}") == .forbidden)
        #expect(APIError.badRequest("x").isPermanentRejection)
        #expect(!APIError.tooManyRequests.isPermanentRejection && !APIError.serverSaid(status: 409, text: "x").isPermanentRejection)
    }

    @Test func featuresDecode() throws {
        let i = try decode(ServerInfo.self, #"{"api": 1, "features": ["chat", "documents", "share"]}"#)
        #expect(i.features == [.chat, .documents, .share])
        #expect(try fixture(ServerInfo.self, "info.json").features.isSuperset(of: [.documents, .share]))
    }
}

@Suite struct OutboxTests {
    func box() -> Outbox { Outbox(directory: temporaryDirectory().appendingPathComponent("outbox")) }
    func uuid() -> String { UUID().uuidString.lowercased() }
    let server = ServerConfig(name: "Lab", kind: .companion, baseURL: base, auth: .identity)
    var list: ServerList { ServerList(servers: [server], selected: server.id) }
    func pdf(_ n: Int = 100) -> ShareItem { .pdf(Data("%PDF-".utf8) + Data(count: n), title: "T") }

    @Test func addListRemove() throws {
        let b = box()
        let id1 = uuid(), id2 = uuid()
        try b.add(pdf(), id: id1, server: server.id, now: Date(timeIntervalSince1970: 10))
        try b.add(.url(URL(string: "https://example.org")!, title: nil), id: id2, server: server.id, now: Date(timeIntervalSince1970: 5))
        #expect(b.entries().map(\.id) == [id2, id1])
        #expect(b.entries().last?.kind == .pdf && b.entries().first?.url == "https://example.org")
        try b.add(pdf(), id: id1, server: server.id)   // the same id is the same item
        #expect(b.count == 2)
        b.remove(id1)
        #expect(b.entries().map(\.id) == [id2])
        #expect(!FileManager.default.fileExists(atPath: b.file(id1).path))
    }

    @Test func limits() throws {
        let b = box()
        for _ in 0..<ShareLimits.outboxItems { try b.add(.url(URL(string: "https://e.org")!, title: nil), id: uuid(), server: server.id) }
        #expect(throws: OutboxError.full) { try b.add(pdf(), id: uuid(), server: server.id) }
        let c = box()
        let big = Data("%PDF-".utf8) + Data(count: 60 * 1_048_576)
        try c.add(.pdf(big, title: nil), id: uuid(), server: server.id)
        #expect(throws: OutboxError.tooLarge) { try c.add(.pdf(big, title: nil), id: uuid(), server: server.id) }
        #expect(c.count == 1)
        #expect(throws: OutboxError.self) { try c.add(pdf(), id: "../../etc/passwd", server: server.id) }
    }

    @Test func drainSendsAndDeletes() async throws {
        let b = box()
        let id = uuid()
        try b.add(pdf(), id: id, server: server.id)
        try b.add(.url(URL(string: "https://example.org/a")!, title: "A"), id: uuid(), server: server.id)
        let t = FakeTransport(json: #"{"ok": true, "text": "ok"}"#)
        let report = await b.drain(servers: list) { CompanionClient(config: $0, tokens: MemoryTokenStore(), transport: t) }
        #expect(report == Outbox.Report(sent: 2, dropped: 0, waiting: 0))
        #expect(b.count == 0)
        #expect(t.requests.contains { $0.value(forHTTPHeaderField: "X-Homelab-Id") == id })
    }

    @Test func drainKeepsOnTransientErrorsAndStopsThatServer() async throws {
        let b = box()
        try b.add(pdf(), id: uuid(), server: server.id, now: Date(timeIntervalSince1970: 1))
        try b.add(pdf(), id: uuid(), server: server.id, now: Date(timeIntervalSince1970: 2))
        let t = FakeTransport(error: URLError(.notConnectedToInternet))
        let report = await b.drain(servers: list, now: Date(timeIntervalSince1970: 100)) {
            CompanionClient(config: $0, tokens: MemoryTokenStore(), transport: t)
        }
        #expect(report == Outbox.Report(sent: 0, dropped: 0, waiting: 2))
        #expect(t.requests.count == 1)   // the second item waits without another try
        #expect(b.entries().map(\.attempts) == [1, 0])
        for status in [500, 429, 403, 401, 409] {
            let t = FakeTransport(status: status, json: "{}")
            await b.drain(servers: list, now: Date(timeIntervalSince1970: 100)) {
                CompanionClient(config: $0, tokens: MemoryTokenStore(), transport: t)
            }
            #expect(b.count == 2, "status \(status) keeps the items")
        }
    }

    @Test func drainDropsWhatNeverWorks() async throws {
        let b = box()
        let stale = uuid(), gone = uuid(), bad = uuid()
        let stranger = UUID()
        try b.add(pdf(), id: stale, server: server.id, now: Date(timeIntervalSince1970: 0))
        try b.add(pdf(), id: gone, server: stranger, now: Date(timeIntervalSince1970: ShareLimits.outboxMaxAge + 90))
        try b.add(pdf(), id: bad, server: server.id, now: Date(timeIntervalSince1970: ShareLimits.outboxMaxAge + 90))
        let t = FakeTransport(status: 415, json: #"{"error": "only PDF"}"#)
        let now = Date(timeIntervalSince1970: ShareLimits.outboxMaxAge + 100)
        let report = await b.drain(servers: list, now: now) { CompanionClient(config: $0, tokens: MemoryTokenStore(), transport: t) }
        #expect(report.dropped == 3 && report.sent == 0)
        #expect(b.count == 0)
        #expect(t.requests.count == 1)   // only the third reached the server
        // Each one is recorded with its reason, so the app can say what wasn't sent; Clear empties the record.
        #expect(b.dropped().map(\.why).sorted() == ["its server was removed", "not sent within 7 days", "only PDF"].sorted())
        #expect(b.dropped().allSatisfy { $0.what == "A scan" || !$0.what.isEmpty })
        #expect(b.entries().isEmpty)   // the record is never read as an item
        b.clearDropped()
        #expect(b.dropped().isEmpty)
    }

    @Test func backgroundDrainLeavesBigPDFs() async throws {
        let b = box()
        let small = uuid(), big = uuid()
        try b.add(pdf(), id: small, server: server.id)
        try b.add(.pdf(Data("%PDF-".utf8) + Data(count: 3 * 1_048_576), title: "Big"), id: big, server: server.id)
        let t = FakeTransport(json: #"{"ok": true, "text": "ok"}"#)
        let report = await b.drain(servers: list, maxPDFBytes: 2 * 1_048_576) {
            CompanionClient(config: $0, tokens: MemoryTokenStore(), transport: t)
        }
        #expect(report == Outbox.Report(sent: 1, dropped: 0, waiting: 1))
        #expect(b.entries().map(\.id) == [big])
    }

    @Test func uploadsUseTheLongSession() {
        var r = URLRequest(url: base)
        r.httpMethod = "POST"
        r.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        #expect(URLSessionTransport.isUpload(r))
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        #expect(!URLSessionTransport.isUpload(r))
        #expect(URLSessionTransport.uploadSession.configuration.timeoutIntervalForResource == 900)
        #expect(URLSessionTransport.defaultSession.configuration.timeoutIntervalForResource == 150)
    }
}

@Suite struct ShareSenderTests {
    let direct = ServerConfig(name: "Lab", kind: .companion, baseURL: base, auth: .identity)
    func box() -> Outbox { Outbox(directory: temporaryDirectory().appendingPathComponent("outbox")) }
    let link = ShareItem.url(URL(string: "https://example.org/a")!, title: nil)

    func api(_ t: FakeTransport) -> any CompanionAPI { CompanionClient(baseURL: base, token: nil, transport: t) }

    @Test func sentDirectly() async {
        let t = FakeTransport(json: #"{"ok": true, "route": "read-later", "text": "Saved to your read-later list."}"#)
        let b = box()
        let out = await ShareSender.send(link, server: direct, api: api(t), features: [.share], outbox: b)
        #expect(out == .sent(text: "Saved to your read-later list."))
        #expect(b.count == 0)
    }

    @Test func offlineGoesToTheOutbox() async {
        let b = box()
        let t = FakeTransport(error: URLError(.cannotConnectToHost))
        #expect(await ShareSender.send(link, server: direct, api: api(t), features: nil, outbox: b) == .queued)
        #expect(b.count == 1)
        let t500 = FakeTransport(status: 502, json: "{}")
        #expect(await ShareSender.send(link, server: direct, api: api(t500), features: nil, outbox: b) == .queued)
    }

    @Test func noClientMeansOutbox() async {
        let b = box()
        let token = ServerConfig(name: "Tok", kind: .companion, baseURL: base, auth: .token)
        #expect(await ShareSender.send(link, server: token, api: nil, features: [.share], outbox: b) == .queued)
        #expect(b.entries().first?.server == token.id)
    }

    @Test func refusalsAreNotQueued() async {
        let b = box()
        let t = FakeTransport(status: 400, json: #"{"error": "not a PDF"}"#)
        let pdf = ShareItem.pdf(Data("%PDF-".utf8), title: nil)
        #expect(await ShareSender.send(pdf, server: direct, api: api(t), features: [.documents], outbox: b) == .failed("not a PDF"))
        let auth = FakeTransport(status: 401, json: "{}")
        let out = await ShareSender.send(link, server: direct, api: api(auth), features: nil, outbox: b)
        if case .failed = out {} else { Issue.record("expected a failure, got \(out)") }
        #expect(b.count == 0)
    }

    @Test func serverWithoutTheFeature() async {
        let b = box()
        let t = FakeTransport(json: "{}")
        let out = await ShareSender.send(link, server: direct, api: api(t), features: [.chat], outbox: b)
        #expect(out == .failed("Lab doesn't take shared links."))
        #expect(t.requests.isEmpty && b.count == 0)
    }

    @Test func fullOutboxFails() async {
        let b = box()
        for _ in 0..<ShareLimits.outboxItems {
            _ = ShareSender.enqueue(link, id: UUID().uuidString.lowercased(), server: direct, outbox: b, now: Date())
        }
        let out = await ShareSender.send(link, server: direct, api: nil, features: nil, outbox: b)
        #expect(out == .failed(OutboxError.full.message))
    }
}
