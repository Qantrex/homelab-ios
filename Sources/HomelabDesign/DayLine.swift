import HomelabKit
import SwiftUI

// Today's mood colours and the day line, shared by the app (Today) and the widgets.

public extension TodayMood.Level {
    var color: Color {
        switch self {
        case .calm: Palette.text
        case .headsUp: Palette.gold
        case .alarm: Palette.love
        case .unknown: Palette.secondary
        }
    }
}

/// The light behind the headline: none when calm, a gold or love glow from the top when something is wrong. In the
/// app it's fixed to the screen, so the content scrolls over it; in a widget it's the background.
public struct MoodGlow: View {
    let level: TodayMood.Level
    let reach: CGFloat

    /// `reach`: how far the glow spreads (520 for a phone screen, less for a widget).
    public init(level: TodayMood.Level, reach: CGFloat = 520) {
        self.level = level
        self.reach = reach
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Palette.background
            // Loud when something is wrong, a faint white light when all is calm: the screen itself has a mood.
            let strength: Double = switch level {
            case .alarm: 0.38
            case .headsUp: 0.30
            case .calm: 0.07
            case .unknown: 0.04
            }
            let tint = level == .alarm || level == .headsUp ? level.color : Palette.text
            RadialGradient(colors: [tint.opacity(strength), tint.opacity(strength * 0.25), .clear],
                           center: UnitPoint(x: 0.15, y: -0.05), startRadius: 10, endRadius: reach)
                .frame(height: reach * 1.15)
                .transition(.opacity)
        }
        .motion(.easeInOut(duration: 0.8), value: level)
        .accessibilityHidden(true)
    }
}

/// The day's stops side by side: equal columns, each with its piece of the line on top and its time under it.
public struct DayLineAcross: View {
    let line: DayTimeline
    let valueSize: CGFloat?
    /// The quiet track under Today's "Leave by" statement: small times, no countdown or subtitle (they are in the
    /// statement above). The widget keeps the full labels.
    let compact: Bool
    /// Whole hours in tomorrow mode, for widgets that don't redraw every minute.
    let coarse: Bool
    /// The compact track's time: 15 pt at the default text size, scaled with the text around it.
    @ScaledMetric(relativeTo: .subheadline) private var compactValueSize: CGFloat = 15

    public init(line: DayTimeline, valueSize: CGFloat? = nil, compact: Bool = false, coarse: Bool = false) {
        self.line = line
        self.valueSize = valueSize
        self.compact = compact
        self.coarse = coarse
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(line.stops.enumerated()), id: \.offset) { i, stop in
                VStack(alignment: .leading, spacing: 10) {
                    DayRail(phase: stop.phase, fill: line.fill(after: i), axis: .horizontal)
                        .frame(height: 18)
                    DayStopLabel(stop: stop, countdown: compact ? nil : line.minutesToNext,
                                 valueSize: compact ? compactValueSize : valueSize, compact: compact,
                                 coarse: coarse && line.isTomorrow)
                        .padding(.trailing, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// One piece of the day line: the stop's dot and the stretch to the next stop, filled as far as now has come.
/// Past stops are grey dots, the next one is bright with a halo, later ones are rings.
public struct DayRail: View {
    let phase: DayTimeline.Phase
    let fill: Double
    let axis: Axis
    /// False for the last stop top to bottom: its piece would run into the notes under it.
    let showsLine: Bool

    public init(phase: DayTimeline.Phase, fill: Double, axis: Axis, showsLine: Bool = true) {
        self.phase = phase
        self.fill = fill
        self.axis = axis
        self.showsLine = showsLine
    }

    /// The dot's centre along the line. Its piece runs from here to the same point of the next stop's piece (which
    /// starts where this one ends), so the line runs dot centre to dot centre.
    static func start(_ axis: Axis) -> CGFloat { axis == .horizontal ? 6 : 9 }

    public var body: some View {
        GeometryReader { geo in
            let length = axis == .horizontal ? geo.size.width : geo.size.height
            let reached = length * fill
            let start = Self.start(axis)
            ZStack(alignment: axis == .horizontal ? .leading : .top) {
                if showsLine { bar(1, color: Palette.line, length: length).offset(along(start)) }
                if showsLine, reached > 0 { bar(2, color: Palette.text, length: reached).offset(along(start)) }
                if showsLine, fill > 0 && fill < 1 {
                    // Where "now" is.
                    Circle().fill(Palette.text).frame(width: 6, height: 6)
                        .frame(width: axis == .horizontal ? 6 : 12, height: axis == .horizontal ? 18 : 6)
                        .offset(along(start + reached - 3))
                }
                dot
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: axis == .horizontal ? .leading : .top)
        }
        .accessibilityHidden(true)
    }

    private func along(_ d: CGFloat) -> CGSize {
        axis == .horizontal ? CGSize(width: d, height: 0) : CGSize(width: 0, height: d)
    }

    /// The line itself, centred across the dot.
    private func bar(_ thickness: CGFloat, color: Color, length: CGFloat) -> some View {
        Rectangle().fill(color)
            .frame(width: axis == .horizontal ? length : thickness, height: axis == .horizontal ? thickness : length)
            .frame(width: axis == .horizontal ? nil : 12, height: axis == .horizontal ? 18 : nil)
    }

    @ViewBuilder
    private var dot: some View {
        ZStack {
            switch phase {
            case .past:
                Circle().fill(Palette.secondary).frame(width: 8, height: 8)
            case .next:
                Circle().fill(Palette.text.opacity(0.22)).frame(width: 20, height: 20)
                Circle().fill(Palette.text).frame(width: 11, height: 11)
            case .later:
                Circle().fill(Palette.background).frame(width: 10, height: 10)
                Circle().strokeBorder(Palette.secondary, lineWidth: 1.5).frame(width: 10, height: 10)
            }
        }
        .frame(width: 12, height: 18)
    }
}

/// A stop's big time, its name, the server's detail ("U6 07:36") and, on the next stop, the countdown.
public struct DayStopLabel: View {
    let stop: DayTimeline.Stop
    let countdown: Int?
    let valueSize: CGFloat?
    let compact: Bool
    let coarse: Bool

    public init(stop: DayTimeline.Stop, countdown: Int?, valueSize: CGFloat? = nil, compact: Bool = false,
                coarse: Bool = false) {
        self.stop = stop
        self.countdown = countdown
        self.valueSize = valueSize
        self.compact = compact
        self.coarse = coarse
    }

    private var valueColor: Color {
        switch stop.phase {
        case .past: Palette.tertiary
        case .next: stop.item.tint?.color ?? Palette.text
        case .later: stop.item.tint?.color ?? Palette.secondary
        }
    }

    /// What VoiceOver adds after the stop: "passed", "next" or nothing.
    private var phaseWord: Text {
        switch stop.phase {
        case .past: Text("passed")
        case .next: Text("next")
        case .later: Text("")
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(stop.item.value ?? "")
                .font(valueSize.map { Font.system(size: $0, weight: .semibold, design: .monospaced) } ?? Typo.displayData)
                .minimumScaleFactor(0.6).lineLimit(1)
                .foregroundStyle(valueColor)
                .contentTransition(Motion.numeric)
            Text(stop.item.title ?? "")
                .font((compact ? Font.footnote : .subheadline).weight(stop.phase == .next ? .semibold : .regular))
                .foregroundStyle(stop.phase == .past ? Palette.tertiary : stop.phase == .next ? Palette.text : Palette.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            if !compact, let s = stop.item.subtitle {
                Text(s).font(Typo.meta).foregroundStyle(Palette.tertiary).lineLimit(1).minimumScaleFactor(0.8)
            }
            if stop.phase == .next, let countdown {
                Text(DayTimeline.countdownText(minutes: countdown, coarse: coarse))
                    .font(.footnote.weight(.semibold)).foregroundStyle(Palette.text).lineLimit(1)
                    .accessibilityLabel(Format.spoken(DayTimeline.countdownText(minutes: countdown, coarse: coarse)))
            }
        }
        .motion(.snappy, value: stop)
        .accessibilityElement(children: .combine)
        .accessibilityValue(phaseWord)
    }
}
