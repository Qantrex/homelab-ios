import Foundation

/// The configurable Actions widget (feature `widget-actions`): which Start actions it offers, what a tap does, and the
/// run itself. Pure logic, tested on Linux; the widget only draws it.
///
/// Rules (security first):
/// - The widget never reads the Keychain. It runs an action only on an identity (Tailscale) server, like its own
///   `/state` fetch (`WidgetPolicy.mayFetch`). On a token server every tap opens the app.
/// - Only an action with no fields, no argument and not destructive runs from the widget. The rest open their form in
///   the app (`homelab://actions/<name>`), where the usual one-tap confirm happens.
/// - Before it runs, the widget asks the server for its action list again and runs nothing the server doesn't list as
///   a Start action with those same properties.
public enum WidgetActions {
    public enum Tap: Sendable, Equatable {
        /// A button that runs the action right here.
        case runs
        /// A link that opens the app on the action's form.
        case opensApp
    }

    /// Actions per widget family: small 2 (1 when the owner picks one), medium 4, large 8, lock screen 1.
    public enum Size: Sendable, CaseIterable {
        case small, medium, large, circular
        public var capacity: Int {
            switch self {
            case .small: 2
            case .medium: 4
            case .large: 8
            case .circular: 1
            }
        }
    }

    /// How long a result stays on its tile.
    public static let resultLife: TimeInterval = 20

    /// What a tap on `action` does on `server` (nil = no server).
    public static func tap(_ action: ActionUsage.Offered, server: ServerConfig?) -> Tap {
        guard WidgetPolicy.mayFetch(server: server) else { return .opensApp }
        // Unknown (an older cache) counts as "needs the app".
        guard action.destructive == false, action.needsInput == false else { return .opensApp }
        return .runs
    }

    /// The same check against the server's own list, right before running.
    public static func runnable(_ spec: ActionSpec?) -> Bool {
        guard let spec else { return false }
        return spec.start && !spec.destructive && spec.fields.isEmpty && spec.variants.isEmpty
    }

    /// `homelab://actions/<name>`, or the Actions tab when the name is not one the server could have sent.
    public static func openURL(_ name: String) -> URL {
        // Only a valid action name becomes a deep link (newer Foundation accepts spaces in URL(string:)).
        (ActionSpec.isValidName(name) ? ActionLink(name: name).url : nil) ?? URL(string: "homelab://actions")!
    }

    // MARK: Which actions the widget offers

    /// What the Edit menu lists for `server`: the Start actions it offered last (cached by the app, no network), the
    /// visible ones in the owner's order first, then the hidden ones (the owner may still pick them explicitly).
    public static func choices(_ usage: ActionUsage, server: UUID?, order: ItemOrder?) -> [ActionUsage.Offered] {
        guard let server else { return [] }
        let offered = usage.offered[ActionUsage.key(server)] ?? []
        let order = order ?? .standard
        let visible = order.arrange(offered, id: \.name)
        let hidden = order.arrange(offered, id: \.name, onlyVisible: false).filter { !order.isVisible($0.name) }
        return visible + hidden
    }

    /// The default selection: the first visible Start tiles.
    public static func defaults(_ usage: ActionUsage, server: UUID?, order: ItemOrder?, count: Int) -> [ActionUsage.Offered] {
        let order = order ?? .standard
        return Array(choices(usage, server: server, order: order).filter { order.isVisible($0.name) }.prefix(max(count, 0)))
    }

    /// The tiles to draw: the picked names that the server still offers (in the picked order, no duplicates), or the
    /// defaults when nothing was picked. A picked action the server no longer lists is dropped, never run.
    public static func tiles(picked: [String], usage: ActionUsage, server: UUID?, order: ItemOrder?, size: Size) -> [ActionUsage.Offered] {
        let all = choices(usage, server: server, order: order)
        guard !picked.isEmpty else { return defaults(usage, server: server, order: order, count: size.capacity) }
        var seen = Set<String>()
        let byName = Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return Array(picked.compactMap { seen.insert($0).inserted ? byName[$0] : nil }.prefix(size.capacity))
    }

    // MARK: Result

    /// The short result a tile shows: "Done", "Started" (still running) or "Failed: ..." (one line, at most 40 characters).
    public static func resultText(_ r: Result<ActionResult, APIError>) -> (text: String, ok: Bool) {
        switch r {
        case .success(let res) where res.ok: return (res.running ? "Started" : "Done", true)
        case .success(let res): return (failed(res.text), false)
        case .failure(.serverSaid(_, let text)): return (failed(text), false)
        case .failure(.badRequest(let text)): return (failed(text), false)
        case .failure(.tooManyRequests): return (failed("too many, wait a minute"), false)
        case .failure(.timeout): return (failed("no answer, check the app"), false)
        case .failure(let e): return (failed(e.message), false)
        }
    }

    static func failed(_ why: String) -> String {
        let one = why.split(whereSeparator: \.isNewline).first.map(String.init) ?? why
        let t = one.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let line = t.isEmpty ? "Failed" : "Failed: " + t
        return line.count <= 40 ? line : String(line.prefix(39)) + "…"
    }

    /// A result shown on a tile for a short while.
    public struct Shown: Codable, Sendable, Equatable {
        public var name: String
        public var text: String
        public var ok: Bool
        public var date: Date
        public init(name: String, text: String, ok: Bool, date: Date) {
            self.name = name; self.text = text; self.ok = ok; self.date = date
        }

        public static let fileName = "widget-action-result.json"

        public func isFresh(at now: Date) -> Bool {
            let age = now.timeIntervalSince(date)
            return age >= 0 && age < WidgetActions.resultLife
        }
    }

    // MARK: VoiceOver

    /// "Wake Minecraft, runs it" / "Add a to-do, opens the app"; a result is spoken first.
    public static func spoken(_ action: ActionUsage.Offered, tap: Tap, result: String? = nil) -> String {
        let how = tap == .runs ? "runs it" : "opens the app"
        return [result, "\(action.label), \(how)"].compactMap { $0 }.joined(separator: ". ")
    }

    // MARK: Running

    public struct Outcome: Sendable, Equatable {
        public var text: String
        public var ok: Bool
        /// The app has to do it (token server, needs input, destructive, not listed any more).
        public var opensApp: Bool
    }

    /// Runs `name` from the widget: only on an identity server, only when the server lists it as a Start action that
    /// needs nothing and is not destructive. One more use is recorded for the quick-action ranking when it ran.
    public static func run(_ name: String, server: ServerConfig?, transport: any HTTPTransport, storage: Storage,
                           now: Date = Date()) async -> Outcome {
        guard let server, WidgetPolicy.mayFetch(server: server), ActionSpec.isValidName(name) else {
            return Outcome(text: "Open the app", ok: false, opensApp: true)
        }
        let client = CompanionClient(config: server, tokens: MemoryTokenStore(), transport: transport)
        let result: Result<ActionResult, APIError>
        do {
            let list = try await client.actions()
            guard runnable(list.first { $0.name == name }) else {
                return Outcome(text: "Open the app", ok: false, opensApp: true)
            }
            result = .success(try await client.run(name, arg: "", payload: [:]))
            var usage = storage.read(ActionUsage.self, ActionUsage.fileName) ?? ActionUsage()
            usage.record(name, server: server.id, at: now)
            try? storage.write(usage, ActionUsage.fileName)
        } catch {
            result = .failure(APIError.from(error, host: server.host))
        }
        let shown = resultText(result)
        try? storage.write(Shown(name: name, text: shown.text, ok: shown.ok, date: now), Shown.fileName)
        return Outcome(text: shown.text, ok: shown.ok, opensApp: false)
    }
}
