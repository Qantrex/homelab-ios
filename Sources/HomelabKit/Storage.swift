import Foundation

/// The app's files. In the App Group container when there is one (so the widget can read them), else in the app's
/// own Application Support. Only non-secret data: tokens are in the Keychain.
public struct Storage: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The shared location for app + widget.
    public static func shared(group: String? = AppGroup.current) -> Storage {
        if let group, let url = AppGroup.containerURL(group) {
            let storage = Storage(directory: url.appendingPathComponent("Homelab", isDirectory: true))
            storage.adoptFiles(from: localDirectory)
            return storage
        }
        return Storage(directory: localDirectory)
    }

    /// Where the files go without an App Group: this bundle's own Application Support. The widget can't see it.
    static var localDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Homelab", isDirectory: true)
    }

    /// An install without an App Group (xtool up to 1.24.0 drops it for a free Apple ID, docs/SETUP.md) kept the server
    /// list, settings and cache in the app's own folder. The first time a group is there, they are copied into it, so
    /// the next install doesn't start from zero. Only into a group that has no server list yet, and never over a file
    /// that is there. Copies, not moves: an install that loses the group again still finds them. Returns the names.
    @discardableResult
    func adoptFiles(from old: URL) -> [String] {
        let fm = FileManager.default
        guard old.standardizedFileURL != directory.standardizedFileURL,
              !fm.fileExists(atPath: url(ServerList.fileName).path),
              fm.fileExists(atPath: old.appendingPathComponent(ServerList.fileName).path),
              let names = try? fm.contentsOfDirectory(atPath: old.path) else { return [] }
        // The server list last: it marks the copy as done, so one that was cut short is finished next time.
        let ordered = names.filter { $0 != ServerList.fileName }.sorted() + [ServerList.fileName]
        var copied: [String] = []
        for name in ordered where !fm.fileExists(atPath: url(name).path) {
            if (try? fm.copyItem(at: old.appendingPathComponent(name), to: url(name))) != nil { copied.append(name) }
        }
        if !copied.isEmpty { AppLog.notice("storage: copied \(copied.count) files into the App Group") }
        return copied
    }

    public func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    public func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? Self.decoder.decode(T.self, from: data)
    }

    public func write<T: Encodable>(_ value: T, _ name: String) throws {
        let data = try Self.encoder.encode(value)
        // Complete protection is too strict: background refresh and widgets read these files while locked.
        #if os(iOS)
        try data.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url(name), options: .atomic)
        #endif
    }

    public func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
    }

    public func removeAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for f in files { try? FileManager.default.removeItem(at: f) }
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// The list of servers and which one is shown. `servers.json`.
public struct ServerList: Codable, Sendable, Equatable {
    public var servers: [ServerConfig]
    public var selected: UUID?

    public init(servers: [ServerConfig] = [], selected: UUID? = nil) {
        self.servers = servers
        self.selected = selected
    }

    public static let fileName = "servers.json"

    /// The Companion-API server the Overview/Actions/Chat tabs show.
    public var selectedServer: ServerConfig? {
        let companion = servers.filter(\.speaksCompanionAPI)
        return companion.first { $0.id == selected } ?? companion.first
    }

    /// The Home Assistant server for the Home tab (the first one).
    public var homeAssistant: ServerConfig? {
        servers.first(where: \.showsHomeTab)
    }

    public mutating func upsert(_ server: ServerConfig) {
        if let i = servers.firstIndex(where: { $0.id == server.id }) {
            servers[i] = server
        } else {
            servers.append(server)
        }
        if selected == nil, server.speaksCompanionAPI { selected = server.id }
    }

    public mutating func remove(_ id: UUID) {
        servers.removeAll { $0.id == id }
        if selected == id { selected = servers.first(where: \.speaksCompanionAPI)?.id }
    }
}

/// The last good answer per server, with when it arrived. Shown while offline (with its age) and read by the widget.
public struct Snapshot: Codable, Sendable, Equatable {
    public var serverID: UUID
    public var serverName: String
    public var state: HomelabState
    public var info: ServerInfo?
    public var fetched: Date

    public init(serverID: UUID, serverName: String, state: HomelabState, info: ServerInfo? = nil, fetched: Date = Date()) {
        self.serverID = serverID; self.serverName = serverName; self.state = state; self.info = info
        self.fetched = fetched
    }

    public static func fileName(_ id: UUID) -> String { "snapshot-\(id.uuidString).json" }
    /// The widget reads this one: the selected server's snapshot.
    public static let widgetFileName = "widget-snapshot.json"

    public func age(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(fetched) }

    /// Older than this, the UI marks the data as stale.
    public static let staleAfter: TimeInterval = 10 * 60
    public func isStale(now: Date = Date()) -> Bool { age(now: now) > Self.staleAfter }

    /// Widgets refresh only when iOS runs the background task (often 15–60+ min), so they call data old later.
    public static let widgetStaleAfter: TimeInterval = 2 * 3600
    public func isStaleForWidget(now: Date = Date()) -> Bool { age(now: now) > Self.widgetStaleAfter }
}
