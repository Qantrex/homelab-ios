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

/// `LabeledContent` puts label and value side by side; at the accessibility text sizes that breaks both into
/// words cut mid-word ("pi-uti- lity.-"). From those sizes on, the value goes under its label. Set once per window
/// (root, sheets, the share extension) with `.labeledContentStyle(.adaptive)`.
public struct AdaptiveLabeledContentStyle: LabeledContentStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { AdaptiveRow(configuration: configuration) }

    struct AdaptiveRow: View {
        let configuration: LabeledContentStyleConfiguration
        @Environment(\.dynamicTypeSize) private var typeSize

        var body: some View {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    configuration.label
                    configuration.content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            } else {
                // .automatic inside: this style would otherwise be applied to itself again.
                LabeledContent { configuration.content } label: { configuration.label }
                    .labeledContentStyle(.automatic)
            }
        }
    }
}

public extension LabeledContentStyle where Self == AdaptiveLabeledContentStyle {
    static var adaptive: AdaptiveLabeledContentStyle { AdaptiveLabeledContentStyle() }
}

/// `lineLimit(n)` at the standard text sizes, no limit at the accessibility sizes: there the text has the full width
/// and cutting it would hide the very words a large-text user came for.
struct StandardSizeLineLimit: ViewModifier {
    let lines: Int
    @Environment(\.dynamicTypeSize) private var typeSize
    func body(content: Content) -> some View { content.lineLimit(typeSize.isAccessibilitySize ? nil : lines) }
}

public extension View {
    func lineLimitAtStandardSizes(_ lines: Int) -> some View { modifier(StandardSizeLineLimit(lines: lines)) }
}
