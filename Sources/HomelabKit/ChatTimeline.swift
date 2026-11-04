import Foundation

/// The chat as the screen shows it: server messages merged with messages the user just sent (shown at once,
/// replaced by the server's copy when it arrives), sorted, without duplicates.
public struct ChatTimeline: Sendable, Equatable {
    public struct Outgoing: Sendable, Equatable, Identifiable {
        public enum State: Sendable, Equatable { case sending, sent(Int64), failed(String) }
        public let id: UUID
        public var text: String
        public var created: Date
        public var state: State
    }

    public private(set) var messages: [ChatMessage] = []
    public private(set) var outgoing: [Outgoing] = []
    public private(set) var busy: [String] = []

    public static let keep = 500

    public init() {}

    /// The id to poll after.
    public var cursor: Int64 { messages.last?.id ?? 0 }

    public var isWorking: Bool {
        !busy.isEmpty || outgoing.contains { if case .sent = $0.state { return true } else { return false } }
    }

    public mutating func merge(_ page: MessagePage) {
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for m in page.messages { byID[m.id] = m }
        messages = byID.values.sorted { $0.id < $1.id }.suffix(Self.keep).map { $0 }
        busy = page.busy
        // A sent message is confirmed once the server lists its id, or a later "me" message with the same text.
        outgoing.removeAll { o in
            switch o.state {
            case .sent(let id): byID[id] != nil
                || messages.contains { $0.from == .me && $0.text == o.text && $0.id >= id }
            default: false
            }
        }
    }

    /// Adds the user's message right away. Returns its local id.
    public mutating func begin(_ text: String, now: Date = Date()) -> UUID {
        let o = Outgoing(id: UUID(), text: text, created: now, state: .sending)
        outgoing.append(o)
        return o.id
    }

    public mutating func confirm(_ local: UUID, serverID: Int64?) {
        guard let i = outgoing.firstIndex(where: { $0.id == local }) else { return }
        if let serverID, messages.contains(where: { $0.id == serverID }) {
            outgoing.remove(at: i)
        } else {
            outgoing[i].state = .sent(serverID ?? cursor)
        }
    }

    public mutating func fail(_ local: UUID, message: String) {
        guard let i = outgoing.firstIndex(where: { $0.id == local }) else { return }
        outgoing[i].state = .failed(message)
    }

    public mutating func discard(_ local: UUID) {
        outgoing.removeAll { $0.id == local }
    }

    public mutating func reset() {
        messages = []
        outgoing = []
        busy = []
    }
}

/// How often to poll. The chat polls fast only while something is running and the screen is visible.
public enum PollPolicy {
    public static func chatInterval(working: Bool, visible: Bool) -> Duration? {
        guard visible else { return nil }
        return working ? .seconds(2) : .seconds(15)
    }

    public static func stateInterval(visible: Bool) -> Duration? {
        visible ? .seconds(30) : nil
    }

    /// Backoff after errors: 5 s, 10 s, 20 s … up to 2 min.
    public static func backoff(failures: Int) -> Duration {
        let s = min(5 * Int(pow(2, Double(max(failures - 1, 0)))), 120)
        return .seconds(s)
    }
}
