import Foundation

// Hyperdetail (owner decision 2026-11-08, docs/DESIGN.md "Hyperdetail"): the fourth detail level after Overkill.
// Everything, everywhere, unfolded: no list is folded, every field the server sent is shown (ids, units, states,
// `updated`, tags, thresholds, host numbers with their whole history), and with a personality on, a remark sits next
// to each fact. The UX is allowed to suffer. With the personality Off only the extra details show.
//
// The decisions are here, pure and tested on Linux: which lines a subject gets (`host`, `item`, `deal`, ...) and which
// remark belongs to which fact (`Fact`, `remark`). The views (HyperdetailViews.swift) only draw the result.

/// One shown field: "mem_pct" and "41". Rendered as a quiet monospaced row, wrapping, never truncated.
public struct HyperLine: Equatable, Sendable, Identifiable {
    public var label: String
    public var value: String
    public var id: String { label + "\u{1F}" + value }
    public init(_ label: String, _ value: String) { self.label = label; self.value = value }
}

public enum Hyper {
    // MARK: Remarks

    /// What a remark is about. Each kind has its own lines per personality (HyperLines.swift).
    public enum Kind: String, CaseIterable, Sendable {
        case hostUp, hostDown, hostFull, hostHot, hostBusy
        case approval, todo, deadline, departure
        case deal, download, grade, news
        case homeTile, chatReply, list, server, action, row

        /// Placeholders every fact of this kind fills.
        public var required: Set<String> {
            switch self {
            case .hostUp, .hostDown: ["host"]
            case .hostFull: ["host", "pct"]
            case .hostHot: ["host", "temp"]
            case .hostBusy: ["host", "load", "cores"]
            case .approval, .deal, .download, .news, .action, .row: ["title"]
            case .todo: ["title", "status"]
            case .deadline: ["title", "when"]
            case .departure: ["towards", "when"]
            case .grade: ["subject", "value"]
            case .homeTile: ["name", "state"]
            case .chatReply: ["words"]
            case .list: ["count", "title"]
            case .server: ["name"]
            }
        }

        /// Placeholders a fact fills when it knows them; a line that needs one it lacks is not used.
        public var optional: Set<String> {
            switch self {
            case .hostUp: ["containers", "checked"]
            case .hostDown: ["checked"]
            case .hostFull: ["mount"]
            case .approval: ["age"]
            case .departure: ["line"]
            case .deal: ["price", "off"]
            case .download: ["progress"]
            case .chatReply: ["age"]
            case .server: ["age"]
            case .action: ["fields"]
            case .row: ["value"]
            default: []
            }
        }

        public var placeholders: Set<String> { required.union(optional) }
    }

    /// The longest a filled remark may be. Hyperdetail wraps, so two short lines at most.
    public static let maxLength = 90

    /// The longest each placeholder's value can get (longer values are cut with an ellipsis).
    public static let caps: [String: Int] = [
        "host": 14, "title": 24, "name": 20, "towards": 20, "line": 12, "subject": 14, "value": 12, "state": 16,
        "status": 8, "mount": 12, "containers": 14, "checked": 14, "age": 14, "words": 12, "count": 12, "progress": 5,
        "off": 5, "price": 10, "when": 16, "pct": 5, "temp": 7, "load": 6, "cores": 10, "fields": 10,
    ]

    /// A fact a remark can be about: the kind, its values (true ones, cut to `caps`) and a seed that tells two facts of
    /// one kind apart (a row's title, a host's id), so they do not all get the same line.
    public struct Fact: Hashable, Sendable {
        public var kind: Kind
        public var values: [String: String]
        public var seed: String

        public init(_ kind: Kind, _ values: [String: String], seed: String = "") {
            self.kind = kind
            var cutValues: [String: String] = [:]
            for (key, value) in values where kind.placeholders.contains(key) {
                let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { cutValues[key] = Voice.cut(v, Hyper.caps[key] ?? 24) }
            }
            self.values = cutValues
            self.seed = seed.isEmpty ? (cutValues["title"] ?? cutValues["host"] ?? cutValues["name"] ?? "") : seed
        }

        /// Every required placeholder is there (a fact without a title says nothing).
        public var isComplete: Bool { kind.required.allSatisfy { values[$0] != nil } }
    }

    /// The lines of a kind that this fact can fill.
    static func eligible(_ fact: Fact, _ personality: Personality) -> [String] {
        HyperLines.all(fact.kind, personality).filter { Voice.placeholders(in: $0).allSatisfy { fact.values[$0] != nil } }
    }

    /// Every line of a kind, placeholders unfilled (for the tests).
    public static func lines(_ kind: Kind, _ personality: Personality) -> [String] { HyperLines.all(kind, personality) }

    /// The remark for a fact, nil when the personality is Off or the fact is incomplete. Fixed for the day (and the
    /// fact's seed); `variant` moves on to the next line.
    public static func remark(_ fact: Fact?, _ personality: Personality, now: Date = Date(),
                              calendar: Calendar = .current, variant: Int = 0) -> String? {
        guard personality != .off, let fact, fact.isComplete else { return nil }
        let options = eligible(fact, personality)
        guard !options.isEmpty else { return nil }
        let n = options.count
        let base = (UInt64(Voice.dayNumber(now, calendar)) &+ Voice.stableHash(fact.kind.rawValue + "|" + fact.seed)) % UInt64(n)
        let index = ((Int(base) + variant % n) % n + n) % n
        return fill(options[index], fact.values)
    }

    /// `Voice.fill` and a capital first letter (a value may start a sentence: "done: Renew the lock").
    static func fill(_ template: String, _ values: [String: String]) -> String {
        let out = Voice.fill(template, values)
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    // MARK: Times and numbers

    /// "2026-11-08 14:03:07 +01:00 (2 min ago)": the exact time with its offset, and the age.
    public static func stamp(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "never" }
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = calendar.timeZone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let zone = String(format: "%@%02d:%02d", sign, abs(offset) / 3600, abs(offset) % 3600 / 60)
        let clock = String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                           c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return "\(clock) \(zone) (\(Format.age(date, now: now)))"
    }

    /// A number as the server sent it: 3 not 3.0, 0.52 not 0.520000.
    public static func raw(_ value: Double) -> String {
        guard value.isFinite else { return "\(value)" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        return "\(value)"
    }

    private static func series(_ values: [Double?]) -> String {
        values.map { $0.map(raw) ?? "·" }.joined(separator: " ")
    }

    // MARK: Hosts

    /// Every field of a host, with all its history numbers.
    public static func host(_ h: Host, now: Date = Date(), calendar: Calendar = .current) -> [HyperLine] {
        var out: [HyperLine] = [HyperLine("id", h.id), HyperLine("name", h.name)]
        if let kind = h.kind { out.append(HyperLine("kind", kind)) }
        out.append(HyperLine("reachable", h.reachable.map { $0 ? "true" : "false" } ?? "unknown"))
        out.append(HyperLine("checked", stamp(h.checked, now: now, calendar: calendar)))
        if let load = h.load {
            var v = raw(load)
            if let cores = h.cpuCount { v += " on \(cores) cores, \(raw((load / Double(cores) * 1000).rounded() / 1000)) per core" }
            out.append(HyperLine("load", v))
        }
        if let cores = h.cpuCount, h.load == nil { out.append(HyperLine("cpu_count", String(cores))) }
        if let mem = h.memPct { out.append(HyperLine("mem_pct", "\(mem)")) }
        if let temp = h.temp { out.append(HyperLine("temp", "\(raw(temp)) °C (warning from \(raw(Format.hotCelsius)))")) }
        for (mount, pct) in h.disks.sorted(by: { $0.key < $1.key }) { out.append(HyperLine("disk \(mount)", "\(pct)")) }
        if h.containersUp != nil || h.containersTotal != nil {
            out.append(HyperLine("containers", "up \(h.containersUp.map(String.init) ?? "?") of \(h.containersTotal.map(String.init) ?? "?")"))
        }
        for c in h.containerList {
            let parts = [c.state.rawValue, c.health?.rawValue, c.restarts.map { "restarts \($0)" },
                         c.restartable ? "restartable" : nil].compactMap { $0 }
            out.append(HyperLine("container \(c.name)", parts.joined(separator: " · ")))
        }
        if let n = h.upgradable { out.append(HyperLine("upgradable", String(n))) }
        if let r = h.rebootRequired { out.append(HyperLine("reboot_required", r ? "true" : "false")) }
        if let b = h.backupLast { out.append(HyperLine("backup last", b)) }
        if let b = h.backupResult { out.append(HyperLine("backup result", b)) }
        if !h.flags.isEmpty { out.append(HyperLine("flags", h.flags.joined(separator: ", "))) }
        if let url = h.url { out.append(HyperLine("url", url.absoluteString)) }
        if let history = h.history { out += self.history(history, now: now, calendar: calendar) }
        return out
    }

    /// The history of a host: step, end and for each series the count, min, max, last and every number.
    public static func history(_ h: HostHistory, now: Date = Date(), calendar: Calendar = .current) -> [HyperLine] {
        var out = [HyperLine("history step", "\(h.step) s"), HyperLine("history end", stamp(h.end, now: now, calendar: calendar))]
        for s in HostHistory.Series.allCases {
            let values = h[s]
            guard values.contains(where: { $0 != nil }) else { continue }
            let present = values.compactMap { $0 }
            var summary = "\(present.count) of \(values.count) points"
            if let lo = h.min(s), let hi = h.max(s) { summary += " · min \(raw(lo)) · max \(raw(hi))" }
            if let last = h.last(s) { summary += " · last \(raw(last))" }
            out.append(HyperLine("history \(s.rawValue)", summary))
            out.append(HyperLine("history \(s.rawValue) values", series(values)))
        }
        return out
    }

    /// The remark's fact for a host row: down, a full disk, hot, busy, else up. Nil while its reachability is unknown.
    public static func fact(host h: Host, now: Date = Date()) -> Fact? {
        let name = h.name.isEmpty ? h.id : h.name
        let checked = h.checked.map { Format.age($0, now: now) }
        if h.reachable == false { return Fact(.hostDown, ["host": name, "checked": checked ?? ""], seed: h.id) }
        guard h.reachable == true else { return nil }
        if let worst = Format.worstDisk(h.disks), worst.percent >= 85 {
            return Fact(.hostFull, ["host": name, "pct": "\(worst.percent)%", "mount": worst.mount], seed: h.id)
        }
        if let temp = h.temp, temp >= 70 { return Fact(.hostHot, ["host": name, "temp": Format.temperature(temp)], seed: h.id) }
        if let load = h.load, let cores = h.cpuCount, load > Double(cores) {
            return Fact(.hostBusy, ["host": name, "load": Format.load(load), "cores": Voice.count(cores, "core")], seed: h.id)
        }
        var values = ["host": name, "checked": checked ?? ""]
        if let up = h.containersUp, up > 0, up == h.containersTotal { values["containers"] = Voice.count(up, "container") }
        return Fact(.hostUp, values, seed: h.id)
    }

    // MARK: Problems, approvals

    public static func problem(_ p: Problem, now: Date = Date(), calendar: Calendar = .current) -> [HyperLine] {
        var out = [HyperLine("id", p.id), HyperLine("severity", p.severity.rawValue)]
        if let host = p.host { out.append(HyperLine("host", host)) }
        out.append(HyperLine("since", p.since.map { stamp($0, now: now, calendar: calendar) } ?? "not given"))
        return out
    }

    public static func pending(_ p: PendingAction, now: Date = Date(), calendar: Calendar = .current) -> [HyperLine] {
        var out = [HyperLine("id", p.id)]
        if let job = p.job { out.append(HyperLine("job", job)) }
        if let a = p.action { out.append(HyperLine("action", a)) }
        if let a = p.arg { out.append(HyperLine("arg", a)) }
        if let r = p.reason { out.append(HyperLine("reason", r)) }
        out.append(HyperLine("created", stamp(p.created, now: now, calendar: calendar)))
        for verb in PendingAction.Verb.allCases { if let label = p.buttons[verb] { out.append(HyperLine("button \(verb.rawValue)", label)) } }
        return out
    }

    public static func fact(pending p: PendingAction, now: Date = Date()) -> Fact {
        Fact(.approval, ["title": p.title, "age": p.created.map { Format.age($0, now: now) } ?? ""], seed: p.id)
    }

    // MARK: Cards and rows

    public static func card(_ c: Card, now: Date = Date(), calendar: Calendar = .current) -> [HyperLine] {
        var out = [HyperLine("id", c.id), HyperLine("style", c.style.rawValue), HyperLine("place", c.place.rawValue)]
        if let icon = c.icon { out.append(HyperLine("icon", icon)) }
        out.append(HyperLine("tint", c.tint.rawValue))
        if let u = c.updated { out.append(HyperLine("updated", u)) }
        if let d = c.date { out.append(HyperLine("date", d)) }
        out.append(HyperLine("items", String(c.items.count)))
        if let t = c.text { out.append(HyperLine("text", "\(t.count) characters")) }
        if let a = c.action { out.append(HyperLine("action", action(a))) }
        return out
    }

    static func action(_ a: ItemAction) -> String {
        var v = a.name
        if !a.arg.isEmpty { v += " arg=\(a.arg)" }
        if let l = a.label { v += " label=\(l)" }
        for (key, value) in a.payload.sorted(by: { $0.key < $1.key }) { v += " \(key)=\(value)" }
        return v
    }

    public static func item(_ i: Card.Item, now: Date = Date(), calendar: Calendar = .current) -> [HyperLine] {
        var out: [HyperLine] = []
        if let v = i.title { out.append(HyperLine("title", v)) }
        if let v = i.subtitle { out.append(HyperLine("subtitle", v)) }
        if let v = i.value { out.append(HyperLine("value", v)) }
        if let v = i.progress { out.append(HyperLine("progress", raw(v))) }
        if let v = i.icon { out.append(HyperLine("icon", v)) }
        if let v = i.tint { out.append(HyperLine("tint", v.rawValue)) }
        if let v = i.url { out.append(HyperLine("url", v.absoluteString)) }
        if let v = i.done { out.append(HyperLine("done", v ? "true" : "false")) }
        if let v = i.due {
            out.append(HyperLine(i.dueIsDay ? "due (day)" : "due", i.dueIsDay ? Format.dayString(v, calendar: calendar)
                                 + " (\(i.dueText(now: now, calendar: calendar) ?? ""))" : stamp(v, now: now, calendar: calendar)))
        }
        if let v = i.action { out.append(HyperLine("action", action(v))) }
        if let v = i.cancelled { out.append(HyperLine("cancelled", v ? "true" : "false")) }
        if let v = i.image { out.append(HyperLine("image", v)) }
        return out
    }

    /// The remark's fact for a row of a card, by the card's kind. Nil when the row has no title to talk about.
    public static func fact(item i: Card.Item, in card: Card, now: Date = Date(), calendar: Calendar = .current) -> Fact? {
        let title = i.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sub = i.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch TodayFold.tileKind(card) {
        case .downloads?:
            guard !title.isEmpty else { return nil }
            return Fact(.download, ["title": title, "progress": i.progress.map { "\(Format.ringPercent($0))%" } ?? ""], seed: title)
        case .grades?:
            let subject = sub.isEmpty ? title : sub
            guard !subject.isEmpty, let value = i.value else { return nil }
            return Fact(.grade, ["subject": subject, "value": value], seed: subject + value)
        case .news?:
            return title.isEmpty ? nil : Fact(.news, ["title": title], seed: title)
        default: break
        }
        if card.style == .departures {
            guard !title.isEmpty, let value = i.value else { return nil }
            return Fact(.departure, ["towards": title, "when": value, "line": card.title ?? ""], seed: title + value)
        }
        guard !title.isEmpty else { return nil }
        switch card.style {
        case .countdown:
            guard let due = i.due else { return nil }
            return Fact(.deadline, ["title": title, "when": Format.due(due, dayOnly: i.dueIsDay, now: now, calendar: calendar)], seed: title)
        case .checklist:
            let status: String
            if i.done == true { status = "done" }
            else if let due = i.due, (i.dueIsDay ? Format.dueDay(due, calendar: calendar) < calendar.startOfDay(for: now) : due < now) { status = "overdue" }
            else { status = "open" }
            return Fact(.todo, ["title": title, "status": status], seed: title)
        default:
            return Fact(.row, ["title": title, "value": i.value ?? ""], seed: title)
        }
    }

    /// The fact for a whole list: how many rows are open, in which card.
    public static func fact(card c: Card) -> Fact? {
        guard !c.items.isEmpty else { return nil }
        let title = (c.title ?? c.id)
        return Fact(.list, ["count": Voice.count(c.items.count, "row"), "title": title], seed: c.id)
    }

    // MARK: Deals

    public static func deal(_ d: Deal, now: Date = Date(), calendar: Calendar = .current) -> [HyperLine] {
        var out = [HyperLine("id", String(d.id))]
        if let v = d.watch { out.append(HyperLine("watch", v)) }
        if let v = d.kind { out.append(HyperLine("kind", v)) }
        if let v = d.price { out.append(HyperLine("price", raw(v))) }
        if let v = d.value { out.append(HyperLine("value", raw(v))) }
        if let v = d.discount { out.append(HyperLine("discount", raw(v))) }
        if let v = d.share { out.append(HyperLine("share", raw(v))) }
        if let v = d.confidence { out.append(HyperLine("confidence", v.rawValue)) }
        if let v = d.verdict { out.append(HyperLine("verdict", v.rawValue)) }
        if let v = d.specs { out.append(HyperLine("specs", v)) }
        if let v = d.location { out.append(HyperLine("location", v)) }
        if let v = d.state { out.append(HyperLine("state", v)) }
        out.append(HyperLine("near", d.near ? "true" : "false"))
        if let v = d.isPrivate { out.append(HyperLine("private", v ? "true" : "false")) }
        if let v = d.ships { out.append(HyperLine("ships", v ? "true" : "false")) }
        if let v = d.condition { out.append(HyperLine("condition", v)) }
        if let v = d.url { out.append(HyperLine("url", v.absoluteString)) }
        if !d.flags.isEmpty { out.append(HyperLine("flags", d.flags.joined(separator: ", "))) }
        out.append(HyperLine("seen", stamp(d.seen, now: now, calendar: calendar)))
        for c in d.comps {
            out.append(HyperLine("comp", [c.title, c.price.map(raw), c.url?.absoluteString].compactMap { $0 }.joined(separator: " · ")))
        }
        return out
    }

    public static func fact(deal d: Deal) -> Fact {
        let off = d.share.flatMap { $0 > 0 ? "\(Int(($0 * 100).rounded()))%" : nil }
        return Fact(.deal, ["title": d.title, "price": d.price.map { DealFormat.price($0).replacingOccurrences(of: "\u{00A0}", with: " ") } ?? "",
                            "off": off ?? ""], seed: String(d.id))
    }

    // MARK: Chat, actions, Home, server

    public static func message(_ m: ChatMessage, now: Date = Date(), calendar: Calendar = .current) -> [HyperLine] {
        var out = [HyperLine("id", String(m.id)), HyperLine("from", m.from.rawValue),
                   HyperLine("ts", stamp(m.ts, now: now, calendar: calendar))]
        if let v = m.job { out.append(HyperLine("job", v)) }
        if let v = m.status { out.append(HyperLine("status", v)) }
        out.append(HyperLine("size", "\(m.text.count) characters · \(wordCount(m.text)) words · \(m.text.split(separator: "\n", omittingEmptySubsequences: false).count) lines"))
        if !m.pending.isEmpty { out.append(HyperLine("pending", m.pending.map(\.id).joined(separator: ", "))) }
        if !m.cards.isEmpty { out.append(HyperLine("cards", m.cards.map(\.id).joined(separator: ", "))) }
        return out
    }

    static func wordCount(_ text: String) -> Int { text.split { $0.isWhitespace }.count }

    /// The remark for an agent reply's header (a message of mine has none).
    public static func fact(message m: ChatMessage, now: Date = Date()) -> Fact? {
        guard m.from == .agent else { return nil }
        let words = wordCount(m.text)
        guard words > 0 else { return nil }
        return Fact(.chatReply, ["words": Voice.count(words, "word"), "age": m.ts.map { Format.age($0, now: now) } ?? ""], seed: String(m.id))
    }

    public static func action(_ a: ActionSpec) -> [HyperLine] {
        var out = [HyperLine("name", a.name), HyperLine("label", a.label)]
        if let v = a.icon { out.append(HyperLine("icon", v)) }
        if let v = a.hint { out.append(HyperLine("hint", v)) }
        out.append(HyperLine("destructive", a.destructive ? "true" : "false"))
        out.append(HyperLine("start", a.start ? "true" : "false"))
        for v in a.variants { out.append(HyperLine("variant", "\(v)")) }
        for f in a.fields {
            out.append(HyperLine("field \(f.name)", "\(f.kind) · max \(f.max) · \(f.required ? "required" : "optional")"
                                 + (f.hidden ? " · hidden" : "") + (f.options.isEmpty ? "" : " · \(f.options.count) options")))
        }
        return out
    }

    public static func fact(action a: ActionSpec) -> Fact {
        let n = a.fields.filter { !$0.hidden }.count
        return Fact(.action, ["title": a.label, "fields": n > 0 ? Voice.count(n, "field") : ""], seed: a.name)
    }

    public static func report(_ r: ActionReport, now: Date = Date(), calendar: Calendar = .current) -> [HyperLine] {
        [HyperLine("ok", r.ok ? "true" : "false"), HyperLine("title", r.title),
         HyperLine("text", "\(r.text.count) characters"), HyperLine("at", stamp(now, now: now, calendar: calendar))]
    }

    public static func service(_ s: Service) -> [HyperLine] {
        var out = [HyperLine("name", s.name), HyperLine("url", s.url.absoluteString)]
        if let v = s.group { out.append(HyperLine("group", v)) }
        if let v = s.icon { out.append(HyperLine("icon", v)) }
        if let v = s.description { out.append(HyperLine("description", v)) }
        return out
    }

    public static func entity(_ e: HAEntity, now: Date = Date(), calendar: Calendar = .current) -> [HyperLine] {
        var out = [HyperLine("entity_id", e.entityID), HyperLine("domain", e.domain), HyperLine("state", e.state),
                   HyperLine("friendly_name", e.name)]
        if let v = e.unit { out.append(HyperLine("unit", v)) }
        if let v = e.deviceClass { out.append(HyperLine("device_class", v)) }
        if let v = e.icon { out.append(HyperLine("icon", v)) }
        out.append(HyperLine("last_changed", stamp(e.lastChanged, now: now, calendar: calendar)))
        return out
    }

    public static func fact(entity e: HAEntity) -> Fact {
        Fact(.homeTile, ["name": e.name, "state": e.unit.map { Format.withUnit(e.state, $0) } ?? e.state], seed: e.entityID)
    }

    /// Which server answered and how fresh it is: name, software, API version, auth, features, fetch and check times.
    public static func server(name: String, snapshot: Snapshot?, info: ServerInfo?, failures: Int = 0, busy: [String] = [],
                              now: Date = Date(), calendar: Calendar = .current) -> [HyperLine] {
        var out = [HyperLine("server", name)]
        if let n = info?.name { out.append(HyperLine("name", n)) }
        if let n = info?.server { out.append(HyperLine("software", n)) }
        if let n = info?.version { out.append(HyperLine("version", n)) }
        if let n = info?.api { out.append(HyperLine("api", String(n))) }
        if let n = info?.auth { out.append(HyperLine("auth", n)) }
        if let f = info?.features { out.append(HyperLine("features", f.map(\.rawValue).sorted().joined(separator: ", "))) }
        if let c = info?.commands, !c.isEmpty { out.append(HyperLine("commands", c.joined(separator: " "))) }
        if let s = snapshot {
            out.append(HyperLine("fetched", stamp(s.fetched, now: now, calendar: calendar)))
            out.append(HyperLine("checked", stamp(s.state.checked, now: now, calendar: calendar)))
            out.append(HyperLine("state time", stamp(s.state.time, now: now, calendar: calendar)))
            out.append(HyperLine("stale", s.isStale(now: now) ? "yes" : "no"))
            out.append(HyperLine("status", s.state.status.rawValue))
            out.append(HyperLine("counts", "\(s.state.hosts.count) hosts · \(s.state.problems.count) problems · \(s.state.pending.count) pending · \(s.state.cards.count) cards"))
        }
        out.append(HyperLine("failures in a row", String(failures)))
        if !busy.isEmpty { out.append(HyperLine("busy", busy.joined(separator: ", "))) }
        out.append(HyperLine("latency", "not measured"))
        return out
    }

    public static func fact(server name: String, snapshot: Snapshot?, now: Date = Date()) -> Fact {
        Fact(.server, ["name": name, "age": snapshot.map { Format.age($0.fetched, now: now) } ?? ""], seed: name)
    }

    /// The stored settings as the file holds them, key by key (what is unset is not there).
    public static func settings(_ s: AppSettings) -> [HyperLine] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(s),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object.keys.sorted().map { key in
            let value = object[key]!
            let text = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\(value)"
            return HyperLine(key, text)
        }
    }

    /// A saved server as the app holds it (never its token): id, kind, address, auth, pinned Home entities.
    public static func serverConfig(_ c: ServerConfig, selected: Bool = false) -> [HyperLine] {
        var out = [HyperLine("id", c.id.uuidString), HyperLine("name", c.name), HyperLine("kind", c.kind.rawValue),
                   HyperLine("url", c.baseURL.absoluteString), HyperLine("auth", c.auth.rawValue)]
        if selected { out.append(HyperLine("selected", "true")) }
        if !c.pinnedEntities.isEmpty { out.append(HyperLine("pinned", c.pinnedEntities.joined(separator: ", "))) }
        return out
    }

    // MARK: Notifications

    /// What a notification gets on top in Hyperdetail: the fields of what it is about, and with a personality the
    /// remark for it. Nil for a summary.
    public static func noticeExtra(_ alert: AlertTracker.Alert, state: HomelabState?, deals: DealList?,
                                   personality: Personality, now: Date = Date(), calendar: Calendar = .current) -> String? {
        var parts: [String] = []
        var fact: Fact?
        switch alert.kind {
        case .problem:
            if let p = state?.problems.first(where: { "problem-\($0.id)" == alert.id }) {
                parts = problem(p, now: now, calendar: calendar).map { "\($0.label): \($0.value)" }
            }
        case .pending:
            if let p = alert.proposal ?? state?.pending.first(where: { "pending-\($0.id)" == alert.id }) {
                parts = pending(p, now: now, calendar: calendar).map { "\($0.label): \($0.value)" }
                fact = self.fact(pending: p, now: now)
            }
        case .deal:
            if let d = deals?.deals.first(where: { "deal-\($0.id)" == alert.id }) {
                parts = deal(d, now: now, calendar: calendar).filter { ["id", "price", "discount", "verdict", "seen", "confidence"].contains($0.label) }
                    .map { "\($0.label): \($0.value)" }
                fact = self.fact(deal: d)
            }
        case .summary: return nil
        }
        let remark = remark(fact, personality, now: now, calendar: calendar)
        let text = ([parts.joined(separator: " · ")] + [remark].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}

public extension ActionReport {
    /// In Hyperdetail the result also lists its fields (ok, title, size of the text, the exact time) after the text
    /// and the remark. Unchanged outside it (`hyper` nil).
    func hyperdetailed(_ hyper: HyperContext?) -> ActionReport {
        guard let hyper else { return self }
        var report = self
        let fields = Hyper.report(self, now: hyper.now, calendar: hyper.calendar).map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        report.text = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fields : text + "\n\n" + fields
        return report
    }
}

/// What the views need in Hyperdetail: the personality and the clock. Nil outside Hyperdetail, so every other level
/// draws exactly what it drew before (`AppModel.hyper`).
public struct HyperContext: Sendable {
    public var personality: Personality
    public var now: Date
    public var calendar: Calendar

    public init(personality: Personality, now: Date = Date(), calendar: Calendar = .current) {
        self.personality = personality; self.now = now; self.calendar = calendar
    }

    /// The remark for `fact`; nil while the personality is Off (then only the details show).
    public func remark(_ fact: Hyper.Fact?, variant: Int = 0) -> String? {
        Hyper.remark(fact, personality, now: now, calendar: calendar, variant: variant)
    }
}

public extension AppModel {
    /// Hyperdetail's context, nil at every other detail level.
    var hyper: HyperContext? {
        settings.todayDensity.isHyper ? HyperContext(personality: settings.voice) : nil
    }
}
