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
    case overview, actions, chat, home, settings

    /// `homelab://actions` and the widget's links.
    public init?(url: URL) {
        guard url.scheme == "homelab" else { return nil }
        let name = url.host ?? url.pathComponents.dropFirst().first ?? ""
        self.init(rawValue: name.lowercased())
    }
}

/// App-wide settings (not secret). `settings.json` in shared storage, so the background task and the widget read them.
public struct AppSettings: Codable, Sendable, Equatable {
    public var notifyProblems = false
    public var notifyPending = false
    public var faceIDLock = false
    public var lastBackgroundRun: Date?
    public var lastBackgroundResult: String?

    public static let fileName = "settings.json"
    public init() {}

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

    public init(snapshot: Snapshot? = nil) {
        self.snapshot = snapshot
    }

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
    public var tab: AppTab = .overview
    public var locked = false

    public let storage: Storage
    public let tokens: any TokenStore
    public let transport: any HTTPTransport
    /// Called whenever the data the widget shows changed (WidgetCenter in the app).
    @ObservationIgnored public var onWidgetDataChange: @MainActor () -> Void = {}

    @ObservationIgnored private var demo: DemoBackend?
    /// The running refresh per server, so callers can wait for fresh data instead of starting a second fetch.
    @ObservationIgnored private var running: [UUID: Task<Void, Never>] = [:]
    /// A refresh was asked for while one was running (e.g. right after pressing a button): run once more after it.
    @ObservationIgnored private var refreshAgain: Set<UUID> = []

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
        var t: Set<AppTab> = [.overview, .settings]
        if selected != nil {
            let f = selectedStatus.features
            if f.contains(.actions) { t.insert(.actions) }
            if f.contains(.chat) { t.insert(.chat) }
        }
        if homeAssistant != nil { t.insert(.home) }
        return t
    }

    /// Falls back to the overview when the shown tab went away (feature list changed, HA server removed).
    public func validateTab() {
        if !availableTabs.contains(tab) { tab = .overview }
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
        }
        saveServers()
        if server.id == selected?.id { writeWidgetSnapshot() }
        validateTab()
    }

    public func remove(_ id: UUID) {
        try? tokens.setToken(nil, for: id)
        storage.remove(Snapshot.fileName(id))
        servers.remove(id)
        status[id] = nil
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
        tab = .overview
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
            refreshAgain.insert(id)
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
            if s.info == nil {
                do {
                    s.info = try await api.info()
                } catch APIError.unsupportedVersion(let v) {
                    throw APIError.unsupportedVersion(v)
                } catch {
                    // A failed /info (timeout, 500) keeps the cached one: tabs must not vanish for a hiccup.
                }
            }
            let info = s.knownInfo
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
            }
            return
        }
        status[server.id] = s
        if let snapshot { try? storage.write(snapshot, Snapshot.fileName(server.id)) }
        if server.id == selected?.id { writeWidgetSnapshot() }
        validateTab()
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

    /// The widget reads the selected server's snapshot from shared storage.
    func writeWidgetSnapshot() {
        if let snap = selectedStatus.snapshot {
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
        if args.demo { setDemo(true) }
        if let url = args.server {
            for old in servers.servers where old.baseURL == url && old.kind == .companion { remove(old.id) }
            let s = ServerConfig(name: url.host ?? "Server", kind: .companion, baseURL: url, auth: .identity)
            servers.upsert(s)
            servers.selected = s.id
            status[s.id] = ServerStatus()
            saveServers()
        }
        if let tab = args.tab, availableTabs.contains(tab) { self.tab = tab }
    }

    public func open(_ url: URL) {
        guard let t = AppTab(url: url) else { return }
        tab = availableTabs.contains(t) ? t : .overview
    }
}

/// `-HomelabDemo YES -HomelabServer http://127.0.0.1:8791 -HomelabTab chat -HomelabResetState YES`
struct LaunchArguments {
    var demo = false
    var reset = false
    var server: URL?
    var tab: AppTab?

    init(_ args: [String]) {
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: "-" + key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func yes(_ key: String) -> Bool { ["yes", "true", "1"].contains(value(key)?.lowercased() ?? "") }
        demo = yes("HomelabDemo")
        reset = yes("HomelabResetState")
        if let s = value("HomelabServer"), case .success(let url) = URLPolicy.serverURL(s) { server = url }
        tab = value("HomelabTab").flatMap { AppTab(rawValue: $0.lowercased()) }
    }
}
