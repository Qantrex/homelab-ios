import Foundation

// Companion API v1 models (server/openapi.yaml). Decoding is tolerant (see Lenient.swift); encoding writes the
// same shape back, so a cached snapshot decodes like a fresh answer.

public struct ServerInfo: Codable, Sendable, Equatable {
    public var api: Int
    public var name: String?
    public var server: String?
    public var version: String?
    public var features: Set<Feature>
    public var auth: String?
    /// Slash commands the server's chat understands, offered as quick buttons. Empty = no buttons.
    public var commands: [String]
    /// The server keeps standing approvals ("Always"). Changes what the confirm text promises.
    public var standingApprovals: Bool

    public enum Feature: String, Codable, Sendable, CaseIterable {
        case status, hosts, actions, chat, cards, services
        /// The app may start actions itself (GET /actions, POST /actions/<name>).
        case runActions = "run-actions"
    }

    public init(api: Int = 1, name: String? = nil, server: String? = nil, version: String? = nil,
                features: Set<Feature> = Set(Feature.allCases), auth: String? = nil, commands: [String] = [],
                standingApprovals: Bool = false) {
        self.api = api; self.name = name; self.server = server; self.version = version
        self.features = features; self.auth = auth; self.commands = commands
        self.standingApprovals = standingApprovals
    }

    enum CodingKeys: String, CodingKey {
        case api, name, server, version, features, auth, commands
        case standingApprovals = "standing_approvals"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let api = c.int(.api) else {
            throw DecodingError.keyNotFound(CodingKeys.api, .init(codingPath: c.codingPath, debugDescription: "no api version"))
        }
        self.api = api
        name = c.text(.name)
        server = c.text(.server)
        version = c.text(.version)
        // Missing list = an old or minimal server: assume the basics, so the overview still shows.
        let raw = c.strings(.features)
        features = c.contains(.features) ? Set(raw.compactMap(Feature.init(rawValue:))) : [.status, .hosts]
        auth = c.text(.auth)
        // Only "/word" commands, short, at most 8: they become buttons.
        commands = Array(c.strings(.commands).filter { $0.hasPrefix("/") && $0.count <= 24 && !$0.contains(" ") }.prefix(8))
        standingApprovals = c.bool(.standingApprovals) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(api, forKey: .api)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(server, forKey: .server)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encode(features.map(\.rawValue).sorted(), forKey: .features)
        try c.encodeIfPresent(auth, forKey: .auth)
        try c.encode(commands, forKey: .commands)
        try c.encode(standingApprovals, forKey: .standingApprovals)
    }
}

public enum OverallStatus: String, Codable, Sendable, CaseIterable {
    case ok, warning, problem, unknown

    public init(lenient raw: String?) {
        switch raw?.lowercased() {
        case "ok", "healthy", "up", "green": self = .ok
        case "warning", "warn", "degraded", "yellow": self = .warning
        case "problem", "error", "alert", "critical", "down", "red": self = .problem
        default: self = .unknown
        }
    }

    /// Worst first, for sorting and for combining several servers.
    public var severity: Int {
        switch self {
        case .problem: 3
        case .warning: 2
        case .unknown: 1
        case .ok: 0
        }
    }
}

public struct Problem: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var text: String
    public var host: String?
    public var severity: Severity
    public var since: Date?

    public enum Severity: String, Codable, Sendable { case warning, problem }

    public init(id: String? = nil, text: String, host: String? = nil, severity: Severity = .problem, since: Date? = nil) {
        self.id = id ?? text
        self.text = text; self.host = host; self.severity = severity; self.since = since
    }

    enum CodingKeys: String, CodingKey { case id, text, host, severity, since }

    public init(from decoder: any Decoder) throws {
        // Legacy servers (and agent-chat's old /api/state) send problems as plain strings.
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self.init(text: s)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let text = c.text(.text) else {
            throw DecodingError.keyNotFound(CodingKeys.text, .init(codingPath: c.codingPath, debugDescription: "no text"))
        }
        self.init(id: c.text(.id), text: text, host: c.text(.host),
                  severity: c.string(.severity)?.lowercased() == "warning" ? .warning : .problem, since: c.date(.since))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(host, forKey: .host)
        try c.encode(severity, forKey: .severity)
        try c.encodeIfPresent(since.map(ServerDate.string), forKey: .since)
    }
}

public struct Host: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String?
    public var reachable: Bool?
    public var checked: Date?
    public var load: Double?
    public var cpuCount: Int?
    public var memPct: Int?
    public var temp: Double?
    public var disks: [String: Int]
    public var containersUp: Int?
    public var containersTotal: Int?
    public var upgradable: Int?
    public var rebootRequired: Bool?
    public var backupLast: String?
    public var backupResult: String?
    public var flags: [String]
    public var url: URL?
    /// The last 24 h (load, RAM, temperature, fullest disk). Nil when the server sends none.
    public var history: HostHistory?
    /// Every container with its state, unique names. Empty when the server sends none (`containers` still counts).
    public var containerList: [ContainerInfo]

    public init(id: String, name: String? = nil, kind: String? = nil, reachable: Bool? = nil, checked: Date? = nil,
                load: Double? = nil, cpuCount: Int? = nil, memPct: Int? = nil, temp: Double? = nil,
                disks: [String: Int] = [:], containersUp: Int? = nil, containersTotal: Int? = nil,
                upgradable: Int? = nil, rebootRequired: Bool? = nil, backupLast: String? = nil,
                backupResult: String? = nil, flags: [String] = [], url: URL? = nil, history: HostHistory? = nil,
                containerList: [ContainerInfo] = []) {
        self.id = id; self.name = name ?? id; self.kind = kind; self.reachable = reachable; self.checked = checked
        self.load = load; self.cpuCount = cpuCount; self.memPct = memPct; self.temp = temp; self.disks = disks
        self.containersUp = containersUp; self.containersTotal = containersTotal; self.upgradable = upgradable
        self.rebootRequired = rebootRequired; self.backupLast = backupLast; self.backupResult = backupResult
        self.flags = flags; self.url = url
        self.history = history.flatMap { $0.isEmpty ? nil : $0 }
        var names = Set<String>()
        self.containerList = Array(containerList.filter { names.insert($0.name).inserted }.prefix(Self.maxContainers))
    }

    /// More than this many containers on one host is a server bug; the rest are dropped.
    public static let maxContainers = 300

    enum CodingKeys: String, CodingKey {
        case id, name, kind, reachable, checked, load, temp, disks, containers, updates, backup, flags, url, history
        case cpuCount = "cpu_count", memPct = "mem_pct", containerList = "container_list"
    }
    enum ContainerKeys: String, CodingKey { case up, total }
    enum UpdateKeys: String, CodingKey { case upgradable, rebootRequired = "reboot_required" }
    enum BackupKeys: String, CodingKey { case last, result }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.text(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "no id"))
        }
        self.init(id: id, name: c.text(.name), kind: c.text(.kind), reachable: c.bool(.reachable),
                  checked: c.date(.checked), load: c.double(.load), cpuCount: c.int(.cpuCount),
                  memPct: c.int(.memPct).map { min(max($0, 0), 100) }, temp: c.double(.temp),
                  disks: c.numberMap(.disks).mapValues { min(max(Int($0.rounded()), 0), 100) },
                  flags: c.strings(.flags), url: c.text(.url).flatMap(URLPolicy.webURL),
                  containerList: c.array(ContainerInfo.self, .containerList))
        // Without its own end, the history ends when the host was checked.
        if var h = c.lenient(HostHistory.self, .history), !h.isEmpty {
            if h.end == nil { h.end = checked }
            history = h
        }
        if let n = try? c.nestedContainer(keyedBy: ContainerKeys.self, forKey: .containers) {
            containersUp = n.int(.up); containersTotal = n.int(.total)
        }
        if let n = try? c.nestedContainer(keyedBy: UpdateKeys.self, forKey: .updates) {
            upgradable = n.int(.upgradable); rebootRequired = n.bool(.rebootRequired)
        }
        if let n = try? c.nestedContainer(keyedBy: BackupKeys.self, forKey: .backup) {
            backupLast = n.text(.last); backupResult = n.text(.result)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(reachable, forKey: .reachable)
        try c.encodeIfPresent(checked.map(ServerDate.string), forKey: .checked)
        try c.encodeIfPresent(load, forKey: .load)
        try c.encodeIfPresent(cpuCount, forKey: .cpuCount)
        try c.encodeIfPresent(memPct, forKey: .memPct)
        try c.encodeIfPresent(temp, forKey: .temp)
        if !disks.isEmpty { try c.encode(disks, forKey: .disks) }
        if containersUp != nil || containersTotal != nil {
            var n = c.nestedContainer(keyedBy: ContainerKeys.self, forKey: .containers)
            try n.encodeIfPresent(containersUp, forKey: .up)
            try n.encodeIfPresent(containersTotal, forKey: .total)
        }
        if upgradable != nil || rebootRequired != nil {
            var n = c.nestedContainer(keyedBy: UpdateKeys.self, forKey: .updates)
            try n.encodeIfPresent(upgradable, forKey: .upgradable)
            try n.encodeIfPresent(rebootRequired, forKey: .rebootRequired)
        }
        if backupLast != nil || backupResult != nil {
            var n = c.nestedContainer(keyedBy: BackupKeys.self, forKey: .backup)
            try n.encodeIfPresent(backupLast, forKey: .last)
            try n.encodeIfPresent(backupResult, forKey: .result)
        }
        if !flags.isEmpty { try c.encode(flags, forKey: .flags) }
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(history, forKey: .history)
        if !containerList.isEmpty { try c.encode(containerList, forKey: .containerList) }
    }
}

public struct PendingAction: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var job: String?
    public var action: String?
    public var arg: String?
    public var reason: String?
    public var created: Date?
    public var buttons: [Verb: String]

    public enum Verb: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
        case approve, always, deny
    }

    public init(id: String, job: String? = nil, action: String? = nil, arg: String? = nil, reason: String? = nil,
                created: Date? = nil, buttons: [Verb: String] = [:]) {
        self.id = id; self.job = job; self.action = action; self.arg = arg; self.reason = reason
        self.created = created; self.buttons = buttons
    }

    enum CodingKeys: String, CodingKey { case id, job, action, arg, reason, created, buttons }
    struct VerbKeys: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.text(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "no id"))
        }
        var buttons: [Verb: String] = [:]
        if let n = try? c.nestedContainer(keyedBy: VerbKeys.self, forKey: .buttons) {
            for verb in Verb.allCases {
                if let s = (try? n.decodeIfPresent(String.self, forKey: VerbKeys(stringValue: verb.rawValue))) ?? nil,
                   !s.isEmpty {
                    buttons[verb] = s
                }
            }
        }
        // "-" is agent-chat's "no argument".
        self.init(id: id, job: c.text(.job), action: c.text(.action), arg: c.text(.arg).flatMap { $0 == "-" ? nil : $0 },
                  reason: c.text(.reason), created: c.date(.created), buttons: buttons)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(job, forKey: .job)
        try c.encodeIfPresent(action, forKey: .action)
        try c.encodeIfPresent(arg, forKey: .arg)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encodeIfPresent(created.map(ServerDate.string), forKey: .created)
        var n = c.nestedContainer(keyedBy: VerbKeys.self, forKey: .buttons)
        for (verb, s) in buttons { try n.encode(s, forKey: VerbKeys(stringValue: verb.rawValue)) }
    }

    /// "restart media sonarr": the line the UI shows as the title.
    public var title: String {
        [action, arg].compactMap { $0 }.joined(separator: " ").nonEmpty ?? "Action \(id)"
    }
}

public enum Tint: String, Codable, Sendable, CaseIterable {
    case gray, blue, green, orange, red, purple, teal, yellow, pink

    public init(lenient raw: String?) {
        self = raw.flatMap { Tint(rawValue: $0.lowercased()) } ?? .gray
    }
}

/// One tap in a card: an action the app may start (`POST /actions/<name>` with `arg` and `payload`). On an item it runs
/// after one confirm; on a card it opens that action's form, prefilled. The app offers it only when `GET /actions`
/// lists the action (see `AppModel.startable`).
public struct ItemAction: Codable, Sendable, Equatable, Hashable {
    /// The action's name, as in `GET /actions` (always a valid name; an invalid one drops the whole action).
    public var name: String
    /// Button or confirm text ("Tick off", "Add"). Nil = the app uses the action's own label.
    public var label: String?
    /// The argument; "" for none.
    public var arg: String
    /// Payload values by field name.
    public var payload: [String: String]

    public init(name: String, label: String? = nil, arg: String = "", payload: [String: String] = [:]) {
        self.name = name; self.label = label; self.arg = arg; self.payload = payload
    }

    enum CodingKeys: String, CodingKey { case name, label, arg, payload }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = c.text(.name), ActionSpec.isValidName(name) else {
            throw DecodingError.keyNotFound(CodingKeys.name, .init(codingPath: c.codingPath, debugDescription: "no valid name"))
        }
        // Payload values are text; anything else (numbers, lists) is dropped rather than guessed.
        let raw = c.lenient([String: Lossy<String>].self, .payload) ?? [:]
        self.init(name: name, label: c.text(.label), arg: c.string(.arg) ?? "", payload: raw.compactMapValues(\.value))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(label, forKey: .label)
        if !arg.isEmpty { try c.encode(arg, forKey: .arg) }
        if !payload.isEmpty { try c.encode(payload, forKey: .payload) }
    }
}

public struct Card: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var title: String?
    public var subtitle: String?
    public var icon: String?
    public var tint: Tint
    public var style: Style
    public var updated: String?
    public var text: String?
    public var items: [Item]
    /// The header button: opens this action's form, prefilled with its `arg` and `payload` ("Add" on a to-do list).
    public var action: ItemAction?

    public enum Style: String, Codable, Sendable {
        case list, metrics, text
        /// To-dos: a circle per item (filled when `done`), title, subtitle and `due`.
        case checklist
        /// Items count down to their `due` ("2 d", "5 h", "today", "3 d ago"), soonest first (`sortedForCountdown`).
        case countdown
    }

    public struct Item: Codable, Sendable, Equatable, Hashable {
        public var title: String?
        public var subtitle: String?
        public var value: String?
        public var progress: Double?
        public var icon: String?
        public var url: URL?
        public var tint: Tint?
        /// Checklist items: ticked off or not. Nil = not sent (open).
        public var done: Bool?
        /// When it's due. A day without a time is local midnight (`Format.isDayOnly`).
        public var due: Date?
        /// One tap runs this action after a confirm (a checklist circle ticks the item off).
        public var action: ItemAction?

        public init(title: String? = nil, subtitle: String? = nil, value: String? = nil, progress: Double? = nil,
                    icon: String? = nil, url: URL? = nil, tint: Tint? = nil, done: Bool? = nil, due: Date? = nil,
                    action: ItemAction? = nil) {
            self.title = title; self.subtitle = subtitle; self.value = value
            self.progress = progress.map { min(max($0, 0), 1) }; self.icon = icon; self.url = url; self.tint = tint
            self.done = done; self.due = due; self.action = action
        }

        enum CodingKeys: String, CodingKey { case title, subtitle, value, progress, icon, url, tint, done, due, action }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(title: c.text(.title), subtitle: c.text(.subtitle), value: c.text(.value),
                      progress: c.double(.progress), icon: c.text(.icon),
                      url: c.text(.url).flatMap(URLPolicy.webURL),
                      tint: c.text(.tint).map { Tint(lenient: $0) }, done: c.bool(.done), due: c.date(.due),
                      action: c.lenient(ItemAction.self, .action))
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(title, forKey: .title)
            try c.encodeIfPresent(subtitle, forKey: .subtitle)
            try c.encodeIfPresent(value, forKey: .value)
            try c.encodeIfPresent(progress, forKey: .progress)
            try c.encodeIfPresent(icon, forKey: .icon)
            try c.encodeIfPresent(url, forKey: .url)
            try c.encodeIfPresent(tint, forKey: .tint)
            try c.encodeIfPresent(done, forKey: .done)
            try c.encodeIfPresent(due.map(ServerDate.string), forKey: .due)
            try c.encodeIfPresent(action, forKey: .action)
        }
    }

    public init(id: String, title: String? = nil, subtitle: String? = nil, icon: String? = nil, tint: Tint = .gray,
                style: Style = .list, updated: String? = nil, text: String? = nil, items: [Item] = [],
                action: ItemAction? = nil) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.icon = icon; self.tint = tint
        self.style = style; self.updated = updated; self.text = text; self.items = items; self.action = action
    }

    enum CodingKeys: String, CodingKey { case id, title, subtitle, icon, tint, style, updated, text, items, action }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.text(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "no id"))
        }
        self.init(id: id, title: c.text(.title), subtitle: c.text(.subtitle), icon: c.text(.icon),
                  tint: Tint(lenient: c.text(.tint)),
                  style: c.text(.style).flatMap { Style(rawValue: $0.lowercased()) } ?? .list,
                  updated: c.text(.updated), text: c.text(.text), items: c.array(Item.self, .items),
                  action: c.lenient(ItemAction.self, .action))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(subtitle, forKey: .subtitle)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encode(tint, forKey: .tint)
        try c.encode(style, forKey: .style)
        try c.encodeIfPresent(updated, forKey: .updated)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encode(items, forKey: .items)
        try c.encodeIfPresent(action, forKey: .action)
    }

    /// Items in countdown order: soonest `due` first (overdue ones lead), items without `due` last, ties in the
    /// server's order.
    public var sortedForCountdown: [Item] {
        items.enumerated().sorted { a, b in
            switch (a.element.due, b.element.due) {
            case let (x?, y?): x == y ? a.offset < b.offset : x < y
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.element)
    }
}

public struct ChatMessage: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: Int64
    public var ts: Date?
    public var from: Sender
    public var job: String?
    public var status: String?
    public var text: String
    /// Proposals made in this message that still wait for an answer (Approve / Always / Deny in the bubble). The
    /// server computes them when it answers; approved, denied or expired ones are gone.
    public var pending: [PendingAction]
    /// Cards shown inside the bubble, under the text.
    public var cards: [Card]

    public enum Sender: String, Codable, Sendable { case me, agent }

    public init(id: Int64, ts: Date? = nil, from: Sender, job: String? = nil, status: String? = nil, text: String,
                pending: [PendingAction] = [], cards: [Card] = []) {
        self.id = id; self.ts = ts; self.from = from; self.job = job; self.status = status; self.text = text
        self.pending = pending; self.cards = cards
    }

    enum CodingKeys: String, CodingKey { case id, ts, from, job, status, text, pending, cards }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.int64(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "no id"))
        }
        var pendingIDs = Set<String>()
        var cardIDs = Set<String>()
        self.init(id: id, ts: c.date(.ts), from: c.string(.from)?.lowercased() == "me" ? .me : .agent,
                  job: c.text(.job), status: c.text(.status)?.uppercased(), text: c.string(.text) ?? "",
                  pending: c.array(PendingAction.self, .pending).filter { pendingIDs.insert($0.id).inserted },
                  cards: c.array(Card.self, .cards).filter { cardIDs.insert($0.id).inserted })
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(ts.map(ServerDate.string), forKey: .ts)
        try c.encode(from, forKey: .from)
        try c.encodeIfPresent(job, forKey: .job)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encode(text, forKey: .text)
        if !pending.isEmpty { try c.encode(pending, forKey: .pending) }
        if !cards.isEmpty { try c.encode(cards, forKey: .cards) }
    }

    /// A scheduled report (morning, watchdog…) rather than a reply in the conversation.
    public var isReport: Bool {
        from == .agent && !(job == nil || job == "chat" || job == "action")
    }
}

public struct MessagePage: Codable, Sendable, Equatable {
    public var messages: [ChatMessage]
    public var busy: [String]

    public init(messages: [ChatMessage] = [], busy: [String] = []) {
        self.messages = messages; self.busy = busy
    }

    enum CodingKeys: String, CodingKey { case messages, busy }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(messages: c.array(ChatMessage.self, .messages).sorted { $0.id < $1.id }, busy: c.strings(.busy))
    }
}

public struct Service: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var name: String
    public var url: URL
    public var group: String?
    public var icon: String?
    public var description: String?

    public var id: String { url.absoluteString + "|" + name }

    public init(name: String, url: URL, group: String? = nil, icon: String? = nil, description: String? = nil) {
        self.name = name; self.url = url; self.group = group; self.icon = icon; self.description = description
    }

    enum CodingKeys: String, CodingKey { case name, url, group, icon, description }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = c.text(.name), let url = c.text(.url).flatMap(URLPolicy.webURL) else {
            throw DecodingError.keyNotFound(CodingKeys.url, .init(codingPath: c.codingPath, debugDescription: "no name/url"))
        }
        self.init(name: name, url: url, group: c.text(.group), icon: c.text(.icon), description: c.text(.description))
    }
}

struct ServiceList: Decodable {
    var services: [Service]
    enum CodingKeys: String, CodingKey { case services }
    init(from decoder: any Decoder) throws {
        // Accept {"services": [...]} and a bare array.
        if let list = try? decoder.singleValueContainer().decode([Lossy<Service>].self) {
            services = list.compactMap(\.value)
            return
        }
        services = try decoder.container(keyedBy: CodingKeys.self).array(Service.self, .services)
    }
}

public struct HomelabState: Codable, Sendable, Equatable {
    public var time: Date?
    public var status: OverallStatus
    public var checked: Date?
    public var problems: [Problem]
    public var hosts: [Host]
    public var pending: [PendingAction]
    public var cards: [Card]
    public var busy: [String]
    public var lastMessage: ChatMessage?

    public init(time: Date? = nil, status: OverallStatus = .unknown, checked: Date? = nil, problems: [Problem] = [],
                hosts: [Host] = [], pending: [PendingAction] = [], cards: [Card] = [], busy: [String] = [],
                lastMessage: ChatMessage? = nil) {
        self.time = time; self.status = status; self.checked = checked; self.problems = problems; self.hosts = hosts
        self.pending = pending; self.cards = cards; self.busy = busy; self.lastMessage = lastMessage
    }

    enum CodingKeys: String, CodingKey {
        case time, status, checked, problems, hosts, pending, cards, busy
        case lastMessage = "last_message"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var problems = c.array(Problem.self, .problems)
        // Duplicate ids would break SwiftUI lists; keep the first.
        var seen = Set<String>()
        problems = problems.filter { seen.insert($0.id).inserted }
        var hostIDs = Set<String>()
        let hosts = c.array(Host.self, .hosts).filter { hostIDs.insert($0.id).inserted }
        var pendingIDs = Set<String>()
        let pending = c.array(PendingAction.self, .pending).filter { pendingIDs.insert($0.id).inserted }
        var cardIDs = Set<String>()
        let cards = c.array(Card.self, .cards).filter { cardIDs.insert($0.id).inserted }
        var status = OverallStatus(lenient: c.string(.status))
        if status == .unknown, c.contains(.problems) || c.contains(.hosts) {
            status = problems.isEmpty ? .ok : problems.contains { $0.severity == .problem } ? .problem : .warning
            if hosts.isEmpty && problems.isEmpty { status = .unknown }
        }
        self.init(time: c.date(.time), status: status, checked: c.date(.checked), problems: problems, hosts: hosts,
                  pending: pending, cards: cards, busy: c.strings(.busy), lastMessage: c.lenient(ChatMessage.self, .lastMessage))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(time.map(ServerDate.string), forKey: .time)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(checked.map(ServerDate.string), forKey: .checked)
        try c.encode(problems, forKey: .problems)
        try c.encode(hosts, forKey: .hosts)
        try c.encode(pending, forKey: .pending)
        try c.encode(cards, forKey: .cards)
        try c.encode(busy, forKey: .busy)
        try c.encodeIfPresent(lastMessage, forKey: .lastMessage)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
