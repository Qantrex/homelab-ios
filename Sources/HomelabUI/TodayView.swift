import HomelabDesign
import HomelabKit
import SwiftUI

/// Today: the first screen. My day first (the server's "today" card, what waits for me, Home tiles, the other cards,
/// the last report), the machines only as one status line that opens Lab.
struct TodayView: View {
    let model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize

    private var status: ServerStatus { model.selectedStatus }
    private var density: Density { model.settings.todayDensity }
    private func when(_ date: Date?) -> String { Format.when(date, exact: density.exactTimes) }
    private var state: HomelabState? { status.snapshot?.state }

    private var dayCard: Card? { state?.dayCard }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
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

    /// The big "now": date, how the lab is doing in two words, the first problem. Tap opens Lab.
    private var hero: some View {
        let m = mood
        return Button {
            if model.availableTabs.contains(.lab) { model.tab = .lab }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(dateLine).font(Typo.mono(.caption, weight: .medium)).tracking(1.5).foregroundStyle(Palette.secondary)
                Text(m.headline)
                    .font(.system(size: typeSize.isAccessibilitySize ? 40 : 54, weight: .heavy))
                    .tracking(-1.5)
                    .foregroundStyle(m.level.color)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                if model.selected != nil, let line = Voice.line(Voice.moment(m.level), model.settings.voice) {
                    Text(line).font(.title3).italic().foregroundStyle(Palette.secondary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .transition(.opacity)
                }
                if let detail = m.detail {
                    Text(detail).font(.title3.weight(.medium)).foregroundStyle(Palette.text.opacity(0.85))
                        .lineLimit(3).multilineTextAlignment(.leading)
                }
                if m.warnings > 0 {
                    Text(m.warnings == 1 ? "and 1 warning" : "and \(m.warnings) warnings")
                        .font(Typo.mono(.caption, weight: .semibold)).foregroundStyle(Palette.gold)
                }
                Text(facts).font(Typo.mono(.caption2)).tracking(1).foregroundStyle(Palette.tertiary).padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 36)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
            .animation(.snappy, value: m)
        }
        .buttonStyle(.pressLight)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint(Text("Opens Lab"))
    }

    private var dateLine: String {
        Date.now.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)).uppercased()
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
        return parts.joined(separator: " · ").uppercased()
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
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Waiting for you", trailing: "\(pending.count)")
            Button {
                model.tab = .actions
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(pending.prefix(density == .overkill ? pending.count : 3)) { p in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "checkmark.shield").foregroundStyle(Palette.gold)
                            VStack(alignment: .leading, spacing: 2) {
                                Text([p.action, p.arg].compactMap { $0 }.joined(separator: " "))
                                    .font(Typo.mono(.subheadline, weight: .semibold)).lineLimit(1)
                                if let reason = p.reason {
                                    Text(reason).font(.caption).foregroundStyle(Palette.secondary)
                                        .lineLimit(density == .overkill ? nil : 2)
                                }
                                // Overkill's exact times are long: their own line, so the title keeps its room.
                                if density.exactTimes, let created = p.created {
                                    Text(when(created)).font(Typo.mono(.caption2)).foregroundStyle(Palette.tertiary)
                                }
                            }
                            Spacer(minLength: 8)
                            if !density.exactTimes, let created = p.created {
                                Text(when(created)).font(Typo.mono(.caption2)).foregroundStyle(Palette.tertiary)
                            }
                        }
                    }
                    if density != .overkill, pending.count > 3 {
                        Text("and \(pending.count - 3) more").font(Typo.mono(.caption2)).foregroundStyle(Palette.tertiary)
                    }
                }
                .card(accent: Palette.gold)
            }
            .buttonStyle(.press)
            .accessibilityHint(Text("Opens Actions"))
        }
    }

    @ViewBuilder
    private func otherCards(_ state: HomelabState) -> some View {
        ForEach(state.cards.filter { $0.id != dayCard?.id }) { CardView(card: $0, model: model) }
    }

    @ViewBuilder
    private func lastReport(_ state: HomelabState) -> some View {
        if let m = state.lastMessage, !m.text.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "Last report", trailing: m.ts.map { when($0) })
                Button {
                    model.tab = .chat
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        if let job = m.job { Chip(job, color: statusColor(m.status)) }
                        Text(markdown(m.text)).font(.subheadline).lineLimit(10).multilineTextAlignment(.leading)
                    }
                    .card()
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
            VStack(alignment: .leading, spacing: 14) {
                if line.stops.isEmpty {
                    Rectangle().fill(Palette.line).frame(height: 1)
                    if let text = line.text {
                        Text(markdown(text)).font(.title3.weight(.medium)).foregroundStyle(Palette.secondary)
                    } else {
                        DayNumbers(items: line.notes)
                    }
                } else {
                    if line.across(accessibilityText: typeSize.isAccessibilitySize) { across(line) } else { down(line) }
                    if !line.notes.isEmpty { notes(line.notes) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(card.title ?? String(localized: "Today")))
    }

    /// Side by side: equal columns, each with its piece of the line on top (shared with the Day widget).
    private func across(_ line: DayTimeline) -> some View {
        DayLineAcross(line: line)
    }

    /// Top to bottom (huge text, or more stops than fit across): the line runs down the left edge.
    private func down(_ line: DayTimeline) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Palette.line).frame(height: 1).padding(.bottom, 14)
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

    private func notes(_ items: [Card.Item]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title ?? "").textCase(.uppercase).font(Typo.mono(.caption2, weight: .semibold)).tracking(1)
                        .foregroundStyle(item.tint?.color ?? Palette.secondary)
                    Text([item.value, item.subtitle].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(item.tint?.color ?? Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The day in big numbers, for a card without clock times: no panel, mono numbers.
struct DayNumbers: View {
    let items: [Card.Item]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible(), alignment: .topLeading)]
                                                            : [GridItem(.adaptive(minimum: 96), spacing: 12, alignment: .topLeading)],
                      alignment: .leading, spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.value ?? "–")
                            .font(.system(size: 30, weight: .semibold, design: .monospaced))
                            .minimumScaleFactor(0.6).lineLimit(1)
                            .foregroundStyle(item.tint?.color ?? Palette.text)
                            .contentTransition(.numericText())
                            .animation(.snappy, value: item.value)
                        Text(item.title ?? "").textCase(.uppercase).font(Typo.mono(.caption2, weight: .medium))
                            .tracking(1).foregroundStyle(Palette.secondary).lineLimit(1)
                        if let s = item.subtitle {
                            Text(s).font(Typo.mono(.caption2)).foregroundStyle(Palette.tertiary).lineLimit(1)
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
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Machines", trailing: "\(hosts.filter { $0.reachable == true }.count)/\(hosts.count) up")
            VStack(alignment: .leading, spacing: 12) {
                ForEach(hosts) { host in
                    let health = state.health(of: host)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle().fill(health.color).frame(width: 7, height: 7)
                            Text(host.name).font(Typo.mono(.subheadline, weight: .semibold))
                            if health != .ok { Text(health.label.uppercased()).font(Typo.mono(.caption2, weight: .semibold)).foregroundStyle(health.color) }
                            Spacer(minLength: 4)
                            if let checked = host.checked {
                                Text(Format.when(checked, exact: exact)).font(Typo.mono(.caption2)).foregroundStyle(Palette.tertiary).lineLimit(1)
                            }
                        }
                        Text(numbers(host)).font(Typo.mono(.caption)).foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let history = host.history, history.last(.load) != nil {
                            Sparkline(history, .load, cores: host.cpuCount, label: String(localized: "\(host.name) load, last 24 hours"),
                                      lineWidth: 1.2, fill: false)
                                .frame(height: 18)
                                .padding(.top, 2)
                        }
                        if !host.flags.isEmpty {
                            Text(host.flags.map(Format.flag).joined(separator: " · ")).font(Typo.mono(.caption2))
                                .foregroundStyle(health == .problem ? Palette.love : Palette.gold)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .card()
        }
    }

    /// "LOAD 1.85/4 · RAM 71% · / 81% · /srv 40% · 63 °C · CT 14/14 · UPD 3 · REBOOT · BACKUP ok"
    private func numbers(_ h: Host) -> String {
        guard h.reachable == true else { return HostHealth(h).label }
        var p: [String] = []
        if h.load != nil { p.append("LOAD " + Format.load(h.load) + (h.cpuCount.map { "/\($0)" } ?? "")) }
        if h.memPct != nil { p.append("RAM " + Format.percent(h.memPct)) }
        for (mount, pct) in h.disks.sorted(by: { $0.key < $1.key }) { p.append("\(mount) \(pct)%") }
        if h.temp != nil { p.append(Format.temperature(h.temp)) }
        if h.containersTotal != nil { p.append("CT " + Format.containers(up: h.containersUp, total: h.containersTotal)) }
        if let u = h.upgradable, u > 0 { p.append("UPD \(u)") }
        if h.rebootRequired == true { p.append("REBOOT") }
        if let b = Format.backup(last: h.backupLast, result: h.backupResult) { p.append("BACKUP " + b) }
        return p.joined(separator: " · ")
    }
}
