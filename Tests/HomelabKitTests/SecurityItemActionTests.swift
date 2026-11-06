import Foundation
import Testing
@testable import HomelabKit

// Fixes from the security review of 2026-11-06 (its probe tests, turned into real ones).

/// A card item's action runs exactly its argument, or nothing.
struct StrictItemActionTests {
    func specs() throws -> [ActionSpec] { try fixture(ActionList.self, "actions.json").actions }
    func spec(_ name: String) throws -> ActionSpec { try #require(try specs().first { $0.name == name }) }

    @Test func nonMatchingArgumentsGiveNoForm() throws {
        for (name, arg) in [("ha-control", "lamps-offf"), ("dns-pause", "60"), ("wake-set", "bogus"),
                            ("wake-set", "2026-11-09:bogus"), ("commute-mode", "car"), ("commute-mode", "2026-11-07:car"),
                            ("restart-container", "gpu:steam"), ("parcel-done", "a b"), ("parcel-done", ""),
                            ("todo-done", "extra"), ("seerr-request", "book:12")] {
            #expect(ActionForm.prefilled(try spec(name), action: ItemAction(name: name, arg: arg)) == nil, "\(name) \(arg)")
        }
        // The lenient form would have run its default: the first option ("lamps-on") for "lamps-offf".
        let lenient = ActionForm(try spec("ha-control"), prefill: ItemAction(name: "ha-control", arg: "lamps-offf"))
        #expect(lenient.arg == "lamps-on")
    }

    @Test func matchingArgumentsAndPayloadsAreKept() throws {
        let off = try #require(ActionForm.prefilled(try spec("ha-control"), action: ItemAction(name: "ha-control", arg: " lamps-off ")))
        #expect(off.arg == "lamps-off")
        let wake = try #require(ActionForm.prefilled(try spec("wake-set"), action: ItemAction(name: "wake-set", arg: "2026-11-09:clear")))
        #expect(wake.arg == "2026-11-09:clear" && wake.variant == 2)
        let tick = ItemAction(name: "todo-done", payload: ["item": "Milk", "list": "shopping", "uid": "u1", "other": "x"])
        let form = try #require(ActionForm.prefilled(try spec("todo-done"), action: tick))
        #expect(form.arg == "" && form.payload == ["item": "Milk", "list": "shopping", "uid": "u1"])
    }

    /// Every item action in the fixtures and the demo still fits its action exactly and is ready to send.
    @Test func fixtureAndDemoItemsStillFit() async throws {
        let all = try specs()
        var actions: [ItemAction] = []
        for name in ["state-problem.json", "state-lab-cards.json", "state-ok.json", "state-departures.json"] {
            let s = try fixture(HomelabState.self, name)
            actions += s.cards.flatMap { $0.items.compactMap(\.action) }
        }
        actions += try fixture(SearchResult.self, "search.json").cards.flatMap { $0.items.compactMap(\.action) }
        let demo = DemoBackend(delay: .zero)
        actions += try await demo.state().cards.flatMap { $0.items.compactMap(\.action) }
        actions += try await demo.search(q: "quiet").cards.flatMap { $0.items.compactMap(\.action) }
        let names = Set(actions.map(\.name))
        #expect(names.isSuperset(of: ["todo-done", "parcel-done", "seerr-request", "dns-pause"]))
        for a in actions {
            let spec = try #require(all.first { $0.name == a.name }, "\(a.name) not in actions.json")
            let form = try #require(ActionForm.prefilled(spec, action: a), "\(a.name) \(a.arg)")
            #expect(form.arg == a.arg && form.problems.isEmpty, "\(a.name) \(a.arg): \(form.problems)")
        }
    }

    @MainActor @Test func modelRefusesAndSendsNothing() async throws {
        let (m, server, _, _) = makeModel()
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        await m.refresh()
        for (name, arg) in [("ha-control", "lamps-offf"), ("dns-pause", "60"), ("wake-set", "bogus"), ("commute-mode", "car")] {
            let r = await m.run(ItemAction(name: name, arg: arg), on: lab)
            #expect(r == .failure(.badRequest("This item's action no longer fits the server.")), "\(name)")
            #expect(server.calls("/api/v1/actions/\(name)") == 0, "\(name)")
        }
        // A fitting one goes out as it is.
        _ = await m.run(ItemAction(name: "todo-done", payload: ["item": "Milk", "list": "shopping"]), on: lab)
        #expect(server.calls("/api/v1/actions/todo-done") == 1)
    }
}
