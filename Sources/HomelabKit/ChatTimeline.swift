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

        var failed: Bool {
            if case .failed = state { return true }
            return false
        }
    }

    public private(set) var messages: [ChatMessage] = []
    public private(set) var outgoing: [Outgoing] = []
    public private(set) var busy: [String] = []
    /// When (phone time) each message last came in a page: a state fetched after that is newer than what the
    /// message says. The server's `ts` has no time zone and another clock, so it can't be compared with `fetched`.
    public private(set) var received: [Int64: Date] = [:]

    public static let keep = 500

    /// "Clear" in the chat hides the messages up to this id on this phone (`clear`). The server keeps them: no
    /// server in this project has a command that deletes its chat, so the app doesn't pretend to.
    public private(set) var clearedThrough: Int64 = 0

    public init() {}

    /// The id to poll after: the newest message, or the newest cleared one when nothing came since.
    public var cursor: Int64 { max(messages.last?.id ?? 0, clearedThrough) }

    /// Something is on screen that Clear would hide.
    public var canClear: Bool { !messages.isEmpty || outgoing.contains(where: \.failed) }

    /// Hides everything shown now (and failed sends); a message still on its way stays. Polling goes on after the
    /// newest hidden id, so only newer messages come in.
    public mutating func clear() {
        clearedThrough = cursor
        messages = []
        received = [:]
        outgoing.removeAll(where: \.failed)
    }

    /// The mark of an earlier clear (from `ChatClears`), set after `reset` before the first load.
    public mutating func restore(clearedThrough mark: Int64) {
        clearedThrough = max(mark, 0)
        messages.removeAll { $0.id <= clearedThrough }
    }

    /// Shows the cleared messages again: the next load starts from the beginning.
    public mutating func unclear() {
        clearedThrough = 0
        messages = []
        received = [:]
    }

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
        for m in page.messages where m.id > clearedThrough {
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
        clearedThrough = 0
    }

    /// A centred time line (the iMessage pattern): above the first message of each day with its day ("Today 14:32"),
    /// and inside a day above a message that comes `stampGap` or more after the one before it ("14:32"). Every other
    /// message goes without a time. Messages without a time get none and don't count as "the one before".
    public struct Stamp: Sendable, Equatable {
        /// "Today", "Yesterday", "Mon" within a week, else "03.11."; nil inside a day.
        public var day: String?
        public var time: Date

        public init(day: String?, time: Date) {
            self.day = day; self.time = time
        }
    }

    /// The gap after which a message gets its own time line again.
    public static let stampGap: TimeInterval = 10 * 60

    /// The time lines by message id (see `Stamp`).
    public func stamps(now: Date = Date(), calendar: Calendar = .current) -> [Int64: Stamp] {
        var out: [Int64: Stamp] = [:]
        var previous: Date?
        for m in messages {
            guard let ts = m.ts else { continue }
            defer { previous = ts }
            let day = calendar.startOfDay(for: ts)
            guard let last = previous, calendar.startOfDay(for: last) == day else {
                out[m.id] = Stamp(day: Self.dayLabel(day, now: now, calendar: calendar), time: ts)
                continue
            }
            if ts.timeIntervalSince(last) >= Self.stampGap {
                out[m.id] = Stamp(day: nil, time: ts)
            }
        }
        return out
    }

    static func dayLabel(_ day: Date, now: Date, calendar: Calendar) -> String {
        let ago = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: now)).day ?? 0
        switch ago {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2...6:
            let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            return weekdays[(calendar.component(.weekday, from: day) - 1 + 7) % 7]
        default:
            let d = calendar.dateComponents([.day, .month], from: day)
            return String(format: "%02d.%02d.", d.day ?? 0, d.month ?? 0)
        }
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

/// Where each server's chat was cleared on this phone (`ChatTimeline.clearedThrough`), by `ServerConfig.target`:
/// another address or type starts with a full chat again. `chat-cleared.json`.
public struct ChatClears: Codable, Sendable, Equatable {
    public var through: [String: Int64]

    public init(through: [String: Int64] = [:]) {
        self.through = through
    }

    public static let fileName = "chat-cleared.json"

    public func mark(for target: String) -> Int64 { through[target] ?? 0 }

    /// 0 removes the entry.
    public mutating func set(_ mark: Int64, for target: String) {
        through[target] = mark > 0 ? mark : nil
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
        let s = Int(clamping: 5 * pow(2, Double(max(failures - 1, 0))), in: 5...120)
        return .seconds(s)
    }
}

/// When a long agent message folds behind "Show more": only when folding hides a real chunk, so a message a line
/// over the limit doesn't get a button that reveals one line. The screen measures the laid-out text; this decides.
public enum ChatFold {
    /// Lines a folded message still shows.
    public static let shownLines = 12
    /// Fold only when that hides at least this many lines.
    public static let minHidden = 4

    /// How many body lines `height` is (the laid-out height of the text, `lineHeight` of one body line).
    public static func lines(height: Double, lineHeight: Double) -> Int {
        guard lineHeight > 0, height > 0 else { return 0 }
        return Int(clamping: height / lineHeight, in: 0...100_000)
    }

    public static func folds(lines: Int) -> Bool { lines >= shownLines + minHidden }

    public static func folds(height: Double, lineHeight: Double) -> Bool {
        folds(lines: lines(height: height, lineHeight: lineHeight))
    }

    /// The height a folded message is cut to.
    public static func foldedHeight(lineHeight: Double) -> Double { Double(shownLines) * lineHeight }
}

/// The block structure of a chat message's Markdown: paragraphs, headings, lists, quotes, code blocks, tables. The
/// text inside a block stays inline Markdown (bold, `code`, links) for the screen to style. Agents write reports
/// with line breaks that matter, so a single newline inside a paragraph stays a newline.
public enum ChatMarkdown {
    public enum Block: Sendable, Equatable {
        case paragraph(String)
        case heading(String, level: Int)
        /// `- item`, `* item`, `+ item`; `checked` for task items (`- [ ]` false, `- [x]` true). `indent` 0…3.
        case bullet(String, indent: Int, checked: Bool?)
        /// `1. item` or `1) item`; `number` as written ("1").
        case numbered(String, number: String, indent: Int)
        case quote(String)
        case code(String, language: String?)
        /// Rows of cells, the first row is the header. The `|---|` line is dropped.
        case table([[String]])
        case rule
    }

    private enum Run { case paragraph, quote, table }

    public static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var run: Run?
        var buffer: [String] = []
        var rows: [[String]] = []
        var code: (language: String?, lines: [String])?

        func flush() {
            switch run {
            case .paragraph: out.append(.paragraph(buffer.joined(separator: "\n")))
            case .quote: out.append(.quote(buffer.joined(separator: "\n")))
            case .table: if !rows.isEmpty { out.append(.table(rows)) }
            case nil: break
            }
            run = nil; buffer = []; rows = []
        }
        func start(_ kind: Run) {
            if run != kind { flush() }
            run = kind
        }

        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var open = code {
                if line.hasPrefix("```") {
                    out.append(.code(open.lines.joined(separator: "\n"), language: open.language))
                    code = nil
                } else {
                    open.lines.append(raw)
                    code = open
                }
                continue
            }
            if line.hasPrefix("```") {
                flush()
                let language = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                code = (language.isEmpty ? nil : language, [])
                continue
            }
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix("|") {
                start(.table)
                if !isTableSeparator(line) { rows.append(cells(line)) }
                continue
            }
            if line.hasPrefix(">") {
                start(.quote)
                buffer.append(line.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }
            let indent = min(leadingWidth(raw) / 2, 3)
            if isRule(line) {
                flush()
                out.append(.rule)
            } else if let (level, title) = heading(line) {
                flush()
                out.append(.heading(title, level: level))
            } else if let (item, checked) = bullet(line) {
                flush()
                out.append(.bullet(item, indent: indent, checked: checked))
            } else if let (number, item) = numbered(line) {
                flush()
                out.append(.numbered(item, number: number, indent: indent))
            } else if run == nil, leadingWidth(raw) >= 2, case let .bullet(item, i, c)? = out.last {
                out[out.count - 1] = .bullet(item + "\n" + line, indent: i, checked: c)   // continues the item
            } else if run == nil, leadingWidth(raw) >= 2, case let .numbered(item, n, i)? = out.last {
                out[out.count - 1] = .numbered(item + "\n" + line, number: n, indent: i)
            } else {
                start(.paragraph)
                buffer.append(line)
            }
        }
        if let open = code { out.append(.code(open.lines.joined(separator: "\n"), language: open.language)) }
        flush()
        return out
    }

    /// Leading spaces, a tab counting 4.
    static func leadingWidth(_ line: String) -> Int {
        var n = 0
        for c in line {
            if c == " " { n += 1 } else if c == "\t" { n += 4 } else { break }
        }
        return n
    }

    static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let title = rest.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        return title.isEmpty ? nil : (hashes, title)
    }

    static func bullet(_ line: String) -> (String, Bool?)? {
        guard let marker = line.first, "-*+".contains(marker), line.dropFirst().first == " " else { return nil }
        let item = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        for (box, checked) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where item.hasPrefix(box) {
            return (item.dropFirst(box.count).trimmingCharacters(in: .whitespaces), checked)
        }
        return item.isEmpty ? nil : (item, nil)
    }

    static func numbered(_ line: String) -> (String, String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard (1...3).contains(digits.count) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        let item = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return item.isEmpty ? nil : (String(digits), item)
    }

    /// `---`, `***`, `___` (3 or more, spaces allowed).
    static func isRule(_ line: String) -> Bool {
        let chars = line.filter { $0 != " " }
        guard chars.count >= 3, let c = chars.first, "-*_".contains(c) else { return false }
        return chars.allSatisfy { $0 == c }
    }

    static func isTableSeparator(_ line: String) -> Bool {
        line.contains("-") && line.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ line: String) -> [String] {
        var s = Substring(line)
        if s.hasPrefix("|") { s = s.dropFirst() }
        if s.hasSuffix("|") { s = s.dropLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
