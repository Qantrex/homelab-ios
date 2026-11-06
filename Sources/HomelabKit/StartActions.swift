import Foundation

// Actions the owner starts from the app (feature `run-actions`): GET /api/v1/actions lists them with what their
// form needs, POST /api/v1/actions/<name> with {arg, payload} runs one at once. The server checks everything again;
// the form only keeps obviously wrong input from being sent.

/// One action the app may start, and how to build its form.
public struct ActionSpec: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var name: String
    public var label: String
    /// SF Symbol name, if the server sent one the app can use.
    public var icon: String?
    public var hint: String?
    /// Asks with a red confirm button (restarting a container).
    public var destructive: Bool
    /// Ways to build the argument; the form offers a picker when there is more than one. Empty = no argument.
    public var variants: [ArgVariant]
    public var fields: [Field]

    public var id: String { name }

    public init(name: String, label: String? = nil, icon: String? = nil, hint: String? = nil, destructive: Bool = false,
                variants: [ArgVariant] = [], fields: [Field] = []) {
        self.name = name; self.label = label ?? name; self.icon = icon; self.hint = hint
        self.destructive = destructive; self.variants = variants; self.fields = fields
    }

    /// A name the server accepts in the path (`[a-z0-9][a-z0-9_-]*`, at most 64).
    public static func isValidName(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-z0-9][a-z0-9_-]{0,63}/) != nil
    }

    public struct Option: Codable, Sendable, Equatable, Hashable, Identifiable {
        public var value: String
        public var label: String
        public var id: String { value }

        public init(value: String, label: String? = nil) {
            self.value = value; self.label = label ?? value
        }

        enum CodingKeys: String, CodingKey { case value, label }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let value = c.text(.value) else {
                throw DecodingError.keyNotFound(CodingKeys.value, .init(codingPath: c.codingPath, debugDescription: "no value"))
            }
            self.init(value: value, label: c.text(.label))
        }
    }

    /// One way to build the argument, e.g. "Wake me" = {Day}T{Time}, "No wake-up" = {Day}:off.
    public struct ArgVariant: Codable, Sendable, Equatable, Hashable {
        public var label: String
        public var parts: [ArgPart]

        public init(label: String, parts: [ArgPart]) {
            self.label = label; self.parts = parts
        }

        enum CodingKeys: String, CodingKey { case label, parts }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // A part the app doesn't know makes the argument unbuildable: drop the whole variant.
            let raw = c.lenient([Lossy<ArgPart>].self, .parts) ?? []
            let parts = raw.compactMap(\.value)
            guard !parts.isEmpty, parts.count == raw.count else {
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "unknown part"))
            }
            self.init(label: c.text(.label) ?? "", parts: parts)
        }
    }

    public enum ArgPart: Codable, Sendable, Equatable, Hashable {
        case literal(String)
        /// 2026-11-07
        case date(label: String)
        /// 07:30
        case time(label: String)
        case number(label: String)
        /// Letters, digits, `.`, `_`, `-`.
        case word(label: String)
        case choice(label: String, options: [Option])

        public var label: String? {
            switch self {
            case .literal: nil
            case .date(let l), .time(let l), .number(let l), .word(let l), .choice(let l, _): l
            }
        }

        enum CodingKeys: String, CodingKey { case kind, label, text, options }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let label = c.text(.label) ?? ""
            switch c.text(.kind)?.lowercased() {
            case "literal":
                guard let t = c.string(.text), !t.isEmpty else { throw Self.bad(c) }
                self = .literal(t)
            case "date": self = .date(label: label)
            case "time": self = .time(label: label)
            case "number": self = .number(label: label)
            case "word": self = .word(label: label)
            case "choice":
                let options = c.array(Option.self, .options)
                guard !options.isEmpty else { throw Self.bad(c) }
                self = .choice(label: label, options: options)
            default: throw Self.bad(c)
            }
        }

        static func bad(_ c: KeyedDecodingContainer<CodingKeys>) -> DecodingError {
            .dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "unknown or empty part"))
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .literal(let t): try c.encode("literal", forKey: .kind); try c.encode(t, forKey: .text)
            case .date(let l): try c.encode("date", forKey: .kind); try c.encode(l, forKey: .label)
            case .time(let l): try c.encode("time", forKey: .kind); try c.encode(l, forKey: .label)
            case .number(let l): try c.encode("number", forKey: .kind); try c.encode(l, forKey: .label)
            case .word(let l): try c.encode("word", forKey: .kind); try c.encode(l, forKey: .label)
            case .choice(let l, let o):
                try c.encode("choice", forKey: .kind); try c.encode(l, forKey: .label); try c.encode(o, forKey: .options)
            }
        }
    }

    /// One text field of the payload.
    public struct Field: Codable, Sendable, Equatable, Hashable, Identifiable {
        public var name: String
        public var label: String
        public var kind: Kind
        public var max: Int
        public var required: Bool
        public var options: [Option]
        public var placeholder: String?

        public var id: String { name }

        public enum Kind: String, Codable, Sendable, CaseIterable {
            case text, multiline, date, datetime, dateOrDatetime = "date-or-datetime", number, choice
        }

        public init(name: String, label: String? = nil, kind: Kind = .text, max: Int = 200, required: Bool = false,
                    options: [Option] = [], placeholder: String? = nil) {
            self.name = name; self.label = label ?? name
            // A choice without options can only be typed.
            self.kind = kind == .choice && options.isEmpty ? .text : kind
            self.max = Swift.min(Swift.max(max, 1), 20000); self.required = required
            self.options = options; self.placeholder = placeholder
        }

        enum CodingKeys: String, CodingKey { case name, label, kind, max, required, options, placeholder }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let name = c.text(.name) else {
                throw DecodingError.keyNotFound(CodingKeys.name, .init(codingPath: c.codingPath, debugDescription: "no name"))
            }
            self.init(name: name, label: c.text(.label), kind: c.text(.kind).flatMap { Kind(rawValue: $0.lowercased()) } ?? .text,
                      max: c.int(.max) ?? 200, required: c.bool(.required) ?? false,
                      options: c.array(Option.self, .options), placeholder: c.text(.placeholder))
        }
    }

    enum CodingKeys: String, CodingKey { case name, label, icon, hint, destructive, arg, fields }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = c.text(.name), Self.isValidName(name) else {
            throw DecodingError.keyNotFound(CodingKeys.name, .init(codingPath: c.codingPath, debugDescription: "no valid name"))
        }
        let variants = c.array(ArgVariant.self, .arg)
        // It needs an argument, but none of its forms can be built: the app can't start it.
        if c.contains(.arg), (c.lenient([Lossy<ArgVariant>].self, .arg)?.isEmpty == false), variants.isEmpty {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "no usable argument form"))
        }
        var seen = Set<String>()
        let fields = c.array(Field.self, .fields).filter { seen.insert($0.name).inserted }
        self.init(name: name, label: c.text(.label), icon: c.text(.icon), hint: c.text(.hint),
                  destructive: c.bool(.destructive) ?? false, variants: variants, fields: fields)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(hint, forKey: .hint)
        if destructive { try c.encode(true, forKey: .destructive) }
        if !variants.isEmpty { try c.encode(variants, forKey: .arg) }
        try c.encode(fields, forKey: .fields)
    }
}

struct ActionList: Decodable {
    var actions: [ActionSpec]
    enum CodingKeys: String, CodingKey { case actions }
    init(from decoder: any Decoder) throws {
        var seen = Set<String>()
        actions = try decoder.container(keyedBy: CodingKeys.self).array(ActionSpec.self, .actions)
            .filter { seen.insert($0.name).inserted }
    }
}

/// The server's answer to starting an action.
public struct ActionResult: Codable, Sendable, Equatable {
    /// The action finished without an error (a still running one counts as ok).
    public var ok: Bool
    public var text: String
    /// Still running on the server; the result comes in the chat.
    public var running: Bool

    public init(ok: Bool, text: String, running: Bool = false) {
        self.ok = ok; self.text = text; self.running = running
    }

    enum CodingKeys: String, CodingKey { case ok, text, running }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let running = c.bool(.running) ?? false
        self.init(ok: c.bool(.ok) ?? true, text: c.text(.text) ?? (running ? "Still running." : "Done."), running: running)
    }
}

/// What the owner typed or picked for one action, and what it adds up to. Pure logic, so the rules are tested here;
/// the view only binds to `values` and `fieldValues`.
public struct ActionForm: Sendable, Equatable {
    public let spec: ActionSpec
    /// The chosen way to build the argument (index into `spec.variants`).
    public var variant: Int {
        didSet { variant = min(max(variant, 0), max(spec.variants.count - 1, 0)) }
    }
    /// Values of the argument parts, per variant and part index ("" for literals).
    public var values: [[String]]
    /// Payload values by field name. Empty = not sent.
    public var fieldValues: [String: String]

    /// Starts with sensible picks: tomorrow for a day, 07:00 for a time, the first option of a choice.
    public init(_ spec: ActionSpec, now: Date = Date(), calendar: Calendar = .current) {
        self.spec = spec
        variant = 0
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        values = spec.variants.map { v in
            v.parts.map { part in
                switch part {
                case .date: Self.day(tomorrow, calendar: calendar)
                case .time: "07:00"
                case .choice(_, let options): options.first?.value ?? ""
                case .literal, .number, .word: ""
                }
            }
        }
        var f: [String: String] = [:]
        for field in spec.fields where field.required {
            f[field.name] = Self.defaultValue(field, now: now, calendar: calendar)
        }
        fieldValues = f
    }

    /// The form of a card or item action (`ItemAction`): starts like `init(_:now:calendar:)`, then takes the payload
    /// values of fields the action has (others are dropped) and, when `arg` fits one of the variants, that variant
    /// with its part values. An `arg` that fits none is ignored.
    public init(_ spec: ActionSpec, prefill: ItemAction?, now: Date = Date(), calendar: Calendar = .current) {
        self.init(spec, now: now, calendar: calendar)
        guard let prefill else { return }
        for field in spec.fields {
            if let v = prefill.payload[field.name] { fieldValues[field.name] = v }
        }
        let arg = prefill.arg.trimmingCharacters(in: .whitespaces)
        guard !arg.isEmpty else { return }
        for (i, v) in spec.variants.enumerated() {
            if let parts = Self.split(arg, into: v.parts) {
                values[i] = parts
                variant = i
                return
            }
        }
    }

    /// Splits an argument back into part values ("" for literals), or nil if it doesn't fit these parts.
    static func split(_ arg: String, into parts: [ActionSpec.ArgPart]) -> [String]? {
        func esc(_ t: String) -> String { NSRegularExpression.escapedPattern(for: t) }
        var pattern = "^"
        for part in parts {
            switch part {
            case .literal(let t): pattern += esc(t)
            case .date: pattern += "([0-9]{4}-[0-1][0-9]-[0-3][0-9])"
            case .time: pattern += "([0-2][0-9]:[0-5][0-9])"
            case .number: pattern += "([0-9]{1,12})"
            case .word: pattern += "([A-Za-z0-9._-]{1,64})"
            case .choice(_, let options): pattern += "(" + options.map { esc($0.value) }.joined(separator: "|") + ")"
            }
        }
        pattern += "$"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: arg, range: NSRange(arg.startIndex..., in: arg)) else { return nil }
        var group = 0
        return parts.map { part in
            if case .literal = part { return "" }
            group += 1
            return Range(m.range(at: group), in: arg).map { String(arg[$0]) } ?? ""
        }
    }

    /// What a field starts with when it's required or switched on: tomorrow for a day (also for "day or time"),
    /// the next full hour for a time, the first option of a choice. Nil for text.
    public static func defaultValue(_ field: ActionSpec.Field, now: Date = Date(), calendar: Calendar = .current) -> String? {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        switch field.kind {
        case .choice: return field.options.first?.value
        case .date, .dateOrDatetime: return day(tomorrow, calendar: calendar)
        case .datetime:
            let hour = calendar.dateInterval(of: .hour, for: now)?.end ?? now
            return dayTime(hour, calendar: calendar)
        case .text, .multiline, .number: return nil
        }
    }

    public var parts: [ActionSpec.ArgPart] {
        spec.variants.indices.contains(variant) ? spec.variants[variant].parts : []
    }

    public func value(part index: Int) -> String {
        values.indices.contains(variant) && values[variant].indices.contains(index) ? values[variant][index] : ""
    }

    public mutating func set(part index: Int, _ value: String) {
        guard values.indices.contains(variant), values[variant].indices.contains(index) else { return }
        values[variant][index] = value
    }

    /// The argument to send, or nil while a part is missing or malformed. "" for an action without one.
    public var arg: String? {
        guard !spec.variants.isEmpty else { return "" }
        var out = ""
        for (i, part) in parts.enumerated() {
            if case .literal(let t) = part { out += t; continue }
            let v = value(part: i).trimmingCharacters(in: .whitespaces)
            guard Self.problem(part, v) == nil else { return nil }
            out += v
        }
        return out.count <= 64 ? out : nil
    }

    /// The payload to send: trimmed, without empty fields.
    public var payload: [String: String] {
        var out: [String: String] = [:]
        for field in spec.fields {
            let v = (fieldValues[field.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { out[field.name] = v }
        }
        return out
    }

    /// What keeps the form from being sent, one line each, in form order. Empty = ready.
    public var problems: [String] {
        var out: [String] = []
        for (i, part) in parts.enumerated() {
            if let p = Self.problem(part, value(part: i).trimmingCharacters(in: .whitespaces)) { out.append(p) }
        }
        let payload = payload
        for field in spec.fields {
            let v = payload[field.name]
            guard let v else {
                if field.required { out.append("\(field.label) is missing.") }
                continue
            }
            if v.count > field.max { out.append("\(field.label) is longer than \(field.max) characters.") }
            switch field.kind {
            case .number where v.wholeMatch(of: /[0-9]{1,12}/) == nil: out.append("\(field.label) must be a whole number.")
            case .date where v.wholeMatch(of: Self.dayPattern) == nil: out.append("\(field.label) must be a day like 2026-11-07.")
            case .datetime where v.wholeMatch(of: Self.dayTimePattern) == nil:
                out.append("\(field.label) must be a time like 2026-11-07T08:00.")
            case .dateOrDatetime where v.wholeMatch(of: Self.dayPattern) == nil && v.wholeMatch(of: Self.dayTimePattern) == nil:
                out.append("\(field.label) must be a day or a time.")
            case .choice where !field.options.contains(where: { $0.value == v }): out.append("\(field.label): pick one of the options.")
            default: break
            }
        }
        return out
    }

    public var isReady: Bool { problems.isEmpty && arg != nil }

    /// Label and value lines for the confirm step ("Day: 2026-11-07", "What: Lamps on"), option labels instead of values.
    public var summary: [(label: String, value: String)] {
        var out: [(String, String)] = []
        if spec.variants.count > 1 { out.append(("", spec.variants[variant].label)) }
        for (i, part) in parts.enumerated() {
            let v = value(part: i)
            switch part {
            case .literal: continue
            case .choice(let label, let options): out.append((label, options.first { $0.value == v }?.label ?? v))
            default: out.append((part.label ?? "", v))
            }
        }
        let payload = payload
        for field in spec.fields {
            guard let v = payload[field.name] else { continue }
            out.append((field.label, field.options.first { $0.value == v }?.label ?? v))
        }
        return out
    }

    static func problem(_ part: ActionSpec.ArgPart, _ v: String) -> String? {
        let name = part.label.flatMap { $0.isEmpty ? nil : $0 } ?? "A choice"
        switch part {
        case .literal: return nil
        case .date: return v.wholeMatch(of: dayPattern) == nil ? "\(name): pick a day." : nil
        case .time: return v.wholeMatch(of: /[0-2][0-9]:[0-5][0-9]/) == nil ? "\(name): pick a time." : nil
        case .number: return v.wholeMatch(of: /[0-9]{1,12}/) == nil ? "\(name) must be a whole number." : nil
        case .word:
            if v.isEmpty { return "\(name) is missing." }
            return v.wholeMatch(of: /[A-Za-z0-9._-]{1,64}/) == nil ? "\(name): only letters, digits, . _ and -." : nil
        case .choice(_, let options): return options.contains { $0.value == v } ? nil : "\(name): pick one of the options."
        }
    }

    nonisolated(unsafe) static let dayPattern = /[0-9]{4}-[0-1][0-9]-[0-3][0-9]/
    nonisolated(unsafe) static let dayTimePattern = /[0-9]{4}-[0-1][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]/

    // MARK: Dates as the server reads them (local time, no zone)

    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    public static func dayTime(_ date: Date, calendar: Calendar = .current) -> String {
        day(date, calendar: calendar) + "T" + time(date, calendar: calendar)
    }

    /// "2026-11-07", "07:30" or "2026-11-07T07:30" back to a date (for the pickers). Nil if it isn't one.
    public static func date(_ text: String, calendar: Calendar = .current) -> Date? {
        let parts = text.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        var c = DateComponents()
        switch parts.count {
        case 2 where text.wholeMatch(of: /[0-2][0-9]:[0-5][0-9]/) != nil:
            let today = calendar.dateComponents([.year, .month, .day], from: Date())
            c.year = today.year; c.month = today.month; c.day = today.day; c.hour = parts[0]; c.minute = parts[1]
        case 3 where text.wholeMatch(of: dayPattern) != nil:
            c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        case 5 where text.wholeMatch(of: dayTimePattern) != nil:
            c.year = parts[0]; c.month = parts[1]; c.day = parts[2]; c.hour = parts[3]; c.minute = parts[4]
        default: return nil
        }
        return calendar.date(from: c)
    }
}
