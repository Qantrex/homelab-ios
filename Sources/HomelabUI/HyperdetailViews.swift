import HomelabDesign
import HomelabKit
import SwiftUI

// Hyperdetail's views (docs/DESIGN.md "Hyperdetail"). The decisions are in HomelabKit (`Hyper`); these only draw the
// result: rows of fields that wrap and are never cut, and the personality's remark next to the fact. Every other
// detail level has no `HyperContext` in the environment and draws exactly what it drew before.

private struct HyperKey: EnvironmentKey {
    static let defaultValue: HyperContext? = nil
}

extension EnvironmentValues {
    /// Set at the root while the detail is Hyperdetail; nil at every other level.
    var hyper: HyperContext? {
        get { self[HyperKey.self] }
        set { self[HyperKey.self] = newValue }
    }
}

/// The fields of one subject as quiet monospaced rows, "label  value", wrapping. Selectable, so a number can be copied.
struct HyperFields: View {
    let lines: [HyperLine]

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    (Text(line.label + "  ").foregroundColor(Palette.tertiary)
                     + Text(line.value).foregroundColor(Palette.secondary))
                        .font(Typo.data(.caption2))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The personality's remark on a fact. Nothing while the personality is Off or there is no fact.
struct HyperRemark: View {
    let fact: Hyper.Fact?
    @Environment(\.hyper) private var hyper
    /// Taps on it move to the next line, like Today's voice line.
    @State private var pokes = 0

    var body: some View {
        if let text = hyper?.remark(fact, variant: pokes) {
            Text(text)
                .font(Typo.secondary.italic())
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(text)
                .onTapGesture { pokes += 1 }
                .accessibilityAction(named: Text("Next comment")) { pokes += 1 }
        }
    }
}

/// A subject's fields and, with a personality, its remark. Draws nothing outside Hyperdetail.
struct HyperNote: View {
    let lines: [HyperLine]
    var fact: Hyper.Fact?
    @Environment(\.hyper) private var hyper

    var body: some View {
        if hyper != nil {
            VStack(alignment: .leading, spacing: 4) {
                HyperRemark(fact: fact)
                HyperFields(lines: lines)
            }
            .padding(.top, 4)
        }
    }
}

/// A titled block of fields, for the screens that have no row to hang them on (settings, the server).
struct HyperSection: View {
    let title: String
    let lines: [HyperLine]
    var fact: Hyper.Fact?
    @Environment(\.hyper) private var hyper

    var body: some View {
        if hyper != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Typo.meta.weight(.semibold)).foregroundStyle(Palette.tertiary)
                HyperRemark(fact: fact)
                HyperFields(lines: lines)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A card whose own layout has no row to hang a note on (the day): its fields, and each item's fields and remark.
struct HyperCardDump: View {
    let card: Card
    @Environment(\.hyper) private var hyper

    var body: some View {
        if let hyper {
            VStack(alignment: .leading, spacing: 8) {
                HyperNote(lines: Hyper.card(card, now: hyper.now, calendar: hyper.calendar), fact: Hyper.fact(card: card))
                ForEach(Array(card.items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title ?? item.value ?? "–").font(Typo.meta.weight(.semibold)).foregroundStyle(Palette.secondary)
                        HyperNote(lines: Hyper.item(item, now: hyper.now, calendar: hyper.calendar),
                                  fact: Hyper.fact(item: item, in: card, now: hyper.now, calendar: hyper.calendar))
                    }
                }
            }
        }
    }
}

// MARK: - The one-time warning

/// The one-time warning when the detail picker lands on Hyperdetail (`HyperdetailWarning`), like Ultrakill's: the pick is
/// undone at once and only applied by "Do it", which also remembers that the warning was seen; "Back" keeps the
/// previous level.
private struct HyperdetailWarningModifier: ViewModifier {
    @Bindable var model: AppModel
    @State private var previous: Density?
    @State private var asking = false

    func body(content: Content) -> some View {
        content
            .onAppear { previous = model.settings.todayDensity }
            .onChange(of: model.settings.todayDensity) { old, new in
                if new == .hyperdetail, model.settings.needsWarning(for: .hyperdetail) {
                    model.settings.todayDensity = previous ?? old
                    asking = true
                } else {
                    previous = new
                }
            }
            .alert(HyperdetailWarning.title, isPresented: $asking) {
                Button(HyperdetailWarning.back, role: .cancel) {}
                Button(HyperdetailWarning.enable) {
                    model.settings.confirmHyperdetail()
                    previous = .hyperdetail
                }
            } message: {
                Text(HyperdetailWarning.message)
            }
    }
}

extension View {
    /// Asks once before Hyperdetail is switched on from `model.settings.todayDensity`.
    func hyperdetailWarning(_ model: AppModel) -> some View { modifier(HyperdetailWarningModifier(model: model)) }
}
