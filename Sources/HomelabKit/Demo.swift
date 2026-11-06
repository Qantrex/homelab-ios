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
        let days = Self.dayShift(from: state.checked, to: now.addingTimeInterval(-120))
        func s(_ d: Date?) -> Date? { d?.addingTimeInterval(shift) }
        state.time = s(state.time); state.checked = s(state.checked)
        state.problems = state.problems.map { var p = $0; p.since = s(p.since); return p }
        // The 24 h history ends now, so its last point is the current value.
        state.hosts = state.hosts.map { var h = $0; h.checked = s(h.checked); h.history?.end = now; return h }
        state.pending = state.pending.map { var p = $0; p.created = s(p.created); return p }
        func card(_ c: Card) -> Card { Self.shiftDue(c, by: shift, days: days) }
        page.messages = page.messages.map { m in
            var m = m
            m.ts = s(m.ts)
            m.pending = m.pending.map { var p = $0; p.created = s(p.created); return p }
            m.cards = m.cards.map(card)
            return m
        }
        state.cards = state.cards.map { $0.id == "today" ? Self.demoDay($0, now: now) : card($0) }
        state.lastMessage = page.messages.last
        state.busy = []
        page.busy = []
        current = state
        self.page = page
        entities = Fixtures.decode([Lossy<HAEntity>].self, "ha-states.json")?.compactMap(\.value) ?? []
        self.delay = delay
    }

    /// Whole calendar days between two times (for moving day-only dues, which must stay on midnight).
    static func dayShift(from: Date?, to: Date, calendar: Calendar = .current) -> Int {
        guard let from else { return 0 }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }

    /// Moves the items' `due` like the other fixture times: a time by the same interval, a day by whole days.
    public static func shiftDue(_ card: Card, by interval: TimeInterval, days: Int, calendar: Calendar = .current) -> Card {
        var card = card
        card.items = card.items.map { item in
            var item = item
            if let due = item.due {
                item.due = item.dueIsDay
                    ? calendar.date(byAdding: .day, value: days, to: due)
                    : due.addingTimeInterval(interval)
            }
            return item
        }
        return card
    }

    /// The day's clock times follow the real clock too: the first stop was 45 min ago, so the day line always has a
    /// "now" between its stops. Times inside subtitles ("U6 07:36") move along. Late at night, when the day wouldn't
    /// fit before midnight, the fixture's times stay.
    public static func demoDay(_ card: Card, now: Date, calendar: Calendar = .current) -> Card {
        let minutes = card.items.compactMap { DayTimeline.minute($0.value) }
        guard let first = minutes.min(), let last = minutes.max() else { return card }
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let shift = (c.hour ?? 0) * 60 + (c.minute ?? 0) - 45 - first
        guard first + shift >= 0, last + shift < 24 * 60 else { return card }
        func move(_ text: String?) -> String? {
            text.map { t in
                t.split(separator: " ", omittingEmptySubsequences: false).map { word in
                    guard let m = DayTimeline.minute(String(word)) else { return String(word) }
                    let s = ((m + shift) % 1440 + 1440) % 1440
                    return String(format: "%02d:%02d", s / 60, s % 60)
                }.joined(separator: " ")
            }
        }
        var card = card
        card.items = card.items.map { var i = $0; i.value = move(i.value); i.subtitle = move(i.subtitle); return i }
        return card
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
        // Answered proposals leave the chat bubbles too, as on a real server.
        page.messages = page.messages.map { var m = $0; m.pending.removeAll { $0.id == action.id }; return m }
        if current.lastMessage != nil { current.lastMessage?.pending.removeAll { $0.id == action.id } }
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

    public func actions() async throws -> [ActionSpec] {
        try await Task.sleep(for: delay)
        return Fixtures.decode(ActionList.self, "actions.json")?.actions ?? []
    }

    public func run(_ action: String, arg: String, payload: [String: String]) async throws -> ActionResult {
        try await Task.sleep(for: delay * 3)
        guard let spec = Fixtures.decode(ActionList.self, "actions.json")?.actions.first(where: { $0.name == action }) else {
            throw APIError.notFound
        }
        let shown = ([arg] + spec.fields.compactMap { payload[$0.name] }).filter { !$0.isEmpty }.joined(separator: " · ")
        page.messages.append(ChatMessage(id: nextID(), ts: Date(), from: .me, text: shown.isEmpty ? spec.label : "\(spec.label): \(shown)"))
        if action == "todo-done", let item = payload["item"] { tickOff(item) }
        let text = "Done: \(spec.label). Demo mode, so nothing ran."
        if action == "restart-container" { restarted(arg) }
        page.messages.append(ChatMessage(id: nextID(), ts: Date(), from: .agent, job: "action", status: "OK", text: text))
        current.lastMessage = page.messages.last
        return ActionResult(ok: true, text: text)
    }

    /// A ticked-off to-do shows as done (a real server would drop it from the open items).
    private func tickOff(_ title: String) {
        current.cards = current.cards.map { card in
            guard card.style == .checklist else { return card }
            var card = card
            card.items = card.items.map { item in
                guard item.title == title, item.done != true else { return item }
                var item = item
                item.done = true
                item.action = nil
                return item
            }
            return card
        }
    }

    /// A restarted container ("media:sonarr") comes back running and healthy, one restart more.
    private func restarted(_ arg: String) {
        let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let h = current.hosts.firstIndex(where: { $0.id == parts[0] }),
              let i = current.hosts[h].containerList.firstIndex(where: { $0.name == parts[1] }) else { return }
        var c = current.hosts[h].containerList[i]
        let wasDown = c.state != .running
        c.state = .running
        if c.health != nil { c.health = .healthy }
        c.restarts = (c.restarts ?? 0) + 1
        current.hosts[h].containerList[i] = c
        if wasDown, let up = current.hosts[h].containersUp { current.hosts[h].containersUp = up + 1 }
        current.hosts[h].checked = Date()   // the demo checks the host at once
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
