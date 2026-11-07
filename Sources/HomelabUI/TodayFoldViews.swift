import HomelabDesign
import HomelabKit
import SwiftUI

/// What a card on Today needs to fold: the density, whether this card is expanded, and the toggle (TodayView keeps the
/// session-only set of expanded ids). Without one a card draws all its rows (Lab, chat bubbles).
struct TodayFoldContext {
    var density: Density
    var expanded: Bool
    var toggle: () -> Void
}

/// The fold row of a list on Today: "Show 8 more · next Fri" / "Show less", the panel's full width, at least 44 pt
/// (it grows with the text size). One VoiceOver button that says what is folded and its state.
struct FoldRow: View {
    let title: String
    let label: String
    let hidden: Int
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Text(verbatim: label).font(Typo.secondary).foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(Typo.meta.weight(.semibold)).foregroundStyle(Palette.tertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 1))
        // The panel pads its content by 16: the row reaches both edges, so the whole width is the target.
        .padding(.horizontal, -16)
        .accessibilityLabel(Text(expanded ? "\(title), expanded" : "\(title), \(hidden) more, collapsed"))
        .accessibilityHint(expanded ? Text("Shows fewer rows") : Text("Shows all rows"))
        .accessibilityAddTraits(.isButton)
    }
}

/// A text card (the briefing) cut to a few lines with a fade and a fold row that says how many lines it hides.
struct FoldedText: View {
    let text: AttributedString
    let title: String
    let fold: TodayFoldContext
    var font: Font = Typo.body
    @State private var fullHeight: CGFloat = 0
    /// One body line, so "fold after N lines" holds at every text size.
    @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = 22

    private var limit: Int { TodayFold.textLines(fold.density) }
    private var lines: Int { ChatFold.lines(height: Double(fullHeight), lineHeight: Double(lineHeight)) }
    private var folds: Bool { TodayFold.textFolds(lines: lines, limit: limit) }
    private var folded: Bool { folds && !fold.expanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(font).tint(Palette.iris)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                .frame(height: folded ? CGFloat(limit) * lineHeight : nil, alignment: .top)
                .clipped()
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0),
                                           .init(color: .black, location: folded ? 0.7 : 1),
                                           .init(color: folded ? .clear : .black, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            if folds {
                FoldRow(title: title, label: fold.expanded ? String(localized: "Show less")
                                                           : String(localized: "Show \(max(lines - limit, 1)) more lines"),
                        hidden: max(lines - limit, 1), expanded: fold.expanded, toggle: fold.toggle)
            }
        }
    }
}

/// A card that is one line ("Minecraft: Vicky playing"): grey text with the card's icon, no panel, never expands.
struct OneLineCard: View {
    let card: Card
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Symbols.safe(card.icon, fallback: "circle")).font(Typo.secondary)
                .foregroundStyle(Palette.secondary).accessibilityHidden(true)
            Text(text).font(Typo.secondary).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

/// One row of the "Also" panel.
struct AlsoItem: Identifiable {
    let kind: TodayFold.AlsoKind
    let summary: String
    /// How many things the summary counts (for VoiceOver); nil when it does not count.
    let count: Int?
    let content: AnyView
    var id: String { "also:" + kind.rawValue }
}

/// "Also": deals, recent downloads, new grades and departures as one-line summaries in one quiet panel. A tap opens a
/// row in place (session-only, TodayView's set). Each row is one VoiceOver element.
struct AlsoPanel: View {
    let items: [AlsoItem]
    let density: Density
    let expanded: Set<String>
    let toggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.titleToPanel) {
            SectionTitle(text: "Also")
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { TodaySeparator() }
                    row(item)
                }
            }
            .rowsPanel()
            .rowMotion(expanded)
        }
    }

    private func row(_ item: AlsoItem) -> some View {
        let open = expanded.contains(item.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button { toggle(item.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: item.kind.symbol).font(Typo.secondary).foregroundStyle(Palette.secondary)
                        .frame(width: 22).accessibilityHidden(true)
                    Text(verbatim: item.summary).font(Typo.secondary).foregroundStyle(Palette.text)
                        .lineLimitAtStandardSizes(density == .overkill ? 3 : 2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down").font(Typo.meta.weight(.semibold)).foregroundStyle(Palette.tertiary)
                        .rotationEffect(.degrees(open ? 180 : 0)).accessibilityHidden(true)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: TodayFold.spokenAlso(item.kind, count: item.count, summary: item.summary)))
            .accessibilityValue(open ? Text("expanded") : Text("collapsed"))
            .accessibilityHint(open ? Text("Double-tap to collapse") : Text("Double-tap to expand"))
            .accessibilityAddTraits(.isButton)
            if open {
                item.content
                    .padding(.horizontal, 16).padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
    }
}
