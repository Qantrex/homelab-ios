import Foundation

/// A personality's comment on one real fact of the lab: "media is 93% full. You will not rewatch all of that." The
/// fact (host, number, title) is always in the text and always true; only the attitude changes with the personality.
public struct Take: Sendable, Equatable {
    public var text: String
    public var fact: Fact
    /// How serious the fact is, for a face or a colour: alarm (a host down, a listed problem), headsUp (a warning,
    /// something due, something to approve), calm (a parcel, all fine). Never `.unknown`.
    public var mood: TodayMood.Level

    public init(text: String, fact: Fact, mood: TodayMood.Level) {
        self.text = text; self.fact = fact; self.mood = mood
    }

    /// The fact a take is about. Values are the real ones (untruncated); the text may shorten long names.
    public enum Fact: Sendable, Equatable, Hashable {
        /// A host that should answer and doesn't (asleep hosts don't count).
        case hostDown(host: String)
        /// A container in a bad state: "unhealthy", "exited", "restarting", "not running", …
        case container(host: String, name: String, state: String)
        case disk(host: String, mount: String?, percent: Int)
        case hot(host: String, celsius: Int)
        case load(host: String, load: Double, cores: Int)
        /// `flag` as shown: "under-voltage now", "throttled now", "under-voltage since boot", "under-voltage", "throttling".
        case power(host: String, flag: String)
        case backupFailed(host: String)
        /// A problem or warning no other case fits: its text, without the "host: " prefix.
        case problem(host: String?, text: String)
        case overdue(count: Int, oldest: String)
        case deadline(title: String, tomorrow: Bool)
        /// Actions to approve; `first` is the first one's title ("restart media sonarr").
        case waiting(count: Int, first: String?)
        case parcel(title: String)
        /// Nothing to report: hosts up, containers running (summed), the host with the least load (with 2+ hosts).
        case allFine(up: Int, containers: Int, quietest: String?)

        public enum Kind: String, CaseIterable, Sendable {
            case hostDown, container, disk, hot, load, power, backupFailed, problem
            case overdue, deadline, waiting, parcel, allFine
        }

        public var kind: Kind {
            switch self {
            case .hostDown: .hostDown
            case .container: .container
            case .disk: .disk
            case .hot: .hot
            case .load: .load
            case .power: .power
            case .backupFailed: .backupFailed
            case .problem: .problem
            case .overdue: .overdue
            case .deadline: .deadline
            case .waiting: .waiting
            case .parcel: .parcel
            case .allFine: .allFine
            }
        }

        /// What the fact is about, without its numbers: the per-day pick stays put while a percentage moves.
        var identity: String {
            switch self {
            case let .hostDown(h), let .hot(h, _), let .load(h, _, _), let .power(h, _), let .backupFailed(h): h
            case let .container(h, n, _): h + "/" + n
            case let .disk(h, m, _): h + (m ?? "")
            case let .problem(h, t): (h ?? "") + t
            case let .overdue(_, t), let .deadline(t, _), let .parcel(t): t
            case .waiting, .allFine: ""
            }
        }

        /// The placeholders this fact fills. A template that needs one not listed here isn't used for it.
        var values: [String: String] {
            switch self {
            case let .hostDown(h):
                return ["host": Voice.cut(h, Voice.hostMax)]
            case let .container(h, n, s):
                return ["host": Voice.cut(h, Voice.hostMax), "container": Voice.cut(n, Voice.containerMax), "state": s]
            case let .disk(h, m, p):
                var v = ["host": Voice.cut(h, Voice.hostMax), "pct": "\(p)%"]
                if let m, !m.isEmpty { v["mount"] = Voice.cut(m, Voice.mountMax) }
                return v
            case let .hot(h, c):
                return ["host": Voice.cut(h, Voice.hostMax), "temp": "\(c)°C"]
            case let .load(h, l, c):
                return ["host": Voice.cut(h, Voice.hostMax), "load": Format.load(l), "cores": Voice.count(c, "core")]
            case let .power(h, f):
                return ["host": Voice.cut(h, Voice.hostMax), "flag": f]
            case let .backupFailed(h):
                return ["host": Voice.cut(h, Voice.hostMax)]
            case let .problem(h, t):
                var v = ["text": Voice.cut(t, Voice.textMax)]
                if let h, !h.isEmpty { v["host"] = Voice.cut(h, Voice.hostMax) }
                return v
            case let .overdue(n, t):
                var v = ["todos": Voice.count(n, "to-do"), "title": Voice.cut(t, Voice.titleMax)]
                if n > 1 { v["more"] = n == 2 ? "1 other" : "\(n - 1) others" }
                return v
            case let .deadline(t, tomorrow):
                return ["title": Voice.cut(t, Voice.titleMax), "when": tomorrow ? "tomorrow" : "today"]
            case let .waiting(n, first):
                var v = ["actions": Voice.count(n, "action")]
                if let first, !first.isEmpty { v["first"] = Voice.cut(first, Voice.firstMax) }
                return v
            case let .parcel(t):
                return ["title": Voice.cut(t, Voice.titleMax)]
            case let .allFine(up, containers, quietest):
                var v = ["machines": Voice.count(up, "machine")]
                if containers > 0 { v["containers"] = Voice.count(containers, "container") }
                if let quietest { v["quiet"] = Voice.cut(quietest, Voice.hostMax) }
                return v
            }
        }
    }
}

public extension Voice {
    // MARK: Takes

    /// The take on the most notable fact of `state`, nil when the personality is off, nothing is loaded, or there is
    /// nothing true to say (status unknown, no host up). Then use `line(moment(mood.level), …)` instead.
    /// The pick is fixed for the day and the fact; `variant` 1, 2, … are the next templates (wrapping), for a "say
    /// something else" tap; `takeCount` says how many there are.
    static func take(for state: HomelabState?, personality: Personality, now: Date = Date(),
                     calendar: Calendar = .current, variant: Int = 0) -> Take? {
        guard personality != .off, let state, let found = notableFact(in: state, now: now, calendar: calendar)
        else { return nil }
        return make(found.fact, mood: found.mood, personality: personality, now: now, calendar: calendar, variant: variant)
    }

    /// How many different takes `take(for:…)` cycles through for the state's fact (0 when it gives none).
    static func takeCount(for state: HomelabState?, personality: Personality, now: Date = Date(),
                          calendar: Calendar = .current) -> Int {
        guard personality != .off, let state, let found = notableFact(in: state, now: now, calendar: calendar)
        else { return 0 }
        return eligible(found.fact, personality).count
    }

    /// A one-line comment for a problem card. `host` is the problem's host, when the state has it (its containers,
    /// disks and flags make the take more specific).
    static func take(for problem: Problem, host: Host?, personality: Personality, now: Date = Date(),
                     calendar: Calendar = .current, variant: Int = 0) -> Take? {
        guard personality != .off else { return nil }
        return make(fact(for: problem, host: host), mood: problem.severity == .problem ? .alarm : .headsUp,
                    personality: personality, now: now, calendar: calendar, variant: variant, card: true)
    }

    static func takeCount(for problem: Problem, host: Host?, personality: Personality) -> Int {
        personality == .off ? 0 : eligible(fact(for: problem, host: host), personality).count
    }

    /// THE most notable fact, in this order: a host down; a listed problem; a disk at 90% or more; a host over 75°C;
    /// load over twice the cores; under-voltage or throttling; any other warning; overdue to-dos; a deadline today or
    /// tomorrow; actions to approve; a parcel out for delivery; else all fine (only when the status is ok).
    static func notableFact(in state: HomelabState, now: Date = Date(),
                            calendar: Calendar = .current) -> (fact: Take.Fact, mood: TodayMood.Level)? {
        let awake = state.hosts.filter { !$0.flags.contains("asleep") }
        let up = awake.filter { $0.reachable == true }
        func host(_ id: String?) -> Host? { id.flatMap { id in state.hosts.first { $0.id == id } } }

        if let down = awake.first(where: { $0.reachable == false }) {
            return (.hostDown(host: down.name), .alarm)
        }
        if let p = state.problems.first(where: { $0.severity == .problem }) {
            return (fact(for: p, host: host(p.host)), .alarm)
        }
        if state.status == .problem && state.problems.isEmpty {
            return (.problem(host: nil, text: "a problem the server won't name"), .alarm)
        }
        let disks = up.compactMap { h in Format.worstDisk(h.disks).map { (h, $0) } }.filter { $0.1.percent >= 90 }
        if let full = disks.max(by: { $0.1.percent < $1.1.percent }) {
            return (.disk(host: full.0.name, mount: full.1.mount, percent: full.1.percent), .headsUp)
        }
        if let h = up.filter({ ($0.temp ?? 0) > 75 }).max(by: { ($0.temp ?? 0) < ($1.temp ?? 0) }), let t = h.temp {
            return (.hot(host: h.name, celsius: Int(clamping: t)), .headsUp)
        }
        func share(_ h: Host) -> Double { Format.loadShare(h.load, cores: h.cpuCount) ?? 0 }
        if let h = up.filter({ share($0) > 2 }).max(by: { share($0) < share($1) }), let l = h.load {
            return (.load(host: h.name, load: l, cores: max(h.cpuCount ?? 1, 1)), .headsUp)
        }
        for flag in ["undervoltage_now", "throttled_now", "undervoltage_since_boot"] {
            if let h = up.first(where: { $0.flags.contains(flag) }) {
                return (.power(host: h.name, flag: Format.flag(flag).lowercased()), .headsUp)
            }
        }
        if let p = state.problems.first {
            return (fact(for: p, host: host(p.host)), .headsUp)
        }
        if let f = numbersWarning(up) { return (f, .headsUp) }
        if state.status == .warning {
            return (.problem(host: nil, text: "a warning the server won't name"), .headsUp)
        }

        let today = calendar.startOfDay(for: now)
        let open = state.cards.flatMap { card in card.items.filter { $0.done != true }.map { (card, $0) } }
        let overdue = open.filter { card, item in
            guard card.style == .checklist, let due = item.due, item.title?.nonEmpty != nil else { return false }
            return item.dueIsDay ? Format.dueDay(due, calendar: calendar) < today : due < now
        }.map(\.1).sorted { ($0.due ?? now) < ($1.due ?? now) }
        if let oldest = overdue.first?.title {
            return (.overdue(count: overdue.count, oldest: oldest), .headsUp)
        }
        let soon = open.compactMap { card, item -> (Date, String, Bool)? in
            guard card.style == .countdown, let due = item.due, let title = item.title?.nonEmpty else { return nil }
            let day = item.dueIsDay ? Format.dueDay(due, calendar: calendar) : calendar.startOfDay(for: due)
            let days = calendar.dateComponents([.day], from: today, to: day).day ?? -1
            guard days == 0 || days == 1, item.dueIsDay || due >= now else { return nil }
            return (due, title, days == 1)
        }.min { $0.0 < $1.0 }
        if let soon {
            return (.deadline(title: soon.1, tomorrow: soon.2), .headsUp)
        }
        if !state.pending.isEmpty {
            return (.waiting(count: state.pending.count, first: state.pending.first?.title), .headsUp)
        }
        let parcel = open.first { card, item in
            guard card.style != .checklist, card.style != .countdown, item.title?.nonEmpty != nil else { return false }
            return [item.subtitle, item.value].compactMap { $0?.lowercased() }.contains { $0.contains("out for delivery") }
        }
        if let title = parcel?.1.title {
            return (.parcel(title: title), .calm)
        }
        guard state.status == .ok, !up.isEmpty else { return nil }
        let loaded = up.filter { $0.load != nil }
        let quiet = loaded.count >= 2 ? loaded.min { share($0) < share($1) }?.name : nil
        return (.allFine(up: up.count, containers: up.reduce(0) { $0 + ($1.containersUp ?? 0) }, quietest: quiet), .calm)
    }

    /// What a problem is about, read from its text and its host's numbers. Only says what the text or the numbers
    /// show; anything else is `.problem` with the text itself.
    static func fact(for problem: Problem, host: Host?) -> Take.Fact {
        let hostName = host?.name ?? problem.host?.nonEmpty
        var text = problem.text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in [problem.host, host?.id, host?.name].compactMap({ $0 }) where !prefix.isEmpty {
            if text.lowercased().hasPrefix(prefix.lowercased() + ":") {
                text = String(text.dropFirst(prefix.count + 1)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        let generic = Take.Fact.problem(host: hostName, text: text.isEmpty ? problem.text : text)
        guard let hostName else { return generic }
        let lower = text.lowercased()
        let words = Set(lower.split { !($0.isLetter || $0.isNumber || "_.-".contains($0)) }.map(String.init))
        func has(_ needles: String...) -> Bool { needles.contains { lower.contains($0) } }

        // A container: named after "container", or one of the host's containers named in the text.
        var name: String?
        if let m = text.firstMatch(of: /[Cc]ontainers?\s+["'`]?([A-Za-z0-9][A-Za-z0-9_.-]*)/) {
            let n = String(m.1).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !["is", "was", "has", "on", "of", "the", "in"].contains(n.lowercased()) { name = n }
        }
        let list = host?.containerList ?? []
        if name == nil {
            let named = list.filter { words.contains($0.name.lowercased()) }
            name = (named.first { $0.health == .unhealthy || $0.state != .running } ?? named.first)?.name
        }
        if let name {
            let info = list.first { $0.name.lowercased() == name.lowercased() }
            let said = ["unhealthy", "exited", "restarting", "not running", "stopped", "crashed", "dead", "paused",
                        "missing", "failing"].first { lower.contains($0) } ?? (words.contains("down") ? "down" : nil)
            let seen: String? = info.flatMap { i in
                if i.health == .unhealthy { return "unhealthy" }
                return i.state == .running || i.state == .unknown ? nil : i.state.rawValue
            }
            if let state = said ?? seen { return .container(host: hostName, name: name, state: state) }
            return generic
        }

        let flags = host?.flags ?? []
        if has("under-voltage", "undervoltage", "under voltage") {
            let flag = lower.contains("since boot") ? "under-voltage since boot"
                : (words.contains("now") || flags.contains("undervoltage_now")) ? "under-voltage now" : "under-voltage"
            return .power(host: hostName, flag: flag)
        }
        if has("throttl") {
            return .power(host: hostName, flag: words.contains("now") || flags.contains("throttled_now")
                          ? "throttled now" : "throttling")
        }
        if has("disk", "full", "space", "storage", "filesystem") {
            let said = text.firstMatch(of: /(\d{1,3})\s*%/).flatMap { Int($0.1) }
            let mount = text.firstMatch(of: /(?:^|\s)(\/[^\s,:;)]*)/).map { String($0.1) }
            if let pct = said {
                let known = mount ?? host?.disks.first { $0.value == pct }?.key
                return .disk(host: hostName, mount: known, percent: pct)
            }
            if let d = host.flatMap({ Format.worstDisk($0.disks) }), d.percent >= 80 {
                return .disk(host: hostName, mount: d.mount, percent: d.percent)
            }
            return generic
        }
        if has("temp", "hot", "°c", "overheat", "thermal") {
            let said = text.firstMatch(of: /(\d{2,3}(?:\.\d+)?)\s*°/).flatMap { Double($0.1) }
            if let c = said ?? host?.temp { return .hot(host: hostName, celsius: Int(clamping: c)) }
            return generic
        }
        if words.contains("load"), let l = host?.load {
            return .load(host: hostName, load: l, cores: max(host?.cpuCount ?? 1, 1))
        }
        if lower.contains("backup"), has("fail", "error") || Format.backupFailed(host?.backupResult) {
            return .backupFailed(host: hostName)
        }
        if has("unreachable", "offline", "not reachable", "no answer", "not responding", "no ping")
            || words.contains("down") || host?.reachable == false {
            return .hostDown(host: hostName)
        }
        return generic
    }

    /// A warning by the numbers alone (as `HostHealth` sees it) when the server lists none.
    private static func numbersWarning(_ up: [Host]) -> Take.Fact? {
        for h in up {
            if let u = h.containersUp, let t = h.containersTotal, u < t {
                if let c = h.containerList.first(where: { $0.health == .unhealthy })
                    ?? h.containerList.first(where: { $0.state != .running && $0.state != .unknown }) {
                    return .container(host: h.name, name: c.name,
                                      state: c.health == .unhealthy ? "unhealthy" : c.state.rawValue)
                }
                return .problem(host: h.name, text: "\(u) of \(t) containers up")
            }
            if Format.backupFailed(h.backupResult) { return .backupFailed(host: h.name) }
            if let m = h.memPct, m >= 95 { return .problem(host: h.name, text: "memory at \(m)%") }
            if let t = h.temp, t >= Format.hotCelsius { return .hot(host: h.name, celsius: Int(clamping: t)) }
        }
        return nil
    }

    // MARK: Filling

    /// Longest value per placeholder (in characters, "…" included); the tests fill every template with these.
    internal static let hostMax = 14, containerMax = 18, mountMax = 12, titleMax = 24, textMax = 40, firstMax = 22

    /// Every template for a fact kind, for the tests and for anyone adding their own. Placeholders: {host}
    /// {container} {state} {mount} {pct} {temp} {load} {cores} {flag} {text} {todos} {more} {title} {when} {actions}
    /// {first} {machines} {containers} {quiet}. A template is only used when its fact has all of them.
    static func templates(_ kind: Take.Fact.Kind, _ personality: Personality) -> [String] {
        TakeLines.all(kind, personality)
    }

    internal static func eligible(_ fact: Take.Fact, _ personality: Personality) -> [String] {
        let values = fact.values
        return templates(fact.kind, personality).filter { placeholders(in: $0).allSatisfy { values[$0] != nil } }
    }

    /// `card`: half the templates further on, so a problem card never repeats the headline's take on the same fact.
    private static func make(_ fact: Take.Fact, mood: TodayMood.Level, personality: Personality, now: Date,
                             calendar: Calendar, variant: Int, card: Bool = false) -> Take? {
        let options = eligible(fact, personality)
        guard !options.isEmpty else { return nil }
        let n = options.count
        let seed = (UInt64(dayNumber(now, calendar)) &+ stableHash(fact.kind.rawValue + "|" + fact.identity)) % UInt64(n)
        let shift = card && n > 1 ? max(n / 2, 1) : 0
        let index = ((Int(seed) + shift + variant % n) % n + n) % n
        return Take(text: fill(options[index], fact.values), fact: fact, mood: mood)
    }

    /// The template with its placeholders replaced; a sentence that starts with a value starts with a capital.
    internal static func fill(_ template: String, _ values: [String: String]) -> String {
        var out = template
        for (key, value) in values { out = out.replacingOccurrences(of: "{\(key)}", with: value) }
        out = out.replacingOccurrences(of: "….", with: "…").replacingOccurrences(of: "..", with: ".")
        if template.hasPrefix("{text}") || template.hasPrefix("{when}") { out = out.prefix(1).uppercased() + out.dropFirst() }
        return out
    }

    internal static func placeholders(in template: String) -> [String] {
        template.matches(of: /\{([a-z]+)\}/).map { String($0.1) }
    }

    /// "1 to-do", "3 to-dos".
    internal static func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }

    /// At most `max` characters, cut at a space when that keeps most of it, with "…"; a trailing full stop dropped
    /// (the templates add their own).
    internal static func cut(_ s: String, _ max: Int) -> String {
        var s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(".") && !s.hasSuffix("...") { s.removeLast() }
        guard s.count > max else { return s }
        var head = String(s.prefix(max - 1))
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) >= max * 2 / 3 {
            head = String(head[..<space])
        }
        return head.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-")) + "…"
    }

    /// FNV-1a: the same on every launch (Swift's `Hasher` is seeded per process).
    private static func stableHash(_ s: String) -> UInt64 {
        s.utf8.reduce(14_695_981_039_346_656_037 as UInt64) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}

/// The templates. Rules: one line on a 5.4" phone once filled (90 characters with the longest values), the fact's
/// values in every one, no "Ah,", "Well, well", "Oh look", "Let's" or em-dashes. Ultrakill goes all the way on dark
/// humour and politically incorrect takes on institutions and ideas, with only the odd swear word. Never slurs or jokes
/// demeaning protected groups, anything sexual, self-harm, real people or threats against people.
enum TakeLines {
    static func all(_ kind: Take.Fact.Kind, _ p: Personality) -> [String] {
        switch p {
        case .off: []
        case .dry: dry(kind)
        case .snarky: snarky(kind)
        case .ultrakill: ultrakill(kind)
        }
    }

    // MARK: Dry: deadpan, British understatement.

    static func dry(_ kind: Take.Fact.Kind) -> [String] {
        switch kind {
        case .hostDown: [
            "{host} isn't answering. Presumably it has its reasons.",
            "No word from {host}. Rude, but not unheard of.",
            "{host} has gone quiet. Rather more quiet than one would like.",
            "{host} is unreachable. Someone may wish to look into that.",
            "{host} has left the network without saying goodbye.",
        ]
        case .container: [
            "{container} on {host} is {state}. Not ideal.",
            "{container} is {state} on {host}. One for after the coffee.",
            "{host} reports {container} as {state}. Noted, with mild concern.",
            "{container} on {host}: {state}. A restart tends to help.",
            "{host} calls {container} {state}. Accurately, one assumes.",
            "{host} would like it known that {container} is {state}.",
        ]
        case .disk: [
            "{host} is {pct} full. It may be time to let something go.",
            "{mount} on {host} sits at {pct}. Quite full, by most standards.",
            "{host}'s disk is at {pct}. The remaining space is largely theoretical.",
            "{pct} used on {host}. Deleting things remains an option.",
            "{host} at {pct} disk. The usual suspects live in the downloads folder.",
            "{mount} on {host}: {pct}. Not yet a crisis. Getting there.",
        ]
        case .hot: [
            "{host} is running at {temp}. Warm, for a computer.",
            "{host} reads {temp}. One wouldn't want to hold it.",
            "{temp} on {host}. Ventilation might be worth a thought.",
            "{host} at {temp}. Somewhat toastier than recommended.",
        ]
        case .load: [
            "{host} has a load of {load} on {cores}. Rather busy.",
            "Load {load} on {host}, which has {cores}. Something is working hard.",
            "{host} at load {load} on {cores}. Mostly queueing, one suspects.",
            "{host} is asking more of {cores} than they have: load {load}.",
        ]
        case .power: [
            "{host} reports {flag}. The power supply has opinions.",
            "{flag} on {host}. A better cable is rarely a bad idea.",
            "{host}: {flag}. Electricity, but not quite enough of it.",
            "{host} notes {flag}. Not dramatic. Not great.",
        ]
        case .backupFailed: [
            "{host}'s backup failed. Best not to need it today.",
            "The backup on {host} didn't succeed. Worth another go.",
            "{host}: backup failed. Everything is fine until it isn't.",
            "{host} failed its backup. Quietly, which is the worst way.",
        ]
        case .problem: [
            "{text}. Duly noted.",
            "{host} mentions: {text}. Probably worth a look.",
            "{text}. Not the end of the world. Not nothing.",
            "{text}. One for the list.",
            "{host} reports: {text}. Mildly inconvenient.",
            "{text}. It won't fix itself, regrettably.",
        ]
        case .overdue: [
            "{todos} overdue. The oldest is {title}.",
            "{title} is overdue, plus {more}.",
            "{todos} past due. {title} has been waiting longest.",
            "Overdue: {todos}, led by {title}.",
            "{title} and {more} are past due. Gently noted.",
        ]
        case .deadline: [
            "{title} is due {when}. Just so you know.",
            "{when}: {title}. It won't move.",
            "{title}, due {when}. Plan accordingly.",
            "{title} is due {when}. Deadlines rarely reconsider.",
            "A reminder that {title} is due {when}.",
        ]
        case .waiting: [
            "{actions} waiting for a yes or a no.",
            "{actions} awaiting your decision. First up: {first}.",
            "The agent proposes {first}. {actions} waiting in all.",
            "{actions} pending. They're in no hurry. The agent is.",
            "{actions} to approve. Or not. Your call.",
            "{actions} on the desk. Decisions, decisions.",
        ]
        case .parcel: [
            "{title} is out for delivery. Someone should be in.",
            "{title} is on the van today.",
            "{title} arrives today, if the courier agrees.",
            "Out for delivery: {title}. Listen for the door.",
        ]
        case .allFine: [
            "{machines} up, {containers} running. Nothing to report.",
            "{machines} up and answering. Uneventful, in the best way.",
            "{machines} up. {quiet} is barely awake.",
            "{containers} running across {machines}. Remarkably dull.",
            "{machines} up, nothing complaining. Make the most of it.",
            "Everything answers: {machines}, {containers}, no fuss.",
            "{quiet} is the calmest of {machines}. Peaceful.",
            "{machines} up. Nothing is on fire, which is the main thing.",
            "{containers} running, none of them complaining. Unusual.",
            "{machines} up and behaving. One hardly knows what to do.",
        ]
        }
    }

    // MARK: Snarky: sarcastic, mocks the hardware and the owner's choices.

    static func snarky(_ kind: Take.Fact.Kind) -> [String] {
        switch kind {
        case .hostDown: [
            "{host} is offline. Did you unplug it for the vacuum again?",
            "{host} stopped answering. Probably sulking about its SD card.",
            "{host} is down. Turning it off and on again is technically a plan.",
            "{host} has ghosted you. Most things you plug in eventually do.",
            "No ping from {host}. Very minimalist of it.",
        ]
        case .container: [
            "{container} on {host} is {state}. Shocking. You never update it.",
            "{container} is {state} on {host}. Tried compose up and hoping?",
            "{container} on {host}: {state}. Another container, another excuse.",
            "{host} says {container} is {state}. You are the help desk now.",
            "{container} is {state}. {host} insists it wasn't its fault.",
            "{container} on {host} is {state}. All that YAML for this.",
        ]
        case .disk: [
            "{host} is {pct} full. Those Linux ISOs won't delete themselves.",
            "{mount} on {host} hits {pct}. Hoarding is a hobby, apparently.",
            "{host} at {pct} disk. You will not rewatch all of that. Nobody does.",
            "{pct} on {host}. Another drive, or some honesty about your watchlist?",
            "{host} is {pct} full of things you'll get to eventually.",
            "{host} sits at {pct}. A bigger disk only moves the problem, you know.",
            "{mount} on {host}: {pct}. Your data-hoarding era is going great.",
        ]
        case .hot: [
            "{host} hits {temp}. Great for the heating bill, terrible for the hardware.",
            "{temp} on {host}. Stuffing it in a cupboard was a bold choice.",
            "{host} is at {temp}. That heatsink is mostly decorative, isn't it?",
            "{host} at {temp}. A fan costs less than a new board. Just saying.",
            "{temp} on {host}. You could fry an egg on it. Please don't.",
        ]
        case .load: [
            "Load {load} on {cores}. {host} is doing its best, which isn't much.",
            "{host} at load {load} with {cores}. Transcoding 4K on a toaster again?",
            "{host}: load {load}, {cores}. Some container thinks it's a crypto miner.",
            "{host} has load {load} on {cores}. It's trying. Bless.",
            "Load {load} on {host}'s {cores}. Overcommitting is a lifestyle now.",
        ]
        case .power: [
            "{host} reports {flag}. That phone charger was never a real PSU.",
            "{flag} on {host}. Running on vibes and a dodgy cable.",
            "{host}: {flag}. Cheap PSU. The cheap PSU remembers.",
            "{host} reports {flag}. Powered by a USB port and optimism.",
            "{flag} on {host}. Ten euros saved on the PSU, money well spent.",
        ]
        case .backupFailed: [
            "{host}'s backup failed. RAID is not a backup, as you'll recall.",
            "Backup failed on {host}. Living dangerously, are we?",
            "{host}'s backup failed. Feeling lucky?",
            "{host}: backup failed. Schrödinger's data, now with fewer copies.",
        ]
        case .problem: [
            "{text}. Didn't see it coming? Everyone else did.",
            "{host} says: {text}. Self-hosting is so freeing.",
            "{text}. Just as the docs predicted, had you read them.",
            "{text}. Cheaper than the cloud, they said.",
            "{host} has a complaint: {text}.",
            "{text}. Another weekend project, then.",
        ]
        case .overdue: [
            "{todos} overdue. {title} has been patient. Unlike me.",
            "{title} is overdue, plus {more}. Procrastination: going great.",
            "{todos} overdue, oldest {title}. Future you will be furious.",
            "{title} is overdue, and {more} with it. The lab is fine. You are not.",
            "Overdue: {todos}. {title} is a lifestyle now, not a task.",
        ]
        case .deadline: [
            "{title} is due {when}. Leaving it this late was a choice.",
            "{title}: due {when}. The servers can wait. This can't.",
            "{when}: {title}. Better start pretending you've started.",
            "{title} due {when}. Panic is a valid workflow, I suppose.",
            "{title} is due {when}. Homelab tinkering doesn't count as progress.",
        ]
        case .waiting: [
            "{actions} waiting. The agent did the thinking; you just press a button.",
            "{actions} pending. It won't approve itself. Believe me, it tried.",
            "{actions} waiting, starting with {first}. Go on, live a little.",
            "{actions} waiting on you. Bottleneck spotted, and it's you.",
            "{actions} queued. The robot is ready. The human is scrolling.",
            "{actions} to approve. Automation, with extra steps.",
        ]
        case .parcel: [
            "{title} is out for delivery. Another thing to plug in and never document.",
            "{title} lands today. Don't tell anyone how much it cost.",
            "{title} is out for delivery. Clear a shelf. Or a desk. Or the floor.",
            "Out for delivery: {title}. The courier will definitely ring. Definitely.",
        ]
        case .allFine: [
            "{machines} up, {containers} running. Suspicious. What are they planning?",
            "{machines} up and nothing's broken. Don't touch anything.",
            "{containers} running and not one is crying. Enjoy it while it lasts.",
            "{quiet} is idling. {machines} up, and they mostly nap.",
            "{machines} up. Go outside. The lab will cope for an hour.",
            "{machines} up, zero drama. You must have stopped tinkering.",
            "{containers} on {machines} and it all works. Write down what you did.",
            "{machines} up, burning watts to save you a streaming subscription.",
            "{containers} running. Every single one essential, I'm sure.",
            "{quiet} is coasting. {machines} up, zero ambition between them.",
        ]
        }
    }

    // MARK: Ultrakill: CARROT's far end. Gallows humour, bleak cynicism, politically incorrect takes on institutions,
    // ideas and the owner's life choices; swearing only now and then. Never: slurs, jokes demeaning people for who
    // they are (ethnicity, nationality, religion, gender, sexuality, disability), anything sexual, self-harm, real
    // people, threats against people.

    static func ultrakill(_ kind: Take.Fact.Kind) -> [String] {
        switch kind {
        case .hostDown: [
            "{host} is dead. Time of death: now. Cause: you.",
            "{host} stopped answering. Obituary: it tried, which is more than you did.",
            "{host} is gone. Entropy wins again. It always does, champ.",
            "{host} is down. Give it a burial at sea. The Danube takes all.",
            "{host} went dark. Faster than the Magistrat ever answered anything.",
            "{host} is unreachable. Even your ISP has better uptime. Low bar.",
            "{host} is offline. Somewhere a tech billionaire felt nothing.",
            "{host} is down, like every startup's promises. Go poke it.",
        ]
        case .container: [
            "{container} on {host} is {state}. Draft the obituary. Keep it short.",
            "{container} is {state} on {host}. Docker was a mistake. Exhibit A.",
            "{container} on {host}: {state}. Mercy-kill it. It's what it'd want.",
            "{host} reports {container} {state}. Dead at birth, like most startups.",
            "{container} is {state} on {host}. In lieu of flowers, restart it.",
            "{container} on {host} is {state}. Its last words were YAML.",
            "{container} is {state} on {host}. HR calls it 'a growth opportunity'.",
            "{container} on {host}: {state}. Open source: free, like a puppy.",
        ]
        case .disk: [
            "{host} is {pct} full of 'Linux ISOs'. The copyright lobby sends regards.",
            "{mount} on {host} at {pct}. Hoarding: the one hobby they can't tax.",
            "{pct} on {host}. You'll be dead before you watch half of that.",
            "{host} at {pct} disk. Entropy only goes one way. So does your hoarding.",
            "{host} is {pct} full. Write a will. Decide who inherits the ISOs.",
            "{mount} on {host}: {pct}. Streaming exists. Your pride doesn't allow it.",
            "{pct} used on {host}. Delete something, or let the disk choose. It will.",
            "{host} at {pct}. Purists buy disks forever rather than pay 10 euros.",
        ]
        case .hot: [
            "{host} is at {temp}. Climate change, but make it a cupboard.",
            "{temp} on {host}. Self-cremation saves on funeral costs, at least.",
            "{host} hits {temp}. The electricity company thanks you for your service.",
            "{host} at {temp}. No amount of 'sustainability' marketing saves this one.",
            "{temp} on {host}. Heat death of the universe, early access edition.",
            "{host} is at {temp}. Point a fan at it, or let the Danube cool it for good.",
        ]
        case .load: [
            "{host} at load {load} on {cores}. Works harder than any LinkedIn hustler.",
            "Load {load} on {cores}. {host} is being worked like a startup intern.",
            "{host}: load {load}, {cores}. Productivity culture claims another victim.",
            "{host} has load {load} on {cores}. Mercy-kill whatever's running.",
            "Load {load} on {host} ({cores}). A crypto bro would call this mining.",
            "{host}: load {load} on {cores}. Exploited labour, but it's silicon. Fine.",
        ]
        case .power: [
            "{host} reports {flag}. The power company gets paid. It doesn't.",
            "{flag} on {host}. Starved by a landlord-grade power supply.",
            "{host}: {flag}. Pis are toys, and you feed it like one.",
            "{host}: {flag}. Cheap PSU, cheap results, cheap owner.",
            "{host}: {flag}. Running on austerity. Brussels would approve.",
            "{flag} on {host}. Feed it properly or give it a mercy kill.",
        ]
        case .backupFailed: [
            "{host}'s backup failed. Every memory you own, one bad sector from oblivion.",
            "Backup failed on {host}. RAID isn't a backup. Neither is faith.",
            "{host}: backup failed. Nothing lasts. You just found out early.",
            "{host} botched its backup. Self-hosting your own data loss. Very sovereign.",
            "{host}'s backup failed. Even the tax office keeps better records than you.",
            "{host}'s backup failed. Start the eulogy for your photo library.",
        ]
        case .problem: [
            "{text}. Shit's broken. Fix it before it spreads.",
            "{host}: {text}. Another empire falls.",
            "{text}. Works on your machine? This isn't your machine.",
            "{text}. Self-hosting is a cope, and here's the receipt.",
            "{host}: {text}. That's on you, champ.",
            "{text}. Fix it, bury it, or give it to the Danube.",
            "{text}. Big Tech breaks too, but with a status page.",
        ]
        case .overdue: [
            "{todos} overdue. {title}. Still. The heat death will get there first.",
            "{title} is overdue, plus {more}. Your servers outwork you.",
            "{todos} overdue, oldest {title}. Hustle culture lied. Do it anyway.",
            "Overdue: {todos}. Do {title}, you lazy sod, or admit defeat.",
            "{title} is overdue, plus {more}. Run like a government project.",
            "Overdue: {todos}. {title} will make your obituary at this rate.",
        ]
        case .deadline: [
            "{title} is due {when}. Austrian bureaucracy moves faster than you.",
            "{when}: {title}. Death and deadlines. The taxman handles the rest.",
            "{title}, due {when}. Do it now or it haunts you from beyond.",
            "{title} is due {when}. The Magistrat won't take your excuses either.",
            "{title} due {when}. Panic now. It's cheaper than panicking later.",
            "{title} is due {when}. Tabs, spaces, who cares. Just bloody do it.",
        ]
        case .waiting: [
            "{actions} waiting. Faster than the Magistrat is a low bar. Clear it.",
            "{actions} pending. The bot did the work. Late-stage capitalism, at home.",
            "{actions} waiting, first up: {first}. Decide before entropy does.",
            "{actions} waiting on you. The slowest component in this homelab is you.",
            "{actions} to approve. The AI hype was real. Your reaction time isn't.",
            "{actions} pending. Approve them. Nobody's watching, it's not LinkedIn.",
            "{actions} waiting. Even the EU passes regulations faster than this.",
        ]
        case .parcel: [
            "{title} is out for delivery. Consumerism: the ideology with tracking.",
            "{title} arrives today. Your bank account has requested a funeral.",
            "Out for delivery: {title}. Stay home. You weren't going out anyway.",
            "{title} is on the van. Miss the doorbell: pickup-point purgatory.",
            "{title} comes today. Hide it from whoever pays the electricity bill.",
            "{title} arrives today. Another thing to outlive you in a drawer.",
        ]
        case .allFine: [
            "{machines} up, {containers} running. Nothing lasts. Enjoy it anyway.",
            "{machines} up and quiet. Shocking, given who set them up.",
            "{containers} running fine. Pure dumb luck, frankly.",
            "{machines} up. {quiet} is doing nothing, just like its owner.",
            "{machines} up. Everything works, which is how the horror films start.",
            "All quiet on {machines}. 'Touch grass', they say. Grass has no uptime.",
            "{containers} running for an audience of one. Worth every watt, surely.",
            "{machines} up, nothing on fire. Entropy is merely pacing itself.",
            "{containers} running to dodge a 10-euro subscription. Big brain move.",
            "{machines} up. Your lab has more uptime than your social life.",
            "{machines} up. The electricity company sends its warmest regards.",
        ]
        }
    }
}
