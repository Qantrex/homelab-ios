import HomelabDesign
import HomelabKit
import SwiftUI
import WidgetKit

/// Deadlines and to-dos (step 6c). With the app lock on they show counts only ("3 deadlines this week", "4 to-dos"),
/// never titles (`WidgetPolicy.redaction`); titles are also `privacySensitive`, so the system blanks them on a
/// locked phone's lock screen. Lock-screen families are one colour: urgency is always words or a symbol.
/// To-dos can't be ticked here: that needs App Intents, which xtool can't build. A tap opens Today.

private let todayURL = URL(string: "homelab://today")!

private func levelColor(_ level: Format.Level) -> Color {
    switch level {
    case .past: Palette.love
    case .soon: Palette.gold
    case .later: Palette.secondary
    }
}

// MARK: - Deadlines

struct DeadlinesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HomelabDeadlines", provider: Provider(follows: .deadlines)) { entry in
            DeadlinesView(entry: entry)
                .containerBackground(Palette.background, for: .widget)
                .widgetURL(todayURL)
        }
        .configurationDisplayName("Deadlines")
        .description("What is due next, counting down.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCircular, .systemSmall, .systemMedium])
    }
}

struct DeadlinesView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    private var countsOnly: Bool { WidgetPolicy.redaction(for: .deadlines, locked: entry.redacted) == .countsOnly }
    private var card: Card? { entry.state?.deadlinesCard }
    private var items: [Card.Item] { Deadlines.list(card) }
    private var week: Int { Deadlines.dueThisWeek(card, now: entry.date) }
    private var weekText: String { week == 1 ? String(localized: "1 deadline this week") : String(localized: "\(week) deadlines this week") }

    private func countdown(_ item: Card.Item) -> (text: String, level: Format.Level)? { item.countdown(now: entry.date) }

    var body: some View {
        switch family {
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        case .accessoryCircular: circular
        case .systemMedium: list(limit: 5, subtitles: true)
        default: list(limit: 3, subtitles: false)
        }
    }

    private var empty: String {
        entry.snapshot == nil ? String(localized: "Open the app") : String(localized: "No deadlines")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if countsOnly {
                Label("Deadlines", systemImage: "hourglass").font(.headline)
                Text(weekText).font(.caption)
            } else if items.isEmpty {
                Label("Deadlines", systemImage: "hourglass").font(.headline)
                Text(empty).font(.caption)
            } else {
                ForEach(Array(items.prefix(2).enumerated()), id: \.offset) { _, item in
                    if let cd = countdown(item) {
                        HStack(spacing: 4) {
                            if cd.level == .past {
                                Image(systemName: "exclamationmark.triangle.fill").font(.caption2).widgetAccentable()
                                    .accessibilityHidden(true)
                            }
                            Text(item.title ?? "").font(.headline).lineLimit(1).privacySensitive()
                            Spacer(minLength: 2)
                            Text(cd.text).font(Typo.data(.caption, weight: .semibold)).lineLimit(1)
                                .accessibilityLabel(Format.spoken(cd.text))
                        }
                    }
                }
                Text(weekText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var inline: some View {
        if countsOnly || items.isEmpty {
            Label(countsOnly ? weekText : empty, systemImage: "hourglass")
        } else if let item = items.first, let cd = countdown(item) {
            let text = cd.text == "today" || cd.text.hasSuffix("ago") ? "\(item.title ?? "") \(cd.text)" : "\(item.title ?? "") in \(cd.text)"
            Label(text, systemImage: cd.level == .past ? "exclamationmark.triangle.fill" : "hourglass").privacySensitive()
                .accessibilityLabel(Format.spoken(text))
        }
    }

    private var circular: some View {
        // Locked: the gauge shows only the count (a week's worth fills it), not how close the nearest one is.
        let value = countsOnly ? min(Double(week) / 7, 1) : Deadlines.urgency(card, now: entry.date)
        return Gauge(value: value) {
            Image(systemName: "hourglass")
        } currentValueLabel: {
            Text("\(week)").font(Typo.data(.title3, weight: .semibold))
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .accessibilityLabel(Text(weekText))
    }

    private func list(limit: Int, subtitles: Bool) -> some View {
        VStack(alignment: .leading, spacing: subtitles ? 8 : 6) {
            HStack(spacing: 6) {
                Image(systemName: "hourglass").font(.footnote.weight(.semibold)).foregroundStyle(Palette.secondary)
                Text("Deadlines").font(.footnote.weight(.semibold)).foregroundStyle(Palette.text)
                Spacer(minLength: 4)
                if entry.stale && entry.snapshot != nil { StaleAge(entry: entry) }
            }
            if countsOnly {
                Spacer(minLength: 0)
                Text(weekText).font(.title3.weight(.semibold)).foregroundStyle(Palette.text).lineLimit(2)
                Text("Open the app for details").font(.footnote).foregroundStyle(Palette.secondary)
            } else if items.isEmpty {
                Spacer(minLength: 0)
                Text(empty).font(.subheadline.weight(.medium)).foregroundStyle(Palette.secondary)
            } else {
                ForEach(Array(items.prefix(limit).enumerated()), id: \.offset) { _, item in
                    if let cd = countdown(item) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.title ?? "").font(subtitles ? .subheadline : .footnote).foregroundStyle(Palette.text)
                                    .lineLimit(1).privacySensitive()
                                if subtitles, let s = item.subtitle {
                                    Text(s).font(.caption2).foregroundStyle(Palette.tertiary).lineLimit(1).privacySensitive()
                                }
                            }
                            Spacer(minLength: 4)
                            Text(cd.text).font(Typo.data(.footnote, weight: .semibold)).foregroundStyle(levelColor(cd.level)).lineLimit(1)
                                .accessibilityLabel(Format.spoken(cd.text))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        // Stale data isn't dimmed (that took the words under 4.5:1): StaleAge in the corner says how old it is.
    }
}

// MARK: - To-dos

struct TodosWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HomelabTodos", provider: Provider()) { entry in
            TodosView(entry: entry)
                .containerBackground(Palette.background, for: .widget)
                .widgetURL(todayURL)
        }
        .configurationDisplayName("To-dos")
        .description("Your open to-dos. Tap to open Today.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .systemSmall, .systemMedium])
    }
}

struct TodosView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    private var countsOnly: Bool { WidgetPolicy.redaction(for: .todos, locked: entry.redacted) == .countsOnly }
    private var open: [Card.Item] { Todos.open(entry.state?.todosCard) }
    private var countText: String { open.count == 1 ? String(localized: "1 to-do") : String(localized: "\(open.count) to-dos") }

    var body: some View {
        switch family {
        case .accessoryRectangular: rectangular
        case .accessoryCircular: circular
        case .systemMedium: list(limit: 6, links: true)
        default: list(limit: 4, links: false)
        }
    }

    private var empty: String {
        entry.snapshot == nil ? String(localized: "Open the app") : String(localized: "Nothing open")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if countsOnly || open.isEmpty {
                Label("To-dos", systemImage: "checklist").font(.headline)
                Text(countsOnly ? countText : empty).font(.caption)
            } else {
                ForEach(Array(open.prefix(3).enumerated()), id: \.offset) { _, item in
                    Label(item.title ?? "", systemImage: "circle").font(.caption).lineLimit(1).privacySensitive()
                }
            }
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "checklist").font(.caption)
                Text("\(open.count)").font(Typo.data(.title3, weight: .bold))
            }
        }
        .accessibilityLabel(Text(countText))
    }

    private func list(limit: Int, links: Bool) -> some View {
        VStack(alignment: .leading, spacing: links ? 8 : 6) {
            HStack(spacing: 6) {
                Image(systemName: "checklist").font(.footnote.weight(.semibold)).foregroundStyle(Palette.secondary)
                Text("To-dos").font(.footnote.weight(.semibold)).foregroundStyle(Palette.text)
                Spacer(minLength: 4)
                if entry.stale && entry.snapshot != nil { StaleAge(entry: entry) }
            }
            if countsOnly {
                Spacer(minLength: 0)
                Text(countText).font(.title3.weight(.semibold)).foregroundStyle(Palette.text)
                Text("Open the app for details").font(.footnote).foregroundStyle(Palette.secondary)
            } else if open.isEmpty {
                Spacer(minLength: 0)
                Text(empty).font(.subheadline.weight(.medium)).foregroundStyle(Palette.secondary)
            } else {
                ForEach(Array(open.prefix(limit).enumerated()), id: \.offset) { _, item in
                    let row = HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "circle").font(.footnote).foregroundStyle(Palette.tertiary)
                        Text(item.title ?? "").font(links ? .subheadline : .footnote).foregroundStyle(Palette.text)
                            .lineLimit(1).privacySensitive()
                        Spacer(minLength: 0)
                    }
                    if links { Link(destination: todayURL) { row } } else { row }
                }
                if open.count > limit {
                    Text("and \(open.count - limit) more").font(.caption2).foregroundStyle(Palette.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
