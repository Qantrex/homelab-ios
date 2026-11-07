import HomelabDesign
import HomelabKit
import SwiftUI
import UIKit

/// Deals (optional endpoint `GET /deals`, feature `deals`): used-market ads the server found clearly below their
/// market value and judged. A sheet from the Actions tab's Start grid, `homelab://deals` and Today's card. A list
/// grouped by the server's verdict (Act now first), a deal opens its detail with the comparable ads. The server's
/// warnings ("too good to be true?") are gold, never love: they say "look twice", not "broken".
struct DealsView: View {
    let model: AppModel
    let server: ServerConfig
    @State private var failure: APIError?
    @State private var loading = false
    @State private var path: [Deal] = []
    @Environment(\.dismiss) private var dismiss

    private var list: DealList? { model.selectedStatus.deals }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.section) {
                    if let failure {
                        ErrorBanner(error: failure, snapshotAge: nil) { Task { await reload() } }
                    }
                    content
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .screenBackground()
            .refreshable { await reload() }
            .navigationTitle("Deals")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Deal.self) { DealDetailView(deal: $0, model: model) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { if loading { ProgressView() } }
            }
            .task {
                await reload()
                if model.openDealDetail, let first = list?.ordered.first {
                    model.openDealDetail = false
                    path = [first]
                }
            }
        }
        .tint(Palette.accent)
        .labeledContentStyle(.adaptive)
    }

    @ViewBuilder private var content: some View {
        if let list {
            if list.deals.isEmpty {
                Placeholder(title: "No deals right now", symbol: "tag", message: LocalizedStringKey(emptyText))
                    .padding(.top, 40)
            } else {
                Text(summary(list)).font(Typo.secondary).foregroundStyle(Palette.secondary)
                ForEach(list.groups, id: \.group) { group in
                    VStack(alignment: .leading, spacing: Space.titleToPanel) {
                        SectionTitle(text: LocalizedStringKey(group.group.title), trailing: "\(group.deals.count)")
                        VStack(spacing: 0) {
                            ForEach(Array(group.deals.enumerated()), id: \.element.id) { i, deal in
                                if i > 0 { Divider().overlay(Palette.line).padding(.leading, 16) }
                                NavigationLink(value: deal) { DealRow(deal: deal) }
                                    .buttonStyle(.press)
                            }
                        }
                        .rowsPanel()
                    }
                }
            }
        } else if failure == nil {
            // The server stopped having deals while the screen was open (or the first answer is on its way).
            if model.selectedStatus.dealsFetched == nil {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
            } else {
                Placeholder(title: "No deals here", symbol: "tag", message: "This server doesn't offer deals.")
                    .padding(.top, 40)
            }
        }
    }

    private var emptyText: String {
        (Voice.line(for: .empty(.deals), personality: model.settings.voice).map { $0 + " " } ?? "")
            + String(localized: "The server looks every hour. Strong ones are pushed to you.")
    }

    /// "5 deals · 2 to act on · updated 4 min ago": the facts, the voice has no say here.
    private func summary(_ list: DealList) -> String {
        var parts = [list.deals.count == 1 ? String(localized: "1 deal") : String(localized: "\(list.deals.count) deals")]
        if list.actCount > 0 { parts.append(String(localized: "\(list.actCount) to act on")) }
        if let updated = list.updated { parts.append(String(localized: "updated \(Format.age(updated))")) }
        return parts.joined(separator: " · ")
    }

    private func reload() async {
        loading = true
        failure = await model.reloadDeals(on: server)
        loading = false
        if let list, failure == nil {
            let n = list.actCount
            announce(n == 0 ? String(localized: "Deals updated") : String(localized: "Deals updated, \(n) to act on"))
        }
    }
}

/// The numbers of a deal at the right of a row: the asking price (15 medium, fixed-width digits), then how far below
/// the value ("−50 %"), then the value. At accessibility sizes the row puts this under the title.
struct DealFigures: View {
    let deal: Deal
    var leading = false

    var body: some View {
        VStack(alignment: leading ? .leading : .trailing, spacing: 2) {
            if let price = deal.price {
                Text(DealFormat.price(price)).font(Typo.rowValue).foregroundStyle(Palette.text)
            }
            if let off = DealFormat.discount(deal.share) {
                Text(off).font(Typo.data(.subheadline, weight: .medium)).foregroundStyle(Palette.text)
                    .accessibilityLabel(DealFormat.spokenDiscount(deal.share) ?? off)
            }
            if let value = deal.value {
                Text(String(localized: "worth \(DealFormat.price(value))")).font(Typo.meta).foregroundStyle(Palette.tertiary)
            }
        }
        .numberMotion(deal.price ?? 0)
    }
}

/// Row grammar (docs/DESIGN.md §6): the name (17 semibold), what explains it (15 secondary), meta (13 tertiary) and
/// the numbers in the right column. The only colour is the warning glyph, in gold, with the server's own words.
struct DealRow: View {
    let deal: Deal
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(deal.title).font(Typo.headline).foregroundStyle(Palette.text).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let specs = deal.specs {
                        Text(specs).font(Typo.secondary).foregroundStyle(Palette.secondary).lineLimit(2)
                    }
                    DealFacts(deal: deal)
                }
                Spacer(minLength: 8)
                if !stacked { DealFigures(deal: deal) }
            }
            if stacked { DealFigures(deal: deal, leading: true) }
            if let note = deal.note {
                Text(note).font(Typo.secondary).foregroundStyle(Palette.secondary).lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            if !deal.flags.isEmpty { DealFlags(flags: deal.flags, limit: 2) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(deal.spoken)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Shows the comparable ads and opens the ad."))
    }
}

/// The meta line: where (with a marker when it is in the pickup area), who sells, shipping, condition, the server's
/// confidence in the value. Words, no colour; "low" confidence is gold with its word.
struct DealFacts: View {
    let deal: Deal

    var body: some View {
        // One flowing line of short facts. A plain Text keeps it wrapping like a sentence at any text size.
        facts
            .font(Typo.meta).foregroundStyle(Palette.tertiary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var facts: Text {
        var parts: [Text] = []
        if let place = deal.place {
            parts.append(deal.near ? Text(Image(systemName: "location.fill")) + Text(" ") + Text(place) : Text(place))
        }
        if let seller = deal.sellerWord { parts.append(Text(LocalizedStringKey(seller))) }
        if deal.ships == true { parts.append(Text("ships")) }
        if let cond = deal.condition { parts.append(Text(verbatim: cond)) }
        if let c = deal.confidence {
            let word = Text(String(localized: "\(c.word) confidence"))
            parts.append(c == .low ? word.foregroundStyle(Palette.gold) : word)
        }
        guard var out = parts.first else { return Text(verbatim: "") }
        for part in parts.dropFirst() { out = out + Text(verbatim: " · ") + part }
        return out
    }
}

/// The server's warnings, each with a gold triangle and its words (never colour alone). `limit` cuts a row's list to
/// the first few ("and 2 more"); the detail shows all.
struct DealFlags: View {
    let flags: [String]
    var limit: Int?

    var body: some View {
        let shown = limit.map { Array(flags.prefix($0)) } ?? flags
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, flag in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(Typo.meta).foregroundStyle(Palette.gold)
                        .accessibilityHidden(true)
                    Text(flag).font(Typo.secondary).foregroundStyle(Palette.gold)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let limit, flags.count > limit {
                Text("and \(flags.count - limit) more").font(Typo.meta).foregroundStyle(Palette.tertiary)
            }
        }
    }
}

/// One deal: the figures, the buttons (open the ad, copy its link), the server's judgement, the warnings, the facts
/// and the comparable ads behind the market value.
struct DealDetailView: View {
    let deal: Deal
    let model: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                header
                if !deal.flags.isEmpty { warnings }
                facts
                if !deal.comps.isEmpty { comps }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .screenBackground()
        .navigationTitle("Deal")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: copied) { _, now in now }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(deal.title).font(Typo.sectionTitle).foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let price = deal.price {
                    Text(DealFormat.price(price)).font(Typo.displayData).foregroundStyle(Palette.text)
                }
                if let off = DealFormat.discount(deal.share) {
                    Text(off).font(Typo.data(.title3, weight: .semibold)).foregroundStyle(Palette.text)
                        .accessibilityLabel(DealFormat.spokenDiscount(deal.share) ?? off)
                }
            }
            if let value = deal.value {
                Text(String(localized: "The server puts the market value at about \(DealFormat.price(value)).")).font(Typo.secondary)
                    .foregroundStyle(Palette.secondary)
            }
            if let verdict = deal.verdict {
                Text(verdictLine(verdict)).font(Typo.body).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = deal.note {
                Text(note).font(Typo.body).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
    }

    /// "Act now." / "Worth a look." / "Skipped by the server."
    private func verdictLine(_ v: Deal.Verdict) -> String {
        switch v {
        case .act: String(localized: "Act now.")
        case .consider: String(localized: "Worth a look.")
        case .skip: String(localized: "The server skipped this one.")
        }
    }

    @ViewBuilder private var buttons: some View {
        if let url = deal.url {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                                       : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Button { openURL(url) } label: { Label("Open the ad", systemImage: "arrow.up.right.square") }
                    .buttonStyle(CapsuleButtonStyle(kind: .filled))
                    .accessibilityHint(Text("Opens willhaben or Safari."))
                Button {
                    UIPasteboardBridge.copy(url.absoluteString)
                    copied = true
                    announce(String(localized: "Link copied"))
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(CapsuleButtonStyle(kind: .raised))
            }
            .padding(.top, 4)
        }
    }

    private var warnings: some View {
        VStack(alignment: .leading, spacing: Space.titleToPanel) {
            SectionTitle(text: "Look twice", trailing: "\(deal.flags.count)")
            DealFlags(flags: deal.flags).panel()
        }
    }

    private var facts: some View {
        let rows: [(String, String)] = [
            (String(localized: "Where"), deal.place.map { deal.near ? String(localized: "\($0), near you") : $0 }),
            (String(localized: "Seller"), deal.sellerWord.map { $0 == "private" ? String(localized: "Private") : String(localized: "Dealer") }),
            (String(localized: "Shipping"), deal.ships.map { $0 ? String(localized: "Ships") : String(localized: "Pickup only") }),
            (String(localized: "Condition"), deal.conditionWord),
            (String(localized: "Details"), deal.specs),
            (String(localized: "Value is"), deal.confidence.map { String(localized: "\($0.word) confidence") }),
            (String(localized: "Found"), deal.seen.map { Format.age($0) }),
            (String(localized: "Search"), deal.watch),
        ].compactMap { label, value in value.map { (label, $0) } }
        return VStack(alignment: .leading, spacing: Space.titleToPanel) {
            SectionTitle(text: "About the ad")
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Divider().overlay(Palette.line).padding(.leading, 16) }
                    fact(row.0, row.1, tone: row.0 == String(localized: "Value is") && deal.confidence == .low ? Palette.gold : Palette.text)
                }
            }
            .rowsPanel()
        }
    }

    /// A label and its value; side by side, or the value under the label at accessibility sizes.
    @ViewBuilder private func fact(_ label: String, _ value: String, tone: Color) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                                                   : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            Text(label).font(Typo.secondary).foregroundStyle(Palette.secondary)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Text(value).font(Typo.secondary).foregroundStyle(tone)
                .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var comps: some View {
        VStack(alignment: .leading, spacing: Space.titleToPanel) {
            SectionTitle(text: "Comparable ads", trailing: "\(deal.comps.count)")
            VStack(spacing: 0) {
                ForEach(Array(deal.comps.enumerated()), id: \.offset) { i, comp in
                    if i > 0 { Divider().overlay(Palette.line).padding(.leading, 16) }
                    CompRow(comp: comp)
                }
            }
            .rowsPanel()
            Text("The server judged the market value from these.").font(Typo.meta).foregroundStyle(Palette.tertiary)
        }
    }
}

/// A comparable ad: its title (a link in iris, underlined, when the server gave one) and its price.
struct CompRow: View {
    let comp: Deal.Comp
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let title = comp.title ?? String(localized: "Ad")
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                                                   : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        let row = layout {
            Text(title).font(Typo.secondary).foregroundStyle(comp.url == nil ? Palette.text : Palette.iris)
                .underline(comp.url != nil)
                .lineLimit(3).multilineTextAlignment(.leading)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            if let price = comp.price { Text(DealFormat.price(price)).font(Typo.rowValue).foregroundStyle(Palette.text) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        if let url = comp.url {
            Button { openURL(url) } label: { row }
                .buttonStyle(.plain)
                .accessibilityLabel(Text([title, comp.price.map(DealFormat.price)].compactMap { $0 }.joined(separator: ", ")))
                .accessibilityHint(Text("Opens the ad."))
        } else {
            row.accessibilityElement(children: .combine)
        }
    }
}
