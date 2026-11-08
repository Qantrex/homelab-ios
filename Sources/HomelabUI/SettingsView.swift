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
                    // Where the data comes from: two explicit choices, then the list to add, edit and delete servers.
                    Section {
                        sourceRow("Show data from", servers: model.servers.servers.filter(\.speaksCompanionAPI),
                                  chosen: model.selected, none: "No server yet",
                                  footer: "Today, Lab, Actions and Chat show this server's data.") { model.select($0) }
                        sourceRow("Home tiles from", servers: model.servers.servers.filter(\.showsHomeTab),
                                  chosen: model.homeAssistant, none: "No Home Assistant server",
                                  footer: "The Home tiles on Today come from this Home Assistant.") { model.selectHome($0) }
                    } header: {
                        Text("Data")
                    } footer: {
                        SettingsFooter("Today, Lab, Actions and Chat come from the server under \"Show data from\"; only the Home tiles come from Home Assistant.")
                    }

                    Section {
                        ForEach(model.servers.servers) { s in
                            Button { editing = s } label: { ServerRow(server: s) }
                                .foregroundStyle(.primary)
                                .accessibilityHint(Text(s.kind == .demo ? "Demo servers can't be edited" : "Edits this server"))
                                .swipeActions {
                                    // Demo servers come and go with the Demo switch below (a swiped one couldn't come back).
                                    if s.kind != .demo { Button("Delete", role: .destructive) { deleting = s } }
                                }
                        }
                        Button { adding = true } label: { Label("Add server", systemImage: "plus") }
                    } header: {
                        Text("Servers")
                    } footer: {
                        SettingsFooter("Tap a server to edit it, swipe to delete it. Demo servers go with the Demo switch.")
                    }

                    Section {
                        Picker("Detail", selection: Binding(get: { model.settings.todayDensity },
                                                            set: { model.settings.todayDensity = $0 })) {
                            ForEach(Density.allCases) { Text($0.title).tag($0) }
                        }
                        .accessibilityHint(Text(verbatim: model.settings.todayDensity.summary))
                        Picker("Personality", selection: Binding(get: { model.settings.voice },
                                                                 set: { model.settings.voice = $0 })) {
                            ForEach(Personality.allCases) { Text($0.title).tag($0) }
                        }
                        .ultrakillWarning(model)
                        PersonalityPreview(model: model)
                    } header: {
                        Text("Today")
                    } footer: {
                        SettingsFooter(verbatim: todayFooter)
                    }

                    Section {
                        Toggle("New problems", isOn: notifyBinding(\.notifyProblems))
                        Toggle("New actions to approve", isOn: notifyBinding(\.notifyPending))
                        // Also while it's on and the server's deals aren't loaded yet (offline, just switched), so it can be turned off.
                        if model.selectedStatus.hasDeals || model.settings.notifyDeals {
                            Toggle("New deals to act on", isOn: notifyBinding(\.notifyDeals))
                        }
                    } header: {
                        Text("Notifications")
                    } footer: {
                        SettingsFooter(verbatim: notificationNote ?? String(localized: "Checked in the background when iOS allows it (often every 15–60 minutes, not exact). If your homelab already pushes alerts (ntfy, Home Assistant), leave these off. Deals: the server already pushes the strong ones."))
                    }

                    Section {
                        Toggle("Lock with Face ID", isOn: Binding(
                            get: { model.settings.faceIDLock },
                            set: { on in Task { await setLock(on) } }))
                            // Stays usable while on: without a passcode any more, it can still be turned off.
                            .disabled(!Biometrics.available && !model.settings.faceIDLock)
                        Button("Reset everything", role: .destructive) { confirmReset = true }
                    } header: {
                        Text("Privacy")
                    } footer: {
                        SettingsFooter("Face ID or the passcode when the app opens; tokens always stay in the Keychain. Reset deletes all servers, tokens, cached data and settings from this phone.")
                    }

                    // The detailed settings: Today's sections and rules, Start tiles, Lab, Chat, the tab bar, quiet hours,
                    // Leave-by, Diagnostics and Demo servers. The title follows the personality (`AdvancedTitle`).
                    Section {
                        NavigationLink {
                            AdvancedSettingsView(model: model)
                        } label: {
                            LabeledContent(LocalizedStringKey(AdvancedTitle.text(model.settings.voice))) {
                                if model.settings.customizedElsewhere || model.settings.today != nil {
                                    Text("Customized").font(Typo.secondary).foregroundStyle(Palette.secondary)
                                }
                            }
                        }
                    } footer: {
                        SettingsFooter("Today's sections and rules, Start tiles, Lab, Chat, the tab bar, quiet hours, Diagnostics and Demo servers.")
                    }

                    Section {
                        NavigationLink("About Homelab") { AboutView() }
                        DataRow("Version", "\(AppVersion.short) (\(AppVersion.build))")
                    } header: {
                        Text("About")
                    }
                }
                .surfaceRows()
                .headerProminence(.increased)
            }
            .screenBackground()
            .navigationTitle("Settings")
            .sheet(item: $editing) { ServerEditor(model: model, server: $0) }
            // "Edit server" on an error banner elsewhere: open that server's editor here.
            .onAppear { openRequestedEditor() }
            .onChange(of: model.editServerRequest) { _, _ in openRequestedEditor() }
            .sheet(isPresented: $adding) { ServerEditor(model: model, server: nil) }
            .confirmationDialog("Delete \(deleting?.name ?? "server")?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { s in
                Button("Delete server and its token", role: .destructive) { model.remove(s.id) }
            } message: { s in
                Text(s.kind == .homeAssistant ? "The address, its saved token, the Home tiles with their names and icons, and cached data are removed from this phone."
                                              : "The address, its saved token and cached data are removed from this phone.")
            }
            .confirmationDialog("Reset everything?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Delete all data", role: .destructive) {
                    model.resetAll()
                    // Also what iOS still shows from before: notifications (problem texts, proposal and deal titles)
                    // and a running Leave-by on the lock screen.
                    let center = UNUserNotificationCenter.current()
                    center.removeAllDeliveredNotifications()
                    center.removeAllPendingNotificationRequests()
                    Task { await LeaveActivityController.endAll() }
                }
            } message: {
                Text("All servers, tokens, Home tiles, cached data and settings are deleted from this phone. Your servers keep their data.")
            }
        }
    }

    private func openRequestedEditor() {
        guard let id = model.editServerRequest else { return }
        model.editServerRequest = nil
        if let s = model.servers.servers.first(where: { $0.id == id }), s.kind != .demo { editing = s }
    }

    /// "Show data from  lab ›": opens the list of servers that can be chosen, each with its kind in words. Without any,
    /// a plain row says so.
    @ViewBuilder
    private func sourceRow(_ title: LocalizedStringKey, servers: [ServerConfig], chosen: ServerConfig?,
                           none: LocalizedStringKey, footer: LocalizedStringKey,
                           choose: @escaping (UUID) -> Void) -> some View {
        if servers.isEmpty {
            LabeledContent(title) { Text(none).foregroundStyle(Palette.secondary) }
        } else {
            NavigationLink {
                ServerChoice(title: title, servers: servers, chosen: chosen?.id, footer: footer, choose: choose)
            } label: {
                LabeledContent(title) {
                    Text(verbatim: chosen?.name ?? "–").foregroundStyle(Palette.secondary).lineLimitAtStandardSizes(1).truncationMode(.middle)
                }
            }
        }
    }

    /// What each detail shows, one line each (`Density.summary`); the personality speaks for itself in the preview above.
    private var todayFooter: String {
        let density = Density.explanation
        guard model.settings.voice == .ultrakill else { return density }
        return density + "\n" + String(localized: "Ultrakill is rude on purpose.")
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

/// Today's headline and what the chosen personality says about it right now (`Voice.sample`, the same take Today
/// shows), so each voice can be heard before it's kept. Changes as the picker moves; a tap asks for another line.
struct PersonalityPreview: View {
    let model: AppModel
    @State private var variant = 0

    private var state: HomelabState? { model.selectedStatus.snapshot?.state }

    private var mood: TodayMood {
        model.selected == nil ? TodayMood(level: .unknown, headline: String(localized: "Home."), detail: nil)
                              : TodayMood(state: state, checking: model.selectedStatus.error == nil)
    }

    private var symbol: String? {
        switch mood.level {
        case .alarm: "exclamationmark.octagon.fill"
        case .headsUp: "exclamationmark.triangle.fill"
        case .calm: "checkmark.circle.fill"
        case .unknown: nil
        }
    }

    var body: some View {
        let voice = model.settings.voice
        let m = mood
        let line = Voice.sample(for: state, level: m.level, personality: voice, variant: variant)
        Button { variant += 1 } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("On Today now").font(Typo.meta).foregroundStyle(Palette.tertiary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let symbol {
                        Image(systemName: symbol).font(Typo.secondary.weight(.semibold)).foregroundStyle(m.level.color)
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: m.headline).font(Typo.sectionTitle).foregroundStyle(Palette.text)
                }
                Text(verbatim: line ?? String(localized: "No commentary: just the facts."))
                    .font(Typo.body)
                    .foregroundStyle(line == nil ? Palette.tertiary : Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .id(voice)
                ForEach(Voice.preview(for: state, personality: voice, variant: variant), id: \.self) {
                    Text(verbatim: $0).font(Typo.meta).foregroundStyle(Palette.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(line == nil)
        .animation(.easeInOut(duration: 0.2), value: line)
        .onChange(of: voice) { variant = 0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Preview: \(m.headline) \(line ?? String(localized: "No commentary."))"))
        .accessibilityHint(line == nil ? Text("") : Text("Shows another line"))
    }
}

/// Settings → Data → "Show data from" / "Home tiles from": the servers that can be chosen, the chosen one ticked.
/// Choosing goes back.
struct ServerChoice: View {
    let title: LocalizedStringKey
    let servers: [ServerConfig]
    let chosen: UUID?
    let footer: LocalizedStringKey
    let choose: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(servers) { s in
                    Button {
                        choose(s.id)
                        dismiss()
                    } label: {
                        HStack {
                            ServerRow(server: s)
                            Spacer()
                            if s.id == chosen {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Palette.text)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(s.id == chosen ? .isSelected : [])
                }
            } footer: {
                SettingsFooter(footer)
            }
            .surfaceRows()
        }
        .screenBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A server in a list: its icon, name, and what kind of server it is in words ("Homelab API · lab.ts.net",
/// "Demo · example data").
struct ServerRow: View {
    let server: ServerConfig

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(Palette.text).frame(width: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: server.name)
                Text(verbatim: detail)
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch server.kind {
        case .companion: String(localized: "Homelab API") + " · " + server.host
        case .homeAssistant: String(localized: "Home Assistant") + " · " + server.host
        case .demo: server.isDemoHomeAssistant ? String(localized: "Demo Home Assistant · example data")
                                               : String(localized: "Demo · example data")
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
    /// Called after a successful Save, before the editor closes (the first run goes on to Found).
    private let onSaved: ((ServerConfig) -> Void)?

    /// `kind` is the type a new server starts with (the first run's "Add Home Assistant"); an existing server keeps
    /// its own.
    init(model: AppModel, server: ServerConfig?, kind newKind: ServerConfig.Kind? = nil,
         onSaved: ((ServerConfig) -> Void)? = nil) {
        self.model = model
        original = server
        self.onSaved = onSaved
        let startKind: ServerConfig.Kind = server.map { $0.kind == .homeAssistant ? .homeAssistant : .companion }
            ?? (newKind == .homeAssistant ? .homeAssistant : .companion)
        _name = State(initialValue: server?.name ?? "")
        _kind = State(initialValue: startKind)
        _address = State(initialValue: server.map { $0.kind == .demo ? "" : $0.baseURL.absoluteString } ?? "")
        _auth = State(initialValue: server?.auth ?? (startKind == .homeAssistant ? .token : .identity))
        _tokenStored = State(initialValue: server.map { model.tokens.token(for: $0.id) != nil } ?? false)
    }

    private var urlResult: Result<URL, URLPolicy.Problem> { URLPolicy.serverURL(address) }
    /// A token over plain http to an address outside this phone and the tailnet: an error, Save stays off (the
    /// clients would refuse the server with the same text).
    private var tokenProblem: String? {
        guard case .success(let url) = urlResult else { return nil }
        return ServerConfig.tokenTransportProblem(kind: kind, auth: kind == .homeAssistant ? .token : auth, url: url)
    }
    private var canSave: Bool { (try? urlResult.get()) != nil && tokenProblem == nil }
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
                            } else if let tokenProblem {
                                Label(tokenProblem, systemImage: "xmark.circle.fill").font(.footnote).foregroundStyle(Palette.love)
                            } else if case .success(let url) = urlResult, url.scheme == "http" {
                                Label("Plain http: only use this inside your home network or tailnet.", systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Palette.gold)
                            }
                        } footer: {
                            SettingsFooter(kind == .homeAssistant
                                 ? "Your Home Assistant address, as you open it in a browser."
                                 : "The server's address without /api/v1. With Tailscale, the .ts.net name of the machine plus the port you gave tailscale serve (for example :7443).")
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
                            .disabled(testing || !canSave)
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
            .labeledContentStyle(.adaptive)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if !isDemo {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }.disabled(!canSave)
                    }
                }
            }
            .onChange(of: kind) { _, new in if new == .homeAssistant { auth = .token } }
            // VoiceOver hears the test result and a save error, wherever the focus is.
            .onChange(of: testResult) { _, new in
                switch new {
                case .success(let text): AccessibilityNotification.Announcement(text).post()
                case .failure(let e): AccessibilityNotification.Announcement(e.message).post()
                case nil: break
                }
            }
            .onChange(of: saveError) { _, new in
                if let new { AccessibilityNotification.Announcement(new).post() }
            }
        }
    }

    private func config() -> ServerConfig? {
        guard case .success(let url) = urlResult else { return nil }
        let fallbackName = kind == .homeAssistant ? "Home Assistant" : ServerConfig.defaultName(for: url)
        // Over the original: editing the token or the name keeps the pins and the tiles' names and icons.
        return ServerConfig.edited(original, name: name.trimmingCharacters(in: .whitespaces).nonEmptyOr(fallbackName),
                                   kind: kind, baseURL: url, auth: kind == .homeAssistant ? .token : auth)
    }

    /// Uses the typed token (or the stored one) without saving anything yet.
    private func test() async {
        guard let c = config(), tokenProblem == nil else { return }
        if (c.kind == .homeAssistant || c.auth == .token) && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !storedTokenUsable {
            testResult = nil
            saveError = String(localized: "Enter the token first.")
            return
        }
        saveError = nil
        testing = true
        testResult = nil   // a repeated result is announced again
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
        guard let c = config(), tokenProblem == nil else { return }
        let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if (c.kind == .homeAssistant || c.auth == .token) && typed.isEmpty && !storedTokenUsable {
            saveError = String(localized: "Enter the token first.")
            return
        }
        do {
            try model.save(c, token: typed.isEmpty ? nil : typed)
            if c.speaksCompanionAPI { Task { await model.refresh(c) } }
            onSaved?(c)
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
                    if let expires = AppExpiry.current {
                        DataRow("Install expires", expires.formatted(date: .abbreviated, time: .shortened))
                    }
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
                Section("At a glance") {
                    LabeledContent("Live Activities", value: LeaveActivityController.allowed ? String(localized: "allowed") : String(localized: "off in iOS Settings"))
                    LabeledContent("Leave-by", value: logText(RunLog.leaveActivity))
                    LabeledContent("Widget fetch", value: logText(RunLog.widgetFetch))
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
                // A Homelab Bridge's sources (SourceStatusSection.swift); nothing for a server without them.
                ForEach(sourceLists) { list in
                    SourceStatusSection(title: list.title, sources: list.sources)
                }
                Section {
                    Button(copied ? "Copied" : "Copy report") {
                        UIPasteboardBridge.copy(report())
                        copied = true
                    }
                } footer: {
                    SettingsFooter("The report has no tokens, and the tailnet part of host names, your servers' names, names ending in .lan, .local, .home.arpa or .internal, and IP addresses (LAN, IPv6 and public) are masked. Check it before posting. It helps when something doesn't work.")
                }
            }
            .surfaceRows()
                .headerProminence(.increased)
        }
        .screenBackground()
        .navigationTitle("Diagnostics")
        .task { probes = AppGroup.resolve().probes }
    }

    /// "3 min ago: ok" for a log the widget or the Live Activity wrote.
    private func logText(_ name: String) -> String {
        guard let log = model.storage.read(RunLog.self, name) else { return "–" }
        return "\(Format.age(log.date)): \(log.result)"
    }

    private struct SourceList: Identifiable {
        let id: UUID
        let title: String
        let sources: [SourceStatus]
    }

    /// Each server that sends `sources` in /info (live or cached), in the list's order. Empty for every other server.
    private var sourceLists: [SourceList] {
        let servers = model.servers.servers.filter { model.status[$0.id]?.knownInfo?.sources != nil }
        return servers.map { s in
            SourceList(id: s.id, title: servers.count > 1 ? "Sources · \(s.name)" : "Sources",
                       sources: model.status[s.id]?.knownInfo?.sources ?? [])
        }
    }

    private func report() -> String {
        var lines = ["Homelab \(AppVersion.short) (\(AppVersion.build)), iOS \(UIDeviceInfo.version)",
                     "bundle \(Bundle.main.bundleIdentifier ?? "?"), group \(AppGroup.current ?? "none")"]
        lines += probes.map { "group \($0.group): found=\($0.containerFound) writable=\($0.writable)" }
        lines.append("background: \(Format.age(model.settings.lastBackgroundRun)) \(model.settings.lastBackgroundResult ?? "")")
        lines.append("live activities: \(LeaveActivityController.allowed ? "allowed" : "off"), leave-by \(logText(RunLog.leaveActivity)), widget fetch \(logText(RunLog.widgetFetch))")
        for s in model.servers.servers {
            let st = model.status[s.id]
            lines.append("server \(s.kind.rawValue)/\(s.auth.rawValue) \(Redact.host(s.host)): data \(Format.age(st?.snapshot?.fetched)), error \(st?.error?.message ?? "none")")
            // Only a Homelab Bridge sends sources; masked with the rest below.
            lines += (st?.knownInfo?.sources ?? []).map { "  " + $0.reportLine() }
        }
        return Redact.hosts(lines.joined(separator: "\n"), knownHosts: model.servers.servers.map(\.host))
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

/// Settings → Today: show or hide each section, choose when it shows, drag to reorder.
struct TodayLayoutEditor: View {
    let model: AppModel

    var body: some View {
        List {
            Group {
                Section {
                    // Each row: the switch, and when it shows (a tap picks the rule; ShowRuleEditor.swift).
                    ForEach(model.settings.todayLayout.listed) { SectionRuleRow(model: model, section: $0) }
                    .onMove { model.settings.todayLayout.moveListed(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    SettingsFooter("The headline with your lab's status always stays on top. Tap a section to choose when it shows. Drag the handles to change the order.")
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
