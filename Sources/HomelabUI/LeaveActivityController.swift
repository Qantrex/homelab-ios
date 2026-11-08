import ActivityKit
import Foundation
import HomelabDesign
import HomelabKit

/// Carries out `LeavePlan.decide` for the "Leave by" Live Activity. `Activity.request` only works while the app is in
/// the foreground; `update` and `end` also work from the background refresh. Nothing is pushed: the countdown runs by
/// itself and the activity goes stale at the train's time.
public enum LeaveActivityController {
    public static var allowed: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Ends every "Leave by" activity now (Reset everything: nothing of the old setup stays on the lock screen).
    public static func endAll() async {
        for a in Activity<LeaveAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
    }

    /// Looks at the selected server's `commute` and starts, updates or ends the activity. Returns what happened (and
    /// writes it to the Diagnostics log).
    @discardableResult
    public static func apply(plan: CommutePlan?, enabled: Bool, foreground: Bool, storage: Storage = .shared(),
                             now: Date = Date()) async -> String {
        let activities = Activity<LeaveAttributes>.activities
        let current = activities.first { $0.activityState == .active || $0.activityState == .stale }
        let decision = LeavePlan.decide(plan: plan, now: now, running: current?.content.state, foreground: foreground,
                                        enabled: enabled)
        let result: String
        switch decision {
        case .none:
            result = "nothing to do"
        case .end:
            for a in activities { await a.end(nil, dismissalPolicy: .immediate) }
            result = "ended"
        case .update(let c):
            if let current {
                await current.update(content(c))
                result = "updated"
            } else {
                result = "nothing to update"
            }
        case .start(let c):
            // Yesterday's leftovers first.
            for a in activities where a.attributes.day != c.day { await a.end(nil, dismissalPolicy: .immediate) }
            if !allowed {
                result = "Live Activities are off for Homelab (iOS Settings)"
            } else {
                do {
                    _ = try Activity.request(attributes: LeaveAttributes(day: c.day, firstLesson: c.firstLesson),
                                             content: content(c), pushType: nil)
                    result = "started"
                } catch {
                    result = "start failed: \(error.localizedDescription)"
                }
            }
        }
        // Only the interesting results replace the log, so "nothing to do" doesn't hide the last real one.
        if decision != .none { storage.log(RunLog.leaveActivity, (foreground ? "app: " : "background: ") + result, now: now) }
        return result
    }

    /// Stale at the first lesson (`LeaveContent.staleDate`): the view then says it is over, even if no update arrives
    /// (the background refresh ends the activity, but it may not run).
    private static func content(_ c: LeaveContent) -> ActivityContent<LeaveContent> {
        ActivityContent(state: c, staleDate: c.staleDate, relevanceScore: 100)
    }
}

public extension AppModel {
    /// Called when the app comes to the front and after each new `/state`: starts the activity on a school morning.
    @MainActor func syncLeaveActivity() async {
        await LeaveActivityController.apply(plan: selectedStatus.snapshot?.state.commute, enabled: settings.leaveByOn,
                                            foreground: true, storage: storage)
    }
}
