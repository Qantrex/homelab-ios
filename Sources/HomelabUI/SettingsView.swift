import HomelabDesign
import HomelabKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var editing: ServerConfig?
    @State private var adding = false
    @State private var confirmReset = false
    @State private var deleting: ServerConfig?
    @State private var notificationNote: String?

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        ForEach(model.servers.servers) { s in
                            Button { editing = s } label: { ServerRow(server: s, selected: s.id == model.selected?.id) }
                                .foregroundStyle(.primary)
                                .swipeActions {
                                    Button("Delete", role: .destructive) { deleting = s }
                                }
                        }
                        Button { adding = true } label: { Label("Add server", systemImage: "plus") }
                    } header: {
                        Text("Servers")
                    } footer: {
                        SettingsFooter("Tap a server to edit it. Today and Lab show the one with the checkmark; swipe to delete.")
                    }

                    if model.servers.servers.filter(\.speaksCompanionAPI).count > 1 {
                        Section {
                            Picker("Today, Lab, actions and chat", selection: Binding(
                                get: { model.selected?.id ?? UUID() },
                                set: { model.select($0) })) {
                                ForEach(model.servers.servers.filter(\.speaksCompanionAPI)) { Text($0.name).tag($0.id) }
                            }
                        } header: {
                            Text("Shown server")
                        }
                    }

                    Section {
                        Picker("Detail", selection: Binding(get: { model.settings.todayDensity },
                                                            set: { model.settings.todayDensity = $0 })) {
                            ForEach(Density.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Picker("Personality", selection: Binding(get: { model.settings.voice },
                                                                 set: { model.settings.voice = $0 })) {
                            ForEach(Personality.allCases) { Text($0.title).tag($0) }
                        }
                        NavigationLink {
                            TodayLayoutEditor(model: model)
                        } label: {
                            LabeledContent("Sections") {
                                Text("\(model.settings.todayLayout.visible.count) of \(TodaySection.allCases.count)")
                                    .font(Typo.data(.body)).foregroundStyle(Palette.secondary)
                            }
                        }
                    } header: {
                        Text("Today")
                    } footer: {
                        Text("Calm: the headline, the day's numbers and Home. Standard: the sections you choose. Overkill: everything at once, every machine's numbers and exact times. Personality: a line of commentary under the headline, on empty screens and in notifications; the facts stay the same.")
                    }

                    Section {
                        Toggle("New problems", isOn: notifyBinding(\.notifyProblems))
                        Toggle("New actions to approve", isOn: notifyBinding(\.notifyPending))
                    } header: {
                        Text("Notifications")
                    } footer: {
                        SettingsFooter(verbatim: notificationNote ?? String(localized: "Checked in the background when iOS allows it (often every 15–60 minutes, not exact). If your homelab already pushes alerts (ntfy, Home Assistant), leave these off."))
                    }

                    Section {
                        Toggle("Lock with Face ID", isOn: Binding(
                            get: { model.settings.faceIDLock },
                            set: { on in Task { await setLock(on) } }))
                            .disabled(!Biometrics.available)
                    } footer: {
                        SettingsFooter("Asks for Face ID or the passcode when the app opens. Tokens are always in the Keychain.")
                    }

                    Section {
                        Toggle("Demo servers", isOn: Binding(get: { model.isDemo }, set: { model.setDemo($0) }))
                    } footer: {
                        SettingsFooter("Example data to look around. Your own servers stay.")
                    }

                    Section {
                        NavigationLink("Diagnostics") { DiagnosticsView(model: model) }
                        NavigationLink("About") { AboutView() }
                    }

                    Section {
                        Button("Reset everything", role: .destructive) { confirmReset = true }
                    } footer: {
                        SettingsFooter("Deletes all servers, tokens, cached data and settings from this phone.")
                    }
                }
                .surfaceRows()
                .headerProminence(.increased)
            }
            .screenBackground()
            .navigationTitle("Settings")
            .sheet(item: $editing) { ServerEditor(model: model, server: $0) }
            .sheet(isPresented: $adding) { ServerEditor(model: model, server: nil) }
            .confirmationDialog("Delete \(deleting?.name ?? "server")?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { s in
                Button("Delete server and its token", role: .destructive) { model.remove(s.id) }
            } message: { _ in
                Text("The address, its saved token and cached data are removed from this phone.")
            }
            .confirmationDialog("Reset everything?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Delete all data", role: .destructive) { model.resetAll() }
            }
        }
    }

    private func notifyBinding(_ key: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: key] }, set: { on in
            if on {
                Task {
                    let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                    if granted {
                        model.settings[keyPath: key] = true
                        notificationNote = nil
                        BackgroundRefresh.schedule()
                    } else {
                        notificationNote = String(localized: "Notifications are off for Homelab. Turn them on in the iOS Settings app.")
                    }
                }
            } else {
                model.settings[keyPath: key] = false
            }
        })
    }

    private func setLock(_ on: Bool) async {
        // Prove it works before locking, so nobody locks themselves out.
        if await Biometrics.authenticate(reason: String(localized: on ? "Turn on the app lock" : "Turn off the app lock")) {
            model.settings.faceIDLock = on
        }
    }
}

struct ServerRow: View {
    let server: ServerConfig
    let selected: Bool

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(Palette.text).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                Text(server.kind == .demo ? String(localized: "Demo") : server.host)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
            }
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(Palette.text).accessibilityLabel(Text("Shown")) }
        }
    }

    private var icon: String {
        switch server.kind {
        case .companion: "server.rack"
        case .homeAssistant: "house"
        case .demo: "sparkles"
        }
    }
}

/// Add or edit a server, with a connection test before saving.
struct ServerEditor: View {
    let model: AppModel
    let original: ServerConfig?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var kind: ServerConfig.Kind
    @State private var address: String
    @State private var auth: ServerConfig.Auth
    @State private var token = ""
    @State private var tokenStored: Bool
    @State private var testing = false
    @State private var testResult: Result<String, APIError>?
    @State private var saveError: String?
    @State private var confirmDelete = false

    init(model: AppModel, server: ServerConfig?) {
        self.model = model
        original = server
        _name = State(initialValue: server?.name ?? "")
        _kind = State(initialValue: server?.kind == .homeAssistant ? .homeAssistant : .companion)
        _address = State(initialValue: server.map { $0.kind == .demo ? "" : $0.baseURL.absoluteString } ?? "")
        _auth = State(initialValue: server?.auth ?? .identity)
        _tokenStored = State(initialValue: server.map { model.tokens.token(for: $0.id) != nil } ?? false)
    }

    private var urlResult: Result<URL, URLPolicy.Problem> { URLPolicy.serverURL(address) }
    private var needsToken: Bool { kind == .homeAssistant || auth == .token }
    private var isDemo: Bool { original?.kind == .demo }

    /// The stored token may only be used while kind and address stay the same (it was made for that server).
    private var storedTokenUsable: Bool {
        guard tokenStored, let original, let c = config() else { return false }
        return original.isSameTarget(as: c)
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    if isDemo {
                        Section { Text("Demo servers can't be edited. Turn demo mode off in Settings to remove them.") }
                    } else {
                        Section {
                            Picker("Type", selection: $kind) {
                                Text("Homelab API").tag(ServerConfig.Kind.companion)
                                Text("Home Assistant").tag(ServerConfig.Kind.homeAssistant)
                            }
                            TextField("Name", text: $name, prompt: Text(kind == .homeAssistant ? "Home Assistant" : "My homelab"))
                            TextField("Address", text: $address, prompt: Text(kind == .homeAssistant ? "https://ha.tailnet.ts.net" : "https://server.tailnet.ts.net:7443"))
                                .keyboardType(.URL)
                                .textContentType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if case .failure(let p) = urlResult, !address.isEmpty {
                                Label(URLPolicy.message(p), systemImage: "xmark.circle.fill").font(.footnote).foregroundStyle(Palette.love)
                            } else if case .success(let url) = urlResult, url.scheme == "http" {
                                Label("Plain http: only use this inside your home network or tailnet.", systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Palette.gold)
                            }
                        } footer: {
                            SettingsFooter(kind == .homeAssistant
                                 ? "Your Home Assistant address, as you open it in a browser."
                                 : "The server's address without /api/v1. With Tailscale, the .ts.net name of the machine plus the port you gave `tailscale serve` (for example :7443).")
                        }

                        Section {
                            if kind == .companion {
                                Picker("Login", selection: $auth) {
                                    Text("Tailscale / proxy").tag(ServerConfig.Auth.identity)
                                    Text("Token").tag(ServerConfig.Auth.token)
                                }
                            }
                            if needsToken {
                                SecureField(storedTokenUsable ? "Token saved (type to replace)" : (kind == .homeAssistant ? "Long-lived access token" : "Token"), text: $token)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .textContentType(.password)
                            }
                        } footer: {
                            if tokenStored && !storedTokenUsable && needsToken {
                                SettingsFooter("The address or type changed, so the saved token is not used for it. Enter the token for this server.")
                            } else if kind == .homeAssistant {
                                SettingsFooter("In Home Assistant: your profile → Security → Long-lived access tokens → Create token.")
                            } else if auth == .identity {
                                SettingsFooter("For servers behind tailscale serve: Tailscale on this phone proves who you are. No token needed.")
                            } else {
                                SettingsFooter("Stored in the iOS Keychain on this phone only.")
                            }
                        }

                        Section {
                            Button {
                                Task { await test() }
                            } label: {
                                HStack {
                                    Text("Test connection")
                                    Spacer()
                                    if testing { ProgressView() }
                                }
                            }
                            .disabled(testing || (try? urlResult.get()) == nil)
                            if let testResult {
                                switch testResult {
                                case .success(let text): Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(Palette.text)
                                case .failure(let e): Label(e.message, systemImage: "xmark.circle.fill").foregroundStyle(Palette.love)
                                }
                            }
                        }
                        if let saveError { Section { Text(saveError).foregroundStyle(Palette.love) } }

                        if let original {
                            Section {
                                Button("Delete server", role: .destructive) { confirmDelete = true }
                                    .confirmationDialog("Delete \(original.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                                        Button("Delete server and its token", role: .destructive) {
                                            model.remove(original.id)
                                            dismiss()
                                        }
                                    } message: {
                                        Text("The address, its saved token and cached data are removed from this phone.")
                                    }
                            }
                        }
                    }
                }
                .surfaceRows()
                .headerProminence(.increased)
            }
            .screenBackground()
            .navigationTitle(original == nil ? "Add server" : "Edit server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if !isDemo {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }.disabled((try? urlResult.get()) == nil)
                    }
                }
            }
            .onChange(of: kind) { _, new in if new == .homeAssistant { auth = .token } }
        }
    }

    private func config() -> ServerConfig? {
        guard case .success(let url) = urlResult else { return nil }
        let fallbackName = kind == .homeAssistant ? "Home Assistant" : (url.host ?? "Homelab")
        return ServerConfig(id: original?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespaces).nonEmptyOr(fallbackName),
                            kind: kind, baseURL: url, auth: kind == .homeAssistant ? .token : auth,
                            pinnedEntities: original?.pinnedEntities ?? [])
    }

    /// Uses the typed token (or the stored one) without saving anything yet.
    private func test() async {
        guard let c = config() else { return }
        testing = true
        defer { testing = false }
        let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = typed.isEmpty ? (storedTokenUsable ? model.tokens.token(for: c.id) : nil) : typed
        do {
            if c.kind == .homeAssistant {
                _ = try await HomeAssistantClient(baseURL: c.baseURL, token: t, transport: model.transport).check()
                testResult = .success(String(localized: "Home Assistant answers."))
            } else {
                let info = try await CompanionClient(baseURL: c.baseURL, token: c.auth == .token ? t : nil, transport: model.transport).info()
                if name.isEmpty, let n = info.name { name = n }
                testResult = .success(String(localized: "Connected to \(info.name ?? c.host): \(Self.describe(info.features))."))
            }
        } catch {
            testResult = .failure(APIError.from(error, host: c.host))
        }
    }

    /// "status, hosts and chat" for the connection test.
    static func describe(_ features: Set<ServerInfo.Feature>) -> String {
        let order: [(ServerInfo.Feature, String)] = [
            (.status, String(localized: "status")), (.hosts, String(localized: "hosts")), (.cards, String(localized: "cards")),
            (.actions, String(localized: "actions")), (.chat, String(localized: "chat")), (.services, String(localized: "services")),
        ]
        let names = order.filter { features.contains($0.0) }.map(\.1)
        return names.isEmpty ? String(localized: "no features") : names.formatted(.list(type: .and))
    }

    private func save() {
        guard let c = config() else { return }
        let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if (c.kind == .homeAssistant || c.auth == .token) && typed.isEmpty && !storedTokenUsable {
            saveError = String(localized: "Enter the token first.")
            return
        }
        do {
            try model.save(c, token: typed.isEmpty ? nil : typed)
            if c.speaksCompanionAPI { Task { await model.refresh(c) } }
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

extension String {
    func nonEmptyOr(_ fallback: String) -> String { isEmpty ? fallback : self }
}

struct DiagnosticsView: View {
    let model: AppModel
    @State private var probes: [AppGroup.Probe] = []
    @State private var copied = false

    var body: some View {
        List {
            Group {
                Section("App") {
                    DataRow("Version", "\(AppVersion.short) (\(AppVersion.build))")
                    DataRow("Bundle ID", Bundle.main.bundleIdentifier ?? "?")
                    DataRow("iOS", UIDeviceInfo.version)
                }
                Section("Shared storage") {
                    if let group = AppGroup.current { DataRow("App Group", group) } else {
                        LabeledContent("App Group", value: String(localized: "none (widget can't see data)"))
                    }
                    ForEach(probes, id: \.group) { p in
                        DataRow(verbatim: p.group, value: p.writable ? "ok" : p.containerFound ? "read-only" : "–")
                    }
                }
                Section("Background") {
                    LabeledContent("Last run", value: Format.age(model.settings.lastBackgroundRun))
                    LabeledContent("Result", value: model.settings.lastBackgroundResult ?? "–")
                }
                Section("Servers") {
                    ForEach(model.servers.servers) { s in
                        let st = model.status[s.id]
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.name).font(.headline)
                            Text("\(s.kind.rawValue), \(s.auth.rawValue), \(s.host)").font(.subheadline).foregroundStyle(Palette.secondary)
                            if let snap = st?.snapshot { Text("Data from \(Format.age(snap.fetched))").font(.footnote).foregroundStyle(Palette.secondary) }
                            if let e = st?.error {
                                Label(e.message, systemImage: "xmark.circle.fill").font(.footnote).foregroundStyle(Palette.love)
                            }
                            if let info = st?.info {
                                Text("\(info.server ?? "?") \(info.version ?? ""), API \(info.api), \(info.features.map(\.rawValue).sorted().joined(separator: ", "))")
                                    .font(.footnote).foregroundStyle(Palette.tertiary)
                            }
                        }
                    }
                }
                Section {
                    Button(copied ? "Copied" : "Copy report") {
                        UIPasteboardBridge.copy(report())
                        copied = true
                    }
                } footer: {
                    SettingsFooter("The report has no tokens. It helps when something doesn't work.")
                }
            }
            .surfaceRows()
                .headerProminence(.increased)
        }
        .screenBackground()
        .navigationTitle("Diagnostics")
        .task { probes = AppGroup.resolve().probes }
    }

    private func report() -> String {
        var lines = ["Homelab \(AppVersion.short) (\(AppVersion.build)), iOS \(UIDeviceInfo.version)",
                     "bundle \(Bundle.main.bundleIdentifier ?? "?"), group \(AppGroup.current ?? "none")"]
        lines += probes.map { "group \($0.group): found=\($0.containerFound) writable=\($0.writable)" }
        lines.append("background: \(Format.age(model.settings.lastBackgroundRun)) \(model.settings.lastBackgroundResult ?? "")")
        for s in model.servers.servers {
            let st = model.status[s.id]
            lines.append("server \(s.kind.rawValue)/\(s.auth.rawValue) \(s.host): data \(Format.age(st?.snapshot?.fetched)), error \(st?.error?.message ?? "none")")
        }
        return lines.joined(separator: "\n")
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Group {
                Section {
                    Text("Homelab is an open-source companion app for self-hosted homelabs. It talks only to the servers you add. No accounts, no analytics, no third-party services.")
                        .font(.body)
                }
                Section("Source") {
                    Link("github.com/Qantrex/homelab-ios", destination: URL(string: "https://github.com/Qantrex/homelab-ios")!)
                    LabeledContent("License", value: "MIT")
                    LabeledContent("Third-party code", value: String(localized: "none"))
                }
                Section("Built with") {
                    Text("SwiftUI and WidgetKit, built with xtool (MIT) and installed with SideStore.").font(.subheadline).foregroundStyle(Palette.secondary)
                }
            }
            .surfaceRows()
                .headerProminence(.increased)
        }
        .screenBackground()
        .navigationTitle("About")
    }
}

/// Settings → Today: show or hide each section, drag to reorder.
struct TodayLayoutEditor: View {
    let model: AppModel

    var body: some View {
        List {
            Group {
                Section {
                    ForEach(model.settings.todayLayout.sections) { s in
                        Toggle(s.title, isOn: Binding(
                            get: { model.settings.todayLayout.isVisible(s) },
                            set: { model.settings.todayLayout.setVisible(s, $0) }))
                    }
                    .onMove { model.settings.todayLayout.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    SettingsFooter("The headline with your lab's status always stays on top. Drag the handles to change the order.")
                }
                Section {
                    Button("Standard layout") { model.settings.todayLayout = .standard }
                        .disabled(model.settings.todayLayout == .standard)
                }
            }
            .surfaceRows()
                .headerProminence(.increased)
        }
        .screenBackground()
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Today")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Footer under a settings section (DESIGN.md §1): footnote, secondary.
struct SettingsFooter: View {
    private let text: Text

    init(_ key: LocalizedStringKey) { text = Text(key) }
    init(verbatim: String) { text = Text(verbatim) }

    var body: some View { text.font(.footnote).foregroundStyle(Palette.secondary) }
}

/// A label with a value in the data font (versions, ids, paths).
struct DataRow: View {
    private let label: Text
    let value: String

    init(_ label: LocalizedStringKey, _ value: String) {
        self.label = Text(label)
        self.value = value
    }

    init(verbatim label: String, value: String) {
        self.label = Text(label)
        self.value = value
    }

    var body: some View {
        LabeledContent { Text(value).font(Typo.data(.subheadline)).foregroundStyle(Palette.secondary) } label: { label }
    }
}
