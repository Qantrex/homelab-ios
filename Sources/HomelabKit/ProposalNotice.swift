import Foundation

/// Approve / Deny right on a "waiting for you" notification. The background refresh posts the notification with a
/// category that names the buttons the proposal has; pressing one (after Face ID or the passcode: the actions are
/// `authenticationRequired`) runs `press` from the notification response handler and posts a short result
/// notification (`message`).
///
/// The signed buttons never go into the notification: it carries only the server id and the proposal id, and the
/// button is looked up again in the cached state (or a fresh one) when it is pressed.
///
/// With the app lock on, a proposal that gets buttons still names its action (owner, 2026-11-06: "the approve deny
/// buttons should show on lock screen notifications after face id is detected"): nobody can answer what they can't
/// read. It relies on iOS hiding notification previews on the locked lock screen ("Show Previews: When Unlocked", the
/// default), and the press itself needs Face ID. Every other notification stays vague with the lock on (`content`).
public enum ProposalNotice {
    public static let approveAction = "com.qantrex.homelab.approve"
    public static let denyAction = "com.qantrex.homelab.deny"

    /// One category per set of buttons, so a proposal never shows a button the server didn't send. "Always" stays in
    /// the app: a standing approval deserves the full explanation there.
    public enum Category: String, CaseIterable, Sendable {
        case approveDeny = "com.qantrex.homelab.pending.approve-deny"
        case approve = "com.qantrex.homelab.pending.approve"
        case deny = "com.qantrex.homelab.pending.deny"

        public var verbs: [PendingAction.Verb] {
            switch self {
            case .approveDeny: [.approve, .deny]
            case .approve: [.approve]
            case .deny: [.deny]
            }
        }
    }

    /// The category for `proposal`'s notification, or nil for a plain one (no approve or deny button). The same with
    /// the app lock on: iOS asks for Face ID before it runs a press.
    public static func category(for proposal: PendingAction) -> Category? {
        switch (proposal.buttons[.approve] != nil, proposal.buttons[.deny] != nil) {
        case (true, true): return .approveDeny
        case (true, false): return .approve
        case (false, true): return .deny
        case (false, false): return nil
        }
    }

    public static func verb(actionID: String) -> PendingAction.Verb? {
        switch actionID {
        case approveAction: .approve
        case denyAction: .deny
        default: nil
        }
    }

    public static func actionID(_ verb: PendingAction.Verb) -> String? {
        switch verb {
        case .approve: approveAction
        case .deny: denyAction
        case .always: nil
        }
    }

    /// What the notification carries (userInfo): the server and the proposal, never its signed buttons.
    public static func userInfo(server: UUID, proposal: String) -> [String: String] {
        ["server": server.uuidString, "proposal": proposal]
    }

    /// A pressed button: which proposal on which server.
    public struct Request: Sendable, Equatable {
        public var server: UUID
        public var proposal: String
        public var verb: PendingAction.Verb

        public init(server: UUID, proposal: String, verb: PendingAction.Verb) {
            self.server = server; self.proposal = proposal; self.verb = verb
        }

        /// From a notification response, or nil when it isn't an Approve / Deny press of a proposal notification.
        public init?(actionID: String, userInfo: [AnyHashable: Any]) {
            guard let verb = ProposalNotice.verb(actionID: actionID),
                  let s = userInfo["server"] as? String, let server = UUID(uuidString: s),
                  let proposal = userInfo["proposal"] as? String, !proposal.isEmpty else { return nil }
            self.init(server: server, proposal: proposal, verb: verb)
        }
    }

    /// What came of a press.
    public struct Outcome: Sendable, Equatable {
        /// The proposal's title ("restart media sonarr"), when it was found.
        public var title: String?
        /// The server's answer; `.forbidden` when the proposal is gone or has no such button (already handled).
        public var result: Result<String, APIError>
    }

    /// Finds the proposal's signed button (in `cached`, else in a fresh `/state`) and presses it.
    public static func press(_ request: Request, api: any CompanionAPI, cached: HomelabState?, host: String) async -> Outcome {
        var proposal = cached?.pending.first { $0.id == request.proposal }
        if proposal?.buttons[request.verb] == nil {
            do {
                proposal = try await api.state().pending.first { $0.id == request.proposal }
            } catch {
                return Outcome(title: proposal?.title, result: .failure(APIError.from(error, host: host)))
            }
        }
        guard let proposal, let button = proposal.buttons[request.verb] else {
            return Outcome(title: proposal?.title, result: .failure(.forbidden))
        }
        do {
            return Outcome(title: proposal.title, result: .success(try await api.press(button)))
        } catch {
            return Outcome(title: proposal.title, result: .failure(APIError.from(error, host: host)))
        }
    }

    /// The server's answer in a notification is cut to this many characters.
    public static let maxBody = 180

    /// The result notification's text. `hidden`: the app lock is on, so it says only what happened, not to what.
    public static func message(_ outcome: Outcome, verb: PendingAction.Verb, server: String, hidden: Bool,
                               hasChat: Bool) -> (title: String, body: String) {
        let done = verb == .deny ? "Denied" : "Approved"
        if hidden {
            switch outcome.result {
            case .success: return ("Homelab", "\(done). Open the app for the answer.")
            case .failure: return ("Homelab", "That didn't go through. Open the app to see why.")
            }
        }
        let what = outcome.title ?? "the action"
        switch outcome.result {
        case .success(let text):
            return ("\(server): \(done.lowercased()) \(what)", short(text.isEmpty ? "Done." : text))
        case .failure(let e):
            let report = ActionReport.pressed(what, .failure(e), hasChat: hasChat)
            let asked = verb == .deny ? "Deny" : "Approve"
            return ("\(server): \(report.title.lowercased())", short("\(asked) \(what): \(report.text)"))
        }
    }

    /// What a background-refresh notification shows.
    public struct Content: Sendable, Equatable {
        public var title: String
        /// The personality's line; never with the app lock on.
        public var subtitle: String?
        public var body: String
        /// Approve / Deny for a proposal that has them.
        public var category: Category?

        public init(title: String, subtitle: String?, body: String, category: Category?) {
            self.title = title; self.subtitle = subtitle; self.body = body; self.category = category
        }
    }

    /// The notification for `alert`. `locked` (the app lock is on): a problem or a summary only says that something
    /// needs a look, and a proposal without buttons that an action waits; a proposal with Approve / Deny names its
    /// action and keeps its buttons, so it can be answered after Face ID (see the type's comment).
    public static func content(for alert: AlertTracker.Alert, locked: Bool, voice: Personality = .off) -> Content {
        let buttons = alert.proposal.flatMap { Self.category(for: $0) }
        if locked && buttons == nil {
            let body = alert.kind == .pending ? "An action is waiting for you." : "Something needs a look."
            return Content(title: "Homelab", subtitle: nil, body: body, category: nil)
        }
        let line = locked ? nil : alert.moment.flatMap { Voice.line($0, voice) }
        return Content(title: alert.title, subtitle: line, body: alert.body, category: buttons)
    }

    static func short(_ text: String) -> String {
        let one = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard one.count > maxBody else { return one }
        return String(one.prefix(maxBody - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
