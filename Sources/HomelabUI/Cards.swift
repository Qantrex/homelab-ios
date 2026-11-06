import HomelabDesign
import HomelabKit
import SwiftUI

/// A card from the server, drawn the same everywhere: Today (every density) and, `compact`, inside a chat bubble.
/// `hero` is the big version (large mono numbers). With a `model` the card's actions work: the header button opens
/// its action's form prefilled, and a checklist circle ticks its item off after a confirm. Without one, or when the
/// server doesn't let the app start that action, there is no button and the circle is only a picture.
struct CardView: View {
    let card: Card
    var hero = false
    var compact = false
    /// Lab: list and metrics cards as rows (docs/DESIGN.md §6): status dot, name, reason, value in the data font.
    var lab = false
    var model: AppModel?
    /// Item actions (a tick-off, "Delivered", "Request") work. False for a card inside a chat message: there the
    /// card's text came from the chat, so its rows only show and never run anything. The header's form button stays
    /// (the form shows everything before it runs).
    var allowsItemActions = true

    /// A chat bubble shows this many rows at most.
    static let compactRows = 6

    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    /// A progress ring in a row's right column (research #5): 20 pt, scaled with the text.
    @ScaledMetric(relativeTo: .subheadline) private var ringSize: CGFloat = 20

    @State private var formFor: ActionSpec?
    /// The form's result, shown once the sheet is gone (an alert can't show over the sheet).
    @State private var afterSheet: ResultMessage?
    /// This card's form sheet, for `AppModel.formSheetOpen`.
    @State private var sheetToken = UUID()
    @State private var ask: TickOff?
    @State private var running: Set<ItemAction> = []
    /// Ticked off here; drawn done until the server's list catches up (`TickedItems`).
    @State private var ticked = TickedItems()
    @State private var result: ResultMessage?
    @State private var outcome: ActionOutcome?
    /// Requested from a poster here (the confirm ran ok): drawn "requested" without its button.
    @State private var requested: Set<ItemAction> = []
    /// Lab: a long list (more than `LabRows.folded` rows) shows all its rows.
    @State private var expanded = false

    /// The item whose circle was tapped, waiting for its confirm.
    struct TickOff: Identifiable {
        let item: Card.Item
        let action: ItemAction
        let spec: ActionSpec
        var id: ItemAction { action }
        /// "Tick off" (the item's label), else the action's own label.
        var verb: String { action.label ?? spec.label }
        /// The confirm's message: the action's own label from /actions (not the card's verb), what it sends, where.
        func message(server: String) -> String {
            confirmText(ActionForm(spec, prefill: action), server: server, label: spec.label)
        }
    }

    /// The item's action, when it may run from here: the server lets the app start it, and the card isn't a chat's.
    private func itemSpec(_ action: ItemAction?) -> ActionSpec? {
        allowsItemActions ? model?.startable(action) : nil
    }

    private var stacked: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        layout
        // Rows that come or go (a parcel delivered, a to-do added) spring into place; a ticked-off item too.
        .rowMotion(card.items)
        .rowMotion(ticked)
        .onChange(of: card) { _, new in ticked.prune(new) }
        .sheet(item: $formFor, onDismiss: {
            if let r = afterSheet { result = r; afterSheet = nil }
        }) { spec in
            if let model, let server = model.selected {
                ActionFormView(model: model, server: server, spec: spec, prefill: card.action) { r in
                    let (ok, message) = ResultMessage.started(spec, r, model: model)
                    outcome = ActionOutcome(ok: ok)
                    afterSheet = message
                }
                // A link to another form waits until this sheet is gone (AppModel.formSheetOpen).
                .onAppear { model.formSheet(sheetToken, open: true) }
                .onDisappear { model.formSheet(sheetToken, open: false) }
            }
        }
        .confirmationDialog(ask.map { String(localized: "\($0.verb) \($0.item.title ?? "")?") } ?? "",
                            isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } }),
                            titleVisibility: .visible, presenting: ask) { a in
            Button(a.verb, role: a.spec.destructive ? .destructive : nil) { Task { await tickOff(a) } }
            Button("Cancel", role: .cancel) {}
        } message: { a in
            Text(a.message(server: model?.selected?.name ?? String(localized: "the server")))
        }
        .actionFeedback(result: $result, outcome: outcome)
    }

    /// On Today (docs/DESIGN.md §2): a title above, one panel under it with the rows split by separators. In a chat
    /// bubble (`compact`): one small panel with a quiet header.
    @ViewBuilder
    private var layout: some View {
        if compact {
            VStack(alignment: .leading, spacing: 8) {
                header
                if let subtitle = card.subtitle { Text(subtitle).font(Typo.meta).foregroundStyle(Palette.secondary) }
                content
            }
            .card(padding: 10)
        } else {
            VStack(alignment: .leading, spacing: Space.titleToPanel) {
                header
                // Lab rows: the card's `text` too ("Key expiry off on all servers"), as the rows are the panel.
                if let subtitle = usesRows ? LabRows.subtitle(card) : card.subtitle {
                    Text(subtitle).font(Typo.secondary).foregroundStyle(Palette.secondary).padding(.top, -8)
                }
                if usesRows { content.rowsPanel() } else { content.panel() }
            }
        }
    }

    /// Lab rows bring their own padding and separators.
    private var usesRows: Bool { lab && !compact && (card.style == .list || card.style == .metrics) && !card.items.isEmpty }

    // MARK: Header

    /// Icon and title, then the age and the "+ Add" button on the right; at accessibility sizes those two go on their
    /// own line under the title, so the title keeps the width.
    @ViewBuilder
    private var header: some View {
        let age = compact ? nil : card.updated.map { ServerDate.parse($0).map { Format.age($0) } ?? $0 }
        let add = card.action.flatMap { action in model?.startable(action).map { (action, $0) } }
        if stacked {
            VStack(alignment: .leading, spacing: 4) {
                headerTitle
                if age != nil || add != nil {
                    HStack(spacing: 12) {
                        if let age { Text(age).font(Typo.meta).foregroundStyle(Palette.tertiary) }
                        if let add { addButton(add.0, add.1) }
                    }
                }
            }
        } else {
            HStack(spacing: 6) {
                headerTitle
                Spacer(minLength: 6)
                if let age { Text(age).font(Typo.meta).foregroundStyle(Palette.tertiary) }
                if let add { addButton(add.0, add.1) }
            }
        }
    }

    private var headerTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Card tints are decoration: the icon stays grey, colour is for status only.
            Image(systemName: Symbols.safe(card.icon)).foregroundStyle(Palette.secondary)
                .font(compact ? .footnote : .subheadline)
                .accessibilityHidden(true)
            Text(card.title ?? card.id)
                .font(compact ? .footnote.weight(.semibold) : Typo.sectionTitle)
                .foregroundStyle(compact ? Palette.secondary : Palette.text)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// "+ Add": opens the card action's form, prefilled.
    private func addButton(_ action: ItemAction, _ spec: ActionSpec) -> some View {
        let label = action.label ?? spec.label
        return Button { formFor = spec } label: {
            HStack(spacing: 3) {
                Image(systemName: "plus").accessibilityHidden(true)
                Text(label)
            }
        }
        .buttonStyle(CapsuleButtonStyle(kind: .raised))
        .accessibilityLabel(Text(label))
        .accessibilityHint(Text("Opens its form."))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch card.style {
        case .text:
            Text(markdown(card.text ?? card.items.compactMap(\.title).joined(separator: "\n"))).tint(Palette.iris)
                .font(compact ? Typo.meta : Typo.body)
        case .metrics where usesRows, .list where usesRows:
            labRows
        case .posterGrid:
            posterGrid
        case .metrics:
            metrics
        case .list:
            // An item ticked off here (a delivered parcel) disappears until the server's list catches up.
            rows(card.items.filter { !ticked.covers($0) }) { itemRow($0) }
        case .checklist:
            // Redrawn every minute, so "today 18:00" turns love when it passes.
            TimelineView(.everyMinute) { context in
                rows(ticked.applied(to: card, now: context.date).items) { checkRow($0, now: context.date) }
            }
        case .countdown:
            TimelineView(.everyMinute) { context in
                rows(card.sortedForCountdown) { countdownRow($0, now: context.date) }
            }
        case .departures:
            departures
        }
    }

    // MARK: Departures

    /// Per direction a row: the direction and the next time, the stop and the ones after. Trains that have left drop
    /// out every minute. A disruption is a gold triangle with its words (never colour alone).
    private var departures: some View {
        let board = DepartureBoard(card: card)
        return TimelineView(.everyMinute) { context in
            let up = board.upcoming(now: context.date)
            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                if up.isEmpty {
                    Text(card.items.isEmpty ? String(localized: "No departures.") : String(localized: "No more departures soon."))
                        .font(compact ? .footnote : .body).foregroundStyle(Palette.secondary)
                }
                ForEach(Array(up.groups.enumerated()), id: \.offset) { i, group in
                    if i > 0, !compact { TodaySeparator() }
                    departureRow(group)
                }
                if let text = board.disruption {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.gold).accessibilityHidden(true)
                        Text(text).foregroundStyle(Palette.text)
                    }
                    .font(compact ? .footnote : .subheadline)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("Disruption: \(text)"))
                }
            }
        }
    }

    private func departureRow(_ group: DepartureBoard.Group) -> some View {
        let first = group.departures[0]
        let later = Array(group.departures.dropFirst().prefix(3))
        let stop = [group.stop, first.planned ? String(localized: "planned") : nil].compactMap { $0 }.joined(separator: " · ")
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return VStack(alignment: .leading, spacing: 2) {
            layout {
                Text(group.towards).font(compact ? .footnote : .body).foregroundStyle(Palette.text).lineLimit(2)
                if !stacked { Spacer(minLength: 8) }
                departureTime(first, color: Palette.text, weight: .semibold)
            }
            layout {
                Text(stop).font(compact ? .caption : .subheadline).foregroundStyle(Palette.secondary).lineLimit(1)
                if !stacked { Spacer(minLength: 8) }
                HStack(spacing: 10) {
                    ForEach(Array(later.enumerated()), id: \.offset) { _, d in departureTime(d, color: Palette.secondary, weight: .regular) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.spoken(group)))
    }

    /// "20:54" in the data font, with a gold "+3" when it runs late.
    private func departureTime(_ d: DepartureBoard.Departure, color: Color, weight: Font.Weight) -> some View {
        HStack(spacing: 3) {
            Text(DepartureBoard.clock(d.due)).font(Typo.data(compact ? .footnote : .subheadline, weight: weight)).foregroundStyle(color)
            if d.late {
                Text(d.delay.map { "+\($0)" } ?? String(localized: "late")).font(Typo.data(.caption, weight: .semibold)).foregroundStyle(Palette.gold)
            }
        }
        .lineLimit(1)
    }

    /// "Floridsdorf from Erlaaer Straße: 20:54, then 20:59 (3 minutes late), 21:04".
    static func spoken(_ group: DepartureBoard.Group) -> String {
        let times = group.departures.prefix(4).enumerated().map { i, d -> String in
            let late = d.late ? (d.delay.map { String(localized: ", \($0) minutes late") } ?? String(localized: ", late")) : ""
            return (i == 0 ? "" : String(localized: "then ")) + DepartureBoard.clock(d.due) + late
        }
        let from = group.stop.map { String(localized: " from \($0)") } ?? ""
        return "\(group.towards)\(from): " + times.joined(separator: ", ")
    }

    /// The rows of a list-like card; its `text` when it has no items ("Nothing open."). A chat bubble shows the
    /// first few and how many more there are.
    @ViewBuilder
    private func rows<Row: View>(_ items: [Card.Item], @ViewBuilder row: @escaping (Card.Item) -> Row) -> some View {
        if items.isEmpty, let text = card.text {
            VStack(alignment: .leading, spacing: 4) {
                Text(markdown(text)).tint(Palette.iris).font(compact ? Typo.meta : Typo.body).foregroundStyle(Palette.secondary)
                if !compact, let empty = Voice.Empty(card: card),
                   let line = Voice.line(for: .empty(empty), personality: model?.settings.voice ?? .off) {
                    Text(line).font(Typo.secondary).foregroundStyle(Palette.secondary)
                }
            }
        } else {
            let shown = compact ? Array(items.prefix(Self.compactRows)) : items
            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                ForEach(Array(Self.keyed(shown).enumerated()), id: \.element.key) { i, keyed in
                    if i > 0, !compact { TodaySeparator() }
                    row(keyed.item).transition(.opacity)
                }
                if shown.count < items.count {
                    Text("and \(items.count - shown.count) more").font(Typo.meta).foregroundStyle(Palette.tertiary)
                }
            }
        }
    }

    private var metrics: some View {
        // Top-aligned, so a tile with a subtitle ("U6 07:36") doesn't sit higher than its neighbours. One column at
        // accessibility sizes, where the labels may wrap.
        let columns = stacked ? [GridItem(.flexible(), alignment: .topLeading)]
            : [GridItem(.adaptive(minimum: hero ? 96 : compact ? 72 : 90), spacing: 10, alignment: .topLeading)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: compact ? 8 : 12) {
            ForEach(Array(card.items.enumerated()), id: \.offset) { _, item in
                let meaning = Self.meaning(item.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title ?? "").font(compact ? .caption : Typo.secondary).foregroundStyle(Palette.secondary)
                        .lineLimit(stacked ? nil : 1)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        // Colour alone never says it: with Differentiate Without Colour the status glyph comes too.
                        if differentiateWithoutColor, let meaning {
                            Image(systemName: meaning.symbol).font(Typo.meta).foregroundStyle(item.tint?.color ?? Palette.text)
                                .accessibilityHidden(true)
                        }
                        Text(item.value ?? "–").font(Typo.data(hero ? .title : compact ? .headline : .title3, weight: .semibold))
                            .minimumScaleFactor(0.6).lineLimit(1)
                            .foregroundStyle(item.tint?.color ?? Palette.text)
                            .numberMotion(item.value)
                    }
                    if let s = item.subtitle { Text(s).font(Typo.meta).foregroundStyle(Palette.tertiary) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(meaning.map { Text($0.word) } ?? Text(""))
            }
        }
    }

    /// What a status tint says, in words for VoiceOver and as a glyph for Differentiate Without Colour: red is a
    /// problem, orange and yellow a warning (the same words as Lab's rows). Other tints are decoration: nil.
    static func meaning(_ tint: Tint?) -> (word: LocalizedStringKey, symbol: String)? {
        switch tint {
        case .red: ("problem", Problem.Severity.problem.symbol)
        case .orange, .yellow: ("warning", Problem.Severity.warning.symbol)
        default: nil
        }
    }

    // MARK: List rows

    /// Each row's identity: its title and subtitle, numbered when the same pair repeats. A row that comes or goes
    /// then moves as itself, instead of its neighbours swapping their text.
    static func keyed(_ items: [Card.Item]) -> [(key: String, item: Card.Item)] {
        var seen: [String: Int] = [:]
        return items.map { item in
            let base = (item.title ?? "") + "\u{1F}" + (item.subtitle ?? "")
            let n = seen[base, default: 0]
            seen[base] = n + 1
            return (base + "\u{1F}\(n)", item)
        }
    }

    // The row grammar (docs/DESIGN.md §6, research #5), for list, checklist and countdown rows alike: a leading glyph
    // at 17 (the only colour) · the name 17 semibold · the reason 15 secondary, two lines · on the right the value
    // 15 mono medium, and a 20 pt progress ring after it. In a chat bubble (`compact`) the same at 13.

    private var nameFont: Font { compact ? Typo.meta.weight(.semibold) : Typo.headline }
    private var reasonFont: Font { compact ? .caption : Typo.secondary }
    private var valueFont: Font { compact ? Typo.data(.footnote, weight: .medium) : Typo.rowValue }
    private var glyphFont: Font { compact ? Typo.meta : Typo.body }

    @ViewBuilder
    private func itemRow(_ item: Card.Item) -> some View {
        // A row leads with its icon; one with progress (a download, an episode) shows a small ring after its value.
        // A cancelled lesson is struck through and grey; a substitution or room change (a lesson with a tint) gets a
        // gold dot (the status colour for "look at this"), so it isn't only the colour of the time that says it.
        let cancelled = item.cancelled == true
        let changed = !cancelled && card.id == "lessons" && item.tint.map { $0 != .gray } == true
        let valueColor = cancelled ? Palette.tertiary : item.tint?.color ?? Palette.secondary
        // Without a value of its own, a ring's row shows its percent there (it used to sit inside the bigger ring).
        let value = item.value ?? item.progress.map { "\(Format.ringPercent($0))%" }
        let row = HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let icon = item.icon {
                Image(systemName: Symbols.safe(icon, fallback: "circle")).font(glyphFont)
                    .foregroundStyle(item.tint?.color ?? Palette.secondary)
            } else if card.id == "lessons" {
                // Every lesson row reserves the dot's space, so the changed ones don't sit 18 pt further right.
                Circle().fill(changed ? Palette.gold : Color.clear).frame(width: 8, height: 8).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? "").font(nameFont).lineLimit(2)
                    .strikethrough(cancelled).foregroundStyle(cancelled ? Palette.tertiary : Palette.text)
                if let s = item.subtitle {
                    Text(s).font(reasonFont).foregroundStyle(cancelled ? Palette.tertiary : Palette.secondary)
                        .strikethrough(cancelled).lineLimit(stacked ? nil : 2)
                }
                if stacked, let value {
                    Text(value).font(valueFont).foregroundStyle(valueColor).strikethrough(cancelled).numberMotion(value)
                }
            }
            Spacer(minLength: 8)
            if !stacked, let value {
                Text(value).font(valueFont).foregroundStyle(valueColor).strikethrough(cancelled).lineLimit(1)
                    .numberMotion(value)
            }
            if let p = item.progress {
                RowRing(value: p, tint: item.tint?.color ?? Palette.text, size: compact ? ringSize * 0.8 : ringSize)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.progress.map { Text("\(Format.ringPercent($0)) percent") }
                            ?? (cancelled ? Text("cancelled") : changed ? Text("changed") : Text("")))
        let main = Group {
            if let url = item.url {
                Button { openURL(url) } label: { row }.buttonStyle(.plain)
            } else {
                row
            }
        }
        withAction(item, main: main)
    }

    /// The row with its action's button at the end (a parcel's "Delivered", Lab's "Pause 5 min"): it asks first, like a
    /// checklist tick. Without a startable action, the row alone.
    @ViewBuilder
    private func withAction<Main: View>(_ item: Card.Item, main: Main) -> some View {
        if let action = item.action, let spec = itemSpec(action) {
            let tick = TickOff(item: item, action: action, spec: spec)
            let busy = running.contains(action)
            // At accessibility sizes the button goes under the row, so the title keeps the full width.
            let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                 : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
            layout {
                main
                actionButton(tick, busy: busy)
            }
        } else {
            main
        }
    }

    /// A raised capsule with the item action's verb, a 44 pt hit area. `wraps`: in a narrow poster column it may take
    /// two lines at large text sizes instead of running out of its column.
    private func actionButton(_ tick: TickOff, busy: Bool, wraps: Bool = false) -> some View {
        Button { ask = tick } label: {
            if busy { ProgressView().controlSize(.small) } else { Text(tick.verb) }
        }
        .buttonStyle(CapsuleButtonStyle(kind: .raised, wraps: wraps))
        .disabled(busy)
        .accessibilityLabel(Text("\(tick.verb) \(tick.item.title ?? "")"))
    }

    // MARK: Lab rows

    /// The status colour of a row's dot and value: gold for warm tints, love for red, else normal text.
    static func statusColor(_ tint: Tint?) -> Color {
        switch tint {
        case .orange, .yellow: Palette.gold
        case .red: Palette.love
        default: Palette.text
        }
    }

    /// The rows in one panel, split by separators. A list with more than three rows shows three and a "Show 5 more"
    /// row that opens the rest ("Show less" closes them); the rows spring in and out (`rowMotion`).
    private var labRows: some View {
        let shown = LabRows.shown(card, expanded: expanded)
        return VStack(spacing: 0) {
            ForEach(Array(Self.keyed(shown).enumerated()), id: \.element.key) { i, keyed in
                if i > 0 { Divider().overlay(Palette.line).padding(.leading, 16) }
                labRow(keyed.item).transition(.opacity)
            }
            if LabRows.folds(card) {
                Divider().overlay(Palette.line).padding(.leading, 16)
                moreRow(hidden: card.items.count - LabRows.folded)
            }
        }
        .rowMotion(expanded)
    }

    /// "Show 5 more" / "Show less": secondary text and a chevron, the row's full width (at least 44 pt) as the target.
    private func moreRow(hidden: Int) -> some View {
        let label = expanded ? String(localized: "Show less") : String(localized: "Show \(hidden) more")
        return Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(label).font(Typo.secondary).foregroundStyle(Palette.secondary)
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
        .accessibilityLabel(Text(label))
        .accessibilityHint(expanded ? Text("Shows the first \(LabRows.folded) rows only.")
                                    : Text("Shows all \(card.items.count) rows."))
    }

    /// Row grammar (docs/DESIGN.md §6): status dot · name 17 semibold · reason 15 secondary · the value 15 medium at
    /// the right (under the name at accessibility sizes); a thin grey bar only for an item with `progress`. A row that
    /// needs a look (a warm or red tint, a tailnet device that is away) has a warning glyph instead of its dot and its
    /// word in the value column ("offline", "seen 3 h ago"); a tailnet device that is simply online shows no value. A
    /// grey item ("not set up") has a grey dot and a grey "–".
    private func labRow(_ item: Card.Item) -> some View {
        let status = Self.statusColor(item.tint)
        let warm = item.tint == .orange || item.tint == .yellow, red = item.tint == .red
        let warns = LabRows.warns(item, in: card)
        let value = LabRows.value(item, in: card)
        let valueColor = warm || red ? status : value == "–" ? Palette.tertiary : Palette.secondary
        let row = HStack(alignment: .firstTextBaseline, spacing: 10) {
            marker(item, warns: warns)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? "").font(Typo.headline).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let s = item.subtitle {
                    Text(s).font(Typo.secondary).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let p = item.progress { Meter(p).padding(.top, 4) }
                if stacked, let value { Text(value).font(Typo.rowValue).foregroundStyle(valueColor) }
            }
            Spacer(minLength: 8)
            if !stacked, let value {
                Text(value).font(Typo.rowValue).foregroundStyle(valueColor)
                    .multilineTextAlignment(.trailing)
                    .numberMotion(value)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(red ? Text("problem") : warm ? Text("warning") : warns ? Text("away") : Text(""))
        let main = Group {
            if let url = item.url { Button { openURL(url) } label: { row }.buttonStyle(.plain) } else { row }
        }
        return withAction(item, main: main)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A lab row's leading mark: an 8 pt dot (white; grey for an inactive item), or a small warning glyph centred in
    /// the same 8 pt column (it reaches a little into the gaps), so every name starts at the same place.
    @ViewBuilder
    private func marker(_ item: Card.Item, warns: Bool) -> some View {
        if warns {
            Image(systemName: item.tint == .red ? Problem.Severity.problem.symbol : Problem.Severity.warning.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.tint == .red || item.tint == .orange || item.tint == .yellow
                                 ? Self.statusColor(item.tint) : Palette.secondary)
                .frame(width: 8)
                .accessibilityHidden(true)
        } else {
            Circle().fill(item.tint == .gray ? Palette.tertiary : Palette.text).frame(width: 8, height: 8)
                .accessibilityHidden(true)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
        }
    }

    // MARK: Poster grid

    /// Posters 2:3 in 3 columns (2 at accessibility sizes), then title, subtitle and value; a request button when the
    /// server lets the app start the item's action (it asks first: "Request <title>?").
    private var posterGrid: some View {
        let items = compact ? Array(card.items.prefix(Self.compactRows)) : card.items
        let count = stacked ? 2 : 3
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: count)
        return Group {
            if items.isEmpty, let text = card.text {
                Text(markdown(text)).tint(Palette.iris).font(compact ? .footnote : .body).foregroundStyle(Palette.secondary)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in poster(item) }
                }
            }
        }
    }

    private func poster(_ item: Card.Item) -> some View {
        let done = item.action.map { requested.contains($0) } ?? false
        let value = done ? String(localized: "requested") : item.value.flatMap { $0.isEmpty ? nil : $0 }
        let action = done ? nil : item.action
        let spec = itemSpec(action)
        return VStack(alignment: .leading, spacing: 4) {
            PosterImage(model: model, path: item.image, icon: card.icon)
            Text(item.title ?? "").font(Typo.secondary.weight(.semibold)).foregroundStyle(Palette.text)
                .lineLimit(2, reservesSpace: false).fixedSize(horizontal: false, vertical: true)
            // Requested here: the server's "· not requested" goes, the value says "requested".
            if let s = item.subtitle.map({ done ? PosterText.withoutRequestState($0) : $0 }) {
                Text(s).font(Typo.meta).foregroundStyle(Palette.tertiary).lineLimit(2)
            }
            if let value { Text(value).font(Typo.meta).foregroundStyle(Palette.secondary).lineLimit(2) }
            if let action, let spec {
                actionButton(TickOff(item: item, action: action, spec: spec), busy: running.contains(action),
                             wraps: true)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    // MARK: Checklist rows

    /// A circle (filled when done), title, subtitle and the due day. The circle ticks the item off when the server
    /// lets the app run the item's action.
    private func checkRow(_ item: Card.Item, now: Date) -> some View {
        let done = item.done == true
        let spec = done ? nil : itemSpec(item.action)
        let busy = item.action.map { running.contains($0) } ?? false
        let countdown = item.countdown(now: now)
        // Shown short ("Mon 18:00"), spoken like the countdown ("in 2 days", "3 days ago").
        let due = item.dueText(now: now).flatMap { text in
            countdown.map { (text: text, level: $0.level, spoken: Self.spoken(countdown: $0.text)) }
        }
        let dueColor = done ? Palette.tertiary : due.map { Self.color($0.level, later: Palette.secondary) } ?? Palette.secondary
        let tick: TickOff? = spec.flatMap { s in item.action.map { TickOff(item: item, action: $0, spec: s) } }
        // No spacing: the circle's 44 pt hit area already leaves the row grammar's 12 pt to the name.
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            circle(done: done, busy: busy, tick: tick)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? "")
                    .font(nameFont)
                    .strikethrough(done, color: Palette.tertiary)
                    .foregroundStyle(done ? Palette.tertiary : Palette.text)
                if let s = item.subtitle {
                    Text(s).font(reasonFont).foregroundStyle(done ? Palette.tertiary : Palette.secondary)
                        .lineLimit(stacked ? nil : 2)
                }
                if stacked, let due { Text(due.text).font(valueFont).foregroundStyle(dueColor).numberMotion(due.text) }
            }
            Spacer(minLength: 8)
            if !stacked, let due {
                Text(due.text).font(valueFont).foregroundStyle(dueColor).lineLimit(1).numberMotion(due.text)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let url = item.url { openURL(url) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.spoken(item, due: due.map { ($0.spoken, $0.level) }, busy: busy)))
        // VoiceOver's double tap ticks the item off (after the confirm), or opens its link.
        .accessibilityAction {
            if let tick, !busy { ask = tick } else if let url = item.url { openURL(url) }
        }
        .accessibilityActions {
            if let tick, !busy {
                Button(tick.verb) { ask = tick }
            }
            if let url = item.url {
                Button("Open") { openURL(url) }
            }
        }
    }

    @ViewBuilder
    private func circle(done: Bool, busy: Bool, tick: TickOff?) -> some View {
        let symbol = Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .font(compact ? Typo.secondary : Typo.body)
            .foregroundStyle(done ? Palette.tertiary : tick != nil ? Palette.text : Palette.tertiary)
            .contentTransition(Motion.symbol)
            .opacity(busy ? 0 : 1)
            .overlay { if busy { ProgressView().controlSize(.small) } }
        // A 44 pt hit area around the 17 pt circle, reaching into the panel's padding on the left so the circle still
        // starts at the row's leading edge; the same width without a button, so the names line up.
        Group {
            if let tick, !busy {
                Button { ask = tick } label: {
                    symbol.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.press)
            } else {
                symbol.frame(minWidth: 44, minHeight: compact ? 0 : 44)
            }
        }
        .padding(.leading, -12)
    }

    private func tickOff(_ t: TickOff) async {
        guard let model, let server = model.selected else { return }
        running.insert(t.action)
        let r = await model.run(t.action, on: server)
        running.remove(t.action)
        let (ok, message) = ResultMessage.started(t.spec, r, model: model)
        // A tick-off is small: a selection tick when it went through (an error buzz when it didn't).
        outcome = ActionOutcome(ok: ok, feel: .selection)
        if ok {
            // The server may list the item as open for a moment longer: draw it done until its list catches up.
            ticked.add(t.action)
            if card.style == .posterGrid { requested.insert(t.action) }
        } else if formFor != nil {
            afterSheet = message   // an alert can't show over the card's open form
        } else {
            result = message
        }
    }

    // MARK: Countdown rows

    /// Title and subtitle on the left, the time left in the value column on the right (below them with very large
    /// text).
    private func countdownRow(_ item: Card.Item, now: Date) -> some View {
        let c = item.countdown(now: now)
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                             : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? "").font(nameFont).lineLimit(stacked ? nil : 2)
                if let s = item.subtitle {
                    Text(s).font(reasonFont).foregroundStyle(Palette.secondary).lineLimit(stacked ? nil : 2)
                }
            }
            if !stacked { Spacer(minLength: 8) }
            Text(c?.text ?? "–")
                .font(valueFont)
                .lineLimit(1)
                .foregroundStyle(c.map { Self.color($0.level, later: Palette.text) } ?? Palette.tertiary)
                .numberMotion(c?.text)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text([item.title, item.subtitle, c.map { Self.spoken(countdown: $0.text) }]
            .compactMap { $0 }.joined(separator: ", ")))
    }

    // MARK: Words and colours

    /// love when past, gold when soon (today, under 24 h), else `later`.
    static func color(_ level: Format.Level, later: Color) -> Color {
        switch level {
        case .past: Palette.love
        case .soon: Palette.gold
        case .later: later
        }
    }

    /// "Milk, Shopping, today, not done"; "Bills, overdue, 3 days ago, not done". `due` is already spoken
    /// (`spoken(countdown:)`).
    static func spoken(_ item: Card.Item, due: (text: String, level: Format.Level)?, busy: Bool) -> String {
        var parts = [item.title, item.subtitle].compactMap { $0 }
        if let due {
            parts.append(due.level == .past && item.done != true ? String(localized: "overdue, \(due.text)") : due.text)
        }
        parts.append(busy ? String(localized: "ticking off") : item.done == true ? String(localized: "done") : String(localized: "not done"))
        return parts.joined(separator: ", ")
    }

    /// "2 d" → "in 2 days", "40 min ago" → "40 minutes ago", "today" stays.
    static func spoken(countdown text: String) -> String {
        let parts = text.split(separator: " ").map(String.init)
        guard parts.count >= 2, let n = Int(parts[0]) else { return text }
        let unit = switch parts[1] {
        case "d": n == 1 ? String(localized: "day") : String(localized: "days")
        case "h": n == 1 ? String(localized: "hour") : String(localized: "hours")
        case "min": n == 1 ? String(localized: "minute") : String(localized: "minutes")
        default: parts[1]
        }
        return parts.count > 2 ? String(localized: "\(n) \(unit) ago") : String(localized: "in \(n) \(unit)")
    }
}

/// The line between two rows inside a panel (docs/DESIGN.md §2): a hairline, the panel's own 16 pt inset on both sides.
struct TodaySeparator: View {
    var body: some View {
        Rectangle().fill(Palette.line).frame(height: 1).accessibilityHidden(true)
    }
}

/// A row's progress ring (research #5): 20 pt, inline after the value, no number inside (the value column has it;
/// text inside a ring this small would be under 11 pt). A full ring when done. VoiceOver reads the row's percent.
struct RowRing: View {
    let value: Double
    let tint: Color
    let size: CGFloat

    var body: some View {
        let share = value.isFinite ? min(max(value, 0), 1) : 0
        let width = max(size * 0.12, 2)
        ZStack {
            Circle().stroke(Palette.line, lineWidth: width)
            Circle()
                .trim(from: 0, to: share)
                .stroke(tint, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(width / 2)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
