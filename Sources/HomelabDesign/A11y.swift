import SwiftUI

// Small accessibility helpers (audit 2026-11-06). Reduce Motion lives in Motion.swift (`motion(_:value:)`,
// `numberMotion`, `Motion.numeric`).

public extension View {
    /// Today's hero font (`Typo.hero`): 48 heavy at the default text size, scaled like `.largeTitle`.
    func heroFont() -> some View {
        modifier(HeroFont())
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
