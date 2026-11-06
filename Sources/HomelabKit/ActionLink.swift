import Foundation

/// A link that opens an action's form, optionally filled in: `homelab://actions/<name>?arg=…&<field>=…` (Shortcuts
/// "Open URL", Safari, a Home-screen quick action). The form always asks before anything runs; a link only types for
/// the owner. Rules:
/// - `arg` is the argument; it fills the form only when it fits one of the action's variants (like a card's `arg`).
/// - Every other query item names a payload field. Only fields the action has and that are not `hidden` are taken:
///   a hidden field (a to-do's `uid`) comes only from the server's own cards, never from a link.
/// - A `choice` field takes only one of its option values; anything else leaves the field as the form starts it.
/// - Values are trimmed; the first of duplicate names counts; empty values are ignored.
public struct ActionLink: Sendable, Equatable {
    public var name: String
    public var arg: String
    /// Payload values by field name, as the link has them (not yet checked against the action).
    public var values: [String: String]

    /// At most this many query items are read; a value longer than `maxValue` code points is dropped (the longest
    /// field the app knows takes 20000).
    public static let maxItems = 32
    public static let maxValue = 20000

    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public init(name: String, arg: String = "", values: [String: String] = [:]) {
        self.name = name; self.arg = arg; self.values = values
    }

    /// The link's action and values, or nil when it isn't `homelab://actions/<valid name>`.
    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == "homelab", url.host?.lowercased() == "actions" else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        guard path.count == 1, ActionSpec.isValidName(path[0]) else { return nil }
        name = path[0]
        arg = ""
        values = [:]
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var seen = Set<String>()
        for item in items.prefix(Self.maxItems) {
            let key = item.name.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            let value = (item.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.unicodeScalars.count <= Self.maxValue else { continue }
            if key == "arg" { arg = value } else { values[key] = value }
        }
    }

    /// The prefill for `spec`'s form (`ActionForm(spec, prefill:)`): the argument, and the values of visible fields
    /// the action has. Hidden fields, unknown names and choice values that aren't options are dropped.
    public func prefill(for spec: ActionSpec) -> ItemAction? {
        guard spec.name == name else { return nil }
        var payload: [String: String] = [:]
        for field in spec.fields where !field.hidden {
            guard let v = values[field.name] else { continue }
            if field.kind == .choice, !field.options.contains(where: { $0.value == v }) { continue }
            payload[field.name] = v
        }
        return ItemAction(name: name, arg: arg.unicodeScalars.count <= ActionForm.maxArg ? arg : "", payload: payload)
    }

    /// The form a link opens: `spec`'s, filled in from the link.
    public func form(for spec: ActionSpec, now: Date = Date(), calendar: Calendar = .current) -> ActionForm {
        ActionForm(spec, prefill: prefill(for: spec), now: now, calendar: calendar)
    }

    /// `homelab://actions/<name>` with the values as query items (`arg` first, then the fields by name), percent-encoded.
    public var url: URL? {
        var pairs: [(String, String)] = arg.isEmpty ? [] : [("arg", arg)]
        pairs += values.keys.sorted().map { ($0, values[$0] ?? "") }
        // Everything but the unreserved characters is encoded, `&`, `=` and `+` too, so a value always reads back as is.
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? "" }
        let query = pairs.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
        return URL(string: "homelab://actions/\(name)" + (query.isEmpty ? "" : "?" + query))
    }
}
