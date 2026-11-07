import HomelabDesign
import HomelabKit
import SwiftUI

/// Today: the first screen. My day first (the server's "today" card, what waits for me, Home tiles, the other cards,
/// the last report), the machines only as one status line that opens Lab.
struct TodayView: View {
    let model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    /// Taps on the voice line (each one: the next comment).
    @State private var pokes = 0
    /// A pull to refresh runs or just ended: the hero says where the data is from (`showsFacts`).
    @State private var pulled = false
    @State private var pulls = 0
    /// Home Assistant's states, read by `homePoll` for the Home tiles, a Home "When it needs me" rule, Where you are and
    /// (without a Companion server) the headline.
    @State private var home = HomeModel()
    /// The time the show rules check (Settings → Today → Sections); ticks every 30 s while a rule is set.
    @State private var ruleClock = Date.now
    /// The folded cards and Also rows the owner opened (card ids, "also:<kind>"). Only for this launch.
    @State private var expanded: Set<String> = []

    private var status: ServerStatus { model.selectedStatus }
    private var density: Density { model.settings.todayDensity }
    private func when(_ date: Date?) -> String { Format.when(date, exact: density.exactTimes) }
    private var state: HomelabState? { status.snapshot?.state }

    private var dayCard: Card? { state?.dayCard }

    var body: some View {
        // Once per redraw; without rules and Where you are it doesn't read Home Assistant's states (`todaySections`).
        let today = model.todaySections(now: ruleClock, homeEntities: { home.entities }, fetched: { home.fetched })
        let shown = today.sections
        let pollKey = HomePollKey(server: model.homeAssistant?.target, active: scenePhase == .active,
                                  polls: model.pollsHome(shown: shown))
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.section) {
                    hero
                    // Free Apple ID: the install stops opening after 7 days. Two days ahead, Today says so.
                    if let warning = AppExpiry.warning(expires: AppExpiry.current) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.gold).accessibilityHidden(true)
                            Text(warning).font(Typo.secondary).foregroundStyle(Palette.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityElement(children: .combine)
                    }
                    if model.selected != nil {
                        if let error = status.error {
                            ErrorBanner(error: error, snapshotAge: status.snapshot?.fetched, retry: { Task { await model.refresh() } },
                                        edit: model.selected.map { s in { model.requestEdit(s.id) } })
                        }
                        if state == nil {
                            if status.loading {
                                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                            } else if status.error == nil {
                                Placeholder(title: "No data yet", symbol: "tray", message: "Pull down to load.")
                            }
                        }
                    }
                    // In my order, without the hidden ones and those a rule hides now (Settings → Today).
                    ForEach(shown) { section(for: $0, shown: shown) }
                    if model.settings.todayLayout.rules != nil, let context = today.context {
                        HiddenNowLine(model: model, context: context, now: ruleClock)
                    }
                    // Only right after a first run (never for the owner): where Today is changed.
                    if model.showsStartTip { startTip }
                }
                .motion(.snappy, value: shape(shown))
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
            .background { MoodGlow(level: mood.level).ignoresSafeArea() }
            .refreshable { await pullToRefresh() }
            .toolbar(.hidden, for: .navigationBar)
            .pollingState(model)
            .task(id: pollKey) { await homePoll(pollKey) }
            .task(id: model.settings.todayLayout.rules != nil) {
                guard model.settings.todayLayout.rules != nil else { return }
                while !Task.isCancelled {
                    ruleClock = .now
                    try? await Task.sleep(for: .seconds(30))
                }
            }
            // A tap you can feel when the lab turns bad while you're looking.
            .sensoryFeedback(trigger: mood.level) { old, new in
                new == .alarm && old != .alarm ? .error : nil
            }
        }
    }

    /// What decides which panels show: when it changes (an action approved elsewhere, a download done, a section
    /// turned off), panels slide instead of jumping.
    private func shape(_ shown: [TodaySection]) -> [String] {
        shown.map(\.rawValue)
            + (state?.pending.map { "p:" + $0.id } ?? [])
            + (state?.cards.map { "c:\($0.id):\($0.items.count)" } ?? [])
            + [state == nil ? "empty" : "loaded"]
    }

    /// Identity of the Home Assistant loop: another Home Assistant, the app going to the background or coming back,
    /// or Today starting or stopping to need the states (`AppModel.pollsHome`) restarts it.
    private struct HomePollKey: Hashable {
        var server: String?
        var active: Bool
        var polls: Bool
    }

    /// The one loop that reads Home Assistant while Today is open, every 30 s, while anything on Today needs the
    /// states: the Home tiles shown, a Home "When it needs me" rule, the headline without a Companion server, or Where
    /// you are (`HomePoll.shouldPoll`). With Home shown (the owner's Today) it is the one request the tiles made.
    private func homePoll(_ key: HomePollKey) async {
        let ha = model.homeAssistant
        home.reset(for: ha)
        guard key.active, key.polls, let ha else { return }
        while !Task.isCancelled {
            await home.load(model.homeAssistantAPI(for: ha), host: ha.host)
            try? await Task.sleep(for: .seconds(HomePoll.interval))
        }
    }

    /// The footer after a first run, until the app quits or it is tapped: Settings → Today changes the sections and
    /// how much they show.
    private var startTip: some View {
        Button { model.openStartTip() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Change what Today shows in Settings → Today")
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).accessibilityHidden(true)
            }
            .font(Typo.meta)
            .foregroundStyle(Palette.tertiary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens Settings"))
    }

    // MARK: Hero

    private var mood: TodayMood {
        // Before the first answer: "Checking…" (grey) while it's on its way, "No signal." once it failed.
        model.selected == nil ? TodayMood(home: homeGlance)
                              : TodayMood(state: state, checking: status.error == nil)
    }

    /// Without a Companion server: Home Assistant at a glance ("Home." · "1 light on" · gold "Bedroom fan
    /// unavailable"), from states read without an error in the last 2 minutes; else nil ("Home." in grey).
    private var homeGlance: HomeGlance? {
        model.homeGlance(entities: home.entities, fetched: home.fetched, failed: home.error != nil, now: .now)
    }

    /// The big "now" (docs/DESIGN.md): the date, how the lab is doing in two words (white; the mood is the light
    /// behind it and the status icon), the first problem, what the voice thinks of it (tap opens Lab). Under it, plain
    /// text: the weather sentence, and where the data is from only when that is worth saying (`FreshnessLine`).
    /// VoiceOver reads it line by line: only the headline is a heading (and opens Lab), the voice line has a "Next
    /// comment" action.
    private var hero: some View {
        let m = mood
        return VStack(alignment: .leading, spacing: 0) {
            heroButton(m)
            // Not part of the button: they are facts to read, not something to tap.
            if let weather {
                weatherLine(weather).padding(.top, 12)
            }
            if showsFacts {
                Text(facts).font(Typo.meta).foregroundStyle(Palette.tertiary)
                    .padding(.top, weather == nil ? 12 : 6)
                    .accessibilityLabel(Format.spoken(facts))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 28)
        .padding(.bottom, 8)
        .motion(.snappy, value: showsFacts)
    }

    /// "☁ Partly cloudy, 7 °C now": one sentence in the secondary style with the weather card's own symbol.
    private func weatherLine(_ text: String) -> some View {
        let symbol = Symbols.safe(weatherCard?.icon, fallback: "cloud.sun")
        return (Text(Image(systemName: symbol)).foregroundColor(Palette.secondary) + Text("\u{00A0}\u{00A0}" + text))
            .font(Typo.secondary).foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Weather: \(text)"))
    }

    private func heroButton(_ m: TodayMood) -> some View {
        Button {
            openLab()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    if let symbol = statusSymbol(m.level) {
                        Image(systemName: symbol).foregroundStyle(m.level.color).font(.footnote.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    Text(dateLine).font(.footnote.weight(.medium)).foregroundStyle(Palette.secondary)
                    // Shows that the headline opens Lab (a tap there was invisible before; VoiceOver has the hint).
                    if model.availableTabs.contains(.lab) {
                        Spacer(minLength: 8)
                        HStack(spacing: 2) {
                            Text("Lab")
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        }
                        .font(.footnote.weight(.medium)).foregroundStyle(Palette.tertiary)
                        .accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .combine)
                Text(m.headline)
                    .heroFont()
                    .tracking(-1)
                    .foregroundStyle(Palette.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .contentTransition(Motion.numeric)
                    .padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHint(model.availableTabs.contains(.lab) ? Text("Opens Lab") : Text(""))
                    .accessibilityAction { openLab() }
                // The fact line: the first problem, and the warnings inline (gold glyph, white words; research #8).
                if m.detail != nil || m.warnings > 0 {
                    factLine(m)
                        .font(Typo.headline).foregroundStyle(Palette.text)
                        .lineLimit(3).multilineTextAlignment(.leading)
                        .padding(.top, 8)
                }
                // The voice: what it thinks of the facts above, in words (DESIGN.md §4). Tap the line for another.
                if let take = take(m) {
                    Text(take).font(Typo.body).foregroundStyle(Palette.secondary).lineLimitAtStandardSizes(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                        .id(take)
                        .transition(.opacity)
                        .onTapGesture { pokes += 1 }
                        .sensoryFeedback(.selection, trigger: pokes)
                        .accessibilityAction(named: Text("Next comment")) { pokes += 1 }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .motion(.snappy, value: m)
            .motion(.snappy, value: pokes)
        }
        .buttonStyle(.pressLight)
        .accessibilityElement(children: .contain)
    }

    private func openLab() {
        if model.availableTabs.contains(.lab) { model.tab = .lab }
    }

    /// "sonarr on media is unhealthy · ⚠ 1 warning": only the glyph is gold.
    private func factLine(_ m: TodayMood) -> Text {
        var t = Text(m.detail ?? "")
        if m.warnings > 0 {
            // No-break spaces keep "⚠ 1 warning" together and the dot at the end of the first line when it wraps.
            if m.detail != nil { t = t + Text("\u{00A0}· ") }
            t = t + Text(Image(systemName: "exclamationmark.triangle.fill")).foregroundColor(Palette.gold)
            if let words = m.warningText {
                t = t + Text(verbatim: "\u{00A0}" + words)   // Home Assistant only: "Bedroom fan unavailable"
            } else {
                t = t + Text(m.warnings == 1 ? "\u{00A0}1\u{00A0}warning" : "\u{00A0}\(m.warnings)\u{00A0}warnings")
            }
        }
        return t
    }

    private func statusSymbol(_ level: TodayMood.Level) -> String? {
        switch level {
        case .alarm: "exclamationmark.octagon.fill"
        case .headsUp: "exclamationmark.triangle.fill"
        case .calm: "checkmark.circle.fill"
        case .unknown: nil
        }
    }

    /// What the voice says about the most notable fact (Voice.take: the real numbers, with an opinion); without a
    /// take (no data yet, the lab unreachable) the mood's general line. Each tap on it moves to the next variant.
    private func take(_ m: TodayMood) -> String? {
        let voice = model.settings.voice
        guard model.selected != nil, voice != .off else { return nil }
        let count = Voice.takeCount(for: state, personality: voice)
        if count > 0, let t = Voice.take(for: state, personality: voice, variant: pokes % count) { return t.text }
        let all = Voice.lines(Voice.moment(m.level), voice)
        guard !all.isEmpty else { return nil }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
        return all[(day + pokes) % all.count]
    }

    private var dateLine: String {
        Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private var weatherCard: Card? { state?.cards.first { $0.id == "weather" } }

    /// The weather sentence: the card's subtitle, with the temperature now when it doesn't say one (`WeatherLine`).
    private var weather: String? { WeatherLine.text(weatherCard) }

    /// Where the data is from, only while a pull to refresh runs (and a moment after), after a failed fetch, or when
    /// the data is older than 10 min. Overkill shows it always (it also lists what the server is busy with).
    private var showsFacts: Bool {
        guard model.selected != nil else { return false }
        if density == .overkill { return true }
        return FreshnessLine.shows(pulled: pulled, failed: status.error != nil, fetched: status.snapshot?.fetched,
                                   checked: state?.checked)
    }

    /// A pull to refresh: the line shows while it runs and 3 s after, so "checked just now" can be read.
    private func pullToRefresh() async {
        pulls += 1
        let pull = pulls
        pulled = true
        await model.refresh()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if pulls == pull { pulled = false }
        }
    }

    /// "homelab · checked 2 min ago"
    private var facts: String {
        var parts: [String] = []
        if let name = status.snapshot?.serverName ?? model.selected?.name { parts.append(name) }
        if status.loading {
            parts.append(String(localized: "updating…"))
        } else if let checked = state?.checked {
            parts.append(String(localized: "checked \(when(checked))"))
        }
        if let fetched = status.snapshot?.fetched, status.snapshot?.isStale() == true {
            parts.append(String(localized: "data from \(when(fetched))"))
        }
        if density == .overkill, let busy = state?.busy, !busy.isEmpty {
            parts.append(String(localized: "busy: \(busy.joined(separator: ", "))"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Content

    @ViewBuilder
    private func section(for section: TodaySection, shown: [TodaySection]) -> some View {
        switch section {
        case .day:
            if let dayCard { DaySection(card: dayCard, plainLines: density != .calm) }
        case .waiting:
            if let state, model.selected != nil, !state.pending.isEmpty { waiting(state.pending) }
        case .deals:
            // Deals are a row of the Also panel (with the cards); alone only when the cards are not on Today.
            if !shown.contains(.cards), model.selected != nil, !freshDeals.isEmpty { alsoOnly }
        case .home:
            if let ha = model.homeAssistant { HomeTiles(model: model, server: ha, home: home) }
        case .cards:
            if let state, model.selected != nil { otherCards(state, withDeals: shown.contains(.deals)) }
        case .report:
            if let state, model.selected != nil { lastReport(state) }
        case .machines:
            EmptyView()   // retired: the machines are in Lab; the headline says how many are up
        }
    }

    /// Actions the agent proposed, so they are seen first thing. Tap opens Actions (with the confirm step there).
    /// At accessibility sizes the age goes under the title, so the title keeps the row's width.
    private func waiting(_ pending: [PendingAction]) -> some View {
        let ageBelow = density.exactTimes || typeSize.isAccessibilitySize
        let cap = TodayFold.approvals(density)
        let shown = Array(pending.prefix(cap))
        return VStack(alignment: .leading, spacing: Space.titleToPanel) {
            SectionTitle(text: "To approve", trailing: "\(pending.count)")
            Button {
                model.tab = .actions
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { TodaySeparator() }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: "checkmark.shield").foregroundStyle(Palette.gold).font(Typo.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text([p.action, p.arg].compactMap { $0 }.joined(separator: " "))
                                    .font(Typo.headline).foregroundStyle(Palette.text).lineLimit(2)
                                if let reason = p.reason {
                                    Text(reason).font(Typo.secondary).foregroundStyle(Palette.secondary)
                                        .lineLimit(density == .overkill ? nil : 2)
                                }
                                // Overkill's exact times are long, and at AX sizes every line is: their own line,
                                // so the title keeps its room.
                                if ageBelow, let created = p.created {
                                    Text(when(created))
                                        .font(density.exactTimes ? Typo.data(.footnote) : Typo.meta)
                                        .foregroundStyle(Palette.tertiary)
                                        .accessibilityLabel(Format.spoken(when(created)))
                                }
                            }
                            Spacer(minLength: 8)
                            if !ageBelow, let created = p.created {
                                Text(when(created)).font(Typo.meta).foregroundStyle(Palette.tertiary)
                                    .accessibilityLabel(Format.spoken(when(created)))
                            }
                        }
                        .multilineTextAlignment(.leading)
                    }
                    if pending.count > cap {
                        // A real row: the whole panel opens Actions, and this says how many more wait there.
                        TodaySeparator()
                        HStack {
                            Text("and \(pending.count - cap) more").font(Typo.secondary).foregroundStyle(Palette.secondary)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(Typo.meta.weight(.semibold))
                                .foregroundStyle(Palette.tertiary).accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.vertical, -6)
                        .accessibilityLabel(Text("\(pending.count - cap) more to approve"))
                    }
                }
                .panel()
            }
            .buttonStyle(.press)
            .accessibilityHint(Text("Opens Actions"))
        }
    }

    /// The "act now" deals from the last day (empty for a server without deals).
    private var freshDeals: [Deal] { status.deals?.freshAct() ?? [] }

    /// A deal's rows, opened in the Also panel; at accessibility sizes the figures go under the title. The last row
    /// opens the Deals screen.
    private func dealRows(_ fresh: [Deal]) -> some View {
        let stacked = typeSize.isAccessibilitySize
        let shown = Array(fresh.prefix(density == .overkill ? fresh.count : 4))
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, deal in
                if i > 0 { TodaySeparator() }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(deal.title).font(Typo.headline).foregroundStyle(Palette.text).lineLimit(2)
                            if let line = deal.note ?? deal.place {
                                Text(line).font(Typo.secondary).foregroundStyle(Palette.secondary)
                                    .lineLimit(density == .overkill ? nil : 2)
                            }
                        }
                        Spacer(minLength: 8)
                        if !stacked { DealFigures(deal: deal) }
                    }
                    if stacked { DealFigures(deal: deal, leading: true) }
                    if !deal.flags.isEmpty { DealFlags(flags: deal.flags, limit: 1) }
                }
                .multilineTextAlignment(.leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(deal.spoken)
            }
            Button { model.showDeals() } label: {
                HStack {
                    Text(fresh.count > shown.count ? "All \(fresh.count) deals" : "Open Deals")
                        .font(Typo.secondary).foregroundStyle(Palette.secondary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(Typo.meta.weight(.semibold)).foregroundStyle(Palette.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens Deals"))
        }
    }

    /// The expanded state of a fold, for `CardView`: this card's id in the session's set.
    private func foldContext(_ card: Card) -> TodayFoldContext {
        TodayFoldContext(density: density, expanded: expanded.contains(card.id)) { toggle(card.id, title: card.title ?? card.id) }
    }

    /// Opens or closes a fold or an Also row; VoiceOver hears what happened.
    private func toggle(_ id: String, title: String) {
        if expanded.remove(id) == nil {
            expanded.insert(id)
            AccessibilityNotification.Announcement(String(localized: "\(title) expanded")).post()
        } else {
            AccessibilityNotification.Announcement(String(localized: "\(title) collapsed")).post()
        }
    }

    /// The Also panel's rows: deals first (when the Deals section is on), then the summarised cards.
    private func alsoItems(_ cards: [Card], deals: [Deal], now: Date) -> [AlsoItem] {
        var items: [AlsoItem] = []
        if let text = TodayFold.summary(deals: deals, density: density) {
            items.append(AlsoItem(kind: .deals, summary: text, count: deals.count, content: AnyView(dealRows(deals))))
        }
        for card in cards {
            guard let kind = TodayFold.alsoKind(card), let text = TodayFold.summary(card, now: now, density: density) else { continue }
            let count = kind == .departures ? nil : card.items.count
            items.append(AlsoItem(kind: kind, summary: text, count: count,
                                  content: AnyView(CardView(card: card, model: model, bare: true))))
        }
        return items
    }

    /// The Also panel with deals only (the cards section is off).
    @ViewBuilder
    private var alsoOnly: some View {
        let items = alsoItems([], deals: freshDeals, now: .now)
        if !items.isEmpty {
            AlsoPanel(items: items, density: density, expanded: expanded) { toggle($0, title: String(localized: "Deals")) }
        }
    }

    /// The server's other Today cards, folded (`TodayFold`): the weather is the hero's, a short list card is one line,
    /// deals, downloads, grades and departures are the Also panel (departures a full board while "Leave by" is near).
    @ViewBuilder
    private func otherCards(_ state: HomelabState, withDeals: Bool) -> some View {
        let deals = withDeals ? freshDeals : []
        let any = state.cards.contains { $0.id != dayCard?.id && $0.place != .lab && TodayFold.drawsOnToday($0) } || !deals.isEmpty
        if any {
            // Every minute: a departure board appears when "Leave by" gets near, its trains drop off.
            TimelineView(.everyMinute) { context in
                let now = context.date
                let board = state.departuresCard.map(DepartureBoard.init(card:))
                let matters = board.map { TodayFold.departuresMatter($0, day: dayCard, now: now) } ?? false
                let plan = TodayFold.plan(state.cards, dayCardID: dayCard?.id, departuresMatter: matters)
                let items = alsoItems(plan.also, deals: deals, now: now)
                VStack(alignment: .leading, spacing: Space.section) {
                    ForEach(Array(plan.blocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .card(let card): CardView(card: card, model: model, fold: foldContext(card))
                        case .line(let card, let text): OneLineCard(card: card, text: text)
                        }
                    }
                    if !items.isEmpty {
                        AlsoPanel(items: items, density: density, expanded: expanded) { toggle($0, title: String(localized: "Also")) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func lastReport(_ state: HomelabState) -> some View {
        if let m = state.lastMessage, !m.text.isEmpty {
            VStack(alignment: .leading, spacing: Space.titleToPanel) {
                SectionTitle(text: "Last report", trailing: m.ts.map { when($0) })
                Button {
                    model.tab = .chat
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        if let job = m.job {
                            HStack(spacing: 8) {
                                Circle().fill(statusColor(m.status)).frame(width: 8, height: 8).accessibilityHidden(true)
                                Text(job).font(Typo.headline).foregroundStyle(Palette.text)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(statusWord(m.status).map { Text($0) } ?? Text(""))
                        }
                        Text(markdown(m.text)).font(Typo.secondary).foregroundStyle(Palette.secondary)
                            .lineLimit(10).multilineTextAlignment(.leading)
                            .tint(Palette.iris)
                    }
                    .panel()
                }
                .buttonStyle(.press)
                .disabled(!model.availableTabs.contains(.chat))
            }
        }
    }
}

// MARK: - The day

/// The day under the hero, from the server's "today" card. Its clock times become a line through the day
/// (wake-up → leave by → first lesson) that fills up to now; the next stop is bright and counts down, past ones fade.
/// Items without a time (a disruption, "Leave by ?") are notes under the line. A card without clock times keeps the
/// big-number grid; a text card ("No school today: …") shows its text.
struct DaySection: View {
    let card: Card
    /// A day that is only a short sentence ("No school") is one plain line without a panel (Standard and Overkill;
    /// Calm keeps its panel).
    var plainLines = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Redrawn every minute, so the line and the countdown move while the screen is open.
        TimelineView(.everyMinute) { context in
            let line = DayTimeline(card: card, now: context.date)
            if plainLines, line.stops.isEmpty, !line.isStale, line.notes.isEmpty, TodayFold.isPlainLine(line.text), let text = line.text {
                plainLine(line, text)
            } else {
            ZStack(alignment: .topLeading) {
                // VoiceOver's heading for the section (the rotor jumps here): the visible "Tomorrow" / "From yesterday"
                // line, or an invisible "Today" (the panel has no title on screen).
                if !line.isTomorrow && !line.isStale {
                    Color.clear.frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityLabel(Text("Today"))
                        .accessibilityAddTraits(.isHeader)
                }
                VStack(alignment: .leading, spacing: 16) {
                    if line.isTomorrow {
                        // From the phone's own clock, not the server's title: a cached evening card is "Today" after midnight.
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("Tomorrow").font(Typo.headline).foregroundStyle(Palette.text)
                            if let day = DayTimeline.day(card.date) {
                                Text(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                                    .font(Typo.secondary).foregroundStyle(Palette.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                    } else if line.isStale {
                        Text(Self.staleText(line.staleDays, card.date)).font(Typo.meta).foregroundStyle(Palette.tertiary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    if line.stops.isEmpty {
                        if let text = line.text {
                            Text(markdown(text)).font(Typo.body).foregroundStyle(Palette.text).tint(Palette.iris)
                        } else {
                            DayNumbers(items: line.notes)
                        }
                    } else {
                        if line.across(accessibilityText: typeSize.isAccessibilitySize) {
                            // One clear statement first ("Leave by 21:27 · in 26 min"), the line under it as a quiet track
                            // (design research #2: the three big times competed with the hero).
                            if let next = line.next { statement(next, countdown: line.minutesToNext) }
                            DayLineAcross(line: line, compact: line.next != nil)
                        } else {
                            down(line)
                        }
                        if !line.notes.isEmpty {
                            TodaySeparator()
                            notes(line.notes)
                        }
                    }
                }
            }
            .panel()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(line.isTomorrow ? String(localized: "Tomorrow") : line.isStale ? Self.staleText(line.staleDays, card.date) : String(localized: "Today")))
            }
        }
    }

    /// "Tomorrow · No school": the day without events as one line of text, no panel. Today's is the sentence alone.
    private func plainLine(_ line: DayTimeline, _ text: String) -> some View {
        let words = Text(markdown(text)).font(Typo.body).foregroundColor(line.isTomorrow ? Palette.secondary : Palette.text)
        return Group {
            if line.isTomorrow {
                (Text("Tomorrow").font(Typo.headline).foregroundColor(Palette.text) + Text("  ·  ").font(Typo.body).foregroundColor(Palette.tertiary) + words)
                    .accessibilityAddTraits(.isHeader)
            } else {
                words.tint(Palette.iris)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    /// The next stop as a sentence: "Leave by **21:27**", then "in 26 min · U6 21:32".
    private func statement(_ next: DayTimeline.Stop, countdown: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(next.item.title ?? "").font(.title2.weight(.semibold)).foregroundStyle(Palette.text)
                Text(next.item.value ?? "").font(Typo.displayData).foregroundStyle(next.item.tint?.color ?? Palette.text)
                    .contentTransition(Motion.numeric)
            }
            let parts = [countdown.map { Format.countdown(minutes: $0) }, next.item.subtitle].compactMap { $0 }
            if !parts.isEmpty {
                Text(parts.joined(separator: " · ")).font(Typo.secondary).foregroundStyle(Palette.secondary)
                    .accessibilityLabel(Format.spoken(parts.joined(separator: ", ")))
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "From yesterday", "From Wed 4 Nov": the cached card is older than today, so nothing on it counts down.
    static func staleText(_ days: Int, _ date: String?) -> String {
        if days == 1 { return String(localized: "From yesterday") }
        guard let day = DayTimeline.day(date) else { return String(localized: "From an earlier day") }
        return String(localized: "From \(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))")
    }

    /// Side by side: equal columns, each with its piece of the line on top (shared with the Day widget).
    private func across(_ line: DayTimeline) -> some View {
        DayLineAcross(line: line)
    }

    /// Top to bottom (huge text, or more stops than fit across): the line runs down the left edge.
    private func down(_ line: DayTimeline) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(line.stops.enumerated()), id: \.offset) { i, stop in
                DayStopLabel(stop: stop, countdown: line.minutesToNext)
                    .padding(.leading, 30)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(alignment: .topLeading) {
                        // As tall as the row and moved down, so the dot sits beside the big time and the line
                        // reaches the next row's dot.
                        DayRail(phase: stop.phase, fill: line.fill(after: i), axis: .vertical,
                                showsLine: i < line.stops.count - 1)
                            .frame(width: 18)
                            .offset(y: 9)
                    }
            }
        }
    }

    /// Items without a time: a status dot in the item's colour (if it has one), then what it says, in words.
    private func notes(_ items: [Card.Item]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let tint = item.tint?.color {
                        Circle().fill(tint).frame(width: 8, height: 8).accessibilityHidden(true)
                    }
                    (Text(item.title ?? "").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.text)
                     + Text(" " + [item.value, item.subtitle].compactMap { $0 }.joined(separator: " · "))
                        .font(Typo.secondary).foregroundStyle(Palette.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The day in big numbers, for a card without clock times: mono numbers, sentence-case labels (the section's panel
/// is around it).
struct DayNumbers: View {
    let items: [Card.Item]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible(), alignment: .topLeading)]
                                                            : [GridItem(.adaptive(minimum: 96), spacing: 12, alignment: .topLeading)],
                      alignment: .leading, spacing: 16) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.value ?? "–")
                            .font(Typo.data(.title, weight: .semibold))
                            .minimumScaleFactor(0.6).lineLimit(1)
                            .foregroundStyle(item.tint?.color ?? Palette.text)
                            .numberMotion(item.value)
                        Text(item.title ?? "").font(Typo.secondary).foregroundStyle(Palette.secondary).lineLimitAtStandardSizes(1)
                        if let s = item.subtitle {
                            Text(s).font(Typo.meta).foregroundStyle(Palette.tertiary).lineLimitAtStandardSizes(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(Self.isHigh(item.tint) ? Text("high") : Text(""))
                }
            }
        }
    }

    /// A gold or love number (orange, yellow or red from the server) is over its limit: VoiceOver says "high", as
    /// the colour alone doesn't (docs/DESIGN.md §3).
    static func isHigh(_ tint: Tint?) -> Bool {
        switch tint {
        case .orange, .yellow, .red: true
        default: false
        }
    }
}
