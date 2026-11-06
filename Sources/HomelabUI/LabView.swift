import HomelabDesign
import HomelabKit
import SwiftUI

/// Lab: the machines. Problems, every host (tap for details), and the service launcher.
struct LabView: View {
    let model: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

    private var status: ServerStatus { model.selectedStatus }
    private var state: HomelabState? { status.snapshot?.state }

    var body: some View {
        NavigationStack {
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
            .navigationDestination(for: Host.self) { HostDetailView(host: $0) }
            .pollingState(model)
        }
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
            let n = state.problems.count
            return n == 1 ? String(localized: "1 problem") : String(localized: "\(n) problems")
        }
    }

    private var sublines: [String] {
        var parts: [String] = []
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
                }
                .card(accent: state.problems.contains { $0.severity != .warning } ? Palette.love : Palette.gold)
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
                        NavigationLink(value: host) { HostTile(host: host) }
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

// MARK: - Host tile and detail

struct HostTile: View {
    let host: Host

    var body: some View {
        let health = HostHealth(host)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: Symbols.host(kind: host.kind)).foregroundStyle(Palette.secondary)
                Text(host.name).font(Typo.mono(.subheadline, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                // Colour plus a word, so the state doesn't depend on seeing colour.
                if health != .ok {
                    Text(health.label.uppercased()).font(Typo.mono(.caption2, weight: .semibold)).foregroundStyle(health.color).lineLimit(1)
                }
                Circle().fill(health.color).frame(width: 7, height: 7)
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
                Text(health.label).font(Typo.mono(.caption)).foregroundStyle(health.color)
                Spacer(minLength: 0)
            }
            if !host.flags.isEmpty {
                Text(host.flags.map(Format.flag).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(host.flags.contains(where: Format.isAlarming) ? Palette.love : Palette.gold)
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
        guard host.reachable == true else { return host.flags.map(Format.flag).joined(separator: ", ") }
        var parts = [String(localized: "load \(Format.load(host.load))"), String(localized: "memory \(Format.percent(host.memPct))")]
        if let d = Format.worstDisk(host.disks) { parts.append(String(localized: "disk \(d.mount) \(d.percent) percent")) }
        if host.temp != nil { parts.append(Format.temperature(host.temp)) }
        if host.containersTotal != nil {
            parts.append(String(localized: "containers \(Format.containers(up: host.containersUp, total: host.containersTotal))"))
        }
        parts += host.flags.map(Format.flag)
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

struct HostDetailView: View {
    let host: Host
    @Environment(\.openURL) private var openURL

    var body: some View {
        let health = HostHealth(host)
        List {
            Section {
                LabeledContent("Status") { Text(health.label).foregroundStyle(health.color) }
                if let checked = host.checked { LabeledContent("Checked", value: Format.age(checked)) }
                if let kind = host.kind { LabeledContent("Kind", value: kind) }
            }
            if host.reachable == true {
                Section("System") {
                    LabeledContent("Load (1 min)", value: Format.load(host.load) + (host.cpuCount.map { " / \($0) cores" } ?? ""))
                    LabeledContent("Memory", value: Format.percent(host.memPct))
                    if host.temp != nil { LabeledContent("Temperature", value: Format.temperature(host.temp)) }
                    if host.containersTotal != nil || host.containersUp != nil {
                        LabeledContent("Containers up", value: Format.containers(up: host.containersUp, total: host.containersTotal))
                    }
                }
                if !host.disks.isEmpty {
                    Section("Disks") {
                        ForEach(host.disks.sorted { $0.key < $1.key }, id: \.key) { mount, pct in
                            VStack(alignment: .leading, spacing: 4) {
                                LabeledContent(mount, value: "\(pct)%")
                                Meter(Double(pct) / 100, warns: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                if host.upgradable != nil || host.rebootRequired != nil || host.backupResult != nil {
                    Section("Maintenance") {
                        if let u = host.upgradable { LabeledContent("Updates waiting", value: "\(u)") }
                        if host.rebootRequired == true { LabeledContent("Reboot", value: String(localized: "required")) }
                        if let b = Format.backup(last: host.backupLast, result: host.backupResult) {
                            LabeledContent("Backup") {
                                Text(b).foregroundStyle(Format.backupFailed(host.backupResult) ? Palette.love : Palette.secondary)
                            }
                        }
                    }
                }
            }
            if !host.flags.isEmpty {
                Section("Flags") {
                    ForEach(host.flags, id: \.self) { f in
                        Label(Format.flag(f), systemImage: Format.isAlarming(flag: f) ? "bolt.trianglebadge.exclamationmark" : "info.circle")
                            .foregroundStyle(Format.isAlarming(flag: f) ? Palette.love : Palette.text)
                    }
                }
            }
            if let url = host.url {
                Section {
                    Button { openURL(url) } label: { Label("Open web interface", systemImage: "safari") }
                }
            }
        }
        .screenBackground()
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Cards and services

/// A card from the server. `hero` is the big version for the top of Today (large mono numbers).
struct CardView: View {
    let card: Card
    var hero = false
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .subheadline) private var ringSize: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: Symbols.safe(card.icon)).foregroundStyle(card.tint.color).font(.footnote)
                Text(card.title ?? card.id).textCase(.uppercase).font(Typo.mono(.caption, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(Palette.secondary)
                Spacer()
                if let updated = card.updated {
                    Text(ServerDate.parse(updated).map { Format.age($0) } ?? updated).font(Typo.mono(.caption2)).foregroundStyle(Palette.tertiary)
                }
            }
            if let subtitle = card.subtitle { Text(subtitle).font(.caption).foregroundStyle(Palette.secondary) }
            switch card.style {
            case .text:
                Text(markdown(card.text ?? card.items.compactMap(\.title).joined(separator: "\n"))).font(.subheadline)
            case .metrics:
                // Top-aligned, so a tile with a subtitle ("U6 07:36") doesn't sit higher than its neighbours.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: hero ? 96 : 90), spacing: 10, alignment: .topLeading)],
                          alignment: .leading, spacing: 12) {
                    ForEach(Array(card.items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title ?? "").font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                            Text(item.value ?? "–").font(Typo.mono(hero ? .title : .title3, weight: .semibold))
                                .minimumScaleFactor(0.6).lineLimit(1)
                                .foregroundStyle(item.tint?.color ?? Palette.text)
                            if let s = item.subtitle { Text(s).font(Typo.mono(.caption2)).foregroundStyle(Palette.tertiary) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            case .list:
                ForEach(Array(card.items.enumerated()), id: \.offset) { _, item in
                    itemRow(item)
                }
            }
        }
        .card()
    }

    @ViewBuilder
    private func itemRow(_ item: Card.Item) -> some View {
        // A row with progress (a download, an episode) leads with a ring; the others with their icon.
        let row = HStack(alignment: item.progress == nil ? .firstTextBaseline : .center, spacing: 10) {
            if let p = item.progress {
                ProgressRing(p, tint: item.tint?.color ?? Palette.text, size: ringSize)
            } else if let icon = item.icon {
                Image(systemName: Symbols.safe(icon, fallback: "circle")).foregroundStyle(item.tint?.color ?? Palette.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title ?? "").font(.subheadline).lineLimit(2)
                if let s = item.subtitle { Text(s).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if let v = item.value { Text(v).font(Typo.mono(.caption)).foregroundStyle(Palette.secondary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.progress.map { Text("\(Format.ringPercent($0)) percent") } ?? Text(""))
        if let url = item.url {
            Button { openURL(url) } label: { row }.buttonStyle(.plain)
        } else {
            row
        }
    }
}

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
