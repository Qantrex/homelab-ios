import HomelabKit
import SwiftUI

/// The lab's face: a tiny terminal monitor with an ASCII face that reacts to how the lab is doing (CARROT Weather's
/// idea of a character that has opinions about the facts; the look is ours: monochrome, mono type, status colours
/// only). Blinks now and then (not with Reduce Motion), bounces when tapped.
public struct Mascot: View {
    public enum Face: Sendable, Equatable {
        case calm, headsUp, alarm, unknown, checking, smug, furious

        var eyes: (String, String) {
            switch self {
            case .calm: ("^", "^")
            case .headsUp: ("o", "O")
            case .alarm: ("x", "x")
            case .unknown: ("-", "-")
            case .checking: ("·", "·")
            case .smug: ("¬", "¬")
            case .furious: ("ò", "ó")
            }
        }

        var mouth: String {
            switch self {
            case .calm: "‿"
            case .headsUp, .checking: "_"
            case .alarm: "﹏"
            case .unknown: "_"
            case .smug: "‿"
            case .furious: "益"
            }
        }

        /// Faces that keep their eyes shut or crossed don't blink.
        var blinks: Bool { ![.alarm, .unknown, .furious].contains(self) }
    }

    let face: Face
    let tint: Color
    let size: CGFloat
    /// Counts taps: each change makes it jump.
    let pokes: Int
    @State private var blinking = false
    @State private var bounced = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(face: Face, tint: Color, size: CGFloat = 64, pokes: Int = 0) {
        self.face = face
        self.tint = tint
        self.size = size
        self.pokes = pokes
    }

    /// The face for a mood and personality: the rude personalities pull ruder faces.
    public static func face(for level: TodayMood.Level, checking: Bool = false, personality: Personality) -> Face {
        switch level {
        case .calm: personality == .off || personality == .dry ? .calm : .smug
        case .headsUp: .headsUp
        case .alarm: personality.rawValue == "ultrakill" ? .furious : .alarm
        case .unknown: checking ? .checking : .unknown
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                    .fill(Palette.background)
                RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                    .strokeBorder(tint.opacity(0.9), lineWidth: max(1.5, size * 0.03))
                Text(faceText)
                    .font(.system(size: size * 0.3, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, size * 0.08)
                    .contentTransition(.opacity)
            }
            .frame(width: size, height: size * 0.78)
            // The stand.
            Rectangle().fill(tint.opacity(0.9)).frame(width: size * 0.12, height: size * 0.08)
            Capsule().fill(tint.opacity(0.9)).frame(width: size * 0.42, height: max(2, size * 0.05))
        }
        .shadow(color: tint.opacity(face == .alarm || face == .furious ? 0.55 : 0.25), radius: size * 0.18)
        .rotationEffect(.degrees(bounced && !reduceMotion ? (face == .furious ? 8 : -6) : 0))
        .offset(y: bounced && !reduceMotion ? -6 : 0)
        .animation(.spring(response: 0.22, dampingFraction: 0.4), value: bounced)
        .animation(.easeInOut(duration: 0.3), value: face)
        .task(id: face) { await blinkLoop() }
        .onChange(of: pokes) {
            bounced = true
            Task { try? await Task.sleep(for: .milliseconds(160)); bounced = false }
        }
        .accessibilityHidden(true)
    }

    private var faceText: String {
        let (l, r) = blinking ? ("-", "-") : face.eyes
        return "\(l)\(face.mouth)\(r)"
    }

    private func blinkLoop() async {
        guard face.blinks, !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 3.0...6.0)))
            blinking = true
            try? await Task.sleep(for: .milliseconds(140))
            blinking = false
        }
    }
}

/// What the mascot says: a speech bubble with a little tail on the left, pointing at the mascot.
public struct SpeechBubble: View {
    let text: String
    let tint: Color

    public init(_ text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text)
            .font(.system(.title3, design: .default, weight: .semibold))
            .foregroundStyle(Palette.text)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BubbleShape().fill(Palette.surface))
            .overlay(BubbleShape().stroke(tint.opacity(0.55), lineWidth: 1.2))
            .contentTransition(.opacity)
    }
}

/// A rounded rectangle with a small tail on the left edge, a third of the way down.
struct BubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 16, tail: CGFloat = 9
        let body = rect.insetBy(dx: 0, dy: 0)
        var p = Path(roundedRect: CGRect(x: body.minX + tail, y: body.minY, width: body.width - tail, height: body.height),
                     cornerRadius: r, style: .continuous)
        let y = min(body.minY + 26, body.midY)
        var t = Path()
        t.move(to: CGPoint(x: body.minX + tail + 1, y: y - 7))
        t.addLine(to: CGPoint(x: body.minX, y: y + 2))
        t.addLine(to: CGPoint(x: body.minX + tail + 1, y: y + 7))
        p.addPath(t)
        return p
    }
}
