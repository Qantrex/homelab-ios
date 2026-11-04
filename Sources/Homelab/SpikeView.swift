import SpikeShared
import SwiftUI
import UIKit
import WidgetKit

/// One diagnostics screen. Every section maps to a test in SPIKE.md. "Copy report" puts all of it on the clipboard,
/// so the owner can paste it into the day-test note.
struct SpikeView: View {
    @Binding var lastDeepLink: String?

    @State private var group: String?
    @State private var probes: [AppGroup.Probe] = []
    @State private var provisioning: Provisioning?
    @State private var state = SpikeState()
    @State private var keychainValue: String?
    @State private var keychainStatus: OSStatus = 0
    @State private var probeURL = ""
    @State private var probe: ProbeResult?
    @State private var probing = false
    @State private var copied = false

    private var bundleID: String { Bundle.main.bundleIdentifier ?? "?" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    row("Bundle ID", bundleID)
                    row("Team suffix", AppGroup.teamSuffix(bundleID: bundleID) ?? "none")
                    row("Version", "\(info("CFBundleShortVersionString")) (\(info("CFBundleVersion")))")
                    row("Profile", provisioning?.name ?? "no embedded.mobileprovision")
                    if let expires = provisioning?.expires { row("Profile expires", expires.formatted()) }
                }

                Section("S4 App Group") {
                    row("In use", group ?? "NONE (fallback: app-only storage)")
                    row("Provisioned", provisioning?.appGroups.joined(separator: ", ") ?? "-")
                    ForEach(probes, id: \.group) { p in
                        row(p.group, p.writable ? "✅ writable" : p.containerFound ? "⚠️ read-only" : "❌")
                    }
                }

                Section("S3 Shared with the widget") {
                    row("Counter", "\(state.counter)")
                    row("Widget last read", state.widgetLastRead?.formatted() ?? "never")
                    Button("Counter +1 and reload widget") {
                        state = SpikeStore.update(group: group) {
                            $0.counter += 1
                            $0.writer = "app"
                            $0.lastWrite = Date()
                        }
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                }

                Section("S6 Keychain") {
                    row("Stored", keychainValue ?? "nothing (status \(keychainStatus))")
                    Button("Delete and write again", role: .destructive) {
                        _ = Keychain.delete()
                        keychainStatus = Keychain.writeIfMissing()
                        keychainValue = Keychain.read().value
                    }
                }

                Section("S6 Background refresh") {
                    row("Runs", "\(state.backgroundRuns)")
                    row("Last run", state.lastBackgroundRun?.formatted() ?? "never")
                    row("Last result", state.lastBackgroundResult ?? "-")
                    Button("Schedule now") { Background.schedule() }
                }

                Section("S5 Tailnet request (no token)") {
                    TextField("https://<host>.<tailnet>.ts.net/api/state", text: $probeURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(probing ? "Testing…" : "Test") {
                        Task { await runProbe() }
                    }
                    .disabled(probing || probeURL.isEmpty)
                    if let probe {
                        row("Result", probe.summary)
                        if !probe.bodyPrefix.isEmpty {
                            Text(probe.bodyPrefix).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }

                Section("Deep link") {
                    row("Last opened", lastDeepLink ?? "none (tap the widget)")
                }

                Section {
                    Button(copied ? "Copied" : "Copy report") {
                        UIPasteboard.general.string = report()
                        copied = true
                    }
                    Button("Reload") { reload() }
                }
            }
            .navigationTitle("Homelab Spike")
            .refreshable { reload() }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        let resolved = AppGroup.resolve()
        group = resolved.group
        probes = resolved.probes
        provisioning = Provisioning.read()
        keychainStatus = Keychain.writeIfMissing()
        keychainValue = Keychain.read().value
        state = SpikeStore.load(group: group)
        if probeURL.isEmpty { probeURL = state.probeURL }
        copied = false
    }

    private func runProbe() async {
        probing = true
        let url = probeURL
        state = SpikeStore.update(group: group) { $0.probeURL = url }
        probe = await NetworkProbe.run(url)
        probing = false
    }

    private func info(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "?"
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).font(.callout.monospaced()).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    private func report() -> String {
        var lines = [
            "Homelab spike report \(Date().formatted())",
            "iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)",
            "bundle \(bundleID), team \(AppGroup.teamSuffix(bundleID: bundleID) ?? "none")",
            "profile \(provisioning?.name ?? "none"), expires \(provisioning?.expires?.formatted() ?? "-")",
            "S4 group in use: \(group ?? "NONE")",
            "S4 provisioned: \(provisioning?.appGroups.joined(separator: ", ") ?? "-")",
        ]
        lines += probes.map { "S4 probe \($0.group): found=\($0.containerFound) writable=\($0.writable)" }
        lines += [
            "S3 counter \(state.counter), widget last read \(state.widgetLastRead?.formatted() ?? "never")",
            "S6 keychain \(keychainValue ?? "missing (\(keychainStatus))")",
            "S6 background runs \(state.backgroundRuns), last \(state.lastBackgroundRun?.formatted() ?? "never"): " +
                (state.lastBackgroundResult ?? "-"),
            "S5 \(probe.map { "\($0.url): \($0.summary)" } ?? "not run")",
            "deep link \(lastDeepLink ?? "none")",
        ]
        return lines.joined(separator: "\n")
    }
}
