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
    /// When (phone time) each message last came in a page: a state fetched after that is newer than what the
    /// message says. The server's `ts` has no time zone and another clock, so it can't be compared with `fetched`.
    public private(set) var received: [Int64: Date] = [:]

    public static let keep = 500

    public init() {}

    /// The id to poll after.
    public var cursor: Int64 { messages.last?.id ?? 0 }

    /// A sent message counts as "working" for at most this long: a server that never echoes it (or changes the
    /// text) must not keep the chat in 2-second polling forever.
    public static let workingTimeout: TimeInterval = 120

    public var isWorking: Bool { isWorking(now: Date()) }

    public func isWorking(now: Date) -> Bool {
        !busy.isEmpty || outgoing.contains {
            if case .sent = $0.state { return now.timeIntervalSince($0.created) < Self.workingTimeout }
            return false
        }
    }

    /// Adds a page of server messages, received at `now`.
    public mutating func merge(_ page: MessagePage, now: Date = Date()) {
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for m in page.messages {
            byID[m.id] = m
            received[m.id] = now
        }
        messages = byID.values.sorted { $0.id < $1.id }.suffix(Self.keep).map { $0 }
        let kept = Set(messages.map(\.id))
        received = received.filter { kept.contains($0.key) }
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
            // Without an id, wait for a message after the current newest one (not the newest itself).
            outgoing[i].state = .sent(serverID ?? (cursor + 1))
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
        received = [:]
    }

    /// The proposals `message` still offers buttons for. The chat only loads messages newer than the last one, so
    /// an older message keeps proposals answered since (here, in the Actions tab or elsewhere). A state fetched after
    /// the message's page came in is newer: it decides which are still open. A proposal counts as the same one only
    /// with the same id and the same buttons: servers reuse short ids, and each button is signed over the whole
    /// pending line, so an old bubble never gets a newer proposal's buttons.
    public func openPending(_ message: ChatMessage, in snapshot: Snapshot?) -> [PendingAction] {
        guard !message.pending.isEmpty, let snapshot, let got = received[message.id], snapshot.fetched >= got else {
            return message.pending
        }
        let open = snapshot.state.pending
        return message.pending.filter { p in open.contains { $0.id == p.id && $0.buttons == p.buttons } }
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
