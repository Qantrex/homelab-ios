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
    /// Offered as a Start tile. False = only used through card/item actions (`start: false`).
    public var start: Bool

    public var id: String { name }

    public init(name: String, label: String? = nil, icon: String? = nil, hint: String? = nil, destructive: Bool = false,
                variants: [ArgVariant] = [], fields: [Field] = [], start: Bool = true) {
        self.start = start
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
        /// Letters, digits, `.`, `_`, `-`, starting with a letter or digit, at most 64 (`ActionForm.wordPattern`).
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
        /// Other field name → values of it that hide this field (`hidden_when`): while that field holds one of them
        /// the form neither shows nor sends this one. Unknown names are harmless (the field stays visible).
        public var hiddenWhen: [String: [String]]
        /// Never shown and never asked for; sent only when a card or item action prefilled it (a to-do's `uid`).
        public var hidden: Bool

        public var id: String { name }

        public enum Kind: String, Codable, Sendable, CaseIterable {
            case text, multiline, date, datetime, dateOrDatetime = "date-or-datetime", number, choice
        }

        public init(name: String, label: String? = nil, kind: Kind = .text, max: Int = 200, required: Bool = false,
                    options: [Option] = [], placeholder: String? = nil, hiddenWhen: [String: [String]] = [:],
                    hidden: Bool = false) {
            self.hiddenWhen = hiddenWhen; self.hidden = hidden
            self.name = name; self.label = label ?? name
            // A choice without options can only be typed.
            self.kind = kind == .choice && options.isEmpty ? .text : kind
            self.max = Swift.min(Swift.max(max, 1), 20000); self.required = required
            self.options = options; self.placeholder = placeholder
        }

        enum CodingKeys: String, CodingKey { case name, label, kind, max, required, options, placeholder, hidden
            case hiddenWhen = "hidden_when"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let name = c.text(.name) else {
                throw DecodingError.keyNotFound(CodingKeys.name, .init(codingPath: c.codingPath, debugDescription: "no name"))
            }
            self.init(name: name, label: c.text(.label), kind: c.text(.kind).flatMap { Kind(rawValue: $0.lowercased()) } ?? .text,
                      max: c.int(.max) ?? 200, required: c.bool(.required) ?? false,
                      options: c.array(Option.self, .options), placeholder: c.text(.placeholder),
                      hiddenWhen: (c.lenient([String: Lossy<[String]>].self, .hiddenWhen) ?? [:]).compactMapValues(\.value),
                      hidden: c.bool(.hidden) ?? false)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(label, forKey: .label)
            try c.encode(kind, forKey: .kind)
            try c.encode(max, forKey: .max)
            try c.encode(required, forKey: .required)
            if !options.isEmpty { try c.encode(options, forKey: .options) }
            try c.encodeIfPresent(placeholder, forKey: .placeholder)
            if !hiddenWhen.isEmpty { try c.encode(hiddenWhen, forKey: .hiddenWhen) }
            if hidden { try c.encode(true, forKey: .hidden) }
        }
    }

    enum CodingKeys: String, CodingKey { case name, label, icon, hint, destructive, arg, fields, start }

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
                  destructive: c.bool(.destructive) ?? false, variants: variants, fields: fields,
                  start: c.bool(.start) ?? true)
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
        if !start { try c.encode(false, forKey: .start) }
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
    /// Values a card or item action prefilled. While a field still holds exactly that, it is sent untouched (the
    /// server matches e.g. a to-do's text exactly, spaces included); typed values are trimmed.
    public private(set) var prefilled: [String: String] = [:]

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
        for field in spec.fields where field.required && !field.hidden {
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
            if let v = prefill.payload[field.name] { fieldValues[field.name] = v; prefilled[field.name] = v }
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

    /// A form for `spec` with its parts filled so that it builds exactly `arg` (Lab's restart), or nil when no variant
    /// of the spec can express it (e.g. a host the server's host choice doesn't list).
    public static func prefilled(_ spec: ActionSpec, arg: String) -> ActionForm? {
        guard !arg.isEmpty, length(arg) <= maxArg else { return nil }
        for (i, variant) in spec.variants.enumerated() {
            guard let values = split(arg, into: variant.parts) else { continue }
            var form = ActionForm(spec)
            form.variant = i
            form.values[i] = values
            if form.arg == arg { return form }
        }
        return nil
    }

    /// The form a card item's action (`ItemAction`) runs with, at once after a confirm: exactly its `arg`
    /// (`prefilled(_:arg:)`, outer spaces trimmed) and the payload values of fields the spec has. Nil when the arg fits
    /// no variant exactly, or an action without an argument gets one: the server's action changed since the item was
    /// made, and the lenient form would run its default instead ("lamps-offf" would switch the lamps on).
    public static func prefilled(_ spec: ActionSpec, action: ItemAction) -> ActionForm? {
        let arg = action.arg.trimmingCharacters(in: .whitespaces)
        var form: ActionForm
        if spec.variants.isEmpty {
            guard arg.isEmpty else { return nil }
            form = ActionForm(spec)
        } else {
            guard let exact = prefilled(spec, arg: arg) else { return nil }
            form = exact
        }
        for field in spec.fields {
            if let v = action.payload[field.name] { form.fieldValues[field.name] = v; form.prefilled[field.name] = v }
        }
        return form
    }

    /// What `AppModel.run(_ action:on:)` says when `prefilled(_:action:)` is nil.
    public static let itemActionMismatch = "This item's action no longer fits the server."

    /// Splits an argument back into part values ("" for literals), or nil if it doesn't fit these parts. Every part
    /// value passes the form's own check (`problem`); free parts try the shortest value first and back off when the
    /// rest doesn't fit ("a.b:c" with word `:` word).
    static func split(_ arg: String, into parts: [ActionSpec.ArgPart]) -> [String]? {
        match(parts[...], Substring(arg))
    }

    private static func match(_ parts: ArraySlice<ActionSpec.ArgPart>, _ rest: Substring) -> [String]? {
        guard let part = parts.first else { return rest.isEmpty ? [] : nil }
        let tail = parts.dropFirst()
        switch part {
        case .literal(let t):
            guard rest.hasPrefix(t) else { return nil }
            return match(tail, rest.dropFirst(t.count)).map { [""] + $0 }
        case .choice(_, let options):
            for o in options where !o.value.isEmpty && rest.hasPrefix(o.value) {
                if let m = match(tail, rest.dropFirst(o.value.count)) { return [o.value] + m }
            }
            return nil
        case .date, .time, .number, .word:
            guard !rest.isEmpty else { return nil }
            for k in 1...rest.count {
                let value = String(rest.prefix(k))
                guard problem(part, value) == nil else { continue }
                if let m = match(tail, rest.dropFirst(k)) { return [value] + m }
            }
            return nil
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

    /// The argument to send, or nil while a part is missing or malformed or it's too long. "" for an action without one.
    public var arg: String? {
        joinedArg.flatMap { $0.unicodeScalars.count <= Self.maxArg ? $0 : nil }
    }

    /// The server takes arguments up to this many characters (code points).
    public static let maxArg = 64

    /// The parts joined, before the length check; nil while a part is missing or malformed.
    private var joinedArg: String? {
        guard !spec.variants.isEmpty else { return "" }
        var out = ""
        for (i, part) in parts.enumerated() {
            if case .literal(let t) = part { out += t; continue }
            let v = value(part: i).trimmingCharacters(in: .whitespaces)
            guard Self.problem(part, v) == nil else { return nil }
            out += v
        }
        return out
    }

    /// Length as the server counts it: code points (Python's `len`), so "👨‍👩‍👧" is 5, not 1.
    public static func length(_ text: String) -> Int { text.unicodeScalars.count }

    /// Whether `hiddenWhen` hides the field right now: the other field holds one of the listed values (a value
    /// the form started with counts like a typed one).
    public func isHidden(_ field: ActionSpec.Field) -> Bool {
        field.hiddenWhen.contains { other, values in
            other != field.name
                && values.contains((fieldValues[other] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The fields to show and send, in form order.
    public var visibleFields: [ActionSpec.Field] { spec.fields.filter { !$0.hidden && !isHidden($0) } }

    /// The payload to send: without empty fields, with prefilled hidden ones; trimmed, except an unchanged prefilled value (`prefilled`).
    public var payload: [String: String] {
        var out: [String: String] = [:]
        for field in visibleFields {
            let raw = fieldValues[field.name] ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            out[field.name] = prefilled[field.name] == raw ? raw : trimmed
        }
        // Hidden fields are never shown or typed: only what a card or item action prefilled, untouched.
        for field in spec.fields where field.hidden {
            if let v = prefilled[field.name], !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out[field.name] = v }
        }
        return out
    }

    /// What keeps the form from being sent, one line each, in form order. Empty = ready.
    public var problems: [String] {
        var out: [String] = []
        for (i, part) in parts.enumerated() {
            if let p = Self.problem(part, value(part: i).trimmingCharacters(in: .whitespaces)) { out.append(p) }
        }
        // Every part fine but together too long: say so, or the form would be "not ready" without a reason.
        if let joined = joinedArg, Self.length(joined) > Self.maxArg {
            let name = spec.variants.count > 1 ? spec.variants[variant].label : spec.label
            out.append("\(name) is too long (\(Self.maxArg) characters at most).")
        }
        let payload = payload
        for field in visibleFields {
            let v = payload[field.name]
            guard let v else {
                if field.required { out.append("\(field.label) is missing.") }
                continue
            }
            if Self.length(v) > field.max { out.append("\(field.label) is longer than \(field.max) characters.") }
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

    /// Nothing to fill in or choose (one way to build the argument, no inputs, no visible fields) and ready to send:
    /// the Start tile asks "Run?" right away instead of opening an empty form.
    public var needsNoInput: Bool {
        spec.variants.count <= 1 && visibleFields.isEmpty && isReady
            && parts.allSatisfy { if case .literal = $0 { true } else { false } }
    }

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
        for field in visibleFields {
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
            return v.wholeMatch(of: wordPattern) == nil
                ? "\(name): only letters, digits, . _ and -, starting with a letter or digit." : nil
        case .choice(_, let options): return options.contains { $0.value == v } ? nil : "\(name): pick one of the options."
        }
    }

    /// A `word` part, as the server's agent checks it: `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`.
    nonisolated(unsafe) static let wordPattern = /[A-Za-z0-9][A-Za-z0-9._-]{0,63}/
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

/// Checklist items ticked off here that the server may still list as open for a moment (its list updates a little
/// later). They are drawn done and can't be tapped again until the card no longer offers that action on an open
/// item, or for `timeout` at most.
public struct TickedItems: Sendable, Equatable {
    public static let timeout: TimeInterval = 180

    private var since: [ItemAction: Date] = [:]

    public init() {}

    public var isEmpty: Bool { since.isEmpty }

    public mutating func add(_ action: ItemAction, at date: Date = Date()) {
        since[action] = date
    }

    /// The item was ticked off here and the server hasn't caught up yet.
    public func covers(_ item: Card.Item, now: Date = Date()) -> Bool {
        guard item.done != true, let a = item.action, let t = since[a] else { return false }
        return now.timeIntervalSince(t) < Self.timeout
    }

    /// The card as it should look: ticked items done and without their action.
    public func applied(to card: Card, now: Date = Date()) -> Card {
        guard !since.isEmpty else { return card }
        var card = card
        card.items = card.items.map { item in
            guard covers(item, now: now) else { return item }
            var item = item
            item.done = true
            item.action = nil
            return item
        }
        return card
    }

    /// Forgets ticks the server caught up with (no open item of `card` offers that action any more) and old ones.
    public mutating func prune(_ card: Card, now: Date = Date()) {
        let open = Set(card.items.filter { $0.done != true }.compactMap(\.action))
        since = since.filter { open.contains($0.key) && now.timeIntervalSince($0.value) < Self.timeout }
    }
}

/// The alert after an action ran from the app: a started action (Actions tab, a card), a container restart (Lab) or
/// a proposal's button (Actions tab, chat). All the words in one place; the views only show them.
public struct ActionReport: Sendable, Equatable {
    public var ok: Bool
    public var title: String
    public var text: String

    public init(ok: Bool, title: String, text: String) {
        self.ok = ok; self.title = title; self.text = text
    }

    /// A started action: its label and the server's text, or why it didn't run. `hasChat`: the server has a chat.
    public static func started(_ label: String, _ r: Result<ActionResult, APIError>, hasChat: Bool) -> ActionReport {
        switch r {
        case .success(let res):
            ActionReport(ok: res.ok, title: res.ok ? label : "\(label) failed", text: res.text)
        case .failure(.serverSaid(_, let text)):
            ActionReport(ok: false, title: "\(label) failed", text: text)
        case .failure(let e):
            failure(e, hasChat: hasChat)
        }
    }

    /// A container restarted from Lab: "Restarted sonarr", "Restart of sonarr started" (still running), or failed.
    public static func restart(_ name: String, _ r: Result<ActionResult, APIError>, hasChat: Bool) -> ActionReport {
        switch r {
        case .success(let res):
            ActionReport(ok: res.ok, title: !res.ok ? "Restart of \(name) failed"
                                            : res.running ? "Restart of \(name) started" : "Restarted \(name)",
                         text: res.text)
        case .failure(.serverSaid(_, let text)):
            ActionReport(ok: false, title: "Restart of \(name) failed", text: text)
        case .failure(let e):
            failure(e, hasChat: hasChat)
        }
    }

    /// A proposal's button (`title`: the proposal's). A 403 means the signed button is spent or expired.
    public static func pressed(_ title: String, _ r: Result<String, APIError>, hasChat: Bool) -> ActionReport {
        switch r {
        case .success(let text):
            ActionReport(ok: true, title: title, text: text)
        case .failure(let e) where e.isForbidden:
            ActionReport(ok: false, title: "No longer valid",
                         text: "This button is no longer valid (already handled or expired).")
        case .failure(let e):
            failure(e, hasChat: hasChat)
        }
    }

    static func failure(_ e: APIError, hasChat: Bool) -> ActionReport {
        let f = e.actionFailure(hasChat: hasChat)
        return ActionReport(ok: false, title: f.title, text: f.text)
    }
}
