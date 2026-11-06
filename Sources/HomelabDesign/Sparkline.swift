import HomelabKit
import SwiftUI

/// A small line of the last values (a host's 24 h load, RAM, temperature or disk). The line is grey; only the dot on the
/// newest value turns gold or love, when that value is over `warning` or `problem`. Gaps (no data) break the
/// line. The shape comes from `SparklineShape` (HomelabKit, tested); this view only draws it.
public struct Sparkline: View {
    let shape: SparklineShape
    let tint: Color
    let lineWidth: CGFloat
    let fill: Bool
    let label: String
    let value: String

    /// A ready shape. The dot is gold or love only by `tintValue` (nil: plain), so an hours-old value doesn't colour
    /// it; VoiceOver says "now" only for that value too. `label` is what VoiceOver says first ("Load, last 24 hours"),
    /// followed by min, max and now in `format`.
    public init(shape: SparklineShape, tintValue: Double?, warning: Double? = nil, problem: Double? = nil, label: String,
                lineWidth: CGFloat = 1.5, fill: Bool = true, format: (Double) -> String = { String(format: "%.1f", $0) }) {
        self.shape = shape
        self.lineWidth = lineWidth
        self.fill = fill
        self.label = label
        if let v = tintValue, let problem, v >= problem {
            tint = Palette.love
        } else if let v = tintValue, let warning, v >= warning {
            tint = Palette.gold
        } else {
            tint = Palette.secondary   // quiet: colour is for status
        }
        if let lo = shape.min, let hi = shape.max, let now = tintValue {
            value = String(localized: "minimum \(format(lo)), maximum \(format(hi)), now \(format(now))")
        } else if let lo = shape.min, let hi = shape.max {
            value = String(localized: "minimum \(format(lo)), maximum \(format(hi)), no current value")
        } else {
            value = String(localized: "no data")
        }
    }

    public var body: some View {
        GeometryReader { geo in
            // Room for the dot at the edges, so it isn't clipped.
            let inset = lineWidth * 1.5 + 1
            let frame = CGRect(x: inset, y: inset, width: max(geo.size.width - inset * 2, 1),
                               height: max(geo.size.height - inset * 2, 1))
            ZStack(alignment: .topLeading) {
                if fill {
                    area(in: frame).fill(LinearGradient(colors: [Palette.secondary.opacity(0.12), Palette.secondary.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                }
                line(in: frame).stroke(Palette.secondary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                if let p = shape.last {
                    let dot = lineWidth * 2 + 2
                    Circle().fill(tint)
                        .frame(width: dot, height: dot)
                        .position(position(p, in: frame))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value))
    }

    private func position(_ p: SparklineShape.Point, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + p.x * frame.width, y: frame.maxY - p.y * frame.height)
    }

    private func line(in frame: CGRect) -> Path {
        Path { path in
            for run in shape.runs {
                guard let first = run.first else { continue }
                path.move(to: position(first, in: frame))
                // A lone point between gaps: a short dash, so it still shows.
                if run.count == 1 {
                    path.addLine(to: position(first, in: frame).applying(.init(translationX: 0.01, y: 0)))
                }
                for p in run.dropFirst() { path.addLine(to: position(p, in: frame)) }
            }
        }
    }

    private func area(in frame: CGRect) -> Path {
        Path { path in
            for run in shape.runs where run.count > 1 {
                guard let first = run.first, let last = run.last else { continue }
                path.move(to: CGPoint(x: position(first, in: frame).x, y: frame.maxY))
                for p in run { path.addLine(to: position(p, in: frame)) }
                path.addLine(to: CGPoint(x: position(last, in: frame).x, y: frame.maxY))
                path.closeSubpath()
            }
        }
    }
}

public extension Sparkline {
    /// One series of a host's history on a 24 h time axis ending `now`, with that series' scale, limits and number
    /// format. Coloured only by a recent last value (`HostHistory.recentLast`).
    init(_ history: HostHistory, _ series: HostHistory.Series, cores: Int?, label: String, now: Date = Date(),
         lineWidth: CGFloat = 1.5, fill: Bool = true) {
        let limits = series.limits(cores: cores)
        self.init(shape: history.shape(series, now: now), tintValue: history.recentLast(series, now: now),
                  warning: limits.warning, problem: limits.problem, label: label, lineWidth: lineWidth, fill: fill,
                  format: series.format)
    }
}
