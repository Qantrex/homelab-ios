import HomelabDesign
import HomelabKit
import SwiftUI

/// Today: the first screen. My day first (the server's "today" card, what waits for me, Home tiles, the other cards,
/// the last report), the machines only as one status line that opens Lab.
struct TodayView: View {
    let model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Taps on the voice line (each one: the next comment).
    @State private var pokes = 0

    private var status: ServerStatus { model.selectedStatus }
    private var density: Density { model.settings.todayDensity }
    private func when(_ date: Date?) -> String { Format.when(date, exact: density.exactTimes) }
    private var state: HomelabState? { status.snapshot?.state }

    private var dayCard: Card? { state?.dayCard }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    hero
                    if model.selected != nil {
                        if let error = status.error {
                            ErrorBanner(error: error, snapshotAge: status.snapshot?.fetched) { Task { await model.refresh() } }
                        }
                        if state == nil {
                            if status.loading {
                                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                            } else if status.error == nil {
                                Placeholder(title: "No data yet", symbol: "tray", message: "Pull down to load.")
                            }
                        }
                    }
                    // In my order, without the hidden ones (Settings → Today).
                    ForEach(density.sections(model.settings.todayLayout)) { section(for: $0) }
                }
                .animation(.snappy, value: shape)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
            .background { MoodGlow(level: mood.level).ignoresSafeArea() }
            .refreshable { await model.refresh() }
            .toolbar(.hidden, for: .navigationBar)
            .pollingState(model)
            // A tap you can feel when the lab turns bad while you're looking.
            .sensoryFeedback(trigger: mood.level) { old, new in
                new == .alarm && old != .alarm ? .error : nil
            }
        }
    }

    /// What decides which panels show: when it changes (an action approved elsewhere, a download done, a section
    /// turned off), panels slide instead of jumping.
    private var shape: [String] {
        density.sections(model.settings.todayLayout).map(\.rawValue)
            + (state?.pending.map { "p:" + $0.id } ?? [])
            + (state?.cards.map { "c:\($0.id):\($0.items.count)" } ?? [])
            + [state == nil ? "empty" : "loaded"]
    }

    // MARK: Hero

    private var mood: TodayMood {
        // Before the first answer: "Checking…" (grey) while it's on its way, "No signal." once it failed.
        model.selected == nil ? TodayMood(level: .unknown, headline: String(localized: "Home."), detail: nil)
                              : TodayMood(state: state, checking: status.error == nil)
    }

    /// The big "now" (docs/DESIGN.md): the date, how the lab is doing in two words (white; the mood is the light
    /// behind it and the status icon), what the voice thinks of it, the first problem, where the data is from.
    /// Tap opens Lab.
    private var hero: some View {
        let m = mood
        return Button {
            if model.availableTabs.contains(.lab) { model.tab = .lab }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    if let symbol = statusSymbol(m.level) {
                        Image(systemName: symbol).foregroundStyle(m.level.color).font(.footnote.weight(.semibold))
                    }
                    Text(dateLine).font(.footnote.weight(.medium)).foregroundStyle(Palette.secondary)
                }
                Text(m.headline)
                    .font(Typo.hero)
                    .tracking(-1)
                    .foregroundStyle(Palette.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    .padding(.top, 4)
                if let detail = m.detail {
                    Text(detail).font(.title3.weight(.semibold)).foregroundStyle(Palette.text)
                        .lineLimit(3).multilineTextAlignment(.leading)
                        .padding(.top, 8)
                }
                // The voice: what it thinks of the facts above, in words (DESIGN.md §4). Tap the line for another.
                if let take = take(m) {
                    Text(take).font(.title3).foregroundStyle(Palette.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                        .id(take)
                        .transition(.opacity)
                        .onTapGesture { pokes += 1 }
                        .sensoryFeedback(.selection, trigger: pokes)
                }
                if m.warnings > 0 {
                    Label(m.warnings == 1 ? "and 1 warning" : "and \(m.warnings) warnings",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.gold)
                        .padding(.top, 8)
                }
                Text(facts).font(.footnote).foregroundStyle(Palette.tertiary).padding(.top, 12)
                // The weather card's one line ("Rain from 15:00, take an umbrella"); Calm shows only the card.
                if density != .calm, let weather {
                    Text(weather).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1).padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 28)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
            .animation(.snappy, value: m)
            .animation(.snappy, value: pokes)
        }
        .buttonStyle(.pressLight)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint(Text("Opens Lab"))
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

    /// The `weather` card's subtitle, when there is one.
    private var weather: String? {
        state?.cards.first { $0.id == "weather" }?.subtitle.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "DEMO HOMELAB · CHECKED 2 MIN AGO"
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
    private func section(for section: TodaySection) -> some View {
        switch section {
        case .day:
            if let dayCard { DaySection(card: dayCard) }
        case .waiting:
            if let state, model.selected != nil, !state.pending.isEmpty { waiting(state.pending) }
        case .home:
            if let ha = model.homeAssistant { HomeTiles(model: model, server: ha) }
        case .cards:
            if let state, model.selected != nil { otherCards(state) }
        case .report:
            if let state, model.selected != nil { lastReport(state) }
        case .machines:
            if let state, model.selected != nil, !state.hosts.isEmpty { MachineList(hosts: state.hosts, state: state, exact: density.exactTimes) }
        }
    }

    /// Actions the agent proposed, so they are seen first thing. Tap opens Actions (with the confirm step there).
    private func waiting(_ pending: [PendingAction]) -> some View {
        let shown = Array(pending.prefix(density == .overkill ? pending.count : 3))
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Waiting for you", trailing: "\(pending.count)")
            Button {
                model.tab = .actions
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { TodaySeparator() }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: "checkmark.shield").foregroundStyle(Palette.gold).font(.subheadline)
                            VStack(alignment: .leading, spacing: 4) {
                                Text([p.action, p.arg].compactMap { $0 }.joined(separator: " "))
                                    .font(.headline).foregroundStyle(Palette.text).lineLimit(2)
                                if let reason = p.reason {
                                    Text(reason).font(.subheadline).foregroundStyle(Palette.secondary)
                                        .lineLimit(density == .overkill ? nil : 2)
                                }
                                // Overkill's exact times are long: their own line, so the title keeps its room.
                                if density.exactTimes, let created = p.created {
                                    Text(when(created)).font(Typo.data(.footnote)).foregroundStyle(Palette.tertiary)
                                }
                            }
                            Spacer(minLength: 8)
                            if !density.exactTimes, let created = p.created {
                                Text(when(created)).font(.footnote).foregroundStyle(Palette.tertiary)
                            }
                        }
                        .multilineTextAlignment(.leading)
                    }
                    if density != .overkill, pending.count > 3 {
                        TodaySeparator()
                        Text("and \(pending.count - 3) more").font(.footnote).foregroundStyle(Palette.tertiary)
                    }
                }
                .panel()
            }
            .buttonStyle(.press)
            .accessibilityHint(Text("Opens Actions"))
        }
    }

    @ViewBuilder
    private func otherCards(_ state: HomelabState) -> some View {
        ForEach(state.cards.filter { $0.id != dayCard?.id && $0.place != .lab }) { CardView(card: $0, model: model) }
    }

    @ViewBuilder
    private func lastReport(_ state: HomelabState) -> some View {
        if let m = state.lastMessage, !m.text.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Last report", trailing: m.ts.map { when($0) })
                Button {
                    model.tab = .chat
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        if let job = m.job {
                            HStack(spacing: 8) {
                                Circle().fill(statusColor(m.status)).frame(width: 8, height: 8).accessibilityHidden(true)
                                Text(job).font(.headline).foregroundStyle(Palette.text)
                            }
                        }
                        Text(markdown(m.text)).font(.subheadline).foregroundStyle(Palette.secondary)
                            .lineLimit(10).multilineTextAlignment(.leading)
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
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Redrawn every minute, so the line and the countdown move while the screen is open.
        TimelineView(.everyMinute) { context in
            let line = DayTimeline(card: card, now: context.date)
            VStack(alignment: .leading, spacing: 16) {
                if line.isTomorrow {
                    Text(card.title ?? String(localized: "Tomorrow")).font(.headline).foregroundStyle(Palette.text)
                }
                if line.stops.isEmpty {
                    if let text = line.text {
                        Text(markdown(text)).font(.body).foregroundStyle(Palette.text)
                    } else {
                        DayNumbers(items: line.notes)
                    }
                } else {
                    if line.across(accessibilityText: typeSize.isAccessibilitySize) { across(line) } else { down(line) }
                    if !line.notes.isEmpty {
                        TodaySeparator()
                        notes(line.notes)
                    }
                }
            }
            .panel()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(card.title ?? String(localized: DayTimeline.isTomorrow(card.date, now: Date()) ? "Tomorrow" : "Today")))
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
                        .font(.subheadline).foregroundStyle(Palette.secondary))
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
                            .contentTransition(.numericText())
                            .animation(.snappy, value: item.value)
                        Text(item.title ?? "").font(.subheadline).foregroundStyle(Palette.secondary).lineLimit(1)
                        if let s = item.subtitle {
                            Text(s).font(.footnote).foregroundStyle(Palette.tertiary).lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// Overkill: every machine with all its numbers and its 24 h load, one dense block each. Tap a host in Lab for the
/// details screen.
struct MachineList: View {
    let hosts: [Host]
    /// The state the hosts come from, for each host's level (`HomelabState.health(of:)`).
    let state: HomelabState
    let exact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Machines", trailing: "\(hosts.filter { $0.reachable == true }.count)/\(hosts.count) up")
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(hosts.enumerated()), id: \.element.id) { i, host in
                    if i > 0 { TodaySeparator() }
                    let health = state.health(of: host)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Circle().fill(health.color).frame(width: 8, height: 8).accessibilityHidden(true)
                            Text(host.name).font(.headline)
                            if health != .ok { Text(health.label).font(.subheadline).foregroundStyle(Palette.secondary) }
                            Spacer(minLength: 4)
                            if let checked = host.checked {
                                Text(Format.when(checked, exact: exact)).font(.footnote).foregroundStyle(Palette.tertiary).lineLimit(1)
                            }
                        }
                        numbers(host)
                            .fixedSize(horizontal: false, vertical: true)
                        if let history = host.history, history.last(.load) != nil {
                            Sparkline(history, .load, cores: host.cpuCount, label: String(localized: "\(host.name) load, last 24 hours"),
                                      lineWidth: 1.2, fill: false)
                                .frame(height: 18)
                                .padding(.top, 4)
                        }
                        if !host.flags.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill").font(.footnote)
                                    .foregroundStyle(health == .problem ? Palette.love : Palette.gold)
                                    .accessibilityHidden(true)
                                Text(host.flags.map(Format.flag).joined(separator: " · ")).font(.footnote)
                                    .foregroundStyle(Palette.secondary)
                            }
                            .padding(.top, 2)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .panel()
        }
    }

    /// "Load 1.85/4 · RAM 71% · / 81% · 63 °C · Containers 14/14 · Updates 3 · Reboot needed · Backup ok": the words
    /// in the text style, only the values in the data font.
    private func numbers(_ h: Host) -> Text {
        guard h.reachable == true else { return Text(HostHealth(h).label).font(.subheadline).foregroundStyle(Palette.secondary) }
        var p: [(label: String, value: String)] = []
        if h.load != nil { p.append((String(localized: "Load"), Format.load(h.load) + (h.cpuCount.map { "/\($0)" } ?? ""))) }
        if h.memPct != nil { p.append((String(localized: "RAM"), Format.percent(h.memPct))) }
        for (mount, pct) in h.disks.sorted(by: { $0.key < $1.key }) { p.append((mount, "\(pct)%")) }
        if h.temp != nil { p.append(("", Format.temperature(h.temp))) }
        if h.containersTotal != nil { p.append((String(localized: "Containers"), Format.containers(up: h.containersUp, total: h.containersTotal))) }
        if let u = h.upgradable, u > 0 { p.append((String(localized: "Updates"), "\(u)")) }
        if h.rebootRequired == true { p.append((String(localized: "Reboot needed"), "")) }
        if let b = Format.backup(last: h.backupLast, result: h.backupResult) { p.append((String(localized: "Backup"), b)) }
        var out = Text("")
        for (i, part) in p.enumerated() {
            if i > 0 { out = out + Text("  ·  ").font(.subheadline).foregroundStyle(Palette.tertiary) }
            if !part.label.isEmpty { out = out + Text(part.label + (part.value.isEmpty ? "" : " ")).font(.subheadline).foregroundStyle(Palette.secondary) }
            if !part.value.isEmpty { out = out + Text(part.value).font(Typo.data(.subheadline)).foregroundStyle(Palette.text) }
        }
        return out
    }
}
