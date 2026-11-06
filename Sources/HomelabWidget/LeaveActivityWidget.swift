import ActivityKit
import HomelabDesign
import HomelabKit
import SwiftUI
import WidgetKit

/// The lock-screen Live Activity "Leave by 07:26 · U6 07:31" (step 6c). The iPhone 12 mini has no Dynamic Island, so
/// the lock-screen view (also the banner and StandBy) is what matters; the island closures are required by the API.
/// The countdown runs by itself (`Text(timerInterval:)`), so the app only has to update it when the pick changes.
/// A disruption or "too late" is always a symbol plus words, never colour alone.
struct LeaveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LeaveAttributes.self) { context in
            LeaveLockScreen(state: context.state)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(Palette.text)
                .widgetURL(URL(string: "homelab://today"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leave by").font(.caption).foregroundStyle(Palette.secondary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.leaveBy, style: .time).font(Typo.data(.title3, weight: .semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(LeaveLockScreen.trainLine(context.state)).font(.footnote).foregroundStyle(Palette.secondary)
                }
            } compactLeading: {
                Image(systemName: context.state.bike ? "bicycle" : "tram.fill")
            } compactTrailing: {
                Text(timerInterval: Date()...max(Date(), context.state.leaveBy), countsDown: true)
                    .font(Typo.data(.caption)).frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "figure.walk")
            }
        }
    }
}

struct LeaveLockScreen: View {
    let state: LeaveContent

    static func clock(_ date: Date) -> String { DepartureBoard.clock(date) }

    /// "U6 07:31 · next 07:36, too late" / "Bike · 25 min"
    static func trainLine(_ s: LeaveContent) -> String {
        if s.bike { return s.ride.map { String(localized: "Bike · \($0) min") } ?? String(localized: "Bike") }
        var text = "\(s.line) \(clock(s.departure))"
        if let next = s.next {
            text += " · " + String(localized: "next \(clock(next))")
            if s.nextTooLate { text += ", " + String(localized: "too late") }
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Leave by").font(.headline).foregroundStyle(Palette.text)
                Text(Self.clock(state.leaveBy)).font(Typo.data(.title2, weight: .semibold)).foregroundStyle(Palette.text)
                Spacer()
                // Counts down on its own: no update needed every minute. Gold only as an addition to the words
                // "Leave by" and the number: the time itself says how close it is.
                Text(timerInterval: Date()...max(Date(), state.leaveBy), countsDown: true)
                    .font(Typo.data(.title3, weight: .semibold)).multilineTextAlignment(.trailing)
                    .foregroundStyle(state.leaveBy.timeIntervalSinceNow < 300 ? Palette.gold : Palette.text)
            }
            HStack(spacing: 6) {
                Image(systemName: state.bike ? "bicycle" : "tram.fill").foregroundStyle(Palette.secondary)
                Text(Self.trainLine(state)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            .font(.subheadline)
            if let d = state.disruption {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.gold)
                    Text(state.moreDisruptions > 0 ? "\(d) +\(state.moreDisruptions)" : d).foregroundStyle(Palette.text).lineLimit(1)
                }
                .font(.footnote)
            }
        }
        .padding(16)
    }
}
