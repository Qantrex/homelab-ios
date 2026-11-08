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

/// The small tiles of Today (deals, downloads, grades): icon and name, a big number, one short line. Laid out by count
/// (`TodayFold.tileRows`: 4 is 2 by 2, 3 one row of 3, 2 one row of 2, 1 full width; one per row at accessibility
/// sizes), so a row is never uneven. A tap opens the full list in a sheet; Today never grows.
struct TodayTiles: View {
    let tiles: [TodayFold.Tile]
    let density: Density
    let open: (TodayFold.Tile) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var rows: [[TodayFold.Tile]] {
        var rest = tiles[...]
        return TodayFold.tileRows(count: tiles.count, stacked: typeSize.isAccessibilitySize).map { n in
            defer { rest = rest.dropFirst(n) }
            return Array(rest.prefix(n))
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                // Equal heights in a row: every tile fills the tallest one.
                HStack(alignment: .top, spacing: 12) {
                    ForEach(row) { tile in TileButton(tile: tile, density: density) { open(tile) } }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// One tile: a button of at least 44 pt and one VoiceOver element ("Deals, 2, best minus 50 percent. Opens the list.").
/// No blue; a warm tint only while something in it needs me.
struct TileButton: View {
    let tile: TodayFold.Tile
    let density: Density
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    // Owner review 2026-11-09: the titles were hard to read in meta grey: secondary size, white, semibold.
                    Image(systemName: tile.kind.symbol).font(Typo.secondary)
                        .foregroundStyle(tile.urgent ? Palette.gold : Palette.text).accessibilityHidden(true)
                    Text(tile.kind.title).font(Typo.secondary.weight(.semibold)).foregroundStyle(Palette.text)
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
                Text(verbatim: String(tile.count)).font(Typo.data(.title, weight: .semibold)).foregroundStyle(Palette.text)
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text(verbatim: tile.line).font(Typo.secondary).foregroundStyle(Palette.secondary)
                    .lineLimitAtStandardSizes(density.atLeastOverkill ? 3 : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                if tile.urgent { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.gold.opacity(0.12)) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.press)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: tile.spoken))
        .accessibilityValue(tile.urgent ? Text("needs you") : Text(""))
        .accessibilityHint(Text("Opens the list"))
        .accessibilityAddTraits(.isButton)
    }
}

/// The full list of a tile, in a sheet: the title and Done; the content is the card's own rendering (or the deals).
struct TileSheet<Content: View>: View {
    let title: String
    /// An optional control at the top left (the News sheet's EN / DE switch).
    var leading: AnyView? = nil
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if let leading { ToolbarItem(placement: .cancellationAction) { leading } }
            }
        }
        .tint(Palette.accent)
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.background)
    }
}
