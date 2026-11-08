import Foundation

// Quiet hours (docs/plans/MODULAR.md, M3.3): Settings → Advanced → Quiet hours, off by default. Inside the
// window the background refresh posts no local notification (problems, actions to approve, deals). It still runs:
// the snapshot, the widget and the alert tracker are updated as always, so what came up during the night is on
// Today and in the widget, and is not announced again in the morning. Without quiet hours nothing changes.

extension AppSettings {
    /// What Quiet hours suggests when it is turned on: 22:00 to 07:00, every day.
    public static let defaultQuietHours = TimeWindow(from: 22 * 60, to: 7 * 60)

    /// Settings → Notifications shows the "Quiet hours" row: while a notification is on, or while quiet hours are set
    /// (so they can be turned off).
    public var showsQuietHoursRow: Bool { notificationsOn || quietHours != nil }

    /// Whether quiet hours hold at `now` (by the calendar's time zone). Always false without quiet hours.
    public func isQuiet(at now: Date, calendar: Calendar = .current) -> Bool {
        quietHours?.contains(now, calendar: calendar) ?? false
    }

    /// The alerts of one background run that become notifications: all of them while notifications are on, none
    /// while they are off or quiet hours hold.
    public func notificationsToPost(_ alerts: [AlertTracker.Alert], now: Date,
                                    calendar: Calendar = .current) -> [AlertTracker.Alert] {
        guard notificationsOn, !isQuiet(at: now, calendar: calendar) else { return [] }
        return alerts
    }

    /// The background run's result line: as before, plus ", quiet hours" when it held alerts back for them.
    public func backgroundResult(problems: Int, pending: Int, alerts: Int, now: Date,
                                 calendar: Calendar = .current) -> String {
        let line = "ok, \(problems) problems, \(pending) pending, \(alerts) alerts"
        return alerts > 0 && notificationsOn && isQuiet(at: now, calendar: calendar) ? line + ", quiet hours" : line
    }
}
