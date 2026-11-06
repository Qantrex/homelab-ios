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
                LazyVStack(alignment: .leading, spacing: 24) {
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

    /// One statement (docs/DESIGN.md): the status icon and how the lab is doing, the facts under it. No box.
    private var header: some View {
        let s = state?.status ?? .unknown
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: s.symbol).foregroundStyle(s.color).accessibilityHidden(true)
                Text(headline).font(Typo.sectionTitle).foregroundStyle(Palette.text)
                Spacer(minLength: 0)
                if status.loading { ProgressView() }
            }
            // Large text: one fact per line instead of a wrapped "a · b · c".
            if typeSize.isAccessibilitySize {
                ForEach(sublines, id: \.self) { Text($0).font(.footnote).foregroundStyle(Palette.tertiary) }
            } else {
                Text(sublines.joined(separator: " · ")).font(.footnote).foregroundStyle(Palette.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Problems")
                // One panel, one row per problem; the severity is the icon and its word, not a coloured card.
                VStack(spacing: 0) {
                    ForEach(Array(state.problems.enumerated()), id: \.element.id) { index, p in
                        if index > 0 { Divider().padding(.leading, 16) }
                        ProblemRow(problem: p)
                    }
                }
                .frame(maxWidth: .infinity)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }

        if !state.pending.isEmpty {
            Button {
                model.tab = .actions
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield").foregroundStyle(Palette.gold).accessibilityHidden(true)
                    Text(state.pending.count == 1 ? "1 action is waiting for you" : "\(state.pending.count) actions are waiting for you")
                        .font(.body)
                        .foregroundStyle(Palette.text)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.tertiary)
                }
                .panel()
            }
            .buttonStyle(.press)
        }

        if !state.hosts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
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

/// One problem in the Problems panel: status icon, the text, severity word and since when.
fileprivate struct ProblemRow: View {
    let problem: Problem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: problem.severity.symbol).foregroundStyle(problem.severity.color).accessibilityHidden(true)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(problem.text).font(.body).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta).font(.footnote).foregroundStyle(Palette.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        let word = problem.severity == .warning ? String(localized: "Warning") : String(localized: "Problem")
        guard let since = problem.since else { return word }
        return String(localized: "\(word), since \(Format.age(since))")
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
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Flags the tile lists below the numbers; "asleep" is already the state word.
    private var shownFlags: [String] { host.flags.filter { $0 != "asleep" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The name is never cut: it wraps. The state is a dot and its word under it.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Symbols.host(kind: host.kind)).foregroundStyle(Palette.secondary).accessibilityHidden(true)
                Text(host.name).font(.headline).foregroundStyle(Palette.text)
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
                metric("Load", Format.load(host.load), Format.loadShare(host.load, cores: host.cpuCount))
                metric("RAM", Format.percent(host.memPct), host.memPct.map { Double($0) / 100 })
                if let d = Format.worstDisk(host.disks) {
                    metric("Disk", "\(d.percent)%", Double(d.percent) / 100)
                }
                HStack(spacing: 12) {
                    if host.temp != nil {
                        chip(Format.temperature(host.temp), symbol: "thermometer.medium", warn: (host.temp ?? 0) >= Format.hotCelsius)
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

    /// Label in sentence case (secondary), value in the data font, a thin meter under them.
    private func metric(_ label: LocalizedStringKey, _ value: String, _ share: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.footnote).foregroundStyle(Palette.secondary)
                Spacer(minLength: 8)
                Text(value).font(Typo.data(.footnote))
                    .foregroundStyle(Palette.text)
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
        VStack(alignment: .leading, spacing: 12) {
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
                Text(s.name).font(.body).foregroundStyle(Palette.text)
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
