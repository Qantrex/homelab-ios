import Foundation
import Observation
#if canImport(os)
import os
#endif

/// Logging that never carries secrets. Error texts can contain host names, so they are `.private`.
public enum AppLog {
    #if canImport(os)
    static let logger = Logger(subsystem: "com.qantrex.homelab", category: "app")
    #endif

    public static func notice(_ message: String) {
        #if canImport(os)
        logger.notice("\(message, privacy: .private)")
        #endif
    }
}

public enum AppTab: String, CaseIterable, Hashable, Sendable {
    case today, actions, chat, lab, settings

    /// A tab by name. Older names still work: the overview and the Home tab became Today (2026-11-05).
    public init?(name: String) {
        switch name.lowercased() {
        case "overview", "home": self = .today
        default: self.init(rawValue: name.lowercased())
        }
    }

    /// `homelab://actions` and the widget's links.
    public init?(url: URL) {
        guard url.scheme == "homelab" else { return nil }
        self.init(name: url.host ?? url.pathComponents.dropFirst().first ?? "")
    }
}

/// App-wide settings (not secret). `settings.json` in shared storage, so the background task and the widget read them.
public struct AppSettings: Codable, Sendable, Equatable {
    public var notifyProblems = false
    public var notifyPending = false
    public var faceIDLock = false
    public var lastBackgroundRun: Date?
    public var lastBackgroundResult: String?
    /// Today's section order and hidden sections; nil = the standard layout (also for settings from older versions).
    public var today: TodayLayout?
    /// Calm, Standard or Overkill; nil = Standard.
    public var density: Density?
    /// Off, Dry, Snarky or Ultrakill; nil = Off.
    public var personality: Personality?
    /// The "Leave by" Live Activity on school mornings; nil = on.
    public var leaveActivity: Bool?

    public static let fileName = "settings.json"
    public init() {}

    public var todayDensity: Density {
        get { density ?? .standard }
        set { density = newValue == .standard ? nil : newValue }
    }

    /// The Settings toggle "Leave-by on the lock screen" (default on).
    public var leaveByOn: Bool {
        get { leaveActivity ?? true }
        set { leaveActivity = newValue ? nil : false }
    }

    public var voice: Personality {
        get { personality ?? .off }
        set { personality = newValue == .off ? nil : newValue }
    }

    public var todayLayout: TodayLayout {
        get { today ?? .standard }
        set { today = newValue == .standard ? nil : newValue }
    }

    public var notificationsOn: Bool { notifyProblems || notifyPending }
}

/// The live state of one Companion server.
public struct ServerStatus: Sendable, Equatable {
    public var snapshot: Snapshot?
    public var info: ServerInfo?
    public var error: APIError?
    public var loading = false
    public var failures = 0
    public var services: [Service] = []
    public var servicesFetched: Date?
    /// Actions the app may start (feature `run-actions`), fetched like services.
    public var actions: [ActionSpec] = []
    public var actionsFetched: Date?
    public var infoFetched: Date?

    public init(snapshot: Snapshot? = nil) {
        self.snapshot = snapshot
    }

    /// A host's level, the one way everywhere (tile, detail, widget): with the server's problems if a state is known.
    public func health(of host: Host) -> HostHealth { snapshot?.state.health(of: host) ?? HostHealth(host) }

    /// The server's /info, live or from the cache.
    public var knownInfo: ServerInfo? { info ?? snapshot?.info }

    /// What the server offers. Until /info has answered once, only what the data itself shows, so no tab appears
    /// for a feature the server doesn't have.
    public var features: Set<ServerInfo.Feature> {
        if let f = knownInfo?.features { return f }
        var f: Set<ServerInfo.Feature> = [.status, .hosts, .cards]
        if snapshot?.state.pending.isEmpty == false { f.insert(.actions) }
        return f
    }
}

/// The app's state and everything that changes it. No UI code, so it is tested on Linux; the app injects the
/// Keychain and the widget reload.
@MainActor @Observable
public final class AppModel {
    public private(set) var servers = ServerList()
    public private(set) var status: [UUID: ServerStatus] = [:]
    public var settings = AppSettings() { didSet { if settings != oldValue { saveSettings() } } }
    /// The shown tab. The user's picks go through `pick(_:)`, which also ends a waiting request; `validateTab` and
    /// `open(_:)` set it directly.
    public var tab: AppTab = .today
    /// A tab a launch argument or link asked for before the server's features were known (right after a reset, the
    /// Chat and Actions tabs only appear once /info has answered). `validateTab` switches to it once it is there, and
    /// drops it once the info is known without it.
    public private(set) var requestedTab: AppTab?
    /// An action form to open (deep link `homelab://actions/<name>`, launch argument `-HomelabAction`). The Actions
    /// tab opens it once the server's list is there, and clears it.
    public var openAction: String?
    /// The Scan screen was asked for (`homelab://scan`, the Home-screen quick action). The Actions tab opens it once
    /// the server is known to take documents, and clears it.
    public private(set) var openScan = false
    /// The search screen was asked for (`homelab://search?q=dune`). The Actions tab opens it once the server is known
    /// to have the `search` feature, and clears it.
    public private(set) var openSearch: SearchRequest?
    /// Items waiting in the outbox (shared or scanned while the server couldn't be reached).
    public private(set) var outboxCount = 0
    /// Scans and links the outbox gave up on (server removed, 7 days, refused): shown until cleared.
    public private(set) var outboxDropped: [Outbox.Dropped] = []
    /// The action form sheets that are open (the Actions tab's, a card's "Add"), one token per sheet. A requested
    /// form waits until none is: a second sheet can't show over the first, and the request would be lost.
    public private(set) var openForms: Set<UUID> = []
    public var formSheetOpen: Bool { !openForms.isEmpty }
    /// A host's detail to open in Lab (deep link `homelab://lab/<host-id>`, launch argument `-HomelabHost`). Lab opens
    /// it once the state has that host (`takeOpenHost`), and clears it.
    public var openHost: String? { didSet { openHostSince = openHost == nil ? nil : Date() } }
    /// When `openHost` was asked for: a snapshot fetched after it that lacks the host drops the request.
    @ObservationIgnored private var openHostSince: Date?
    /// Containers restarted from Lab, per server and `<host>:<name>`, until the host's next check (`restartWaiting`).
    public private(set) var restarted: [UUID: [String: Date]] = [:]
    /// Proposals whose button press is on its way (by proposal id). The Actions tab and the chat share it, so the same
    /// proposal can't be pressed a second time from the other place meanwhile.
    public private(set) var proposalsSending: Set<String> = []
    public var locked = false

    public let storage: Storage
    public let tokens: any TokenStore
    public let transport: any HTTPTransport
    /// Called whenever the data the widget shows changed (WidgetCenter in the app).
    @ObservationIgnored public var onWidgetDataChange: @MainActor () -> Void = {}

    @ObservationIgnored private var demo: DemoBackend?
    /// The picture loader per server (memory and disk cache), made when a card first shows a picture.
    @ObservationIgnored private var loaders: [UUID: ImageLoader] = [:]
    /// The running refresh per server, so callers can wait for fresh data instead of starting a second fetch.
    @ObservationIgnored private var running: [UUID: Task<Void, Never>] = [:]
    /// A refresh was asked for while one was running (e.g. right after pressing a button): run once more after it.
    @ObservationIgnored private var refreshAgain: Set<UUID> = []
    /// The running fetch has sent its /state request: data a new caller needs may be newer than its answer.
    @ObservationIgnored private var stateRequested: Set<UUID> = []

    public init(storage: Storage, tokens: any TokenStore, transport: any HTTPTransport = URLSessionTransport(),
                arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.storage = storage
        self.tokens = tokens
        self.transport = transport
        let args = LaunchArguments(arguments)
        if args.reset { Self.wipe(storage: storage, tokens: tokens) }
        servers = storage.read(ServerList.self, ServerList.fileName) ?? ServerList()
        settings = storage.read(AppSettings.self, AppSettings.fileName) ?? AppSettings()
        for s in servers.servers where s.speaksCompanionAPI {
            status[s.id] = ServerStatus(snapshot: storage.read(Snapshot.self, Snapshot.fileName(s.id)))
        }
        apply(args)
        locked = settings.faceIDLock
        outboxCount = Outbox(directory: storage.url("outbox")).count
        outboxDropped = Outbox(directory: storage.url("outbox")).dropped()
    }

    // MARK: Servers

    public var selected: ServerConfig? { servers.selectedServer }
    public var homeAssistant: ServerConfig? { servers.homeAssistant }
    public var selectedStatus: ServerStatus { selected.flatMap { status[$0.id] } ?? ServerStatus() }
    public var hasServers: Bool { !servers.servers.isEmpty }
    public var isDemo: Bool { servers.servers.contains { $0.kind == .demo } }
    public var pendingCount: Int { selectedStatus.snapshot?.state.pending.count ?? 0 }

    /// The tabs RootView shows right now. Deep links and launch arguments can only pick one of these.
    public var availableTabs: Set<AppTab> {
        var t: Set<AppTab> = [.today, .settings]
        if selected != nil {
            let f = selectedStatus.features
            t.insert(.lab)
            if f.contains(.actions) || f.contains(.runActions) || f.contains(.documents) || f.contains(.search) { t.insert(.actions) }
            if f.contains(.chat) { t.insert(.chat) }
        }
        return t
    }

    /// Falls back to Today when the shown tab went away (feature list changed, server removed), and switches to a
    /// waiting requested tab once it is available.
    public func validateTab() {
        let wanted = requestedTab
        if !availableTabs.contains(tab) { tab = .today }
        requestedTab = wanted   // the fallback isn't the user's choice: the request still waits
        guard let wanted else { return }
        if availableTabs.contains(wanted) {
            tab = wanted
            requestedTab = nil
        } else if selected == nil || selectedStatus.knownInfo != nil {
            requestedTab = nil   // no server, or its features are known and don't include the tab
        }
    }

    /// The Actions tab asks whether to open Scan now. True once, when the tab shows, no form is open and the server
    /// takes documents. Without that feature (known) the request is dropped.
    public func takeOpenScan() -> Bool {
        guard openScan else { return false }
        if selectedStatus.features.contains(.documents) {
            guard tab == .actions, !formSheetOpen else { return false }
            openScan = false
            return true
        }
        if selectedStatus.knownInfo != nil || selected == nil { openScan = false }
        return false
    }

    /// The Actions tab asks whether to open the search screen now: once, when the tab shows, no form is open and the
    /// server has `search`. Without that feature (known) the request is dropped.
    public func takeOpenSearch() -> SearchRequest? {
        guard let request = openSearch else { return nil }
        if selectedStatus.features.contains(.search) {
            guard tab == .actions, !formSheetOpen else { return nil }
            openSearch = nil
            return request
        }
        if selectedStatus.knownInfo != nil || selected == nil { openSearch = nil }
        return nil
    }

    /// Where unsent shares and scans wait (App Group, so the share extension fills it too).
    public var outbox: Outbox { Outbox(directory: storage.url("outbox")) }

    /// Sends what waits in the outbox. Called when the app comes to the foreground and after a scan was saved.
    public func drainOutbox() async {
        let box = outbox
        if box.count > 0 {
            await box.drain(servers: servers) { [self] server in self.companionForDrain(server) }
        }
        outboxCount = box.count
        outboxDropped = box.dropped()
    }

    /// Refreshes `outboxCount` (a scan was queued).
    public func outboxChanged() {
        outboxCount = outbox.count
        outboxDropped = outbox.dropped()
    }

    /// The owner has seen what wasn't sent.
    public func clearOutboxDropped() {
        outbox.clearDropped()
        outboxDropped = []
    }

    nonisolated func companionForDrain(_ server: ServerConfig) -> any CompanionAPI {
        server.kind == .demo ? DemoBackend(delay: .zero) : CompanionClient(config: server, tokens: tokens, transport: transport)
    }

    /// The user picked a tab by hand (the tab bar). A link or launch argument's request (its tab, action form and
    /// host) is one request: picking another tab ends all of it, so nothing opens later on its own.
    public func pick(_ t: AppTab) {
        if t != tab { dropRequests() }
        tab = t
    }

    /// Forgets a waiting request: tab, action form and host.
    func dropRequests() {
        requestedTab = nil
        openAction = nil
        openHost = nil
        openScan = false
        openSearch = nil
    }

    /// The app locks (Face ID, in the background): the system closes every sheet, so no form counts as open.
    public func lock() {
        locked = true
        openForms = []
    }

    /// Shows `t` now if it is there, else once the server's info shows it (or never, see `validateTab`).
    func request(_ t: AppTab) {
        requestedTab = nil   // the newest request counts
        if availableTabs.contains(t) {
            tab = t
        } else {
            requestedTab = t
            validateTab()
        }
    }

    /// Shows another server. The overview's poll loop restarts for it and fetches; no extra fetch here.
    public func select(_ id: UUID) {
        guard servers.servers.contains(where: { $0.id == id && $0.speaksCompanionAPI }) else { return }
        servers.selected = id
        saveServers()
        writeWidgetSnapshot()
        validateTab()
    }

    /// `token: nil` keeps the stored token, but only while the server stays the same target (kind + origin).
    /// A new address or type drops it, so a token is never sent to a server it wasn't made for.
    public func save(_ server: ServerConfig, token: String?) throws {
        let old = servers.servers.first { $0.id == server.id }
        let sameTarget = old.map { $0.isSameTarget(as: server) } ?? false
        if server.auth == .token || server.kind == .homeAssistant {
            if let token {
                try tokens.setToken(token, for: server.id)
            } else if !sameTarget {
                try tokens.setToken(nil, for: server.id)
            }
        } else {
            try tokens.setToken(nil, for: server.id)
        }
        servers.upsert(server)
        if old == nil || !sameTarget || old?.auth != server.auth {
            // Different server now: its old data, features and services don't apply.
            storage.remove(Snapshot.fileName(server.id))
            status[server.id] = server.speaksCompanionAPI ? ServerStatus() : nil
            restarted[server.id] = nil
        }
        loaders[server.id] = nil   // a new address or token: the loader asks with the old ones
        saveServers()
        if server.id == selected?.id { writeWidgetSnapshot() }
        validateTab()
    }

    public func remove(_ id: UUID) {
        try? tokens.setToken(nil, for: id)
        storage.remove(Snapshot.fileName(id))
        servers.remove(id)
        status[id] = nil
        restarted[id] = nil
        loaders[id] = nil
        refreshAgain.remove(id)
        saveServers()
        writeWidgetSnapshot()
        validateTab()
    }

    public func setPinned(_ entities: [String], for id: UUID) {
        guard var s = servers.servers.first(where: { $0.id == id }) else { return }
        s.pinnedEntities = entities
        servers.upsert(s)
        saveServers()
    }

    /// Demo on: two demo servers. Off: they go away (the user's own servers stay).
    public func setDemo(_ on: Bool) {
        if on, !isDemo {
            let d = ServerConfig.demo()
            servers.upsert(d)
            servers.upsert(.demoHomeAssistant())
            if servers.selected == nil || !servers.servers.contains(where: { $0.id == servers.selected && $0.speaksCompanionAPI }) {
                servers.selected = d.id
            }
            status[d.id] = ServerStatus()
            demo = nil
        } else if !on {
            for s in servers.servers where s.kind == .demo { remove(s.id) }
            demo = nil
        }
        saveServers()
        validateTab()
    }

    /// Everything gone: servers, tokens, caches, settings.
    public func resetAll() {
        Self.wipe(storage: storage, tokens: tokens)
        servers = ServerList()
        status = [:]
        settings = AppSettings()
        demo = nil
        refreshAgain = []
        tab = .today
        dropRequests()
        restarted = [:]
        openForms = []
        proposalsSending = []
        onWidgetDataChange()
    }

    static func wipe(storage: Storage, tokens: any TokenStore) {
        if let list = storage.read(ServerList.self, ServerList.fileName) {
            for s in list.servers { try? tokens.setToken(nil, for: s.id) }
        }
        tokens.removeAll()
        storage.removeAll()
    }

    // MARK: Backends

    func demoBackend() -> DemoBackend {
        if let demo { return demo }
        let d = DemoBackend()
        demo = d
        return d
    }

    public func companion(for server: ServerConfig) -> any CompanionAPI {
        server.kind == .demo ? demoBackend() : CompanionClient(config: server, tokens: tokens, transport: transport)
    }

    /// Loads this server's pictures (`Card.Item.image`): through its API client, so with its login and only its own
    /// host, cached in memory and in `images` next to the other app files (30 days, 20 MB).
    public func imageLoader(for server: ServerConfig) -> ImageLoader {
        if let l = loaders[server.id] { return l }
        let l = ImageLoader(api: companion(for: server), scope: server.id.uuidString, directory: storage.url("images"))
        loaders[server.id] = l
        return l
    }

    /// `GET /search?q=` on the selected server (feature `search`).
    public func search(_ q: String, on server: ServerConfig) async -> Result<SearchResult, APIError> {
        do {
            return .success(try await companion(for: server).search(q: q))
        } catch {
            return .failure(APIError.from(error, host: server.host))
        }
    }

    public func homeAssistantAPI(for server: ServerConfig) -> any HomeAssistantAPI {
        server.kind == .demo ? demoBackend() : HomeAssistantClient(config: server, tokens: tokens, transport: transport)
    }

    // MARK: Refresh

    /// Fetches the selected server's state. Errors keep the last snapshot.
    public func refresh() async {
        guard let server = selected else { return }
        await refresh(server)
    }

    /// Fetches one server. If a fetch is already running, this one is queued behind it and the call returns only
    /// when the data is current (so a button press sees its own result).
    public func refresh(_ server: ServerConfig) async {
        let id = server.id
        if let task = running[id] {
            // Only queue a second fetch if the running one already asked for /state; before that, its answer
            // will be new enough, and several taps at once cost one fetch.
            if stateRequested.contains(id) { refreshAgain.insert(id) }
            await task.value
            return
        }
        // The task clears its own entry in the same main-actor step as the loop's last check, so a caller can
        // never attach to a fetch that has already finished (and then get no fetch at all).
        let task = Task {
            await self.refreshLoop(id)
            self.running[id] = nil
        }
        running[id] = task
        await task.value
    }

    private func refreshLoop(_ id: UUID) async {
        repeat {
            // Always the current config: an edit while waiting must not fetch the old address.
            guard let server = servers.servers.first(where: { $0.id == id }), server.speaksCompanionAPI else {
                refreshAgain.remove(id)
                return
            }
            await fetch(server)
        } while refreshAgain.remove(id) != nil
    }

    private func fetch(_ server: ServerConfig) async {
        var s = status[server.id] ?? ServerStatus()
        s.loading = true
        status[server.id] = s
        let api = companion(for: server)
        var snapshot: Snapshot?
        do {
            // /info once, then every 10 minutes: a server can gain a feature (chat) without an app restart.
            if s.info == nil || s.infoFetched.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
                do {
                    s.info = try await api.info()
                    s.infoFetched = Date()
                } catch APIError.unsupportedVersion(let v) {
                    throw APIError.unsupportedVersion(v)
                } catch {
                    // A failed /info (timeout, 500) keeps the cached one: tabs must not vanish for a hiccup.
                }
            }
            let info = s.knownInfo
            stateRequested.insert(server.id)
            defer { stateRequested.remove(server.id) }
            let state = try await api.state()
            snapshot = Snapshot(serverID: server.id, serverName: info?.name ?? server.name, state: state, info: info)
            s.snapshot = snapshot
            s.error = nil
            s.failures = 0
            // Services rarely change: once, then every 10 minutes, and only from servers that offer them.
            if s.features.contains(.services), s.servicesFetched.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
                if let list = try? await api.services() {
                    s.services = list
                    s.servicesFetched = Date()
                }
            }
            if s.features.contains(.runActions), s.actionsFetched.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
                if let list = try? await api.actions() {
                    s.actions = list
                    s.actionsFetched = Date()
                }
            } else if !s.features.contains(.runActions) {
                s.actions = []
            }
        } catch {
            let e = APIError.from(error, host: server.host)
            if e != .cancelled {
                s.error = e
                s.failures += 1
                AppLog.notice("refresh failed: \(e.message)")
            }
        }
        s.loading = false
        // The server may have been removed or edited while we waited: then this answer belongs to nobody.
        // (A queued refresh stays queued: refreshLoop runs it with the current config.)
        guard servers.servers.contains(where: { $0.id == server.id && $0.isSameTarget(as: server) && $0.auth == server.auth }) else {
            if var current = status[server.id] {
                current.loading = false
                status[server.id] = current
                // Edited while we waited: fetch once more with the new config (refreshLoop reads it).
                refreshAgain.insert(server.id)
            }
            return
        }
        status[server.id] = s
        if let snapshot { try? storage.write(snapshot, Snapshot.fileName(server.id)) }
        if server.id == selected?.id { writeWidgetSnapshot() }
        validateTab()
    }

    /// Presses a proposal's signed button; returns the server's answer, after the list is fresh again. Nil when a
    /// press of that proposal is already on its way (`proposalsSending`): nothing is sent.
    public func press(_ button: String, proposal: String, on server: ServerConfig) async -> Result<String, APIError>? {
        guard proposalsSending.insert(proposal).inserted else { return nil }
        defer { proposalsSending.remove(proposal) }
        return await press(button, on: server)
    }

    /// Press a signed action button; returns the server's answer. Returns after the list is fresh again.
    public func press(_ button: String, on server: ServerConfig) async -> Result<String, APIError> {
        let result: Result<String, APIError>
        do {
            result = .success(try await companion(for: server).press(button))
        } catch {
            result = .failure(APIError.from(error, host: server.host))
        }
        await refresh(server)
        return result
    }

    /// Start an action from its form; returns the server's answer, after one refresh of the state. A server that
    /// applies the change at once shows it then; one that updates its lists later shows it with a later refresh.
    public func run(_ form: ActionForm, on server: ServerConfig) async -> Result<ActionResult, APIError> {
        guard let arg = form.arg, form.problems.isEmpty else {
            return .failure(.badRequest(form.problems.first ?? "The form isn't complete."))
        }
        let result: Result<ActionResult, APIError>
        do {
            result = .success(try await companion(for: server).run(form.spec.name, arg: arg, payload: form.payload))
        } catch {
            result = .failure(APIError.from(error, host: server.host))
        }
        await refresh(server)
        return result
    }

    /// The form a link asked for (`openAction`), once the Actions tab shows, the selected server lists it and no
    /// other form sheet is open (`formSheetOpen`); the request is cleared then. A request the server can't serve (its
    /// loaded list lacks the name, or it has no `run-actions`) is dropped too, so it doesn't pop up later after a
    /// server switch. Nil while the list isn't loaded yet, another tab shows or a sheet is open: the request waits.
    public func takeOpenAction() -> ActionSpec? {
        guard let name = openAction, tab == .actions, !formSheetOpen else { return nil }
        let s = selectedStatus
        // Only actions offered as Start tiles: a card-only one (tick off, parcel delivered) needs its card's prefill
        // (the to-do's uid, the parcel id); a link can't give that, so it is dropped below like an unknown name.
        if s.features.contains(.runActions), let spec = s.actions.first(where: { $0.name == name && $0.start }) {
            openAction = nil
            return spec
        }
        if s.actionsFetched != nil || (s.knownInfo != nil && !s.features.contains(.runActions)) { openAction = nil }
        return nil
    }

    /// The form sheet with `token` (one per sheet, stable while it lives) appeared or went away (`formSheetOpen`).
    /// Idempotent: appearing twice or going away twice counts once.
    public func formSheet(_ token: UUID, open: Bool) {
        if open { openForms.insert(token) } else { openForms.remove(token) }
    }

    /// The host a link asked for (`openHost`), once Lab shows and the selected snapshot has it; the request is cleared
    /// then. A snapshot fetched after the request without that host drops it, so it doesn't pop up later (another
    /// server, a host that is gone). Nil while there is no such snapshot yet or another tab shows: the request waits.
    public func takeOpenHost() -> Host? {
        guard let id = openHost, tab == .lab, let snap = selectedStatus.snapshot else { return nil }
        if let host = snap.state.hosts.first(where: { $0.id == id }) {
            openHost = nil
            return host
        }
        if let since = openHostSince, snap.fetched >= since { openHost = nil }
        return nil
    }

    /// How long a restart waits for the host's next check at most (the watchdog runs every 5–9 min).
    public nonisolated static let restartWait: TimeInterval = 10 * 60

    /// Notes a container restarted from Lab on `server` (nil: the selected one) at `date`, the time the request was
    /// sent: its row says so until the host is checked again.
    public func noteRestart(host: String, container: String, at date: Date, on server: UUID? = nil) {
        guard let id = server ?? selected?.id, status[id] != nil else { return }
        restarted[id, default: [:]] = restarted[id, default: [:]].filter { date.timeIntervalSince($0.value) < Self.restartWait }
        restarted[id, default: [:]]["\(host):\(container)"] = date
    }

    /// Restarts `container` on `host` with its ready form (`ServerStatus.restartForm`). The time is taken before the
    /// request: a check that ran while it was on its way (the demo checks at once) already shows the new state. A
    /// restart that ran, or may have, is noted (`restartWaiting`).
    public func restart(_ form: ActionForm, host: String, container: String, on server: ServerConfig) async -> Result<ActionResult, APIError> {
        let sent = Date()
        let r = await run(form, on: server)
        switch r {
        case .success(let res) where res.ok: noteRestart(host: host, container: container, at: sent, on: server.id)
        case .failure(let e) where e.mayHaveRun: noteRestart(host: host, container: container, at: sent, on: server.id)
        default: break
        }
        return r
    }

    /// When `container` on `host` was restarted from here, while the data still predates it: the host wasn't checked
    /// since (and it's under `restartWait` ago). Nil once a newer check shows the container's real state.
    public func restartWaiting(host: Host, container: ContainerInfo, now: Date = Date()) -> Date? {
        guard let id = selected?.id, let t = restarted[id]?["\(host.id):\(container.name)"] else { return nil }
        return Self.waitsForCheck(restarted: t, checked: host.checked, now: now) ? t : nil
    }

    /// A restart at `restarted` still waits for the host's next check at `now`.
    public nonisolated static func waitsForCheck(restarted: Date, checked: Date?, now: Date) -> Bool {
        if now.timeIntervalSince(restarted) >= restartWait { return false }
        if let checked, checked > restarted { return false }
        return true
    }

    /// The action a card or item offers, if the selected server lets the app start it (feature `run-actions` and
    /// listed in `GET /actions`). Nil = hide the button.
    public func startable(_ action: ItemAction?) -> ActionSpec? {
        guard let action else { return nil }
        return selectedStatus.actions.first { $0.name == action.name }
    }

    /// Runs a card item's action at once (after the view's confirm): its form prefilled with the action's `arg` and
    /// `payload`, sent like `run(_ form:on:)`. `.notFound` when the server doesn't list the action.
    public func run(_ action: ItemAction, on server: ServerConfig) async -> Result<ActionResult, APIError> {
        guard let spec = status[server.id]?.actions.first(where: { $0.name == action.name }) else {
            return .failure(.notFound)
        }
        return await run(ActionForm(spec, prefill: action), on: server)
    }

    /// The widget reads the selected server's snapshot from shared storage.
    func writeWidgetSnapshot() {
        if var snap = selectedStatus.snapshot {
            // The widget shows neither the 24 h history nor the container lists: keep its copy small.
            snap.state.hosts = snap.state.hosts.map { var h = $0; h.history = nil; h.containerList = []; return h }
            try? storage.write(snap, Snapshot.widgetFileName)
        } else {
            storage.remove(Snapshot.widgetFileName)
        }
        onWidgetDataChange()
    }

    // MARK: Persistence

    func saveServers() {
        do {
            try storage.write(servers, ServerList.fileName)
        } catch {
            AppLog.notice("save servers: \(error.localizedDescription)")
        }
    }

    func saveSettings() {
        try? storage.write(settings, AppSettings.fileName)
        onWidgetDataChange()   // the widget hides details while the app lock is on
    }

    /// Re-read settings written by the background task.
    public func reloadSettings() {
        if let s = storage.read(AppSettings.self, AppSettings.fileName) { settings = s }
    }

    // MARK: Launch arguments (tests, screenshots, the owner's first run)

    func apply(_ args: LaunchArguments) {
        if args.demo {
            setDemo(true)
            // -HomelabDemo means "show the demo", also when another server was selected before (CI screenshots run
            // after live-mode shots that leave the fixture server selected).
            if let d = servers.servers.first(where: { $0.kind == .demo && $0.speaksCompanionAPI }) { select(d.id) }
        }
        if let url = args.server {
            for old in servers.servers where old.baseURL == url && old.kind == .companion { remove(old.id) }
            let s = ServerConfig(name: url.host ?? "Server", kind: .companion, baseURL: url, auth: .identity)
            servers.upsert(s)
            servers.selected = s.id
            status[s.id] = ServerStatus()
            saveServers()
        }
        if let tab = args.tab { request(tab) }
        if let a = args.action {
            openAction = a
            request(.actions)
        }
        if let h = args.host {
            openHost = h
            request(.lab)
        }
        if let d = args.density { settings.todayDensity = d }
        if let p = args.personality { settings.voice = p }
    }

    public func open(_ url: URL) {
        // homelab://scan: the Actions tab with the Scan screen on top (it waits for the server's features).
        if url.scheme == "homelab", url.host?.lowercased() == "scan" {
            dropRequests()
            request(.actions)
            openScan = true
            return
        }
        // homelab://search?q=dune: the search screen on the Actions tab, the text already in the field.
        if url.scheme == "homelab", url.host?.lowercased() == "search" {
            dropRequests()
            request(.actions)
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
            openSearch = SearchRequest(query: SearchQuery.prefill(q ?? ""))
            return
        }
        guard let t = AppTab(url: url) else { return }
        dropRequests()   // a new link replaces a request that still waits (its tab, form and host)
        if !availableTabs.contains(t) { tab = .today }
        request(t)
        // homelab://actions/<name>: that action's form (it waits like the tab).
        let path = url.pathComponents.filter { $0 != "/" }
        if t == .actions, tab == .actions || requestedTab == .actions, url.host == "actions", path.count == 1,
           ActionSpec.isValidName(path[0]) { openAction = path[0] }
        // homelab://lab/<host-id>: that host's details (they wait like the tab).
        if t == .lab, tab == .lab || requestedTab == .lab, url.host == "lab", path.count == 1,
           LaunchArguments.isHostID(path[0]) { openHost = path[0] }
    }
}

/// `-HomelabDemo YES -HomelabServer http://127.0.0.1:8791 -HomelabTab chat -HomelabResetState YES -HomelabDensity overkill
/// -HomelabPersonality snarky -HomelabAction wake-set -HomelabHost media`
struct LaunchArguments {
    var demo = false
    var reset = false
    var server: URL?
    var tab: AppTab?
    var density: Density?
    var personality: Personality?
    var action: String?
    var host: String?

    /// A host id as servers send them: letters, digits, `.`, `_`, `-`, at most 64.
    static func isHostID(_ s: String) -> Bool {
        s.wholeMatch(of: /[A-Za-z0-9._-]{1,64}/) != nil
    }

    init(_ args: [String]) {
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: "-" + key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func yes(_ key: String) -> Bool { ["yes", "true", "1"].contains(value(key)?.lowercased() ?? "") }
        demo = yes("HomelabDemo")
        reset = yes("HomelabResetState")
        if let s = value("HomelabServer"), case .success(let url) = URLPolicy.serverURL(s) { server = url }
        tab = value("HomelabTab").flatMap { AppTab(name: $0) }
        density = value("HomelabDensity").flatMap { Density(rawValue: $0.lowercased()) }
        personality = value("HomelabPersonality").flatMap { Personality(rawValue: $0.lowercased()) }
        action = value("HomelabAction").flatMap { ActionSpec.isValidName($0) ? $0 : nil }
        host = value("HomelabHost").flatMap { Self.isHostID($0) ? $0 : nil }
    }
}
