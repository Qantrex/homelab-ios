import HomelabDesign
import HomelabKit
import SwiftUI
import WidgetKit

/// Departures (step 6c): the next trains of the direction the server lists first. Lock-screen widgets draw in one
/// colour, so a delay or a disruption is always a symbol plus words (docs/DESIGN.md §3); gold only on the home
/// screen, as an addition. The times are public data, so the app lock does not hide them.
struct DeparturesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HomelabU6", provider: Provider(follows: .departures)) { entry in
            DeparturesView(entry: entry)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)   // grows with the text size, but fits the widget
                .containerBackground(Palette.background, for: .widget)
                .widgetURL(URL(string: "homelab://today"))
        }
        .configurationDisplayName(DepartureBoard.galleryName)
        .description(DepartureBoard.galleryDescription)
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCircular, .systemSmall])
    }
}

struct DeparturesView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    private var board: DepartureBoard? {
        entry.state?.departuresCard.map { DepartureBoard(card: $0).upcoming(now: entry.date) }
    }
    private var group: DepartureBoard.Group? { board?.groups.first }
    private var line: String { board?.line ?? CommutePlan.defaultLine }
    private var disrupted: Bool { board?.isDisrupted == true }
    /// The biggest delay among the shown trains.
    private var delay: Int? { group?.departures.prefix(3).compactMap(\.delay).max() }

    private func clock(_ d: DepartureBoard.Departure) -> String { DepartureBoard.clock(d.due) }

    var body: some View {
        switch family {
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        case .accessoryCircular: circular
        default: small
        }
    }

    private var empty: String {
        if entry.snapshot == nil { return entry.noData(String(localized: "Open the app")) }
        return entry.state?.departuresCard == nil ? String(localized: "No departures from this server")
                                                  : String(localized: "No departures soon")
    }

    // MARK: Lock screen

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let group {
                Text("\(line) \(group.towards)").font(.headline).lineLimit(1)
                Text(group.departures.prefix(3).map(clock).joined(separator: " · ")).font(Typo.data(.caption)).lineLimit(1)
                if disrupted {
                    Label { Text("Disruption") } icon: { Image(systemName: "exclamationmark.triangle.fill").widgetAccentable() }
                        .font(.caption2).lineLimit(1)
                } else if let delay {
                    Label { Text("Delay +\(delay) min") } icon: { Image(systemName: "clock.badge.exclamationmark").widgetAccentable() }
                        .font(.caption2).lineLimit(1)
                        .accessibilityLabel(Text("Delay, \(Format.spokenDelay(minutes: delay))"))
                } else {
                    Text(group.stop ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text(line).font(.headline)
                Text(empty).font(.caption).lineLimit(2)
                if disrupted {
                    Label { Text("Disruption") } icon: { Image(systemName: "exclamationmark.triangle.fill").widgetAccentable() }
                        .font(.caption2)
                }
            }
        }
    }

    @ViewBuilder
    private var inline: some View {
        if let group {
            let times = group.departures.prefix(2).map(clock).joined(separator: " · ")
            if disrupted {
                Label("\(line) disruption · \(times)", systemImage: "exclamationmark.triangle.fill")
            } else {
                Label("\(line) \(times)", systemImage: "tram.fill")
            }
        } else {
            Label("\(line) \(empty)", systemImage: disrupted ? "exclamationmark.triangle.fill" : "tram.fill")
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let next = group?.departures.first {
                // Counts down to the next train by itself, and starts over at the next entry (each departure).
                ProgressView(timerInterval: entry.date...next.due, countsDown: true) {
                    EmptyView()
                } currentValueLabel: {
                    VStack(spacing: 0) {
                        if disrupted { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).widgetAccentable() }
                        Text(timerInterval: entry.date...next.due, countsDown: true, showsHours: false)
                            .font(Typo.data(.caption2, weight: .semibold)).multilineTextAlignment(.center)
                    }
                }
                .progressViewStyle(.circular)
            } else {
                VStack(spacing: 0) {
                    Image(systemName: disrupted ? "exclamationmark.triangle.fill" : "tram.fill").font(.title3).widgetAccentable()
                    Text(line).font(.caption2.weight(.bold))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(circularLabel))
    }

    /// "U6 07:31, 3 minutes late, disruption": the ring shows the disruption as a glyph only.
    private var circularLabel: String {
        var parts = [group?.departures.first.map { "\(line) \(clock($0))" } ?? "\(line) \(empty)"]
        if let next = group?.departures.first, next.late { parts.append(Format.spokenDelay(minutes: next.delay)) }
        if disrupted { parts.append(String(localized: "disruption")) }
        return parts.joined(separator: ", ")
    }

    // MARK: Home screen, StandBy

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "tram.fill").font(.footnote.weight(.semibold)).foregroundStyle(Palette.secondary)
                    .widgetAccentable().accessibilityHidden(true)
                Text(line).font(.footnote.weight(.semibold)).foregroundStyle(Palette.text)
                Spacer(minLength: 4)
                if entry.stale && entry.snapshot != nil { StaleAge(entry: entry) }
            }
            if let group {
                Text("\(group.towards)").font(.footnote.weight(.medium)).foregroundStyle(Palette.text).lineLimit(1)
                Text(group.stop ?? "").font(.caption2).foregroundStyle(Palette.secondary).lineLimit(1)
                ForEach(Array(group.departures.prefix(3).enumerated()), id: \.offset) { i, d in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(clock(d)).font(Typo.data(.title3, weight: i == 0 ? .semibold : .regular))
                            .foregroundStyle(i == 0 ? Palette.text : Palette.secondary)
                        if d.late {
                            Text(d.delay.map { "+\($0)" } ?? String(localized: "late"))
                                .font(Typo.data(.caption, weight: .semibold)).foregroundStyle(Palette.gold)
                                .accessibilityLabel(Format.spokenDelay(minutes: d.delay))
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } else {
                Spacer(minLength: 0)
                Text(empty).font(.subheadline.weight(.medium)).foregroundStyle(Palette.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
            if let text = board?.disruption {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.gold).widgetAccentable()
                        .accessibilityLabel(Text("Disruption"))
                    Text(text).foregroundStyle(Palette.text).lineLimit(2)
                }
                .font(.caption2)
                .accessibilityElement(children: .combine)
            }
        }
        // Stale data isn't dimmed (that took the words under 4.5:1): StaleAge in the corner says how old it is.
    }
}
