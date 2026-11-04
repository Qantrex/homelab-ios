import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HomelabKit

/// The real client against the real mock server (server/reference_server.py --fixtures), over real HTTP.
/// Runs when HOMELAB_FIXTURE_URL is set (CI and scripts/test-linux start the server).
let fixtureURL = ProcessInfo.processInfo.environment["HOMELAB_FIXTURE_URL"].flatMap(URL.init(string:))

@Suite(.enabled(if: fixtureURL != nil, "HOMELAB_FIXTURE_URL not set"), .serialized)
struct IntegrationTests {
    var client: CompanionClient { CompanionClient(baseURL: fixtureURL!, token: nil) }

    func control(_ query: String) async throws {
        var parts = URLComponents(url: fixtureURL!.appendingPathComponent("__control"), resolvingAgainstBaseURL: false)!
        parts.query = query
        _ = try await URLSession.shared.data(from: parts.url!)
    }

    @Test func infoAndState() async throws {
        try await control("state=state-problem.json&reset=1")
        let info = try await client.info()
        #expect(info.api == 1 && info.features.contains(.chat))
        let state = try await client.state()
        #expect(state.status == .problem && state.hosts.count == 4 && state.pending.count == 2)
        try await control("state=state-ok.json")
        #expect(try await client.state().status == .ok)
        try await control("state=state-problem.json")
    }

    @Test func chatRoundTrip() async throws {
        try await control("state=state-problem.json&reset=1")
        let before = try await client.messages(after: 0)
        let cursor = before.messages.last?.id ?? 0
        let id = try await client.send("ping from swift")
        var page = MessagePage()
        for _ in 0..<20 {
            page = try await client.messages(after: cursor)
            if page.messages.contains(where: { $0.from == .agent }) { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(page.messages.contains { $0.from == .me && $0.text == "ping from swift" && (id == nil || $0.id == id) })
        #expect(page.messages.contains { $0.from == .agent && $0.text.contains("ping from swift") })
    }

    @Test func buttons() async throws {
        try await control("state=state-problem.json&reset=1")
        let state = try await client.state()
        let approve = try #require(state.pending.first?.buttons[.approve])
        #expect(try await client.press(approve).isEmpty == false)
        do {
            _ = try await client.press("HOMELAB_APPROVE_ab12_ffffffffffffffff")
            Issue.record("a forged button worked")
        } catch let e as APIError {
            #expect(e.isForbidden)
        }
    }

    @Test func services() async throws {
        #expect(try await client.services().count == 5)
    }

    @Test func unknownPathIsNotFound() async throws {
        let r = try await URLSessionTransport().send(URLRequest(url: fixtureURL!.appendingPathComponent("api/v1/nope")))
        #expect(r.1.statusCode == 404)
    }
}
