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

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
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

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            let s = state?.status ?? .unknown
            Image(systemName: s.symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(s.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(Typo.mono(.headline, weight: .semibold))
                // Large text: one fact per line instead of a wrapped "a · b · c".
                if typeSize.isAccessibilitySize {
                    ForEach(sublines, id: \.self) { Text($0).font(Typo.mono(.caption)).foregroundStyle(Palette.secondary) }
                } else {
                    Text(sublines.joined(separator: " · ")).font(Typo.mono(.caption)).foregroundStyle(Palette.secondary)
                }
            }
            Spacer()
            if status.loading { ProgressView() }
        }
        .card(accent: headerAccent)
        .accessibilityElement(children: .combine)
    }

    /// The header's border: the status colour for a warning or problem, else the normal hairline. (A separate
    /// property: inline, Xcode 26's type checker gave up on it.)
    private var headerAccent: Color? {
        guard let s = state?.status, s == .warning || s == .problem else { return nil }
        return s.color
    }

    private var headline: String {
        guard let state else { return String(localized: "Not loaded") }
        switch state.status {
        case .ok: return String(localized: "All good")
        case .unknown: return String(localized: "Status unknown")
        case .warning, .problem:
            // Counted like Today's mood: warnings apart (they go in the subline).
            let t = ProblemTally(state)
            if t.problems > 0 { return t.problems == 1 ? String(localized: "1 problem") : String(localized: "\(t.problems) problems") }
            if t.warnings > 0 { return t.warnings == 1 ? String(localized: "1 warning") : String(localized: "\(t.warnings) warnings") }
            return String(localized: "Warning")
        }
    }

    private var sublines: [String] {
        var parts: [String] = []
        if let state, state.status == .warning || state.status == .problem {
            let t = ProblemTally(state)
            if t.problems > 0, t.warnings > 0 {
                parts.append(t.warnings == 1 ? String(localized: "1 warning") : String(localized: "\(t.warnings) warnings"))
            }
        }
        if let checked = state?.checked { parts.append(String(localized: "checked \(Format.age(checked))")) }
        if let fetched = status.snapshot?.fetched, status.snapshot?.isStale() == true {
            parts.append(String(localized: "updated \(Format.age(fetched))"))
        }
        if let n = state?.pending.count, n > 0 { parts.append(n == 1 ? String(localized: "1 action waiting") : String(localized: "\(n) actions waiting")) }
        return parts.isEmpty ? [model.selected?.host ?? ""] : parts
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ state: HomelabState) -> some View {
        if !state.problems.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "Problems")
                ForEach(state.problems) { p in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: p.severity.symbol).foregroundStyle(p.severity.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.text).font(.subheadline)
                            if let since = p.since {
                                Text("since \(Format.age(since))").font(Typo.mono(.caption2)).foregroundStyle(Palette.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .card(accent: p.severity.color)   // each card its own severity
                }
            }
        }

        if !state.pending.isEmpty {
            Button {
                model.tab = .actions
            } label: {
                HStack {
                    Image(systemName: "checkmark.shield").foregroundStyle(Palette.gold)
                    Text(state.pending.count == 1 ? "1 action is waiting for you" : "\(state.pending.count) actions are waiting for you")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.tertiary)
                }
                .card()
            }
            .buttonStyle(.press)
        }

        if !state.hosts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "Hosts", trailing: "\(state.hosts.filter { $0.reachable == true }.count)/\(state.hosts.count) up")
                // Large text: one host per row, so names and numbers fit on a small phone.
                LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())]
                                                                : [GridItem(.adaptive(minimum: 165), spacing: 12)], spacing: 12) {
                    ForEach(state.hosts) { host in
                        NavigationLink(value: host) { HostTile(host: host, health: state.health(of: host)) }
                            .buttonStyle(.press)
                    }
                }
            }
        }

        if !status.services.isEmpty {
            ServicesSection(services: status.services)
        }
    }
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

    /// Flags the tile lists below the numbers; "asleep" is already the state word.
    private var shownFlags: [String] { host.flags.filter { $0 != "asleep" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: Symbols.host(kind: host.kind)).foregroundStyle(Palette.secondary)
                // The name first; the state word only where it still fits (the dot and VoiceOver keep the state).
                Text(host.name).font(Typo.mono(.subheadline, weight: .semibold)).lineLimit(1)
                    .layoutPriority(2)
                Spacer(minLength: 0)
                // Colour plus a word, so the state doesn't depend on seeing colour.
                if health != .ok {
                    ViewThatFits(in: .horizontal) {
                        Text(health.label.uppercased()).font(Typo.mono(.caption2, weight: .semibold)).foregroundStyle(health.color)
                            .lineLimit(1).fixedSize()
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .layoutPriority(1)
                }
                Circle().fill(health.color).frame(width: 7, height: 7)
            }
            if let history = host.history, history.last(.load) != nil {
                // 24 h of load; also for a host that is down now (its last hours are a gap).
                Sparkline(history, .load, cores: host.cpuCount, label: String(localized: "Load, last 24 hours"), lineWidth: 1.2)
                    .frame(height: 22)
            }
            if host.reachable == true {
                metric("Load", Format.load(host.load), Format.loadShare(host.load, cores: host.cpuCount))
                metric("RAM", Format.percent(host.memPct), host.memPct.map { Double($0) / 100 })
                if let d = Format.worstDisk(host.disks) {
                    metric("Disk", "\(d.percent)%", Double(d.percent) / 100)
                }
                HStack(spacing: 6) {
                    if host.temp != nil { Chip(Format.temperature(host.temp), color: (host.temp ?? 0) >= Format.hotCelsius ? Palette.gold : Palette.secondary, symbol: "thermometer.medium") }
                    if host.containersTotal != nil {
                        Chip(Format.containers(up: host.containersUp, total: host.containersTotal),
                             color: (host.containersUp ?? 0) < (host.containersTotal ?? 0) ? Palette.gold : Palette.secondary, symbol: "shippingbox")
                    }
                }
            } else {
                // A sleeping machine: the header already says so. A down one keeps its word here too, in case the
                // header had no room for it.
                if health != .asleep {
                    Text(health.label).font(Typo.mono(.caption)).foregroundStyle(health.color)
                }
                if let checked = host.checked {
                    Text("last seen \(Format.age(checked))").font(Typo.mono(.caption)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 0)
            }
            if !shownFlags.isEmpty {
                Text(shownFlags.map(Format.flag).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(shownFlags.contains(where: Format.isAlarming) ? Palette.love : Palette.gold)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .card(accent: health == .problem ? Palette.love : nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(host.name), \(health.label)"))
        .accessibilityValue(Text(spokenMetrics))
        .accessibilityHint(Text("Shows details"))
        .accessibilityAddTraits(.isButton)
    }

    /// What VoiceOver reads after the name: the numbers the tile shows.
    private var spokenMetrics: String {
        guard host.reachable == true else {
            let seen = host.checked.map { [String(localized: "last seen \(Format.age($0))")] } ?? []
            return (seen + shownFlags.map(Format.flag)).joined(separator: ", ")
        }
        var parts = [String(localized: "load \(Format.load(host.load))"), String(localized: "memory \(Format.percent(host.memPct))")]
        if let d = Format.worstDisk(host.disks) { parts.append(String(localized: "disk \(d.mount) \(d.percent) percent")) }
        if host.temp != nil { parts.append(Format.temperature(host.temp)) }
        if host.containersTotal != nil {
            parts.append(String(localized: "containers \(Format.containers(up: host.containersUp, total: host.containersTotal))"))
        }
        if let h = host.history, let lo = h.min(.load), let hi = h.max(.load) {
            parts.append(String(localized: "load 24 h: min \(Format.load(lo)), max \(Format.load(hi))"))
        }
        parts += shownFlags.map(Format.flag)
        return parts.joined(separator: ", ")
    }

    private func metric(_ label: LocalizedStringKey, _ value: String, _ share: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).textCase(.uppercase).font(Typo.mono(.caption2)).foregroundStyle(Palette.tertiary)
                Spacer()
                Text(value).font(Typo.mono(.caption))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: value)
            }
            if let share { Meter(share, warns: true) }
        }
    }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Services")
            VStack(alignment: .leading, spacing: 14) {
                ForEach(groups, id: \.0) { group, items in
                    VStack(alignment: .leading, spacing: 6) {
                        if groups.count > 1 { Text(group).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(items) { s in
                                Button {
                                    openURL(s.url)
                                } label: {
                                    Label(s.name, systemImage: Symbols.safe(s.icon, fallback: "globe"))
                                        .font(.subheadline)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 10)
                                        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint(Text(s.url.host ?? ""))
                            }
                        }
                    }
                }
            }
            .card()
        }
    }
}
