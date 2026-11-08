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
    /// A local notification for a new "act now" deal (feature `deals`); nil = off (the server already pushes those).
    /// Stored as an optional so settings files from before deals still decode.
    public var dealNotifications: Bool?
    public var faceIDLock = false
    public var lastBackgroundRun: Date?
    public var lastBackgroundResult: String?
    /// Today's section order and hidden sections; nil = the standard layout (also for settings from older versions).
    public var today: TodayLayout?
    /// Calm, Standard, Overkill or Hyperdetail; nil = Standard.
    public var density: Density?
    /// Off, Dry, Snarky or Ultrakill; nil = Off.
    public var personality: Personality?
    /// The "Leave by" Live Activity on school mornings; nil = on.
    public var leaveActivity: Bool?
    /// Settings → Advanced → Where you are: the Home Assistant `person.*` or `device_tracker.*` entity the "At home" and
    /// "Away" rules read (`HomePresence.swift`); nil = off.
    public var presenceEntity: String?
    /// Settings → Advanced → Quiet hours: no local notifications in this window (`QuietHours.swift`); nil = off.
    public var quietHours: TimeWindow?
    /// True once the owner confirmed the one-time Ultrakill warning (`UltrakillWarning`); nil (omitted from the file)
    /// until then, so settings without it stay byte for byte as before.
    public var ultrakillWarned: Bool?
    /// The same for Hyperdetail (`HyperdetailWarning`): nil (omitted from the file) until the owner said "Do it" once.
    public var hyperdetailWarned: Bool?
    /// Settings → Advanced (`Customization.swift`): order and hidden Start tiles (by action name), Lab blocks (by card
    /// id), tabs; chat text size and folding. All nil = the standard, and omitted from the file then.
    public var startTiles: ItemOrder?
    public var labBlocks: ItemOrder?
    public var tabs: ItemOrder?
    public var chatText: ChatTextSize?
    public var chatFold: ChatFoldMode?

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

    /// The Settings toggle "New deals to act on" (default off).
    public var notifyDeals: Bool {
        get { dealNotifications ?? false }
        set { dealNotifications = newValue ? true : nil }
    }

    public var voice: Personality {
        get { personality ?? .off }
        set { personality = newValue == .off ? nil : newValue }
    }

    /// Choosing `level` needs the one-time warning first: Ultrakill, until the owner has confirmed it once.
    public func needsWarning(for level: Personality) -> Bool { level == .ultrakill && ultrakillWarned != true }

    /// The warning's "Enable": remembers that it was seen and switches to Ultrakill.
    public mutating func confirmUltrakill() {
        ultrakillWarned = true
        voice = .ultrakill
    }

    /// Choosing `level` needs the one-time warning first: Hyperdetail, until the owner has confirmed it once.
    public func needsWarning(for level: Density) -> Bool { level == .hyperdetail && hyperdetailWarned != true }

    /// The warning's "Do it": remembers that it was seen and switches to Hyperdetail.
    public mutating func confirmHyperdetail() {
        hyperdetailWarned = true
        todayDensity = .hyperdetail
    }

    public var todayLayout: TodayLayout {
        get { today ?? .standard }
        set { today = newValue == .standard ? nil : newValue }
    }

    public var notificationsOn: Bool { notifyProblems || notifyPending || notifyDeals }

    /// Every stored field; the encoder is the synthesized one, so a saved file stays byte for byte as before.
    enum CodingKeys: String, CodingKey {
        case notifyProblems, notifyPending, dealNotifications, faceIDLock, lastBackgroundRun, lastBackgroundResult
        case today, density, personality, leaveActivity, presenceEntity, quietHours, ultrakillWarned, hyperdetailWarned
        case startTiles, labBlocks, tabs, chatText, chatFold
    }
}

extension AppSettings {
    /// Field by field: one value this version can't read (a newer version's quiet hours, a hand edit) falls back to
    /// its default alone, instead of failing the whole file and losing Face ID lock, notifications and the layout.
    /// Readable values come out exactly as the synthesized decoder read them.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        notifyProblems = c.lenient(Bool.self, .notifyProblems) ?? false
        notifyPending = c.lenient(Bool.self, .notifyPending) ?? false
        dealNotifications = c.lenient(Bool.self, .dealNotifications)
        faceIDLock = c.lenient(Bool.self, .faceIDLock) ?? false
        lastBackgroundRun = c.lenient(Date.self, .lastBackgroundRun)
        lastBackgroundResult = c.lenient(String.self, .lastBackgroundResult)
        today = c.lenient(TodayLayout.self, .today)
        density = c.lenient(Density.self, .density)
        personality = c.lenient(Personality.self, .personality)
        leaveActivity = c.lenient(Bool.self, .leaveActivity)
        presenceEntity = c.lenient(String.self, .presenceEntity)
        quietHours = c.lenient(TimeWindow.self, .quietHours)
        ultrakillWarned = c.lenient(Bool.self, .ultrakillWarned)
        hyperdetailWarned = c.lenient(Bool.self, .hyperdetailWarned)
        startTiles = c.lenient(ItemOrder.self, .startTiles).flatMap { $0.isStandard ? nil : $0 }
        labBlocks = c.lenient(ItemOrder.self, .labBlocks).flatMap { $0.isStandard ? nil : $0 }
        tabs = c.lenient(ItemOrder.self, .tabs).flatMap { $0.isStandard ? nil : $0 }
        chatText = c.lenient(ChatTextSize.self, .chatText)
        chatFold = c.lenient(ChatFoldMode.self, .chatFold)
    }
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
    /// The server's deals (`GET /deals`), nil when it has none (404, or never asked). Not cached on disk.
    public var deals: DealList?
    /// When `/deals` was last asked, whatever the answer: the next ask waits (`DealsFetch`).
    public var dealsFetched: Date?
    public var infoFetched: Date?

    public init(snapshot: Snapshot? = nil) {
        self.snapshot = snapshot
    }

    /// A host's level, the one way everywhere (tile, detail, widget): with the server's problems if a state is known.
    public func health(of host: Host) -> HostHealth { snapshot?.state.health(of: host) ?? HostHealth(host) }

    /// The server answers `/deals` with a list: the Deals screen, its Start tile and Today's card exist.
    public var hasDeals: Bool { deals != nil }

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
    /// A server whose editor Settings should open (an error banner's "Edit server"); Settings clears it.
    public var editServerRequest: UUID?

    /// Opens Settings with this server's editor: the way out of a setup error (wrong token, address, certificate).
    public func requestEdit(_ id: UUID) {
        dropRequests()   // a waiting link (homelab://chat, deals) must not pull the user away from the fix
        editServerRequest = id
        tab = .settings
    }
    /// A tab a launch argument or link asked for before the server's features were known (right after a reset, the
    /// Chat and Actions tabs only appear once /info has answered). `validateTab` switches to it once it is there, and
    /// drops it once the info is known without it.
    public private(set) var requestedTab: AppTab?
    /// An action form to open (deep link `homelab://actions/<name>`, launch argument `-HomelabAction`). The Actions
    /// tab opens it once the server's list is there, and clears it.
    public var openAction: String?
    /// The values a link gave for `openAction` (`homelab://actions/<name>?arg=…&<field>=…`); used only while its name
    /// is the requested one.
    public private(set) var openActionLink: ActionLink?
    /// The Scan screen was asked for (`homelab://scan`, the Home-screen quick action). The Actions tab opens it once
    /// the server is known to take documents, and clears it.
    public private(set) var openScan = false
    /// The search screen was asked for (`homelab://search?q=dune`). The Actions tab opens it once the server is known
    /// to have the `search` feature, and clears it.
    public private(set) var openSearch: SearchRequest?
    /// The Deals screen was asked for (`homelab://deals`, the ntfy push, the Today card). The Actions tab opens it once
    /// the server is known to answer `/deals`, and clears it.
    public private(set) var openDeals = false
    /// Launch argument only: the Deals screen opens the first deal's detail (screenshots).
    public var openDealDetail = false
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
    /// Actions (by name) whose run is on its way: a second tap waits for the first, so nothing starts twice.
    public private(set) var actionsRunning: Set<String> = []
    public var locked = false
    /// The first run while it lasts (`FirstRun`): it only starts with no server saved. In memory only.
    public internal(set) var firstRun: FirstRun?
    /// After a first run, Today ends with a line pointing to Settings → Today, until the app quits. In memory only.
    public internal(set) var showsStartTip = false
    /// Today sections the user tapped "Show" for on the "Hidden now" line: they pass their rules until the app
    /// closes (`showAnyway`, ShowRuleEditing.swift). Never stored.
    public internal(set) var shownAnyway: Set<TodaySection> = []
    /// `-HomelabTime 14:00`: the clock time Today's show rules check (screenshots of a rule); nil = the real time.
    @ObservationIgnored public private(set) var fixedTime: Int?

    public let storage: Storage
    public let tokens: any TokenStore
    public let transport: any HTTPTransport
    /// Called whenever the data the widget shows changed (WidgetCenter in the app).
    @ObservationIgnored public var onWidgetDataChange: @MainActor () -> Void = {}
    /// Called when the Home-screen quick actions may have changed: an action was started, or a server's Start list
    /// changed (`ActionUsage`).
    @ObservationIgnored public var onQuickActionsChange: @MainActor () -> Void = {}

    @ObservationIgnored private var demo: DemoBackend?
    /// What the demo homelab shows (`-HomelabDemoScene problem` or `ha-only` for screenshots); calm by default.
    @ObservationIgnored var demoScene: DemoBackend.Scene = .calm
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
        // No server list at all (first launch, or the app was deleted and installed again): Keychain items outlive
        // the app, so tokens of servers nobody can see any more would still be there. Wipe them. A list that exists
        // but can't be read (before the first unlock) is not "missing".
        if !FileManager.default.fileExists(atPath: storage.url(ServerList.fileName).path) { tokens.removeAll() }
        servers = storage.read(ServerList.self, ServerList.fileName) ?? ServerList()
        Self.removeSharedImages(in: storage.url("images"))
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
            // .deals counts too, not only a loaded list: a deals push on a cold launch opens Actions before /deals answered.
            if f.contains(.actions) || f.contains(.runActions) || f.contains(.documents) || f.contains(.search)
                || f.contains(.deals) || selectedStatus.hasDeals { t.insert(.actions) }
            if f.contains(.chat) { t.insert(.chat) }
        }
        return t
    }

    /// The tabs the bar shows, in the owner's order: the available ones without the hidden ones (Settings is never
    /// hidden). The first is where the app opens.
    public var shownTabs: [AppTab] { TabBar.shown(available: availableTabs, settings.tabs) }

    /// A tab a link or a tap asked for that the owner hid (Settings → Advanced → Tabs): the app stays where it is and
    /// RootView says so once. Cleared by `dismissHiddenTabNotice`.
    public private(set) var hiddenTabNotice: AppTab?
    public func dismissHiddenTabNotice() { hiddenTabNotice = nil }

    /// Shows `t` if the bar has it; a hidden but available tab says it is hidden instead.
    @discardableResult
    public func go(_ t: AppTab) -> Bool {
        if shownTabs.contains(t) { tab = t; return true }
        if availableTabs.contains(t) { hiddenTabNotice = t }
        return false
    }

    /// Falls back to the first shown tab (Today unless hidden) when the shown tab went away (feature list changed,
    /// server removed, tab hidden), and switches to a waiting requested tab once it is available.
    public func validateTab() {
        let wanted = requestedTab
        if !shownTabs.contains(tab) { tab = shownTabs.first ?? .settings }
        requestedTab = wanted   // the fallback isn't the user's choice: the request still waits
        guard let wanted else { return }
        if availableTabs.contains(wanted) {
            go(wanted)
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

    /// Asks for the Deals screen (the link, Today's card): the Actions tab opens it once the server is known to have
    /// deals (`takeOpenDeals`).
    public func showDeals() {
        dropRequests()
        request(.actions)
        openDeals = true
    }

    /// The Actions tab asks whether to open the Deals screen now: once, when the tab shows, no form is open and the
    /// server has deals. When the server was asked and has none (or is unknown), the request is dropped.
    public func takeOpenDeals() -> Bool {
        guard openDeals else { return false }
        if selectedStatus.hasDeals {
            guard tab == .actions, !formSheetOpen else { return false }
            openDeals = false
            return true
        }
        if selectedStatus.dealsFetched != nil || selected == nil { openDeals = false }
        return false
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
        openActionLink = nil
        openHost = nil
        openScan = false
        openSearch = nil
        openDeals = false
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
            go(t)
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

    /// Takes the Home tiles from another Home Assistant server.
    public func selectHome(_ id: UUID) {
        guard servers.servers.contains(where: { $0.id == id && $0.showsHomeTab }) else { return }
        servers.home = id
        saveServers()
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
            removeImages(server.id)   // the old server's pictures aren't this one's
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
        removeImages(id)
        refreshAgain.remove(id)
        saveServers()
        writeWidgetSnapshot()
        validateTab()
    }

    /// Sets the pinned entities. Names and icons of entities that are no longer pinned are dropped; `names` and
    /// `icons`, when given, replace the custom tile names (cleaned: see `TileName`) and icons (see `TileIcon`).
    public func setPinned(_ entities: [String], names: [String: String]? = nil, icons: [String: String]? = nil, for id: UUID) {
        guard var s = servers.servers.first(where: { $0.id == id }) else { return }
        s.pinnedEntities = entities
        s.tileNames = TileName.cleaned(names ?? s.tileNames, pinned: entities)
        s.tileIcons = TileIcon.cleaned(icons ?? s.tileIcons, pinned: entities)
        servers.upsert(s)
        saveServers()
    }

    /// Demo on: two demo servers. Off: they go away (the user's own servers stay). The `ha-only` scene has only the
    /// demo Home Assistant: Today as someone without a Companion server sees it.
    public func setDemo(_ on: Bool) {
        if on, !demoScene.hasHomelab {
            for s in servers.servers where s.kind == .demo && s.speaksCompanionAPI { remove(s.id) }
            if !servers.servers.contains(where: \.isDemoHomeAssistant) { servers.upsert(.demoHomeAssistant()) }
            demo = nil
        } else if on, !isDemo {
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
        loaders = [:]
        refreshAgain = []
        tab = .today
        dropRequests()
        restarted = [:]
        openForms = []
        proposalsSending = []
        firstRun = nil
        showsStartTip = false
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
        let d = DemoBackend(scene: demoScene)
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
        let l = ImageLoader(api: companion(for: server), scope: server.id.uuidString, directory: imageDirectory(server.id))
        loaders[server.id] = l
        return l
    }

    /// One folder per server (`images/<id>`), so removing a server or changing its address removes its pictures.
    func imageDirectory(_ id: UUID) -> URL {
        storage.url("images").appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Pictures of the first version with posters lay in `images` itself, for all servers together: removed (they come
    /// back into the server's own folder when shown again).
    static func removeSharedImages(in directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "img" { try? FileManager.default.removeItem(at: f) }
    }

    /// Forgets a server's pictures: the loader (memory) and its folder (disk).
    func removeImages(_ id: UUID) {
        loaders[id] = nil
        try? FileManager.default.removeItem(at: imageDirectory(id))
    }

    /// `GET /search?q=` on the selected server (feature `search`).
    public func search(_ q: String, on server: ServerConfig) async -> Result<SearchResult, APIError> {
        do {
            return .success(try await companion(for: server).search(q: q))
        } catch {
            return .failure(APIError.from(error, host: server.host))
        }
    }

    /// The time `/deals` timing goes by (tests move it).
    var clock: @Sendable () -> Date = { Date() }

    /// Asks `/deals` when it is time (`DealsFetch`) and keeps the answer. A 404 means "no deals here": the list goes
    /// and the feature hides without a word. Any other failure (offline, 5xx, a page that isn't JSON) keeps the
    /// last list, and the next ask waits.
    func fetchDeals(_ api: any CompanionAPI, into s: inout ServerStatus, force: Bool = false) async {
        guard force || DealsFetch.shouldFetch(listed: s.features.contains(.deals), available: s.hasDeals,
                                              fetched: s.dealsFetched, now: clock()) else { return }
        // Stamped with the time it was asked, not answered: a slow poll that asked before a pull to refresh is older.
        let asked = clock()
        do {
            s.deals = try await api.deals()
        } catch APIError.notFound {
            s.deals = nil
        } catch {
            AppLog.notice("deals failed: \(APIError.from(error, host: "server").message)")
        }
        s.dealsFetched = asked
    }

    /// The Deals screen's pull to refresh: asks now, whatever the timer says. Nil on success, else why not.
    @discardableResult
    public func reloadDeals(on server: ServerConfig) async -> APIError? {
        var s = status[server.id] ?? ServerStatus()
        let asked = clock()
        do {
            s.deals = try await companion(for: server).deals()
            s.dealsFetched = asked
            store(dealStatus: s, for: server)
            return nil
        } catch APIError.notFound {
            s.deals = nil
            s.dealsFetched = asked
            store(dealStatus: s, for: server)
            return nil
        } catch {
            return APIError.from(error, host: server.host)
        }
    }

    /// Writes back only the deals of `s`: the status may have changed while the request was on its way.
    private func store(dealStatus s: ServerStatus, for server: ServerConfig) {
        guard var current = status[server.id] else { return }
        current.deals = s.deals
        current.dealsFetched = s.dealsFetched
        status[server.id] = current
        validateTab()
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
            await fetchDeals(api, into: &s)
            if s.features.contains(.runActions), s.actionsFetched.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
                if let list = try? await api.actions() {
                    s.actions = list
                    s.actionsFetched = Date()
                    noteOffered(list, server: server.id)
                }
            } else if !s.features.contains(.runActions) {
                if s.knownInfo != nil { noteOffered([], server: server.id) }
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
        // A pull to refresh on the Deals screen may have stored a newer list while this poll waited: keep that one.
        if let current = status[server.id], let newer = current.dealsFetched, newer > (s.dealsFetched ?? .distantPast) {
            s.deals = current.deals
            s.dealsFetched = newer
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
        guard actionsRunning.insert(form.spec.name).inserted else {
            return .failure(.badRequest("\(form.spec.label) is already running."))
        }
        defer { actionsRunning.remove(form.spec.name) }
        noteStarted(form.spec.name, server: server.id)
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
        takeOpenActionForm()?.spec
    }

    /// Like `takeOpenAction`, with the link's prefill for the form (nil: a plain link or launch argument). Hidden
    /// fields and choice values that aren't options never come from a link (`ActionLink.prefill`).
    public func takeOpenActionForm() -> (spec: ActionSpec, prefill: ItemAction?)? {
        guard let name = openAction, tab == .actions, !formSheetOpen else { return nil }
        let s = selectedStatus
        // Only actions offered as Start tiles: a card-only one (tick off, parcel delivered) needs its card's prefill
        // (the to-do's uid, the parcel id); a link can't give that, so it is dropped below like an unknown name.
        if s.features.contains(.runActions), let spec = s.actions.first(where: { $0.name == name && $0.start }) {
            let link = openActionLink?.name == name ? openActionLink : nil
            openAction = nil
            openActionLink = nil
            return (spec, link?.prefill(for: spec))
        }
        if s.actionsFetched != nil || (s.knownInfo != nil && !s.features.contains(.runActions)) {
            openAction = nil
            openActionLink = nil
        }
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

    /// Runs a card item's action at once (after the view's confirm): exactly its `arg` and its `payload`
    /// (`ActionForm.prefilled(_:action:)`), sent like `run(_ form:on:)`. `.notFound` when the server doesn't list the
    /// action; refused, with nothing sent, when the arg no longer fits the server's action (never its default).
    public func run(_ action: ItemAction, on server: ServerConfig) async -> Result<ActionResult, APIError> {
        guard let spec = status[server.id]?.actions.first(where: { $0.name == action.name }) else {
            return .failure(.notFound)
        }
        guard let form = ActionForm.prefilled(spec, action: action) else {
            return .failure(.badRequest(ActionForm.itemActionMismatch))
        }
        return await run(form, on: server)
    }

    // MARK: Quick actions (ActionUsage)

    /// The owner started `name` on `server`: one more use for the quick actions' ranking.
    func noteStarted(_ name: String, server: UUID) {
        var usage = storage.read(ActionUsage.self, ActionUsage.fileName) ?? ActionUsage()
        usage.record(name, server: server)
        try? storage.write(usage, ActionUsage.fileName)
        onQuickActionsChange()
    }

    /// `server`'s Start list as the quick actions offer it; written only when it changed.
    func noteOffered(_ specs: [ActionSpec], server: UUID) {
        var usage = storage.read(ActionUsage.self, ActionUsage.fileName) ?? ActionUsage()
        let before = usage
        usage.setOffered(specs, server: server)
        usage.keep(servers: servers.servers.map(\.id))
        guard usage != before else { return }
        try? storage.write(usage, ActionUsage.fileName)
        onQuickActionsChange()
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
        // The background task writes the last run into the same file. Never overwrite a newer one with this copy's.
        if let disk = storage.read(AppSettings.self, AppSettings.fileName), let ran = disk.lastBackgroundRun,
           ran > (settings.lastBackgroundRun ?? .distantPast) {
            settings.lastBackgroundRun = ran      // settings didSet runs once more, finds nothing newer and saves
            settings.lastBackgroundResult = disk.lastBackgroundResult
            return
        }
        try? storage.write(settings, AppSettings.fileName)
        onWidgetDataChange()   // the widget hides details while the app lock is on
    }

    /// Re-read settings written by the background task.
    public func reloadSettings() {
        if let s = storage.read(AppSettings.self, AppSettings.fileName) { settings = s }
    }

    // MARK: Launch arguments (tests, screenshots, the owner's first run)

    func apply(_ args: LaunchArguments) {
        if args.demoOff { setDemo(false) }
        if let pins = args.pins, let ha = homeAssistant { setPinned(pins, for: ha.id) }
        if let names = args.tileNames, let ha = homeAssistant {
            // Names only count for pinned tiles: set them after -HomelabPins (this launch's or an earlier one).
            var merged = homeAssistant?.tileNames ?? ha.tileNames
            for (id, name) in names { merged[id] = name }
            setPinned(homeAssistant?.pinnedEntities ?? ha.pinnedEntities, names: merged, for: ha.id)
        }
        if let icons = args.tileIcons, let ha = homeAssistant {
            // Like names: after -HomelabPins, so read the server again (this launch may have just changed the pins).
            var merged = homeAssistant?.tileIcons ?? ha.tileIcons
            for (id, symbol) in icons { merged[id] = symbol }
            setPinned(homeAssistant?.pinnedEntities ?? ha.pinnedEntities, icons: merged, for: ha.id)
        }
        if let scene = args.demoScene {
            demoScene = scene
            demo = nil
        }
        if args.demo {
            setDemo(true)
            // -HomelabDemo means "show the demo", also when another server was selected before (CI screenshots run
            // after live-mode shots that leave the fixture server selected).
            if let d = servers.servers.first(where: { $0.kind == .demo && $0.speaksCompanionAPI }) { select(d.id) }
        }
        if let url = args.server {
            for old in servers.servers where old.baseURL == url && old.kind == .companion { remove(old.id) }
            let s = ServerConfig(name: ServerConfig.defaultName(for: url), kind: .companion, baseURL: url, auth: .identity)
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
        if let d = args.deals {
            showDeals()
            openDealDetail = d == "detail"
        }
        if let h = args.host {
            openHost = h
            request(.lab)
        }
        if let d = args.density { settings.todayDensity = d }
        // Stored like the setting: `-HomelabRules deals=always` removes the Deals rule again.
        for (section, rule) in args.rules ?? [] { settings.todayLayout.setRule(rule, for: section) }
        if let t = args.time { fixedTime = t }
        if let p = args.personality { settings.voice = p }
        // Found and "Start with" over the demo (screenshots). Only when every server is a demo one: never over real ones.
        if args.firstRun, hasServers, firstRun == nil, servers.servers.allSatisfy({ $0.kind == .demo }) {
            firstRun = FirstRun(found: servers.servers.map(\.id))
        }
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
            openSearch = SearchRequest(query: SearchQuery.prefill(q ?? ""), held: true)
            return
        }
        // homelab://deals: the Deals screen on the Actions tab (the ntfy push for an "act now" deal opens it).
        if url.scheme == "homelab", url.host?.lowercased() == "deals" {
            showDeals()
            return
        }
        guard let t = AppTab(url: url) else { return }
        dropRequests()   // a new link replaces a request that still waits (its tab, form and host)
        if !shownTabs.contains(t) { tab = shownTabs.first ?? .settings }
        request(t)
        // homelab://actions/<name>: that action's form (it waits like the tab).
        let path = url.pathComponents.filter { $0 != "/" }
        // homelab://actions/<name>?arg=…&<field>=…: that form, filled in (ActionLink).
        if t == .actions, tab == .actions || requestedTab == .actions, url.host == "actions", path.count == 1,
           ActionSpec.isValidName(path[0]) {
            openAction = path[0]
            openActionLink = ActionLink(url)
        }
        // homelab://lab/<host-id>: that host's details (they wait like the tab).
        if t == .lab, tab == .lab || requestedTab == .lab, url.host == "lab", path.count == 1,
           LaunchArguments.isHostID(path[0]) { openHost = path[0] }
    }
}

/// `-HomelabDemo YES -HomelabServer http://127.0.0.1:8791 -HomelabTab chat -HomelabResetState YES -HomelabDensity overkill
/// -HomelabPersonality snarky -HomelabAction wake-set -HomelabHost media -HomelabDemoScene problem`
struct LaunchArguments {
    var demo = false
    /// `-HomelabDemo NO`: the demo servers go away (phone-shots ends with it, so the owner's daily setup stays clean).
    var demoOff = false
    /// `-HomelabPins light.a,scene.b`: the Home tiles of the Home tiles server (set up from the laptop over USB).
    var pins: [String]?
    /// `-HomelabTileNames "light.a=Living room,script.b=Alarm off"`: custom names for pinned Home tiles (ids as in
    /// `-HomelabPins`, names cleaned by `TileName`; anything odd drops the whole argument).
    var tileNames: [String: String]?
    /// `-HomelabTileIcons "light.a=lamp.floor,script.b=moon.stars"`: icons for pinned Home tiles, symbols from
    /// `TileIcon.choices` only (anything odd drops the whole argument).
    var tileIcons: [String: String]?
    /// The demo's scene for this launch (`DemoBackend.Scene`): screenshots of the problem state, or of Home Assistant
    /// only (`ha-only`).
    var demoScene: DemoBackend.Scene?
    var reset = false
    var server: URL?
    var tab: AppTab?
    var density: Density?
    var personality: Personality?
    var action: String?
    var host: String?
    /// `-HomelabDeals list|detail`: the Deals screen, with the first deal's detail for `detail` (screenshots).
    var deals: String?
    /// `-HomelabFirstRun YES` with `-HomelabDemo YES`: the first run's Found step over the demo servers (screenshots).
    var firstRun = false
    /// `-HomelabRules "deals=evenings,cards=18:00-22:00"`: show rules for Today's sections (`ShowRuleArgument`).
    var rules: [(TodaySection, ShowRule?)]?
    /// `-HomelabTime 14:00`: the clock time the show rules check, in minutes after midnight.
    var time: Int?

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
        demoOff = ["no", "false", "0"].contains(value("HomelabDemo")?.lowercased() ?? "")
        pins = value("HomelabPins").map { $0.split(separator: ",").map(String.init).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } }.flatMap { ids in
            ids.count <= 12 && ids.allSatisfy({ $0.wholeMatch(of: /[a-z_]{1,32}\.[a-z0-9_]{1,96}/) != nil }) ? ids : nil
        }
        tileNames = value("HomelabTileNames").flatMap(TileName.parse)
        tileIcons = value("HomelabTileIcons").flatMap(TileIcon.parse)
        demoScene = value("HomelabDemoScene").flatMap { DemoBackend.Scene(rawValue: $0.lowercased()) }
        reset = yes("HomelabResetState")
        if let s = value("HomelabServer"), case .success(let url) = URLPolicy.serverURL(s) { server = url }
        tab = value("HomelabTab").flatMap { AppTab(name: $0) }
        density = value("HomelabDensity").flatMap { Density(rawValue: $0.lowercased()) }
        personality = value("HomelabPersonality").flatMap { Personality(rawValue: $0.lowercased()) }
        action = value("HomelabAction").flatMap { ActionSpec.isValidName($0) ? $0 : nil }
        deals = value("HomelabDeals").flatMap { ["list", "detail"].contains($0) ? $0 : nil }
        host = value("HomelabHost").flatMap { Self.isHostID($0) ? $0 : nil }
        firstRun = yes("HomelabFirstRun")
        rules = value("HomelabRules").flatMap(ShowRuleArgument.parse)
        time = value("HomelabTime").flatMap(ShowRuleArgument.minutes)
    }
}
