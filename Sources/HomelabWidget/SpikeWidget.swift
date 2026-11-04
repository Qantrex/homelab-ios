import SpikeShared
import SwiftUI
import WidgetKit

/// Test S3/S4: shows what the app wrote into the shared App Group file, and which group the widget itself found.
/// StaticConfiguration only: xtool can't build App Intents, so no configurable or interactive widgets.
@main
struct SpikeWidgetBundle: WidgetBundle {
    var body: some Widget {
        SpikeWidget()
    }
}

struct SpikeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HomelabSpike", provider: Provider()) { entry in
            EntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "homelab://spike"))
        }
        .configurationDisplayName("Homelab Spike")
        .description("Shows the shared counter and the App Group the widget found.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

struct Entry: TimelineEntry {
    var date: Date
    var group: String?
    var state: SpikeState
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), group: "group…", state: SpikeState())
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = current()
        completion(Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(15 * 60))))
    }

    private func current() -> Entry {
        let group = AppGroup.resolve().group
        // Record the read, so the app can prove the widget really ran against the same file.
        let state = SpikeStore.update(group: group) { $0.widgetLastRead = Date() }
        return Entry(date: Date(), group: group, state: state)
    }
}

struct EntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("Spike \(entry.state.counter)").font(.headline)
                Text(entry.group == nil ? "no group" : "group ok")
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                Text("Homelab Spike").font(.caption).foregroundStyle(.secondary)
                Text("\(entry.state.counter)").font(.system(size: 40, weight: .bold, design: .rounded))
                Text(entry.group ?? "NO GROUP").font(.caption2).lineLimit(2).minimumScaleFactor(0.6)
                Text(entry.date, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
