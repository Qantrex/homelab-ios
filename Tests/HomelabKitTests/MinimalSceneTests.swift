import Foundation
import Testing
@testable import HomelabKit

/// The `minimal` demo scene is a server that sends only /info and /state: every optional endpoint answers 404.
@Suite("Minimal demo scene")
struct MinimalSceneTests {
    @Test func onlyInfoAndStateAnswer() async throws {
        let demo = DemoBackend(scene: .minimal, delay: .zero)
        let info = try await demo.info()
        #expect(info.features.contains(.status))
        #expect(!info.features.contains(.chat) && !info.features.contains(.runActions))
        let state = try await demo.state()
        #expect(!state.hosts.isEmpty && state.cards.isEmpty && state.pending.isEmpty)
        await #expect(throws: APIError.self) { _ = try await demo.messages(after: 0) }
        await #expect(throws: APIError.self) { _ = try await demo.services() }
        await #expect(throws: APIError.self) { _ = try await demo.actions() }
        await #expect(throws: APIError.self) { _ = try await demo.deals() }
        await #expect(throws: APIError.self) { _ = try await demo.search(q: "matrix") }
        await #expect(throws: APIError.self) { _ = try await demo.send("hi") }
    }
}
