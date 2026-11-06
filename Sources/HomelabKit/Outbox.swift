import Foundation

public enum OutboxError: Error, Equatable, Sendable {
    case full
    case tooLarge

    public var message: String {
        switch self {
        case .full: "The outbox is full (\(ShareLimits.outboxItems) items). Open Homelab to send them first."
        case .tooLarge: "The outbox is full (\(ShareLimits.outboxBytes / 1_048_576) MB). Open Homelab to send what waits first."
        }
    }
}

/// Items the share extension (or the Scan screen) couldn't send: Tailscale off, a token server (the extension holds
/// no tokens), a server that is down. They wait in the App Group as `outbox/<id>.json` (+ `<id>.pdf`) until the app
/// sends them: when it comes to the foreground and in the background refresh. At most 10 items and 100 MB.
public struct Outbox: Sendable {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public enum Kind: String, Codable, Sendable { case url, pdf }
        public var id: String
        public var kind: Kind
        public var server: UUID
        public var url: String?
        public var title: String?
        public var bytes: Int
        public var created: Date
        public var attempts: Int
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    static func isValidID(_ id: String) -> Bool { id.wholeMatch(of: /[0-9a-f-]{36}/) != nil }

    func meta(_ id: String) -> URL { directory.appendingPathComponent(id + ".json") }
    func file(_ id: String) -> URL { directory.appendingPathComponent(id + ".pdf") }

    /// Oldest first.
    public func entries() -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let decoder = Storage.decoder
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let e = try? decoder.decode(Entry.self, from: data), Self.isValidID(e.id),
                  e.id + ".json" == name else { return nil }
            return e
        }.sorted { ($0.created, $0.id) < ($1.created, $1.id) }
    }

    public var count: Int { entries().count }

    public func add(_ item: ShareItem, id: String, server: UUID, now: Date = Date()) throws {
        guard Self.isValidID(id) else { throw OutboxError.full }
        let all = entries()
        if all.contains(where: { $0.id == id }) { return }   // the same item again
        let bytes: Int
        var entry: Entry
        switch item {
        case .pdf(let data, let title):
            bytes = data.count
            entry = Entry(id: id, kind: .pdf, server: server, url: nil, title: title, bytes: bytes, created: now, attempts: 0)
        case .url(let url, let title):
            bytes = url.absoluteString.utf8.count
            entry = Entry(id: id, kind: .url, server: server, url: url.absoluteString, title: title, bytes: bytes,
                          created: now, attempts: 0)
        }
        guard all.count < ShareLimits.outboxItems else { throw OutboxError.full }
        guard all.reduce(bytes, { $0 + $1.bytes }) <= ShareLimits.outboxBytes else { throw OutboxError.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if case .pdf(let data, _) = item { try write(data, to: file(id)) }
        try write(try Storage.encoder.encode(entry), to: meta(id))
    }

    private func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    public func remove(_ id: String) {
        guard Self.isValidID(id) else { return }
        try? FileManager.default.removeItem(at: meta(id))
        try? FileManager.default.removeItem(at: file(id))
    }

    func bumpAttempts(_ entry: Entry) {
        var e = entry
        e.attempts += 1
        if let data = try? Storage.encoder.encode(e) { try? write(data, to: meta(e.id)) }
    }

    /// The item as `ShareSender` knows it; nil when its file is gone or unreadable.
    func item(for entry: Entry) -> ShareItem? {
        switch entry.kind {
        case .pdf:
            guard let data = try? Data(contentsOf: file(entry.id)), data.count == entry.bytes else { return nil }
            return .pdf(data, title: entry.title)
        case .url:
            guard let s = entry.url, let url = URL(string: s) else { return nil }
            return .url(url, title: entry.title)
        }
    }

    public struct Report: Sendable, Equatable {
        public var sent = 0
        public var dropped = 0
        public var waiting = 0
    }

    /// One drain at a time per outbox in this process (foreground and background refresh may both ask). A repeat is harmless
    /// anyway: the server answers a repeated id with the first result.
    private static let gate = DrainGate()

    /// Sends what waits, oldest first. An item leaves the outbox on a 2xx, on an answer that never changes (400, 413,
    /// 415, 422), when its server is gone, its file is gone, or it is older than seven days. Any other error keeps
    /// it, and stops that server's items for this run (it is probably not reachable).
    @discardableResult
    public func drain(servers: ServerList, now: Date = Date(),
                      api: @Sendable (ServerConfig) -> any CompanionAPI) async -> Report {
        var report = Report()
        let key = directory.path
        guard Self.gate.enter(key) else { return report }
        defer { Self.gate.leave(key) }
        var stopped = Set<UUID>()
        for entry in entries() {
            guard let server = servers.servers.first(where: { $0.id == entry.server && $0.speaksCompanionAPI }),
                  now.timeIntervalSince(entry.created) <= ShareLimits.outboxMaxAge,
                  let item = item(for: entry) else {
                remove(entry.id); report.dropped += 1; continue
            }
            if stopped.contains(server.id) { report.waiting += 1; continue }
            do {
                switch item {
                case .pdf(let data, let title): _ = try await api(server).upload(pdf: data, title: title, id: entry.id)
                case .url(let url, let title): _ = try await api(server).share(url: url, title: title, id: entry.id)
                }
                remove(entry.id); report.sent += 1
            } catch let e as APIError where e.isPermanentRejection {
                remove(entry.id); report.dropped += 1
            } catch {
                bumpAttempts(entry)
                stopped.insert(server.id)
                report.waiting += 1
            }
        }
        return report
    }
}

final class DrainGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = Set<String>()
    func enter(_ key: String) -> Bool { lock.withLock { busy.insert(key).inserted } }
    func leave(_ key: String) { lock.withLock { _ = busy.remove(key) } }
}
