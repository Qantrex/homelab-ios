import HomelabDesign
import HomelabKit
import SwiftUI

/// One host: status, the last 24 h as sparklines, its containers (restart the ones on its list), system numbers,
/// disks, maintenance, flags and its web interface. Shows the newest data of that host while it is open.
struct HostDetailView: View {
    let model: AppModel
    /// The host as it was tapped; `current` follows refreshes.
    let host: Host

    @State private var confirm: ContainerInfo?
    @State private var restarting: Set<String> = []
    @State private var result: ResultMessage?
    @State private var outcome: ActionOutcome?
    @Environment(\.openURL) private var openURL

    private var current: Host { model.selectedStatus.snapshot?.state.hosts.first { $0.id == host.id } ?? host }

    var body: some View {
        let host = current
        let health = HostHealth(host)
        List {
            Group {
                Section {
                    LabeledContent("Status") { Text(health.label).foregroundStyle(health.color) }
                    if let checked = host.checked { LabeledContent("Checked", value: Format.age(checked)) }
                    if let kind = host.kind { LabeledContent("Kind", value: kind) }
                }
                if let history = host.history {
                    HistorySection(history: history, cores: host.cpuCount)
                }
                if !host.containerList.isEmpty {
                    containers(host)
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
            .surfaceRows()
        }
        .screenBackground()
        .refreshable { await model.refresh() }
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { c in
            Button("Restart", role: .destructive) { Task { await restart(c) } }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text("Restarts \(c.name) on \(host.name) at once. It is down for a moment.")
        }
        .actionFeedback(result: $result, outcome: outcome)
    }

    // MARK: Containers

    private func containers(_ host: Host) -> some View {
        let list = ContainerInfo.ordered(host.containerList)
        let problems = list.filter(\.isProblem).count
        return Section {
            ForEach(list) { c in
                let waiting = model.restartWaiting(host: host, container: c)
                ContainerRow(container: c, restarting: restarting.contains(c.name), restartedAt: waiting,
                             canRestart: waiting == nil && model.selectedStatus.restartForm(host: host, container: c) != nil) {
                    confirm = c
                }
            }
        } header: {
            HStack {
                Text("Containers")
                Spacer()
                if problems > 0 {
                    Text(problems == 1 ? "1 problem" : "\(problems) problems").font(Typo.mono(.caption2)).foregroundStyle(Palette.love)
                }
            }
        }
    }

    private var confirmTitle: String {
        confirm.map { String(localized: "Restart \($0.name)?") } ?? ""
    }

    /// Runs the server's `restart-container` with `<host>:<name>`, like the form on the Actions tab would.
    private func restart(_ c: ContainerInfo) async {
        guard let server = model.selected, let form = model.selectedStatus.restartForm(host: current, container: c) else { return }
        restarting.insert(c.name)
        let r = await model.run(form, on: server)
        restarting.remove(c.name)
        switch r {
        case .success(let res):
            outcome = ActionOutcome(ok: res.ok)
            // The list only changes with the host's next check: until then the row says it was restarted.
            if res.ok { model.noteRestart(host: current.id, container: c.name) }
            let title = !res.ok ? String(localized: "Restart of \(c.name) failed")
                : res.running ? String(localized: "Restart of \(c.name) started") : String(localized: "Restarted \(c.name)")
            result = ResultMessage(title: title, text: res.text)
        case .failure(let e):
            // A broken connection may still have restarted it: wait for the next check too.
            if e.mayHaveRun { model.noteRestart(host: current.id, container: c.name) }
            outcome = ActionOutcome(ok: false)
            result = ResultMessage(title: e.actionFailure.title, text: e.actionFailure.text)
        }
    }
}

/// One container: a dot (love or gold for a problem), its name in mono, state, health and restarts, and a Restart
/// button when the server lets the app restart it.
struct ContainerRow: View {
    let container: ContainerInfo
    let restarting: Bool
    /// Restarted from here; the shown state is older than that until the host's next check.
    var restartedAt: Date?
    let canRestart: Bool
    let restart: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                                  : AnyLayout(HStackLayout(spacing: 10))
        layout {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(container.name).font(Typo.mono(.subheadline, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(Typo.mono(.caption2))
                        .foregroundStyle(container.severity?.color ?? Palette.secondary)
                    if let restartedAt {
                        Text("restarted \(restartedAt.formatted(date: .omitted, time: .shortened)), waiting for the next check")
                            .font(Typo.mono(.caption2)).foregroundStyle(Palette.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            if restarting {
                ProgressView().accessibilityLabel(Text("Restarting"))
            } else if canRestart {
                Button(action: restart) { ButtonText(title: "Restart", symbol: "arrow.clockwise") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(container.isProblem ? Palette.love : Palette.text)
                    .fixedSize()
                    .accessibilityLabel(Text("Restart \(container.name)"))
            }
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        if let s = container.severity { return s.color }
        return container.state == .running ? Palette.secondary : Palette.tertiary
    }

    /// "exited · 3 restarts", "running · unhealthy".
    private var detail: String {
        var parts = [container.state.rawValue]
        if let h = container.health { parts.append(h.rawValue) }
        if let n = container.restarts, n > 0 { parts.append(n == 1 ? String(localized: "1 restart") : String(localized: "\(n) restarts")) }
        return parts.joined(separator: " · ")
    }
}

/// The last 24 h: one sparkline per series the server sends, with min, max and now in mono.
struct HistorySection: View {
    let history: HostHistory
    let cores: Int?

    private var shown: [HostHistory.Series] {
        HostHistory.Series.allCases.filter { history.last($0) != nil }
    }

    var body: some View {
        if !shown.isEmpty {
            Section {
                ForEach(shown, id: \.self) { series in row(series) }
            } header: {
                Text("Last 24 h")
            } footer: {
                Text(footer).font(Typo.mono(.caption2))
            }
        }
    }

    private func row(_ series: HostHistory.Series) -> some View {
        let date = Date()
        // "now" only for a recent value; an old history shows its last value dimmed with its time.
        let now = history.recentLast(series, now: date)
        let last = history.points(series).last
        let shown = now ?? history.last(series) ?? 0
        let lo = history.min(series) ?? shown, hi = history.max(series) ?? shown
        let limits = series.limits(cores: cores)
        let nowColor = now.map { $0 >= limits.problem ? Palette.love : $0 >= limits.warning ? Palette.gold : Palette.text }
            ?? Palette.tertiary
        let spokenNow = now.map { String(localized: "now \(series.format($0))") }
            ?? last.map { String(localized: "until \($0.date.formatted(date: .omitted, time: .shortened)): \(series.format($0.value))") }
            ?? String(localized: "no current value")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title(series)).font(.subheadline)
                Spacer()
                if now == nil, let last {
                    Text("until \(last.date.formatted(date: .omitted, time: .shortened))").font(Typo.mono(.caption2))
                        .foregroundStyle(Palette.tertiary)
                }
                Text(series.format(shown)).font(Typo.mono(.subheadline, weight: .semibold)).foregroundStyle(nowColor)
            }
            Sparkline(history, series, cores: cores, label: title(series), now: date)
                .frame(height: 44)
            HStack {
                Text("min \(series.format(lo))")
                Spacer()
                Text("max \(series.format(hi))")
            }
            .font(Typo.mono(.caption2))
            .foregroundStyle(Palette.tertiary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title(series)), last 24 hours"))
        .accessibilityValue(Text("\(spokenNow), minimum \(series.format(lo)), maximum \(series.format(hi))"))
    }

    private func title(_ series: HostHistory.Series) -> String {
        switch series {
        case .load: String(localized: "Load")
        case .memPct: String(localized: "Memory")
        case .temp: String(localized: "Temperature")
        case .diskPct: String(localized: "Fullest disk")
        }
    }

    /// "One point every 5 min, until 21:25."
    private var footer: String {
        let every = history.step % 60 == 0 ? "\(history.step / 60) min" : "\(history.step) s"
        guard let end = history.end else { return String(localized: "One point every \(every).") }
        return String(localized: "One point every \(every), until \(end.formatted(date: .omitted, time: .shortened)).")
    }
}
