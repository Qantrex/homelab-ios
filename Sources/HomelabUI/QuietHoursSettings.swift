import HomelabDesign
import HomelabKit
import SwiftUI

/// Settings → Advanced → "Quiet hours": the row. Only while a notification is on (or quiet hours are set, so
/// they can be turned off); off by default.
struct QuietHoursRow: View {
    let model: AppModel

    var body: some View {
        if model.settings.showsQuietHoursRow {
            NavigationLink {
                QuietHoursEditor(model: model)
            } label: {
                LabeledContent("Quiet hours") {
                    Text(verbatim: model.settings.quietHours?.words(calendar: .current) ?? String(localized: "Off"))
                        .foregroundStyle(Palette.secondary)
                }
            }
        }
    }
}

/// Quiet hours on or off, and from when to when (every day; an end before the start runs past midnight).
struct QuietHoursEditor: View {
    let model: AppModel
    @Environment(\.calendar) private var calendar

    var body: some View {
        List {
            Group {
                Section {
                    Toggle("Quiet hours", isOn: Binding(
                        get: { model.settings.quietHours != nil },
                        set: { model.settings.quietHours = $0 ? (model.settings.quietHours ?? AppSettings.defaultQuietHours) : nil }))
                    if model.settings.quietHours != nil {
                        DatePicker("From", selection: time(\.from), displayedComponents: .hourAndMinute)
                        DatePicker("To", selection: time(\.to), displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    SettingsFooter("No notifications from Homelab in this window: new problems, actions to approve and deals. The app still checks, so Today and the widget show what came up, and it isn't announced again afterwards. Pushes from your server (ntfy, Home Assistant) are not affected; use a Focus for those. The same start and end means all day.")
                }
            }
            .surfaceRows()
        }
        .screenBackground()
        .navigationTitle("Quiet hours")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A time of the window as the picker's date (a fixed day, so 2:30 stays 2:30 on the day the clocks go forward);
    /// minutes after midnight in the settings.
    private func time(_ key: WritableKeyPath<TimeWindow, Int>) -> Binding<Date> {
        Binding(get: {
            TimeWindow.pickerDate(minutes: model.settings.quietHours?[keyPath: key] ?? 0, calendar: calendar)
        }, set: { date in
            guard var w = model.settings.quietHours else { return }
            w[keyPath: key] = TimeWindow.minutes(of: date, calendar: calendar)
            model.settings.quietHours = TimeWindow(from: w.from, to: w.to, days: w.days)
        })
    }
}
