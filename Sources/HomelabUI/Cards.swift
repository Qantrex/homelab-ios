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

    /// A chat bubble shows this many rows at most.
    static let compactRows = 6

    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var ringSize: CGFloat = 34

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

    /// The item whose circle was tapped, waiting for its confirm.
    struct TickOff: Identifiable {
        let item: Card.Item
        let action: ItemAction
        let spec: ActionSpec
        var id: ItemAction { action }
        /// "Tick off" (the item's label), else the action's own label.
        var verb: String { action.label ?? spec.label }
    }

    private var stacked: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        layout
        .animation(reduceMotion ? nil : .snappy, value: card.items)
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
            Button(a.verb) { Task { await tickOff(a) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Runs at once on \(model?.selected?.name ?? "the server").")
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
                if let subtitle = card.subtitle {
                    Text(subtitle).font(Typo.secondary).foregroundStyle(Palette.secondary).padding(.top, -8)
                }
                if usesRows { content.rowsPanel() } else { content.panel() }
            }
        }
    }

    /// Lab rows bring their own padding and separators.
    private var usesRows: Bool { lab && !compact && (card.style == .list || card.style == .metrics) && !card.items.isEmpty }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            // Card tints are decoration: the icon stays grey, colour is for status only.
            Image(systemName: Symbols.safe(card.icon)).foregroundStyle(Palette.secondary)
                .font(compact ? .footnote : .subheadline)
                .accessibilityHidden(true)
            Text(card.title ?? card.id)
                .font(compact ? .footnote.weight(.semibold) : Typo.sectionTitle)
                .foregroundStyle(compact ? Palette.secondary : Palette.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 6)
            if !compact, let updated = card.updated {
                Text(ServerDate.parse(updated).map { Format.age($0) } ?? updated).font(Typo.meta).foregroundStyle(Palette.tertiary)
            }
            if let action = card.action, let spec = model?.startable(action) {
                addButton(action, spec)
            }
        }
    }

    /// "+ Add": opens the card action's form, prefilled.
    private func addButton(_ action: ItemAction, _ spec: ActionSpec) -> some View {
        let label = action.label ?? spec.label
        return Button { formFor = spec } label: {
            HStack(spacing: 3) {
                Image(systemName: "plus").accessibilityHidden(true)
                Text(label).lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Palette.raised, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.press)
        .fixedSize()
        .accessibilityLabel(Text(label))
        .accessibilityHint(Text("Opens its form."))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch card.style {
        case .text:
            Text(markdown(card.text ?? card.items.compactMap(\.title).joined(separator: "\n")))
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
        }
    }

    /// The rows of a list-like card; its `text` when it has no items ("Nothing open."). A chat bubble shows the
    /// first few and how many more there are.
    @ViewBuilder
    private func rows<Row: View>(_ items: [Card.Item], @ViewBuilder row: @escaping (Card.Item) -> Row) -> some View {
        if items.isEmpty, let text = card.text {
            Text(markdown(text)).font(compact ? Typo.meta : Typo.body).foregroundStyle(Palette.secondary)
        } else {
            let shown = compact ? Array(items.prefix(Self.compactRows)) : items
            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                ForEach(Array(shown.enumerated()), id: \.offset) { i, item in
                    if i > 0, !compact { TodaySeparator() }
                    row(item)
                }
                if shown.count < items.count {
                    Text("and \(items.count - shown.count) more").font(Typo.meta).foregroundStyle(Palette.tertiary)
                }
            }
        }
    }

    private var metrics: some View {
        // Top-aligned, so a tile with a subtitle ("U6 07:36") doesn't sit higher than its neighbours.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: hero ? 96 : compact ? 72 : 90), spacing: 10, alignment: .topLeading)],
                  alignment: .leading, spacing: compact ? 8 : 12) {
            ForEach(Array(card.items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title ?? "").font(compact ? .caption : Typo.secondary).foregroundStyle(Palette.secondary).lineLimit(1)
                    Text(item.value ?? "–").font(Typo.data(hero ? .title : compact ? .headline : .title3, weight: .semibold))
                        .minimumScaleFactor(0.6).lineLimit(1)
                        .foregroundStyle(item.tint?.color ?? Palette.text)
                    if let s = item.subtitle { Text(s).font(Typo.meta).foregroundStyle(Palette.tertiary) }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: List rows

    @ViewBuilder
    private func itemRow(_ item: Card.Item) -> some View {
        // A row with progress (a download, an episode) leads with a ring; the others with their icon.
        // A cancelled lesson is struck through and grey; a substitution or room change (a lesson with a tint) gets a
        // gold dot (the status colour for "look at this"), so it isn't only the colour of the time that says it.
        let cancelled = item.cancelled == true
        let changed = !cancelled && card.id == "lessons" && item.tint.map { $0 != .gray } == true
        let valueColor = cancelled ? Palette.tertiary : item.tint?.color ?? Palette.secondary
        let row = HStack(alignment: item.progress == nil ? .firstTextBaseline : .center, spacing: 10) {
            if let p = item.progress {
                ProgressRing(p, tint: item.tint?.color ?? Palette.text, size: compact ? ringSize * 0.8 : ringSize)
            } else if let icon = item.icon {
                Image(systemName: Symbols.safe(icon, fallback: "circle")).foregroundStyle(item.tint?.color ?? Palette.secondary)
            } else if card.id == "lessons" {
                // Every lesson row reserves the dot's space, so the changed ones don't sit 18 pt further right.
                Circle().fill(changed ? Palette.gold : Color.clear).frame(width: 8, height: 8).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title ?? "").font(compact ? Typo.meta : Typo.body).lineLimit(2)
                    .strikethrough(cancelled).foregroundStyle(cancelled ? Palette.tertiary : Palette.text)
                if let s = item.subtitle {
                    Text(s).font(compact ? .caption : Typo.secondary).foregroundStyle(cancelled ? Palette.tertiary : Palette.secondary)
                        .strikethrough(cancelled).lineLimit(stacked ? nil : 1)
                }
                if stacked, let v = item.value { Text(v).font(Typo.data(.subheadline)).foregroundStyle(valueColor).strikethrough(cancelled) }
            }
            Spacer(minLength: 8)
            if !stacked, let v = item.value { Text(v).font(Typo.data(.subheadline)).foregroundStyle(valueColor).strikethrough(cancelled) }
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
        if let action = item.action, let spec = model?.startable(action) {
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

    private func actionButton(_ tick: TickOff, busy: Bool) -> some View {
        Button { ask = tick } label: {
            Group {
                if busy { ProgressView().controlSize(.small) } else { Text(tick.verb).lineLimit(1) }
            }
            .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Palette.raised, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.press)
        .fixedSize()
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

    private var labRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(card.items.enumerated()), id: \.offset) { i, item in
                if i > 0 { Divider().overlay(Palette.line).padding(.leading, 16) }
                labRow(item)
            }
        }
    }

    /// Row grammar (docs/DESIGN.md §6): status dot (the only colour) · name 17 semibold · reason 15 secondary · the
    /// value 15 mono medium at the right (under the name at accessibility sizes). A progress shows as a thin grey bar.
    private func labRow(_ item: Card.Item) -> some View {
        let status = Self.statusColor(item.tint)
        let warm = item.tint == .orange || item.tint == .yellow, red = item.tint == .red
        let value = item.value.flatMap { $0.isEmpty ? nil : $0 }
        let row = HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(item.tint == nil || item.tint == .gray ? Palette.text : status).frame(width: 8, height: 8)
                .accessibilityHidden(true)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? "").font(Typo.headline).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let s = item.subtitle {
                    Text(s).font(Typo.secondary).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let p = item.progress { Meter(p).padding(.top, 2) }
                if stacked, let value { Text(value).font(Typo.rowValue).foregroundStyle(warm || red ? status : Palette.secondary) }
            }
            Spacer(minLength: 8)
            if !stacked, let value {
                Text(value).font(Typo.rowValue).foregroundStyle(warm || red ? status : Palette.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(red ? Text("problem") : warm ? Text("warning") : Text(""))
        let main = Group {
            if let url = item.url { Button { openURL(url) } label: { row }.buttonStyle(.plain) } else { row }
        }
        return withAction(item, main: main)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                Text(markdown(text)).font(compact ? .footnote : .body).foregroundStyle(Palette.secondary)
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
        let spec = model?.startable(action)
        return VStack(alignment: .leading, spacing: 4) {
            PosterImage(model: model, path: item.image, icon: card.icon)
            Text(item.title ?? "").font(Typo.secondary.weight(.semibold)).foregroundStyle(Palette.text)
                .lineLimit(2, reservesSpace: false).fixedSize(horizontal: false, vertical: true)
            if let s = item.subtitle { Text(s).font(Typo.meta).foregroundStyle(Palette.tertiary).lineLimit(2) }
            if let value { Text(value).font(Typo.meta).foregroundStyle(Palette.secondary).lineLimit(2) }
            if let action, let spec {
                actionButton(TickOff(item: item, action: action, spec: spec), busy: running.contains(action))
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
        let spec = done ? nil : model?.startable(item.action)
        let busy = item.action.map { running.contains($0) } ?? false
        let countdown = item.countdown(now: now)
        // Shown short ("Mon 18:00"), spoken like the countdown ("in 2 days", "3 days ago").
        let due = item.dueText(now: now).flatMap { text in
            countdown.map { (text: text, level: $0.level, spoken: Self.spoken(countdown: $0.text)) }
        }
        let dueColor = done ? Palette.tertiary : due.map { Self.color($0.level, later: Palette.secondary) } ?? Palette.secondary
        let tick: TickOff? = spec.flatMap { s in item.action.map { TickOff(item: item, action: $0, spec: s) } }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            circle(done: done, busy: busy, tick: tick)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title ?? "")
                    .font(compact ? Typo.meta : Typo.body)
                    .strikethrough(done, color: Palette.tertiary)
                    .foregroundStyle(done ? Palette.tertiary : Palette.text)
                if let s = item.subtitle { Text(s).font(compact ? .caption : Typo.secondary).foregroundStyle(Palette.tertiary) }
                if stacked, let due { Text(due.text).font(Typo.data(.subheadline)).foregroundStyle(dueColor) }
            }
            Spacer(minLength: 8)
            if !stacked, let due { Text(due.text).font(Typo.data(.subheadline)).foregroundStyle(dueColor).lineLimit(1) }
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
            .font(compact ? .body : .title3)
            .foregroundStyle(done ? Palette.tertiary : tick != nil ? Palette.text : Palette.tertiary)
            .contentTransition(.symbolEffect(.replace))
            .opacity(busy ? 0 : 1)
            .overlay { if busy { ProgressView().controlSize(.small) } }
        if let tick, !busy {
            Button { ask = tick } label: {
                symbol.frame(minWidth: 30, minHeight: 30).contentShape(Rectangle())
            }
            .buttonStyle(.press)
        } else {
            symbol.frame(minWidth: 30, minHeight: compact ? 0 : 30)
        }
    }

    private func tickOff(_ t: TickOff) async {
        guard let model, let server = model.selected else { return }
        running.insert(t.action)
        let r = await model.run(t.action, on: server)
        running.remove(t.action)
        let (ok, message) = ResultMessage.started(t.spec, r, model: model)
        outcome = ActionOutcome(ok: ok)
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

    /// Title and subtitle on the left, the time left big on the right (below them with very large text).
    private func countdownRow(_ item: Card.Item, now: Date) -> some View {
        let c = item.countdown(now: now)
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        return layout {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title ?? "").font(compact ? Typo.meta : Typo.body).lineLimit(stacked ? nil : 2)
                if let s = item.subtitle { Text(s).font(compact ? .caption : Typo.secondary).foregroundStyle(Palette.secondary) }
            }
            if !stacked { Spacer(minLength: 8) }
            Text(c?.text ?? "–")
                .font(.system(compact ? .headline : .title2, design: .monospaced).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(c.map { Self.color($0.level, later: Palette.text) } ?? Palette.tertiary)
                .contentTransition(.numericText())
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
