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
    @Environment(\.hyper) private var hyper

    private var current: Host { model.selectedStatus.snapshot?.state.hosts.first { $0.id == host.id } ?? host }

    var body: some View {
        let host = current
        let health = model.selectedStatus.health(of: host)
        List {
            Group {
                Section {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Circle().fill(health.color).frame(width: 8, height: 8).accessibilityHidden(true)
                            Text(health.label).foregroundStyle(Palette.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let checked = host.checked {
                        LabeledContent("Checked") {
                            Text(Format.age(checked)).foregroundStyle(Palette.secondary)
                                .accessibilityLabel(Format.spokenAge(checked))
                        }
                    }
                    if let kind = host.kind { LabeledContent("Kind") { Text(kind).foregroundStyle(Palette.secondary) } }
                }
                if let history = host.history {
                    HistorySection(history: history, cores: host.cpuCount)
                }
                if !host.containerList.isEmpty {
                    containers(host)
                }
                if host.reachable == true {
                    Section {
                        LabeledContent("Load (1 min)") {
                            HStack(spacing: 6) {
                                Text(Format.load(host.load)).font(Typo.data(.body))
                                    .accessibilityLabel(spokenHigh(Format.load(host.load), host.loadLevel))
                                if let cores = host.cpuCount { Text("of \(cores) cores").foregroundStyle(Palette.secondary) }
                            }
                        }
                        value("Memory", Format.percent(host.memPct), level: host.ramLevel)
                        if host.temp != nil { value("Temperature", Format.temperature(host.temp), level: host.tempLevel) }
                        if host.containersTotal != nil || host.containersUp != nil {
                            value("Containers up", Format.containers(up: host.containersUp, total: host.containersTotal))
                        }
                    } header: { sectionHeader("System") }
                    if !host.disks.isEmpty {
                        Section {
                            ForEach(host.disks.sorted { $0.key < $1.key }, id: \.key) { mount, pct in
                                let level = HostHistory.Series.diskPct.level(of: Double(pct), cores: nil)
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(mount).font(Typo.data(.body))
                                        Spacer()
                                        Text("\(pct)%").font(Typo.data(.body))
                                            .foregroundStyle(Meter.valueColor(level))
                                    }
                                    Meter(Double(pct) / 100, warns: true)
                                }
                                .padding(.vertical, 2)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text(mount))
                                .accessibilityValue(Text(spokenHigh("\(pct)%", level)))
                            }
                        } header: { sectionHeader("Disks") }
                    }
                    if host.upgradable != nil || host.rebootRequired != nil || host.backupResult != nil {
                        Section {
                            if let u = host.upgradable { value("Updates waiting", "\(u)") }
                            if host.rebootRequired == true {
                                LabeledContent("Reboot") { Text("required").foregroundStyle(Palette.secondary) }
                            }
                            if let b = Format.backup(last: host.backupLast, result: host.backupResult) {
                                LabeledContent("Backup") {
                                    HStack(spacing: 6) {
                                        if Format.backupFailed(host.backupResult) {
                                            Image(systemName: "xmark.octagon.fill").foregroundStyle(Palette.love).accessibilityHidden(true)
                                        }
                                        Text(b).foregroundStyle(Palette.secondary)
                                    }
                                }
                            }
                        } header: { sectionHeader("Maintenance") }
                    }
                }
                if !host.flags.isEmpty {
                    Section {
                        ForEach(host.flags, id: \.self) { f in
                            let alarming = Format.isAlarming(flag: f)
                            Label {
                                Text(Format.flag(f)).foregroundStyle(Palette.text)
                            } icon: {
                                Image(systemName: alarming ? "bolt.trianglebadge.exclamationmark" : "info.circle")
                                    .foregroundStyle(alarming ? (health == .problem ? Palette.love : Palette.gold) : Palette.secondary)
                            }
                        }
                    } header: { sectionHeader("Flags") }
                }
                if let url = host.url {
                    Section {
                        Button { openURL(url) } label: { Label("Open web interface", systemImage: "safari") }
                            .foregroundStyle(Palette.text)
                    }
                }
                // Hyperdetail: every field the server sent for this host, all history numbers included.
                if let hyper {
                    Section {
                        HyperNote(lines: Hyper.host(host, now: hyper.now, calendar: hyper.calendar),
                                  fact: Hyper.fact(host: host, now: hyper.now))
                    } header: { sectionHeader("Everything") }
                }
            }
            .surfaceRows()
        }
        .screenBackground()
        .refreshable { await model.refresh() }
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Palette.accent)
        .labeledContentStyle(.adaptive)
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { c in
            Button("Restart", role: .destructive) { Task { await restart(c) } }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text("Restarts \(c.name) on \(host.name) at once. It is down for a moment.")
        }
        .actionFeedback(result: $result, outcome: outcome)
    }

    /// A row with its value in the data font (a number or an id). A value over its limit (`level`) says "high".
    private func value(_ label: LocalizedStringKey, _ text: String, level: ValueLevel = .normal) -> some View {
        LabeledContent(label) { Text(text).font(Typo.data(.body)).accessibilityLabel(spokenHigh(text, level)) }
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
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Containers")
                Spacer()
                if problems > 0 {
                    Text(problems == 1 ? "1 problem" : "\(problems) problems").font(.footnote).foregroundStyle(Palette.secondary)
                        .textCase(nil)
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
        // The list only changes with the host's next check: until then the row says it was restarted (also after a
        // broken connection, which may still have restarted it). AppModel.restart notes that.
        let r = await model.restart(form, host: current.id, container: c.name, on: server)
        restarting.remove(c.name)
        let (ok, message) = ResultMessage.restart(c.name, r, model: model)
        outcome = ActionOutcome(ok: ok)
        result = message
    }
}

/// One container: a status dot (love or gold for a problem), its name, the state in words, and a Restart button
/// when the server lets the app restart it.
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
                                                  : AnyLayout(HStackLayout(spacing: 12))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(container.name).font(Typo.headline).foregroundStyle(Palette.text)
                        .lineLimit(2).truncationMode(.middle)
                    Text(detail).font(.footnote).foregroundStyle(Palette.secondary)
                    if let restartedAt {
                        Text("restarted \(restartedAt.formatted(date: .omitted, time: .shortened)), waiting for the next check")
                            .font(.footnote).foregroundStyle(Palette.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            if restarting {
                ProgressView().accessibilityLabel(Text("Restarting"))
            } else if canRestart {
                Button(action: restart) { Label("Restart", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered)
                    .tint(Palette.text)
                    .fixedSize()
                    .accessibilityLabel(Text("Restart \(container.name)"))
            }
        }
        .padding(.vertical, 4)
    }

    private var color: Color {
        if let s = container.severity { return s.color }
        return container.state == .running ? Palette.secondary : Palette.tertiary
    }

    /// "Exited, 3 restarts", "Running, unhealthy": the state in words, so the dot never carries it alone.
    private var detail: String {
        var parts = [container.state.rawValue.capitalizedFirst]
        if let h = container.health { parts.append(h.rawValue) }
        if let n = container.restarts, n > 0 { parts.append(n == 1 ? String(localized: "1 restart") : String(localized: "\(n) restarts")) }
        return parts.joined(separator: " · ")
    }
}

fileprivate extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// A value for VoiceOver, with "high" after it when it is over its limit (docs/DESIGN.md §3: never colour alone).
fileprivate func spokenHigh(_ text: String, _ level: ValueLevel) -> String {
    level.isHigh ? text + " " + String(localized: "high") : text
}

/// A section title in the app's title role (sentence case), for grouped lists.
fileprivate func sectionHeader(_ text: LocalizedStringKey) -> some View {
    Text(text).font(Typo.sectionTitle).foregroundStyle(Palette.text).textCase(nil)
}

/// The last 24 h: one sparkline per series the server sends, with min, max and now in mono.
struct HistorySection: View {
    let history: HostHistory
    let cores: Int?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var shown: [HostHistory.Series] {
        HostHistory.Series.allCases.filter { history.last($0) != nil }
    }

    var body: some View {
        if !shown.isEmpty {
            Section {
                ForEach(shown, id: \.self) { series in row(series) }
            } header: {
                sectionHeader("Last 24 h")
            } footer: {
                Text(footer).font(.footnote).accessibilityLabel(Format.spoken(footer))
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
        let nowColor = now.map { Meter.valueColor(series.level(of: $0, cores: cores)) } ?? Palette.tertiary
        let spokenNow = now.map { spokenHigh(String(localized: "now \(series.format($0))"), series.level(of: $0, cores: cores)) }
            ?? last.map { String(localized: "until \($0.date.formatted(date: .omitted, time: .shortened)): \(series.format($0.value))") }
            ?? String(localized: "no current value")
        // From AX3 the title, the time and the big value don't fit side by side: one under the other.
        let stacked = typeSize >= .accessibility3
        let header = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                             : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        return VStack(alignment: .leading, spacing: 8) {
            header {
                Text(title(series)).font(Typo.secondary).foregroundStyle(Palette.secondary)
                if !stacked { Spacer() }
                if now == nil, let last {
                    Text("until \(last.date.formatted(date: .omitted, time: .shortened))").font(Typo.meta)
                        .foregroundStyle(Palette.tertiary)
                }
                Text(series.format(shown)).font(Typo.displayData).foregroundStyle(nowColor)
            }
            Sparkline(history, series, cores: cores, label: title(series), now: date)
                .frame(height: 44)
            HStack(spacing: 4) {
                Text("Min").foregroundStyle(Palette.tertiary)
                Text(series.format(lo)).font(Typo.data(.footnote)).foregroundStyle(Palette.secondary)
                Spacer()
                Text("Max").foregroundStyle(Palette.tertiary)
                Text(series.format(hi)).font(Typo.data(.footnote)).foregroundStyle(Palette.secondary)
            }
            .font(.footnote)
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
