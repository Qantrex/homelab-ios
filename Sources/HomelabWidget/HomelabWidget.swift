import HomelabDesign
import HomelabKit
import SwiftUI
import WidgetKit

/// Read-only widgets from the snapshot the app (or its background refresh) wrote into the App Group, in the app's
/// look (docs/DESIGN.md): true black, a white headline, the mood as Today's glow plus a status icon, sentence-case
/// meta in secondary, numbers in the data font. Margins are the system's per family; inside, a 4/8 grid.
/// StaticConfiguration only: xtool can't build App Intents, so no configurable or interactive widgets.
/// The widget never holds tokens. A widget may GET `/state` itself for an identity (Tailscale) server, at most every
/// 5 minutes across all kinds (WidgetData); otherwise it shows what the app wrote.
@main
struct HomelabWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        DayWidget()
        HostsWidget()
        DeparturesWidget()
        DeadlinesWidget()
        TodosWidget()
        LeaveActivityWidget()
    }
}

struct Entry: TimelineEntry {
    var date: Date
    var snapshot: Snapshot?
    /// The app lock is on: show status and counts only, never problem text, host names or the day.
    var redacted = false

    var state: HomelabState? { snapshot?.state }
    // Old data keeps its status (dimmed, with its age) instead of turning grey: the background refresh is rare.
    var stale: Bool { snapshot?.isStaleForWidget(now: date) ?? true }
    var mood: TodayMood {
        snapshot == nil ? TodayMood(level: .unknown, headline: String(localized: "Open the app."), detail: nil)
                        : TodayMood(state: state)
    }
    var pending: Int { state?.pending.count ?? 0 }
    var age: String { snapshot.map { Format.age($0.fetched, now: date) } ?? "" }
    /// "Fri 6"
    var dateLine: String { date.formatted(.dateTime.weekday(.abbreviated).day()) }
}

struct Provider: TimelineProvider {
    /// When the entries are: the Day widget redraws every minute while a stop is near (its countdown), U6 at each
    /// departure, deadlines at midnight and at timed dues; the others every 15 minutes.
    enum Follows { case none, day, departures, deadlines }
    var follows = Follows.none

    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), snapshot: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snapshot: context.isPreview ? (Self.load() ?? Self.sample) : Self.load(),
                         redacted: !context.isPreview && Self.locked()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // WidgetKit's completion isn't Sendable; it is called exactly once, from this task.
        nonisolated(unsafe) let completion = completion
        Task {
            // Fresh data when the shared snapshot is older than 5 minutes (identity servers only), else what is there.
            let now = Date()
            let snap = await WidgetData.current(now: now)
            let redacted = Self.locked()
            let dates: [Date]
            switch follows {
            case .none:
                dates = [now]
            case .day:
                dates = DayTimeline.redrawDates(card: redacted ? nil : snap?.state.dayCard, now: now)
            case .departures:
                dates = snap?.state.departuresCard.map { DepartureTimeline.entries(DepartureBoard(card: $0), now: now) } ?? [now]
            case .deadlines:
                dates = Deadlines.redrawDates(redacted ? nil : snap?.state.deadlinesCard, now: now)
            }
            // The next reload in 15 minutes (WidgetKit decides; a widget seen often gets about 40-70 a day). The
            // entries above are free and cover the time until then.
            completion(Timeline(entries: dates.map { Entry(date: $0, snapshot: snap, redacted: redacted) },
                                policy: .after(now.addingTimeInterval(15 * 60))))
        }
    }

    static func load() -> Snapshot? {
        Storage.shared().read(Snapshot.self, Snapshot.widgetFileName)
    }

    static func locked() -> Bool {
        Storage.shared().read(AppSettings.self, AppSettings.fileName)?.faceIDLock ?? false
    }

    /// The widget gallery: the demo data, with the day moved to now like in demo mode.
    static var sample: Snapshot? {
        Fixtures.decode(HomelabState.self, "state-problem.json").map { state in
            var s = state
            s.cards = s.cards.map { $0.id == "today" ? DemoBackend.demoDay($0, now: Date()) : $0 }
            return Snapshot(serverID: UUID(), serverName: "Homelab", state: s, fetched: Date())
        }
    }
}

/// Meta text (DESIGN.md §1): footnote, sentence case, secondary or tertiary. Not capitals, not mono.
private struct Meta: View {
    let text: String
    var color = Palette.secondary

    init(_ text: String, color: Color = Palette.secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text).font(.footnote).foregroundStyle(color).lineLimit(1)
    }
}

/// The mood as an icon next to the text; the headline itself stays white.
private func statusSymbol(_ level: TodayMood.Level) -> String? {
    switch level {
    case .alarm: "exclamationmark.octagon.fill"
    case .headsUp: "exclamationmark.triangle.fill"
    case .calm: "checkmark.circle.fill"
    case .unknown: nil
    }
}

private struct StatusIcon: View {
    let level: TodayMood.Level

    var body: some View {
        if let symbol = statusSymbol(level) {
            Image(systemName: symbol).font(.footnote.weight(.semibold)).foregroundStyle(level.color).accessibilityHidden(true)
        }
    }
}

// MARK: - Status (small, lock screen)

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HomelabStatus", provider: Provider()) { entry in
            StatusView(entry: entry)
                .containerBackground(for: .widget) { MoodGlow(level: entry.stale ? .unknown : entry.mood.level, reach: 220) }
        }
        .configurationDisplayName("Homelab status")
        .description("How the lab is doing, and actions waiting for you.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct StatusView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    private var status: OverallStatus { entry.state?.status ?? .unknown }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: status.symbol).font(.title3)
                    if entry.pending > 0 { Text("\(entry.pending)").font(Typo.data(.caption2, weight: .bold)) }
                }
            }
            .widgetURL(URL(string: entry.pending > 0 ? "homelab://actions" : "homelab://today"))
            .accessibilityLabel(Text("Homelab \(status.title), \(entry.pending) waiting"))
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.mood.headline).font(.headline.weight(.heavy)).lineLimit(1)
                Text(line).font(.caption).lineLimit(1).privacySensitive()
                Text(footer).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .widgetURL(URL(string: "homelab://today"))
        case .accessoryInline:
            Label("\(entry.mood.headline)\(entry.pending > 0 ? " · \(entry.pending) waiting" : "")", systemImage: status.symbol)
        default:
            small
        }
    }

    private var small: some View {
        let mood = entry.mood
        let level = entry.stale ? TodayMood.Level.unknown : mood.level
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StatusIcon(level: level)
                Meta(entry.dateLine)
                Spacer(minLength: 4)
                if entry.pending > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.shield.fill").font(.footnote.weight(.semibold))
                        Text("\(entry.pending)").font(Typo.data(.footnote, weight: .semibold))
                    }
                    .foregroundStyle(Palette.gold)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("\(entry.pending) actions waiting"))
                }
            }
            Spacer(minLength: 0)
            Text(mood.headline)
                .font(.system(size: 26, weight: .heavy))
                .tracking(-0.8)
                .foregroundStyle(Palette.text)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            Text(line).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(2).privacySensitive()
            Text(footer).font(.caption2).foregroundStyle(Palette.tertiary).lineLimit(1).padding(.top, 4)
        }
        .opacity(entry.stale && entry.snapshot != nil ? 0.6 : 1)
        .widgetURL(URL(string: entry.pending > 0 ? "homelab://actions" : "homelab://today"))
    }

    /// The first problem, or how many machines are up.
    private var line: String {
        guard let state = entry.state else { return String(localized: "No data yet") }
        if entry.stale { return String(localized: "Data from \(entry.age), open the app") }
        if entry.redacted {
            return state.problems.isEmpty ? String(localized: "No problems") : String(localized: "\(state.problems.count) problems, open the app")
        }
        if let p = state.problems.first { return state.problems.count > 1 ? "\(p.text) +\(state.problems.count - 1)" : p.text }
        return entry.mood.detail ?? String(localized: "\(state.hosts.count) machines")
    }

    /// "Homelab · 2 min ago"
    private var footer: String {
        [entry.snapshot?.serverName ?? "Homelab", entry.age].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Day (small, medium, lock screen)

struct DayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HomelabDay", provider: Provider(follows: .day)) { entry in
            DayView(entry: entry)
                .containerBackground(Palette.background, for: .widget)
                .widgetURL(URL(string: "homelab://today"))
        }
        .configurationDisplayName("Homelab day")
        .description("Your day as a line: wake-up, leave by, first lesson, with a countdown to the next.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct DayView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    private var card: Card? { entry.redacted ? nil : entry.state?.dayCard }
    private var line: DayTimeline? { card.map { DayTimeline(card: $0, now: entry.date) } }
    /// The stop to show big: the next one, or the last one once the day is over.
    private var focus: DayTimeline.Stop? { line.flatMap { $0.next ?? $0.stops.last } }

    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                if let stop = focus, let line {
                    Text("\(stop.item.title ?? "") \(stop.item.value ?? "")").font(.headline).lineLimit(1)
                    Text(detail(stop, line)).font(.caption).lineLimit(1)
                    Text(rest(line)).font(Typo.data(.caption2)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(line?.isTomorrow == true ? "Tomorrow" : "Today").font(.headline)
                    Text(empty).font(.caption).lineLimit(2)
                }
            }
            .privacySensitive()
        case .accessoryInline:
            if let stop = focus, let line, stop.phase == .next {
                Text("\(stop.item.title ?? "") \(stop.item.value ?? "") · \(Format.countdown(minutes: line.minutesToNext ?? 0))")
            } else {
                Text(empty)
            }
        case .systemMedium:
            medium
        default:
            small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            Meta(line?.isTomorrow == true ? String(localized: "Tomorrow") : entry.dateLine)
            Spacer(minLength: 0)
            if let stop = focus, let line {
                Text(stop.item.title ?? "").font(.footnote.weight(.medium)).foregroundStyle(Palette.secondary).lineLimit(1)
                Text(stop.item.value ?? "")
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .foregroundStyle(stop.phase == .past ? Palette.tertiary : Palette.text)
                Text(detail(stop, line)).font(.footnote.weight(stop.phase == .next ? .semibold : .regular))
                    .foregroundStyle(stop.phase == .next ? Palette.text : Palette.tertiary).lineLimit(1)
                // The whole day as dots, filled up to now.
                HStack(spacing: 0) {
                    ForEach(Array(line.stops.enumerated()), id: \.offset) { i, s in
                        DayRail(phase: s.phase, fill: line.fill(after: i), axis: .horizontal).frame(height: 18)
                    }
                }
                .padding(.top, 4)
            } else {
                Text(empty).font(.subheadline.weight(.medium)).foregroundStyle(Palette.secondary).lineLimit(4)
            }
        }
        .privacySensitive()
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(card?.title ?? String(localized: line?.isTomorrow == true ? "Tomorrow" : "Today")).font(.headline).foregroundStyle(Palette.text).lineLimit(1)
                Meta(entry.dateLine)
                Spacer(minLength: 4)
                Meta(entry.age, color: Palette.tertiary)
            }
            if let line, !line.stops.isEmpty {
                DayLineAcross(line: line, valueSize: 26)
                if let note = line.notes.first {
                    Text([note.title, note.value, note.subtitle].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(note.tint?.color ?? Palette.secondary).lineLimit(1)
                }
            } else {
                Spacer(minLength: 0)
                Text(empty).font(.title3.weight(.medium)).foregroundStyle(Palette.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .opacity(entry.stale && entry.snapshot != nil ? 0.6 : 1)
        .privacySensitive()
    }

    /// "in 26 min · U6 07:36" for the next stop, "passed" once the day is over.
    private func detail(_ stop: DayTimeline.Stop, _ line: DayTimeline) -> String {
        let when = stop.phase == .next ? Format.countdown(minutes: line.minutesToNext ?? 0) : String(localized: "passed")
        return ([when] + [stop.item.subtitle].compactMap { $0 }).joined(separator: " · ")
    }

    /// The other stops in one line: "06:20 · 08:00".
    private func rest(_ line: DayTimeline) -> String {
        line.stops.filter { $0 != focus }.compactMap(\.item.value).joined(separator: " · ")
    }

    private var empty: String {
        if entry.redacted { return String(localized: "Open the app") }
        if entry.snapshot == nil { return String(localized: "Open Homelab to load your day.") }
        if let text = card?.text { return text }
        return String(localized: "Nothing planned today.")
    }
}

// MARK: - Hosts (medium, large)

struct HostsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HomelabHosts", provider: Provider()) { entry in
            HostsView(entry: entry)
                .containerBackground(for: .widget) { MoodGlow(level: entry.stale ? .unknown : entry.mood.level, reach: 300) }
                .widgetURL(URL(string: "homelab://lab"))
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
        let state = entry.state
        let mood = entry.mood
        let level = entry.stale ? TodayMood.Level.unknown : mood.level
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                StatusIcon(level: level)
                Text(mood.headline).font(.system(size: 20, weight: .heavy)).tracking(-0.5)
                    .foregroundStyle(Palette.text).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                Meta([entry.snapshot?.serverName ?? "Homelab", entry.age].filter { !$0.isEmpty }.joined(separator: " · "),
                     color: Palette.tertiary)
            }
            if entry.redacted, let hosts = state?.hosts, !hosts.isEmpty {
                // App lock on: no host names or numbers on the home screen, only how many are up.
                Spacer()
                Text("\(hosts.filter { $0.reachable == true }.count) of \(hosts.count) machines up")
                    .font(.title3.weight(.semibold))
                Meta(String(localized: "Open the app for details"))
            } else if let hosts = state?.hosts, !hosts.isEmpty {
                let limit = family == .systemLarge ? 8 : 4
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                          alignment: .leading, spacing: 8) {
                    ForEach(hosts.prefix(limit)) { HostCell(host: $0, health: state?.health(of: $0) ?? HostHealth($0)) }
                }
                .opacity(entry.stale ? 0.55 : 1)   // only the data dims; the age above stays readable
                if family == .systemLarge, let problems = state?.problems, !problems.isEmpty {
                    Rectangle().fill(Palette.line).frame(height: 1)
                    ForEach(problems.prefix(4)) { p in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: p.severity.symbol).font(.caption).foregroundStyle(p.severity.color)
                            Text(p.text).font(.footnote).foregroundStyle(Palette.text).lineLimit(1)
                        }
                        .privacySensitive()
                    }
                }
            } else {
                Spacer()
                Text(entry.snapshot == nil ? "Open Homelab to load your machines." : "No machines reported.")
                    .font(.footnote).foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct HostCell: View {
    let host: Host
    /// With the server's problems for this host.
    let health: HostHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(health.color).frame(width: 6, height: 6)
                Text(host.name).font(.footnote.weight(.semibold)).foregroundStyle(Palette.text).lineLimit(1)
            }
            if host.reachable == true {
                (Text("Load ") + Text(Format.load(host.load)).font(Typo.data(.caption2))
                    + Text(" · RAM ") + Text(Format.percent(host.memPct)).font(Typo.data(.caption2)))
                    .font(.caption2).foregroundStyle(Palette.secondary).lineLimit(1).minimumScaleFactor(0.8)
                if let d = Format.worstDisk(host.disks) { Meter(Double(d.percent) / 100, warns: true) }
            } else {
                Text(health.label).font(.caption2.weight(.semibold)).foregroundStyle(health.color)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
