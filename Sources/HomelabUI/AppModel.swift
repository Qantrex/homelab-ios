import Foundation
import HomelabKit
import OSLog
import SwiftUI
import WidgetKit

let log = Logger(subsystem: "com.qantrex.homelab", category: "app")

public enum AppTab: String, CaseIterable, Hashable, Sendable {
    case overview, actions, chat, home, settings

    /// `homelab://actions` and the widget's links.
    public init?(url: URL) {
        guard url.scheme == "homelab" else { return nil }
        let name = url.host ?? url.pathComponents.dropFirst().first ?? ""
        self.init(rawValue: name.lowercased())
    }
}

/// App-wide settings (not secret). `settings.json` in shared storage, so the background task reads them too.
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

    public var features: Set<ServerInfo.Feature> { info?.features ?? snapshot?.info?.features ?? Set(ServerInfo.Feature.allCases) }
}

@MainActor @Observable
public final class AppModel {
    public private(set) var servers = ServerList()
    public private(set) var status: [UUID: ServerStatus] = [:]
    public var settings = AppSettings() { didSet { if settings != oldValue { saveSettings() } } }
    public var tab: AppTab = .overview
    public var locked = false

    public let storage: Storage
    public let tokens: any TokenStore
    let transport: any HTTPTransport
    private var demo: DemoBackend?

    public init(storage: Storage = .shared(), tokens: any TokenStore = KeychainTokenStore(),
                transport: any HTTPTransport = URLSessionTransport(),
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

    public func select(_ id: UUID) {
        servers.selected = id
        saveServers()
        Task { await refresh() }
    }

    public func save(_ server: ServerConfig, token: String?) throws {
        if server.auth == .token || server.kind == .homeAssistant {
            if let token { try tokens.setToken(token, for: server.id) }
        } else {
            try tokens.setToken(nil, for: server.id)
        }
        servers.upsert(server)
        if server.speaksCompanionAPI, status[server.id] == nil { status[server.id] = ServerStatus() }
        saveServers()
    }

    public func remove(_ id: UUID) {
        try? tokens.setToken(nil, for: id)
        storage.remove(Snapshot.fileName(id))
        servers.remove(id)
        status[id] = nil
        saveServers()
        writeWidgetSnapshot()
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
        Task { await refresh() }
    }

    /// Everything gone: servers, tokens, caches, settings.
    public func resetAll() {
        Self.wipe(storage: storage, tokens: tokens)
        servers = ServerList()
        status = [:]
        settings = AppSettings()
        demo = nil
        tab = .overview
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func wipe(storage: Storage, tokens: any TokenStore) {
        if let list = storage.read(ServerList.self, ServerList.fileName) {
            for s in list.servers { try? tokens.setToken(nil, for: s.id) }
        }
        (tokens as? KeychainTokenStore)?.removeAll()
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

    /// Fetches the selected server's state (and its info the first time). Errors keep the last snapshot.
    public func refresh() async {
        guard let server = selected else { return }
        await refresh(server)
    }

    public func refresh(_ server: ServerConfig) async {
        var s = status[server.id] ?? ServerStatus()
        guard !s.loading else { return }
        s.loading = true
        status[server.id] = s
        let api = companion(for: server)
        do {
            if s.info == nil { s.info = try? await api.info() }
            let state = try await api.state()
            let snap = Snapshot(serverID: server.id, serverName: s.info?.name ?? server.name, state: state, info: s.info)
            s.snapshot = snap
            s.error = nil
            s.failures = 0
            try? storage.write(snap, Snapshot.fileName(server.id))
            if s.features.contains(.services) || s.services.isEmpty {
                if let list = try? await api.services() { s.services = list }
            }
        } catch {
            let e = APIError.from(error, host: server.host)
            if e != .cancelled {
                s.error = e
                s.failures += 1
                log.notice("refresh failed: \(e.message, privacy: .public)")
            }
        }
        s.loading = false
        status[server.id] = s
        if server.id == selected?.id { writeWidgetSnapshot() }
    }

    /// Press a signed action button; returns the server's answer for the alert.
    public func press(_ button: String, on server: ServerConfig) async -> Result<String, APIError> {
        do {
            let text = try await companion(for: server).press(button)
            await refresh(server)
            return .success(text)
        } catch {
            await refresh(server)
            return .failure(APIError.from(error, host: server.host))
        }
    }

    /// The widget reads the selected server's snapshot from shared storage.
    func writeWidgetSnapshot() {
        if let snap = selectedStatus.snapshot {
            try? storage.write(snap, Snapshot.widgetFileName)
        } else {
            storage.remove(Snapshot.widgetFileName)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Persistence

    func saveServers() {
        do { try storage.write(servers, ServerList.fileName) } catch { log.error("save servers: \(error.localizedDescription, privacy: .public)") }
    }

    func saveSettings() {
        try? storage.write(settings, AppSettings.fileName)
    }

    /// Re-read settings written by the background task.
    public func reloadSettings() {
        if let s = storage.read(AppSettings.self, AppSettings.fileName) { settings = s }
    }

    // MARK: Launch arguments (tests, screenshots, the owner's first run)

    func apply(_ args: LaunchArguments) {
        if args.demo { setDemo(true) }
        if let url = args.server {
            let s = ServerConfig(name: url.host ?? "Server", kind: .companion, baseURL: url, auth: .identity)
            servers.servers.removeAll { $0.baseURL == url && $0.kind == .companion }
            servers.upsert(s)
            servers.selected = s.id
            status[s.id] = ServerStatus()
            saveServers()
        }
        if let tab = args.tab { self.tab = tab }
    }

    public func open(_ url: URL) {
        if let t = AppTab(url: url) { tab = t }
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
