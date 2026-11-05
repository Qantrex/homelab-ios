import Foundation

/// The bundled fixtures (Sources/HomelabKit/Fixtures): demo mode, previews, tests, and the mock server use the same files.
public enum Fixtures {
    public static func data(_ name: String) -> Data? {
        let base = (name as NSString).deletingPathExtension
        guard let url = Bundle.module.url(forResource: base, withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: base, withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        data(name).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

/// Demo mode: everything from fixtures, with a little life (chat echoes, buttons answer, toggles flip).
/// Times are shifted so the demo always looks current.
public actor DemoBackend: CompanionAPI, HomeAssistantAPI {
    private var current: HomelabState
    private var page: MessagePage
    private var entities: [HAEntity]
    private let delay: Duration

    public init(stateFixture: String = "state-problem.json", delay: Duration = .milliseconds(250), now: Date = Date()) {
        var state = Fixtures.decode(HomelabState.self, stateFixture) ?? HomelabState()
        var page = Fixtures.decode(MessagePage.self, "messages.json") ?? MessagePage()
        // Shift every fixture time so "checked" is 2 minutes ago.
        let shift = state.checked.map { now.addingTimeInterval(-120).timeIntervalSince($0) } ?? 0
        func s(_ d: Date?) -> Date? { d?.addingTimeInterval(shift) }
        state.time = s(state.time); state.checked = s(state.checked)
        state.problems = state.problems.map { var p = $0; p.since = s(p.since); return p }
        state.hosts = state.hosts.map { var h = $0; h.checked = s(h.checked); return h }
        state.pending = state.pending.map { var p = $0; p.created = s(p.created); return p }
        page.messages = page.messages.map { var m = $0; m.ts = s(m.ts); return m }
        state.lastMessage = page.messages.last
        state.busy = []
        page.busy = []
        current = state
        self.page = page
        entities = Fixtures.decode([Lossy<HAEntity>].self, "ha-states.json")?.compactMap(\.value) ?? []
        self.delay = delay
    }

    public func info() async throws -> ServerInfo {
        try await Task.sleep(for: delay)
        return Fixtures.decode(ServerInfo.self, "info.json") ?? ServerInfo(name: "Demo homelab")
    }

    public func state() async throws -> HomelabState {
        try await Task.sleep(for: delay)
        current.time = Date()
        return current
    }

    public func messages(after: Int64) async throws -> MessagePage {
        try await Task.sleep(for: delay)
        return MessagePage(messages: page.messages.filter { $0.id > after }, busy: page.busy)
    }

    public func send(_ text: String) async throws -> Int64? {
        try await Task.sleep(for: delay)
        let id = nextID()
        page.messages.append(ChatMessage(id: id, ts: Date(), from: .me, text: text))
        page.busy = ["chat"]
        Task { await self.reply(to: text) }
        return id
    }

    private func reply(to text: String) async {
        try? await Task.sleep(for: .seconds(1.2))
        let answer = text.hasPrefix("/")
            ? "Demo mode: `\(text)` would run on your homelab. Add a server in **Settings** to try it for real."
            : "This is demo mode, so nobody is reading this. Add your own server in **Settings**."
        page.messages.append(ChatMessage(id: nextID(), ts: Date(), from: .agent, job: "chat", status: "OK", text: answer))
        page.busy = []
        current.lastMessage = page.messages.last
    }

    public func press(_ button: String) async throws -> String {
        try await Task.sleep(for: delay * 3)
        guard let action = current.pending.first(where: { $0.buttons.values.contains(button) }),
              let verb = action.buttons.first(where: { $0.value == button })?.key else {
            throw APIError.forbidden
        }
        current.pending.removeAll { $0.id == action.id }
        switch verb {
        case .deny: return "Dropped \(action.title) (demo)."
        case .always: return "Ran \(action.title), and it may run by itself from now on (demo)."
        case .approve: return "Ran \(action.title) (demo)."
        }
    }

    public func services() async throws -> [Service] {
        try await Task.sleep(for: delay)
        return Fixtures.decode(ServiceList.self, "services.json")?.services ?? []
    }

    // MARK: Home Assistant

    public func check() async throws -> String { "API running. (demo)" }

    public func states() async throws -> [HAEntity] {
        try await Task.sleep(for: delay)
        return entities
    }

    public func call(_ entity: HAEntity) async throws -> [HAEntity] {
        try await Task.sleep(for: delay)
        guard let i = entities.firstIndex(where: { $0.entityID == entity.entityID }) else { return [] }
        guard entities[i].isAvailable else { throw APIError.badRequest("\(entity.name) is unavailable.") }
        if entity.control == .toggle {
            entities[i].state = entities[i].isOn ? "off" : "on"
            entities[i].lastChanged = Date()
        }
        return [entities[i]]
    }

    private func nextID() -> Int64 {
        let now = Int64(Date().timeIntervalSince1970 * 1e9)
        return max(now, (page.messages.last?.id ?? 0) + 1)
    }
}
