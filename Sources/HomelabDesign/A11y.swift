import SwiftUI

// Small accessibility helpers (audit 2026-11-06). The Reduce Motion pair here is a stopgap for the screens outside
// the actions flow; it can be folded into `View.motion(_:value:)` / `Motion.numeric` later.

public extension View {
    /// `.animation(animation, value: value)`, but none with Reduce Motion on.
    func reducedMotionAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(ReducedMotionAnimation(animation: animation, value: value))
    }

    /// `.contentTransition(.numericText())` (rolling digits), a plain swap with Reduce Motion on.
    func reducedMotionNumericText() -> some View {
        modifier(ReducedMotionNumericText())
    }

    /// Today's hero font (`Typo.hero`): 48 heavy at the default text size, scaled like `.largeTitle`.
    func heroFont() -> some View {
        modifier(HeroFont())
    }
}

private struct ReducedMotionAnimation<V: Equatable>: ViewModifier {
    let animation: Animation?
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

private struct ReducedMotionNumericText: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.contentTransition(reduceMotion ? .identity : .numericText())
    }
}

private struct HeroFont: ViewModifier {
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 48

    func body(content: Content) -> some View {
        content.font(Typo.hero(size: size))
    }
}

/// Says `text` with VoiceOver (when it's on): "Sent", "3 results", "Can't reach the server".
@MainActor
public func announce(_ text: String) {
    AccessibilityNotification.Announcement(text).post()
}
