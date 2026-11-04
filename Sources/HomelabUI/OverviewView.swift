import HomelabDesign
import HomelabKit
import SwiftUI

struct OverviewView: View {
    let model: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

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
            .background(Color(.systemGroupedBackground))
            .refreshable { await model.refresh() }
            .navigationTitle(status.snapshot?.serverName ?? model.selected?.name ?? "Homelab")
            .toolbar { serverMenu }
            .navigationDestination(for: Host.self) { HostDetailView(host: $0) }
            .task(id: PollKey(server: model.selected?.id, active: scenePhase == .active)) {
                if scenePhase == .active { await poll() }
            }
        }
    }

    /// Refresh every 30 s while this screen is visible (the task ends when it disappears).
    private func poll() async {
        while !Task.isCancelled {
            await model.refresh()
            let wait = status.failures > 0 ? PollPolicy.backoff(failures: status.failures) : PollPolicy.stateInterval(visible: true)
            try? await Task.sleep(for: wait ?? .seconds(30))
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
                .font(.system(size: 34))
                .foregroundStyle(s.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.headline)
                Text(subline).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if status.loading { ProgressView() }
        }
        .card()
        .accessibilityElement(children: .combine)
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

    private var subline: String {
        var parts: [String] = []
        if let checked = state?.checked { parts.append(String(localized: "checked \(Format.age(checked))")) }
        if let fetched = status.snapshot?.fetched, status.snapshot?.isStale() == true {
            parts.append(String(localized: "updated \(Format.age(fetched))"))
        }
        if let n = state?.pending.count, n > 0 { parts.append(n == 1 ? String(localized: "1 action waiting") : String(localized: "\(n) actions waiting")) }
        return parts.isEmpty ? (model.selected?.host ?? "") : parts.joined(separator: " · ")
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
                                Text("since \(Format.age(since))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
                .card()
            }
        }

        if !state.pending.isEmpty {
            Button {
                model.tab = .actions
            } label: {
                HStack {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(.blue)
                    Text(state.pending.count == 1 ? "1 action is waiting for you" : "\(state.pending.count) actions are waiting for you")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .card()
            }
            .buttonStyle(.plain)
        }

        if !state.hosts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "Hosts", trailing: "\(state.hosts.filter { $0.reachable == true }.count)/\(state.hosts.count) up")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 12)], spacing: 12) {
                    ForEach(state.hosts) { host in
                        NavigationLink(value: host) { HostTile(host: host) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }

        ForEach(state.cards) { CardView(card: $0) }

        if !status.services.isEmpty {
            ServicesSection(services: status.services)
        }

        if let m = state.lastMessage, !m.text.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "Last report", trailing: m.ts.map { Format.age($0) })
                VStack(alignment: .leading, spacing: 6) {
                    if let job = m.job { Chip(job, color: statusColor(m.status)) }
                    Text(markdown(m.text)).font(.subheadline).lineLimit(8)
                }
                .card()
            }
        }
    }
}

func statusColor(_ status: String?) -> Color {
    switch status?.uppercased() {
    case "OK": .green
    case "WARN", "WARNING": .orange
    case "ALERT", "ERROR", "PROBLEM": .red
    default: .secondary
    }
}

// MARK: - Host tile and detail

struct HostTile: View {
    let host: Host

    var body: some View {
        let health = HostHealth(host)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: Symbols.host(kind: host.kind)).foregroundStyle(.secondary)
                Text(host.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Circle().fill(health.color).frame(width: 9, height: 9)
            }
            if host.reachable == true {
                metric("Load", Format.load(host.load), Format.loadShare(host.load, cores: host.cpuCount))
                metric("RAM", Format.percent(host.memPct), host.memPct.map { Double($0) / 100 })
                if let d = Format.worstDisk(host.disks) {
                    metric("Disk", "\(d.percent)%", Double(d.percent) / 100)
                }
                HStack(spacing: 6) {
                    if host.temp != nil { Chip(Format.temperature(host.temp), color: (host.temp ?? 0) >= Format.hotCelsius ? .orange : .secondary, symbol: "thermometer.medium") }
                    if host.containersTotal != nil {
                        Chip(Format.containers(up: host.containersUp, total: host.containersTotal),
                             color: (host.containersUp ?? 0) < (host.containersTotal ?? 0) ? .orange : .secondary, symbol: "shippingbox")
                    }
                }
            } else {
                Text(health.label).font(.caption).foregroundStyle(health.color)
                Spacer(minLength: 0)
            }
            if !host.flags.isEmpty {
                Text(host.flags.map(Format.flag).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(host.flags.contains(where: Format.isAlarming) ? .red : .orange)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(host.name), \(health.label)"))
        .accessibilityHint(Text("Shows details"))
    }

    private func metric(_ label: LocalizedStringKey, _ value: String, _ share: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.caption.monospacedDigit())
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
                                Text(b).foregroundStyle(Format.backupFailed(host.backupResult) ? .red : .secondary)
                            }
                        }
                    }
                }
            }
            if !host.flags.isEmpty {
                Section("Flags") {
                    ForEach(host.flags, id: \.self) { f in
                        Label(Format.flag(f), systemImage: Format.isAlarming(flag: f) ? "bolt.trianglebadge.exclamationmark" : "info.circle")
                            .foregroundStyle(Format.isAlarming(flag: f) ? .red : .primary)
                    }
                }
            }
            if let url = host.url {
                Section {
                    Button { openURL(url) } label: { Label("Open web interface", systemImage: "safari") }
                }
            }
        }
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Cards and services

struct CardView: View {
    let card: Card
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: Symbols.safe(card.icon)).foregroundStyle(card.tint.color)
                Text(card.title ?? card.id).font(.headline)
                Spacer()
                if let updated = card.updated {
                    Text(ServerDate.parse(updated).map { Format.age($0) } ?? updated).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let subtitle = card.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            switch card.style {
            case .text:
                Text(markdown(card.text ?? card.items.compactMap(\.title).joined(separator: "\n"))).font(.subheadline)
            case .metrics:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(Array(card.items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title ?? "").font(.caption).foregroundStyle(.secondary)
                            Text(item.value ?? "–").font(.title3.weight(.semibold).monospacedDigit())
                                .foregroundStyle(item.tint?.color ?? .primary)
                            if let s = item.subtitle { Text(s).font(.caption2).foregroundStyle(.secondary) }
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
        let row = VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let icon = item.icon { Image(systemName: Symbols.safe(icon, fallback: "circle")).foregroundStyle(item.tint?.color ?? .secondary) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title ?? "").font(.subheadline).lineLimit(2)
                    if let s = item.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                if let v = item.value { Text(v).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if let p = item.progress { Meter(p, tint: card.tint == .gray ? .accentColor : card.tint.color) }
        }
        .accessibilityElement(children: .combine)
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
                                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
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
