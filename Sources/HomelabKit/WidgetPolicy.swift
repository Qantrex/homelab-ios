import Foundation

/// What the widgets may fetch, write and show (step 6c). Pure, so it is tested on Linux.
public enum WidgetPolicy {
    /// A widget GETs `/state` itself only for a Companion server that is reached by identity (Tailscale): it never
    /// reads the Keychain, so a token server can't be asked. Demo servers have nothing to fetch.
    public static func mayFetch(server: ServerConfig?) -> Bool {
        guard let server else { return false }
        return server.kind == .companion && server.auth == .identity
    }

    /// Every widget kind runs its own timeline, so they share one snapshot: fetch only when it is older than this.
    public static let freshFor: TimeInterval = 5 * 60

    public static func shouldFetch(snapshot: Snapshot?, now: Date) -> Bool {
        guard let snapshot else { return true }
        let age = now.timeIntervalSince(snapshot.fetched)
        return age > freshFor || age < -freshFor   // a snapshot "from the future" (clock change) is not fresh
    }

    /// The widget writes `widget-snapshot.json` only when it belongs to the selected server and is newer than what is
    /// there. The app and the widget can race; the write itself is atomic.
    public static func shouldWrite(_ new: Snapshot, over current: Snapshot?, selected: UUID?) -> Bool {
        guard new.serverID == selected else { return false }
        guard let current, current.serverID == new.serverID else { return true }
        return new.fetched > current.fetched
    }

    public enum Kind: String, Sendable, CaseIterable {
        case departures, deadlines, todos
    }

    public enum Redaction: Equatable, Sendable {
        case full
        /// Counts only: "3 deadlines this week", "4 to-dos".
        case countsOnly
    }

    /// With the app lock on, U6 times (public data) stay; deadline and to-do titles never show.
    public static func redaction(for kind: Kind, locked: Bool) -> Redaction {
        guard locked else { return .full }
        return kind == .departures ? .full : .countsOnly
    }
}

/// The last result of something that runs without the user looking (a widget fetch, the Live Activity), for
/// Diagnostics. A small file of its own: the widget never writes the app's settings.
public struct RunLog: Codable, Sendable, Equatable {
    public var date: Date
    public var result: String

    public init(date: Date = Date(), result: String) {
        self.date = date; self.result = result
    }

    public static let widgetFetch = "widget-fetch.json"
    public static let leaveActivity = "leave-activity.json"
}

extension Storage {
    public func log(_ name: String, _ result: String, now: Date = Date()) {
        try? write(RunLog(date: now, result: result), name)
    }
}
