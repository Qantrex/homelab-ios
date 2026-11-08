import HomelabDesign
import HomelabKit
import SwiftUI

/// Lab: the machines. Problems, every host (tap for details), and the service launcher.
struct LabView: View {
    let model: AppModel
    @State private var path: [Host] = []
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.hyper) private var hyper

    private var status: ServerStatus { model.selectedStatus }
    private var state: HomelabState? { status.snapshot?.state }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.section) {
                    header
                    // Hyperdetail: which server answered, and when.
                    if let hyper, model.selected != nil {
                        HyperSection(title: "Server", lines: Hyper.server(
                            name: model.selected?.name ?? "none", snapshot: status.snapshot, info: status.knownInfo,
                            failures: status.failures, busy: state?.busy ?? [], now: hyper.now, calendar: hyper.calendar),
                                     fact: model.selected.map { Hyper.fact(server: $0.name, snapshot: status.snapshot, now: hyper.now) })
                    }
                    if let error = status.error {
                        ErrorBanner(error: error, snapshotAge: status.snapshot?.fetched, retry: { refresh() },
                                    edit: model.selected.map { s in { model.requestEdit(s.id) } })
                    }
                    if let state {
                        content(state)
                    } else if status.loading {
                        ProgressView("Loading…").frame(maxWidth: .infinity).padding(.top, 60)
                    } else if status.error == nil {
                        Placeholder(title: "No data yet", symbol: "tray", message: "Pull down to load.")
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .screenBackground()
            .refreshable { await model.refresh() }
            .navigationTitle("Lab")
            .toolbar { serverMenu }
            .navigationDestination(for: Host.self) { HostDetailView(model: model, host: $0) }
            .pollingState(model)
            .onChange(of: model.openHost) { _, _ in openRequestedHost() }
            .onChange(of: model.tab) { _, _ in openRequestedHost() }
            .onChange(of: status.snapshot?.fetched) { _, _ in openRequestedHost() }
            .onChange(of: model.selected?.id) { _, _ in path = [] }   // another server's hosts
            .onAppear { openRequestedHost() }
        }
    }

    /// A requested host (deep link, launch argument) opens once Lab shows and the state has it
    /// (`AppModel.takeOpenHost`).
    private func openRequestedHost() {
        guard model.tab == .lab else { return }
        if let host = model.takeOpenHost() { path = [host] }
    }

    private func refresh() {
        Task { await model.refresh() }
    }

    @ToolbarContentBuilder
    private var serverMenu: some ToolbarContent {
        let companions = model.servers.servers.filter(\.speaksCompanionAPI)
        if companions.count > 1 {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(companions) { s in
                        Button {
                            model.select(s.id)
                        } label: {
                            if s.id == model.selected?.id { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                        }
                    }
                } label: {
                    Label("Server", systemImage: "server.rack")
                }
            }
        }
    }

    // MARK: Header

    /// One status line (docs/DESIGN.md): the coloured status icon and how the lab is doing in 15 pt secondary, the
    /// check time under it in meta. No box.
    private var header: some View {
        let s = state?.status ?? .unknown
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: s.symbol).foregroundStyle(s.color).accessibilityHidden(true)
                Text(headline).font(Typo.secondary).foregroundStyle(Palette.secondary)
                Spacer(minLength: 0)
                if status.loading { ProgressView() }
            }
            if let mood = Voice.LabMood(state), let line = Voice.line(for: .lab(mood), personality: model.settings.voice) {
                Text(line).font(Typo.secondary).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // Large text: one fact per line instead of a wrapped "a · b · c".
            if typeSize.isAccessibilitySize {
                ForEach(sublines, id: \.self) {
                    Text($0).font(Typo.meta).foregroundStyle(Palette.tertiary).accessibilityLabel(Format.spoken($0))
                }
            } else {
                Text(sublines.joined(separator: " · ")).font(Typo.meta).foregroundStyle(Palette.tertiary)
                    .accessibilityLabel(Format.spoken(sublines.joined(separator: ", ")))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// "1 problem · 1 warning"; counted like Today's mood.
    private var headline: String {
        guard let state else { return String(localized: "Not loaded") }
        switch state.status {
        case .ok:
            // The server says ok, but hosts below may still carry a gold note (an accepted under-voltage): say so,
            // so the header doesn't read "All good" right above gold dots. Today stays calm.
            let noted = state.hosts.filter { state.health(of: $0) == .warning }.count
            if noted == 0 { return String(localized: "All good") }
            return noted == 1 ? String(localized: "No problems · 1 host with a warning")
                              : String(localized: "No problems · \(noted) hosts with a warning")
        case .unknown: return String(localized: "Status unknown")
        case .warning, .problem:
            let t = ProblemTally(state)
            var parts: [String] = []
            if t.problems > 0 { parts.append(t.problems == 1 ? String(localized: "1 problem") : String(localized: "\(t.problems) problems")) }
            if t.warnings > 0 { parts.append(t.warnings == 1 ? String(localized: "1 warning") : String(localized: "\(t.warnings) warnings")) }
            return parts.isEmpty ? String(localized: "Warning") : parts.joined(separator: " · ")
        }
    }

    private var sublines: [String] {
        var parts: [String] = []
        if let checked = state?.checked { parts.append(String(localized: "checked \(Format.age(checked))")) }
        if let fetched = status.snapshot?.fetched, status.snapshot?.isStale() == true {
            parts.append(String(localized: "updated \(Format.age(fetched))"))
        }
        return parts.isEmpty ? [model.selected?.host ?? ""] : parts
    }

    // MARK: Content

    /// Minimal: Lab fits about one screen too (`LabCompact`, review row 41).
    private var compact: Bool { LabCompact.applies(model.settings.todayDensity) }

    /// Minimal: one short line per host (dot, name, why it is not fine or "up"); a tap opens the details as before.
    @ViewBuilder
    private func compactHostsBlock(_ state: HomelabState) -> some View {
        if !state.hosts.isEmpty {
            VStack(alignment: .leading, spacing: Space.titleToPanel) {
                SectionTitle(text: "Hosts", trailing: String(localized: "\(state.hosts.filter { $0.reachable == true }.count) of \(state.hosts.count) up"))
                VStack(spacing: 0) {
                    ForEach(Array(state.hosts.enumerated()), id: \.element.id) { index, host in
                        if index > 0 { Divider().padding(.leading, 16) }
                        let health = state.health(of: host)
                        NavigationLink(value: host) {
                            HStack(spacing: 10) {
                                Circle().fill(health.color).frame(width: 8, height: 8).accessibilityHidden(true)
                                Text(host.name).font(Typo.headline).foregroundStyle(Palette.text).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(LabCompact.hostNote(host)).font(Typo.secondary).foregroundStyle(Palette.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .accessibilityElement(children: .combine)
                            .accessibilityHint(Text("Shows details"))
                        }
                        .buttonStyle(PressStyle(scale: 1))
                    }
                }
                .rowsPanel()
            }
        }
    }

    /// Minimal: a card (or the services) folded to its title and a count; a tap opens it.
    private func foldedRow<Content: View>(_ fold: (title: String, count: String?), @ViewBuilder content: () -> Content) -> some View {
        DisclosureGroup {
            content().padding(.top, 8)
        } label: {
            HStack {
                Text(fold.title).font(Typo.headline).foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                if let count = fold.count { Text(count).font(Typo.data(.subheadline)).foregroundStyle(Palette.secondary) }
            }
        }
        .tint(Palette.secondary)
        .padding(16)
        .rowsPanel()
    }

    @ViewBuilder
    private func hostsBlock(_ state: HomelabState) -> some View {
        if !state.hosts.isEmpty {
            VStack(alignment: .leading, spacing: Space.titleToPanel) {
                SectionTitle(text: "Hosts", trailing: String(localized: "\(state.hosts.filter { $0.reachable == true }.count) of \(state.hosts.count) up"))
                // One panel, a row per host in every density and text size: Load, RAM and Disk in three right-hand
                // columns (stacked under the name from xxLarge). Never tiles: three hosts made an uneven grid (owner 2026-11-08).
                VStack(spacing: 0) {
                    if !HostRow.stacked(typeSize) {
                        HostColumnHeader().padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 2)
                    }
                    ForEach(Array(state.hosts.enumerated()), id: \.element.id) { index, host in
                        if index > 0 { Divider().padding(.leading, 16) }
                        NavigationLink(value: host) { HostRow(host: host, health: state.health(of: host)) }
                            .buttonStyle(PressStyle(scale: 1))
                        if let hyper {
                            HyperNote(lines: Hyper.host(host, now: hyper.now, calendar: hyper.calendar),
                                      fact: Hyper.fact(host: host, now: hyper.now))
                                .padding(.horizontal, 16).padding(.bottom, 12)
                        }
                    }
                }
                .rowsPanel()
            }
        }
    }

    @ViewBuilder
    private func content(_ state: HomelabState) -> some View {
        if !state.problems.isEmpty {
            VStack(alignment: .leading, spacing: Space.titleToPanel) {
                SectionTitle(text: "Problems")
                // One panel, one row per problem; the waiting actions are its last row.
                VStack(spacing: 0) {
                    ForEach(Array(state.problems.enumerated()), id: \.element.id) { index, p in
                        if index > 0 { Divider().padding(.leading, 16) }
                        ProblemRow(problem: p, aside: Voice.aside(for: p, in: state, personality: model.settings.voice))
                    }
                    if !state.pending.isEmpty {
                        Divider().padding(.leading, 16)
                        pendingRow(state.pending.count)
                        pendingNotes(state.pending)
                    }
                }
                .rowsPanel()
            }
        } else if !state.pending.isEmpty {
            VStack(spacing: 0) {
                pendingRow(state.pending.count)
                pendingNotes(state.pending)
            }
            .rowsPanel()
        }

        // Hosts, the server's lab cards (tailnet, ad blocking, backups) and the services, in the owner's order and
        // without the ones hidden (Settings -> Advanced -> Lab; `LabBlocks`). Problems above stay.
        let cards = state.cards.filter { $0.place == .lab }
        ForEach(LabBlocks.visibleIDs(cards: cards, model.settings.labBlocks), id: \.self) { id in
            switch id {
            case LabBlocks.hosts: if compact { compactHostsBlock(state) } else { hostsBlock(state) }
            case LabBlocks.services:
                if !status.services.isEmpty {
                    if compact {
                        foldedRow(LabCompact.servicesFold(status.services.count)) { ServicesSection(services: status.services) }
                    } else {
                        ServicesSection(services: status.services)
                    }
                }
            default:
                if let card = cards.first(where: { $0.id == id }) {
                    if compact {
                        foldedRow(LabCompact.cardFold(card)) { CardView(card: card, lab: true, model: model) }
                    } else {
                        CardView(card: card, lab: true, model: model)
                    }
                }
            }
        }

        // Where to look when something doesn't load: also here, not only under Settings → About.
        NavigationLink {
            DiagnosticsView(model: model)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "stethoscope").foregroundStyle(Palette.secondary).accessibilityHidden(true)
                Text("Diagnostics").font(Typo.headline).foregroundStyle(Palette.text)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(Typo.meta.weight(.semibold)).foregroundStyle(Palette.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 1))
        .rowsPanel()
        .accessibilityHint(Text("Connection, storage and background details for a bug report"))
    }

    /// Hyperdetail: every action that waits, with its fields and a remark.
    @ViewBuilder
    private func pendingNotes(_ pending: [PendingAction]) -> some View {
        if let hyper {
            ForEach(pending) { p in
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title).font(Typo.meta.weight(.semibold)).foregroundStyle(Palette.secondary)
                    HyperNote(lines: Hyper.pending(p, now: hyper.now, calendar: hyper.calendar),
                              fact: Hyper.fact(pending: p, now: hyper.now))
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func pendingRow(_ count: Int) -> some View {
        Button {
            model.go(.actions)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield").foregroundStyle(Palette.gold).accessibilityHidden(true)
                Text(count == 1 ? "1 action to approve" : "\(count) actions to approve")
                    .font(Typo.headline)
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(Typo.meta.weight(.semibold)).foregroundStyle(Palette.tertiary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 1))
    }
}

/// One problem in the Problems panel (row grammar, research 3c #5): status icon (the only colour) · what happened
/// in 17 semibold · severity word in 15 secondary · since when at the right in 13 tertiary.
fileprivate struct ProblemRow: View {
    let problem: Problem
    /// The personality's aside under the status line (`Voice.aside`), nil when off.
    var aside: String?
    @Environment(\.hyper) private var hyper

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: problem.severity.symbol).foregroundStyle(problem.severity.color).accessibilityHidden(true)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(problem.text).font(Typo.headline).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                // The age shares the status line, so the problem's text keeps the row's full width (a right-hand
                // "since 20 min ago" column squeezed it to three lines on a 5.4" phone).
                (Text(word).font(Typo.secondary).foregroundStyle(Palette.secondary)
                    + Text(age.map { " · \($0)" } ?? "").font(Typo.secondary).foregroundStyle(Palette.tertiary))
                    .accessibilityLabel(Format.spoken(([word] + (age.map { [$0] } ?? [])).joined(separator: ", ")))
                if let aside { Text(aside).font(Typo.secondary).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true) }
                if let hyper { HyperFields(lines: Hyper.problem(problem, now: hyper.now, calendar: hyper.calendar)) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var word: String { problem.severity == .warning ? String(localized: "Warning") : String(localized: "Problem") }
    private var age: String? { problem.since.map { String(localized: "since \(Format.age($0))") } }
}

/// Colour of a report's status word (OK, WARN, ALERT).
func statusColor(_ status: String?) -> Color {
    switch status?.uppercased() {
    case "WARN", "WARNING": Palette.gold
    case "ALERT", "ERROR", "PROBLEM": Palette.love
    default: Palette.secondary
    }
}

/// What `statusColor` says in words, for VoiceOver ("Warning", "Problem"); nil when the dot is grey.
func statusWord(_ status: String?) -> String? {
    switch status?.uppercased() {
    case "WARN", "WARNING": String(localized: "Warning")
    case "ALERT", "ERROR", "PROBLEM": String(localized: "Problem")
    default: nil
    }
}

extension View {
    /// Refreshes the selected server every 30 s (backing off after errors) while this screen is visible and the app
    /// is active. Today and Lab both use it; the task ends when the screen disappears.
    func pollingState(_ model: AppModel) -> some View { modifier(StatePolling(model: model)) }
}

struct StatePolling: ViewModifier {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: PollKey(server: model.selected?.target, active: scenePhase == .active)) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.refresh()
                let st = model.selectedStatus
                let wait = st.failures > 0 ? PollPolicy.backoff(failures: st.failures) : PollPolicy.stateInterval(visible: true)
                try? await Task.sleep(for: wait ?? .seconds(30))
            }
        }
    }
}

// MARK: - Host row (every density)

/// The header over the three value columns of the host rows. The columns are as wide as `HostRow`'s (same scaled
/// width), so "Load", "RAM" and "Disk" stay over their numbers at every text size.
fileprivate struct HostColumnHeader: View {
    @ScaledMetric(relativeTo: .subheadline) private var column: CGFloat = 50

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            ForEach(["Load", "RAM", "Disk"], id: \.self) { title in
                Text(LocalizedStringKey(title)).font(Typo.meta).foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
                    .frame(width: column, alignment: .trailing)
            }
        }
        .accessibilityHidden(true)
    }
}

/// One host as a row (research 3c #6): status dot · name in 17 semibold (up to two lines, never cut) · a small grey
/// sparkline (dropped first when the row is too narrow) · Load, RAM and Disk as three right-aligned mono values in
/// fixed columns. Only a value over its limit turns gold or love (`Host.loadLevel` and friends: the sparkline's
/// limits). Under the name, in meta: the state when it isn't OK, flags, a hot temperature or missing containers. At
/// accessibility sizes (and from xxLarge, where the columns left the name one word per line) the values go under the
/// name, one "Load 0.42" per line (docs/DESIGN.md §6).
struct HostRow: View {
    let host: Host
    let health: HostHealth
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.hyper) private var hyper
    @ScaledMetric(relativeTo: .subheadline) private var column: CGFloat = 50

    private var shownFlags: [String] { host.flags.filter { $0 != "asleep" } }
    private var diskPercent: Int? { Format.worstDisk(host.disks)?.percent }
    private var up: Bool { host.reachable == true }

    /// The stacked layout: from xxLarge on, three value columns next to a long name cut it ("pi-me…" at xxxLarge).
    static func stacked(_ size: DynamicTypeSize) -> Bool { size >= .xxLarge }

    var body: some View {
        Group {
            if Self.stacked(typeSize) {
                VStack(alignment: .leading, spacing: 8) {
                    nameBlock(withMeta: true)
                    if up {
                        VStack(alignment: .leading, spacing: 4) {
                            labelled("Load", loadText, host.loadLevel)
                            labelled("RAM", ramText, host.ramLevel)
                            labelled("Disk", diskText, host.diskLevel)
                        }
                        .padding(.leading, 18)   // under the name, past the status dot
                    }
                }
            } else {
                // The second line spans the whole row: squeezed next to the values it broke after every word
                // ("Under-vol-tage") on a 5.4" phone (2026-11-06).
                VStack(alignment: .leading, spacing: 2) {
                    // The sparkline goes first when the name and the values don't fit with it; the name then wraps.
                    ViewThatFits(in: .horizontal) {
                        line(withSparkline: true)
                        line(withSparkline: false)
                    }
                    if let meta {
                        meta.font(Typo.secondary).foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 18)   // under the name, past the status dot
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(host.name), \(health.label)"))
        .accessibilityValue(Text(hostSpokenMetrics(host, flags: shownFlags)))
        .accessibilityHint(Text("Shows details"))
        .accessibilityAddTraits(.isButton)
    }

    private func line(withSparkline: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            nameBlock(withMeta: false)
            Spacer(minLength: 4)
            if withSparkline, up, let history = host.history, history.last(.load) != nil {
                Sparkline(history, .load, cores: host.cpuCount, label: String(localized: "Load, last 24 hours"),
                          lineWidth: 1, fill: false)
                    .frame(width: 56, height: 20)
            }
            value(loadText, host.loadLevel)
            value(ramText, host.ramLevel)
            value(diskText, host.diskLevel)
        }
    }

    private func nameBlock(withMeta: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(health.color).frame(width: 8, height: 8).accessibilityHidden(true)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            VStack(alignment: .leading, spacing: 2) {
                // Two lines, never cut and never shrunk ("pi-me…" and "media…" on the 5.4" phone, 2026-11-06).
                Text(host.name).font(Typo.headline).foregroundStyle(Palette.text).lineLimit(hyper == nil ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                if withMeta, let meta { meta.font(Typo.secondary).foregroundStyle(Palette.secondary) }
            }
        }
    }

    /// The second line: only when there is something to say. Symbols carry the gold, the words stay grey.
    private var meta: Text? {
        var parts: [Text] = []
        if !up {
            parts.append(Text(health == .asleep ? health.label : host.checked.map { String(localized: "last seen \(Format.age($0))") } ?? health.label))
        } else if health != .ok {
            parts.append(Text(health.label))
        }
        if up, host.tempLevel != .normal {
            parts.append(Text(Image(systemName: "thermometer.medium")).foregroundColor(Palette.gold) + Text(" " + Format.temperature(host.temp)))
        }
        if up, host.containersTotal != nil, (host.containersUp ?? 0) < (host.containersTotal ?? 0) {
            parts.append(Text(Image(systemName: "shippingbox")).foregroundColor(Palette.gold)
                         + Text(" " + Format.containers(up: host.containersUp, total: host.containersTotal)))
        }
        if !shownFlags.isEmpty { parts.append(Text(shownFlags.map(Format.flag).joined(separator: ", "))) }
        guard var first = parts.first else { return nil }
        for p in parts.dropFirst() { first = first + Text(" · ") + p }
        return first
    }

    private var loadText: String { up ? Format.load(host.load) : "–" }
    private var ramText: String { up ? Format.percent(host.memPct) : "–" }
    private var diskText: String { up ? (diskPercent.map { "\($0)%" } ?? "–") : "–" }

    private func value(_ text: String, _ level: ValueLevel) -> some View {
        Text(text).font(Typo.rowValue)
            .foregroundStyle(text == "–" ? Palette.tertiary : Meter.valueColor(level))
            .lineLimit(1)
            .frame(width: column, alignment: .trailing)
    }

    /// "Load 0.42" on one line: the label in meta, the value in the data font.
    private func labelled(_ label: LocalizedStringKey, _ text: String, _ level: ValueLevel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(Typo.meta).foregroundStyle(Palette.tertiary)
            Text(text).font(Typo.rowValue).foregroundStyle(text == "–" ? Palette.tertiary : Meter.valueColor(level))
        }
    }
}

/// What VoiceOver reads after a host's name: the numbers the tile or row shows. A number over its limit says "high".
fileprivate func hostSpokenMetrics(_ host: Host, flags shownFlags: [String]) -> String {
    guard host.reachable == true else {
        let seen = host.checked.map { [String(localized: "last seen \(Format.spokenAge($0))")] } ?? []
        return (seen + shownFlags.map(Format.flag)).joined(separator: ", ")
    }
    func high(_ text: String, _ level: ValueLevel) -> String { level.isHigh ? text + " " + String(localized: "high") : text }
    var parts = [high(String(localized: "load \(Format.load(host.load))"), host.loadLevel),
                 high(String(localized: "memory \(Format.percent(host.memPct))"), host.ramLevel)]
    if let d = Format.worstDisk(host.disks) {
        parts.append(high(String(localized: "disk \(d.mount) \(d.percent) percent"), host.diskLevel))
    }
    if host.temp != nil { parts.append(high(Format.temperature(host.temp), host.tempLevel)) }
    if host.containersTotal != nil {
        parts.append(String(localized: "containers \(Format.containers(up: host.containersUp, total: host.containersTotal))"))
    }
    if let h = host.history, let lo = h.min(.load), let hi = h.max(.load) {
        parts.append(String(localized: "load 24 h: min \(Format.load(lo)), max \(Format.load(hi))"))
    }
    parts += shownFlags.map(Format.flag)
    return parts.joined(separator: ", ")
}

// MARK: - Services (cards: Cards.swift)

struct ServicesSection: View {
    let services: [Service]
    @Environment(\.openURL) private var openURL
    @Environment(\.hyper) private var hyper

    var groups: [(String, [Service])] {
        let byGroup = Dictionary(grouping: services) { $0.group ?? String(localized: "Services") }
        var order: [String] = []
        for s in services where !order.contains(s.group ?? String(localized: "Services")) {
            order.append(s.group ?? String(localized: "Services"))
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    /// One panel; rows split by separators, a group's name as a small heading when there are several.
    var body: some View {
        VStack(alignment: .leading, spacing: Space.titleToPanel) {
            SectionTitle(text: "Services")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.element.0) { gi, entry in
                    if groups.count > 1 {
                        Text(entry.0).font(.footnote).foregroundStyle(Palette.secondary)
                            .padding(.horizontal, 16).padding(.top, gi == 0 ? 16 : 20).padding(.bottom, 4)
                    }
                    ForEach(Array(entry.1.enumerated()), id: \.element.id) { si, s in
                        if si > 0 { Divider().padding(.leading, 16) }
                        serviceRow(s)
                        if hyper != nil {
                            HyperNote(lines: Hyper.service(s), fact: Hyper.Fact(.row, ["title": s.name, "value": s.group ?? ""], seed: s.id))
                                .padding(.horizontal, 16).padding(.bottom, 8)
                        }
                    }
                }
                if groups.count > 1 { Color.clear.frame(height: 4) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func serviceRow(_ s: Service) -> some View {
        Button {
            openURL(s.url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: Symbols.safe(s.icon, fallback: "globe"))
                    .foregroundStyle(Palette.secondary).frame(width: 24).accessibilityHidden(true)
                Text(s.name).font(Typo.body).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.tertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(s.url.host ?? ""))
    }
}
