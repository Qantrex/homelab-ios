import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Motion in one place (research #10), for the app and the widget. Views say what happened ("rows changed", "a number
// changed"); how that moves is decided here, and Reduce Motion is respected here, so no view has to remember it:
// animations become nil, number and symbol transitions become `.identity`.

public enum Motion {
    /// Rows coming and going: a short spring that settles without bouncing.
    public static let rows = Animation.spring(response: 0.35, dampingFraction: 0.85)
    /// A number changing in place.
    public static let number = Animation.snappy

    /// Reduce Motion is on. Views that can read the environment use `motion(_:value:)`, which reads
    /// `accessibilityReduceMotion`; this is for the content transitions below, which are values, not modifiers.
    @MainActor public static var reduced: Bool {
        #if canImport(UIKit)
        UIAccessibility.isReduceMotionEnabled
        #else
        false
        #endif
    }

    /// Rolling digits for a number that changes (`.contentTransition(Motion.numeric)`); none with Reduce Motion.
    @MainActor public static var numeric: ContentTransition { reduced ? .identity : .numericText() }

    /// A symbol that swaps (a circle that becomes a check mark); none with Reduce Motion.
    @MainActor public static var symbol: ContentTransition { reduced ? .identity : .symbolEffect(.replace) }
}

public extension View {
    /// `animation(_:value:)` that is nil with Reduce Motion. Use it for every animation in the app.
    func motion<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(ReducibleAnimation(animation: animation, value: value))
    }

    /// Rows inserted into or removed from a list spring into place when `value` (their ids) changes.
    func rowMotion<V: Equatable>(_ value: V) -> some View {
        motion(Motion.rows, value: value)
    }

    /// A number or short value that changes in place: its digits roll (`Motion.numeric`).
    func numberMotion<V: Equatable>(_ value: V) -> some View {
        contentTransition(Motion.numeric).motion(Motion.number, value: value)
    }
}

private struct ReducibleAnimation<V: Equatable>: ViewModifier {
    let animation: Animation?
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}
