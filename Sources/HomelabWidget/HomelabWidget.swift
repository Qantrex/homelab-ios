import HomelabDesign
import HomelabKit
import SwiftUI
import WidgetKit

/// Read-only widgets from the snapshot the app (or its background refresh) wrote into the App Group.
/// StaticConfiguration only: xtool can't build App Intents, so no configurable or interactive widgets.
/// The widget never holds tokens and never talks to the network.
@main
struct HomelabWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        HostsWidget()
    }
}

struct Entry: TimelineEntry {
    var date: Date
    var snapshot: Snapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), snapshot: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snapshot: context.isPreview ? (Self.load() ?? Self.sample) : Self.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The app reloads timelines whenever it has new data; this is only the fallback, so the age text stays right.
        let now = Date()
        let snap = Self.load()
        let entries = (0..<4).map { Entry(date: now.addingTimeInterval(Double($0) * 15 * 60), snapshot: snap) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    static func load() -> Snapshot? {
        Storage.shared().read(Snapshot.self, Snapshot.widgetFileName)
    }

    static var sample: Snapshot? {
        Fixtures.decode(HomelabState.self, "state-problem.json").map {
            Snapshot(serverID: UUID(), serverName: "Homelab", state: $0, fetched: Date())
        }
    }
}

// MARK: - Status (small, lock screen)

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HomelabStatus", provider: Provider()) { entry in
            StatusView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Homelab status")
        .description("Overall status and actions waiting for you.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct StatusView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    private var state: HomelabState? { entry.snapshot?.state }
    // Old data keeps its status (dimmed, with its age) instead of turning grey: the background refresh is rare.
    private var stale: Bool { entry.snapshot?.isStaleForWidget(now: entry.date) ?? true }
    private var status: OverallStatus { state?.status ?? .unknown }
    private var pending: Int { state?.pending.count ?? 0 }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: status.symbol).font(.title3)
                    if pending > 0 { Text("\(pending)").font(.caption2.bold()) }
                }
            }
            .widgetURL(URL(string: pending > 0 ? "homelab://actions" : "homelab://overview"))
            .accessibilityLabel(Text("Homelab \(status.title), \(pending) waiting"))
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label(entry.snapshot?.serverName ?? "Homelab", systemImage: status.symbol).font(.headline)
                Text(line).font(.caption).privacySensitive()
                Text(age).font(.caption2).foregroundStyle(.secondary)
            }
            .widgetURL(URL(string: "homelab://overview"))
        case .accessoryInline:
            Label("\(status.title)\(pending > 0 ? " · \(pending) waiting" : "")", systemImage: status.symbol)
        default:
            small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: status.symbol).font(.title2).foregroundStyle(status.color)
                Spacer()
                if pending > 0 {
                    Text("\(pending)")
                        .font(.caption.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.blue, in: Capsule())
                        .foregroundStyle(.white)
                        .accessibilityLabel(Text("\(pending) actions waiting"))
                }
            }
            Text(entry.snapshot?.serverName ?? "Homelab").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(entry.snapshot == nil ? String(localized: "Open the app") : status.title)
                .font(.headline)
                .lineLimit(1)
            Text(line).font(.caption2).lineLimit(2).privacySensitive()
            Spacer(minLength: 0)
            Text(age).font(.caption2).foregroundStyle(.secondary)
        }
        .widgetURL(URL(string: pending > 0 ? "homelab://actions" : "homelab://overview"))
    }

    private var line: String {
        guard let state, entry.snapshot != nil else { return String(localized: "No data yet") }
        if stale { return String(localized: "Data from \(age), open the app") }
        if let p = state.problems.first { return state.problems.count > 1 ? "\(p.text) +\(state.problems.count - 1)" : p.text }
        let up = state.hosts.filter { $0.reachable == true }.count
        return String(localized: "\(up)/\(state.hosts.count) hosts up")
    }

    private var age: String {
        entry.snapshot.map { Format.age($0.fetched, now: entry.date) } ?? ""
    }
}

// MARK: - Hosts (medium)

struct HostsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HomelabHosts", provider: Provider()) { entry in
            HostsView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "homelab://overview"))
        }
        .configurationDisplayName("Homelab hosts")
        .description("Each host with load, memory and disk.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct HostsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        let state = entry.snapshot?.state
        let stale = entry.snapshot?.isStaleForWidget(now: entry.date) ?? true
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                let status = state?.status ?? .unknown
                Image(systemName: status.symbol).foregroundStyle(status.color)
                Text(entry.snapshot?.serverName ?? "Homelab").font(.headline).lineLimit(1)
                Spacer()
                Text(entry.snapshot.map { Format.age($0.fetched, now: entry.date) } ?? "").font(.caption2).foregroundStyle(.secondary)
            }
            if let hosts = state?.hosts, !hosts.isEmpty {
                let limit = family == .systemLarge ? 8 : 4
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                    ForEach(hosts.prefix(limit)) { HostCell(host: $0) }
                }
                if family == .systemLarge, let problems = state?.problems, !problems.isEmpty {
                    Divider()
                    ForEach(problems.prefix(4)) { p in
                        Label(p.text, systemImage: p.severity.symbol).font(.caption).foregroundStyle(p.severity.color).lineLimit(1)
                            .privacySensitive()
                    }
                }
            } else {
                Spacer()
                Text(entry.snapshot == nil ? "Open Homelab to load your hosts." : "No hosts reported.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .opacity(stale ? 0.55 : 1)
    }
}

struct HostCell: View {
    let host: Host

    var body: some View {
        let health = HostHealth(host)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(health.color).frame(width: 7, height: 7)
                Text(host.name).font(.caption.weight(.semibold)).lineLimit(1)
            }
            if host.reachable == true {
                Text("load \(Format.load(host.load)) · RAM \(Format.percent(host.memPct))").font(.caption2).foregroundStyle(.secondary)
                if let d = Format.worstDisk(host.disks) { Meter(Double(d.percent) / 100, warns: true) }
            } else {
                Text(health.label).font(.caption2).foregroundStyle(health.color)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
