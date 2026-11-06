import HomelabDesign
import HomelabKit
import SwiftUI

/// Lab: the machines. Problems, every host (tap for details), and the service launcher.
struct LabView: View {
    let model: AppModel
    @State private var path: [Host] = []
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

    private var status: ServerStatus { model.selectedStatus }
    private var state: HomelabState? { status.snapshot?.state }
    private var overkill: Bool { model.settings.todayDensity == .overkill }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.section) {
                    header
                    if let error = status.error {
                        ErrorBanner(error: error, snapshotAge: status.snapshot?.fetched) { refresh() }
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
            // Large text: one fact per line instead of a wrapped "a · b · c".
            if typeSize.isAccessibilitySize {
                ForEach(sublines, id: \.self) { Text($0).font(Typo.meta).foregroundStyle(Palette.tertiary) }
            } else {
                Text(sublines.joined(separator: " · ")).font(Typo.meta).foregroundStyle(Palette.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// "1 problem · 1 warning"; counted like Today's mood.
    private var headline: String {
        guard let state else { return String(localized: "Not loaded") }
        switch state.status {
        case .ok: return String(localized: "All good")
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

    @ViewBuilder
    private func content(_ state: HomelabState) -> some View {
        if !state.problems.isEmpty {
            VStack(alignment: .leading, spacing: Space.titleToPanel) {
                SectionTitle(text: "Problems")
                // One panel, one row per problem; the waiting actions are its last row.
                VStack(spacing: 0) {
                    ForEach(Array(state.problems.enumerated()), id: \.element.id) { index, p in
                        if index > 0 { Divider().padding(.leading, 16) }
                        ProblemRow(problem: p)
                    }
                    if !state.pending.isEmpty {
                        Divider().padding(.leading, 16)
                        pendingRow(state.pending.count)
                    }
                }
                .rowsPanel()
            }
        } else if !state.pending.isEmpty {
            pendingRow(state.pending.count).rowsPanel()
        }

        if !state.hosts.isEmpty {
            VStack(alignment: .leading, spacing: Space.titleToPanel) {
                SectionTitle(text: "Hosts", trailing: "\(state.hosts.filter { $0.reachable == true }.count)/\(state.hosts.count) up")
                if overkill {
                    // Overkill keeps the tiles; large text: one per row.
                    LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())]
                                                                    : [GridItem(.adaptive(minimum: 165), spacing: 12)], spacing: 12) {
                        ForEach(state.hosts) { host in
                            NavigationLink(value: host) { HostTile(host: host, health: state.health(of: host)) }
                                .buttonStyle(.press)
                        }
                    }
                } else {
                    // Standard: one panel, a row per host, the numbers in three right-hand columns.
                    VStack(spacing: 0) {
                        if !typeSize.isAccessibilitySize {
                            HostColumnHeader().padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 2)
                        }
                        ForEach(Array(state.hosts.enumerated()), id: \.element.id) { index, host in
                            if index > 0 { Divider().padding(.leading, 16) }
                            NavigationLink(value: host) { HostRow(host: host, health: state.health(of: host)) }
                                .buttonStyle(PressStyle(scale: 1))
                        }
                    }
                    .rowsPanel()
                }
            }
        }

        // Cards the server wants here (tailnet, ad blocking, backups), as rows, between the hosts and the services.
        ForEach(state.cards.filter { $0.place == .lab }) { CardView(card: $0, lab: true, model: model) }

        if !status.services.isEmpty {
            ServicesSection(services: status.services)
        }
    }

    private func pendingRow(_ count: Int) -> some View {
        Button {
            model.tab = .actions
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield").foregroundStyle(Palette.gold).accessibilityHidden(true)
                Text(count == 1 ? "1 action is waiting for you" : "\(count) actions are waiting for you")
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: problem.severity.symbol).foregroundStyle(problem.severity.color).accessibilityHidden(true)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(problem.text).font(Typo.headline).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                // The age shares the status line, so the problem's text keeps the row's full width (a right-hand
                // "since 20 min ago" column squeezed it to three lines on a 5.4" phone).
                Text(word).font(Typo.secondary).foregroundStyle(Palette.secondary)
                    + Text(age.map { " · \($0)" } ?? "").font(Typo.secondary).foregroundStyle(Palette.tertiary)
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

// MARK: - Host tile (the details are in HostDetailView.swift)

struct HostTile: View {
    let host: Host
    /// With the server's problems for this host (`HomelabState.health(of:)`).
    let health: HostHealth
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Flags the tile lists below the numbers; "asleep" is already the state word.
    private var shownFlags: [String] { host.flags.filter { $0 != "asleep" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The name is never cut: it wraps. The state is a dot and its word under it.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Symbols.host(kind: host.kind)).foregroundStyle(Palette.secondary).accessibilityHidden(true)
                Text(host.name).font(Typo.headline).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if health != .ok {
                HStack(spacing: 6) {
                    Circle().fill(health.color).frame(width: 8, height: 8)
                    Text(health.label).font(.footnote).foregroundStyle(Palette.secondary)
                }
                .accessibilityHidden(true)
            }
            if let history = host.history, history.last(.load) != nil {
                // 24 h of load; also for a host that is down now (its last hours are a gap).
                Sparkline(history, .load, cores: host.cpuCount, label: String(localized: "Load, last 24 hours"), lineWidth: 1, fill: false)
                    .frame(height: 20)
            }
            if host.reachable == true {
                metric("Load", Format.load(host.load), Format.loadShare(host.load, cores: host.cpuCount),
                       host.loadLevel)
                metric("RAM", Format.percent(host.memPct), host.memPct.map { Double($0) / 100 }, host.ramLevel)
                if let d = Format.worstDisk(host.disks) {
                    metric("Disk", "\(d.percent)%", Double(d.percent) / 100, host.diskLevel)
                }
                HStack(spacing: 12) {
                    if host.temp != nil {
                        chip(Format.temperature(host.temp), symbol: "thermometer.medium", warn: host.tempLevel != .normal)
                    }
                    if host.containersTotal != nil {
                        chip(Format.containers(up: host.containersUp, total: host.containersTotal), symbol: "shippingbox",
                             warn: (host.containersUp ?? 0) < (host.containersTotal ?? 0))
                    }
                }
            } else if let checked = host.checked {
                Text("last seen \(Format.age(checked))").font(.footnote).foregroundStyle(Palette.tertiary)
            }
            if !shownFlags.isEmpty {
                Label {
                    Text(shownFlags.map(Format.flag).joined(separator: ", ")).font(.footnote).foregroundStyle(Palette.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").font(.footnote)
                        .foregroundStyle(health == .problem ? Palette.love : Palette.gold)   // flags alone are a warning; the server decides problems
                }
            }
            Spacer(minLength: 0)
        }
        // Equal heights in a row: every tile has the same minimum, taller only for more text.
        .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 0 : 176, alignment: .topLeading)
        .panel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(host.name), \(health.label)"))
        .accessibilityValue(Text(spokenMetrics))
        .accessibilityHint(Text("Shows details"))
        .accessibilityAddTraits(.isButton)
    }

    private var spokenMetrics: String { hostSpokenMetrics(host, flags: shownFlags) }

    /// Label in sentence case (secondary), value in the data font, a thin meter under them.
    private func metric(_ label: LocalizedStringKey, _ value: String, _ share: Double?, _ level: ValueLevel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.footnote).foregroundStyle(Palette.secondary)
                Spacer(minLength: 8)
                Text(value).font(Typo.data(.footnote))
                    .foregroundStyle(Meter.valueColor(level))   // the bar stays grey; the number turns gold/love at its limits
                    .contentTransition(.numericText())
                    .animation(.snappy, value: value)
            }
            if let share { Meter(share, warns: true) }
        }
    }

    /// A fact without a border: an icon and the value. Only the icon turns gold.
    private func chip(_ text: String, symbol: String, warn: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.footnote).foregroundStyle(warn ? Palette.gold : Palette.secondary)
            Text(text).font(Typo.data(.footnote)).foregroundStyle(Palette.secondary)
        }
        .lineLimit(1)
    }
}

// MARK: - Host row (Standard density)

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
/// accessibility sizes the values go under the name, one "Load 0.42" per line (docs/DESIGN.md §6).
struct HostRow: View {
    let host: Host
    let health: HostHealth
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var column: CGFloat = 50

    private var shownFlags: [String] { host.flags.filter { $0 != "asleep" } }
    private var diskPercent: Int? { Format.worstDisk(host.disks)?.percent }
    private var up: Bool { host.reachable == true }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
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
                Text(host.name).font(Typo.headline).foregroundStyle(Palette.text).lineLimit(2)
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
        let seen = host.checked.map { [String(localized: "last seen \(Format.age($0))")] } ?? []
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
