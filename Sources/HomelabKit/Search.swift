import Foundation

// Search (feature `search`) and pictures (`Card.Item.image`): the query rules, the answer, picture type checks, the
// two-level picture cache, and generated grey posters for demo mode and tests. Foundation only (runs on Linux).

/// What the search field sends: 2 to 100 characters, control characters out, runs of spaces made one.
public enum SearchQuery {
    public static let minLength = 2
    public static let maxLength = 100
    public static let rule = "Type 2 to 100 characters."

    /// The text to send, or nil while it is too short or too long.
    public static func clean(_ text: String) -> String? {
        let out = normalize(text)
        return (minLength...maxLength).contains(out.count) ? out : nil
    }

    /// What a link puts into the search field: normalised and cut to the longest allowed query.
    public static func prefill(_ text: String) -> String {
        normalize(String(normalize(text).prefix(maxLength)))   // the cut may leave a space at the end
    }

    /// Typing searches by itself (400 ms after the last key); text a link put into the field (`held`) waits for the
    /// user's submit until it is edited, so opening a link never sends a request on its own.
    public static func runsOnItsOwn(_ text: String, held: String?) -> Bool {
        guard let held, !held.isEmpty else { return true }
        return normalize(text) != held
    }

    /// Control characters and runs of white space become one space; the ends are trimmed.
    static func normalize(_ text: String) -> String {
        var out = ""
        var space = false
        for scalar in text.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                space = !out.isEmpty
            } else {
                if space { out.append(" "); space = false }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

/// A search asked for by a link: the text for the field (maybe empty).
public struct SearchRequest: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public let query: String
    /// True for text from a link: it fills the field and waits for the user's submit.
    public let held: Bool
    public init(query: String, held: Bool = false) { self.query = query; self.held = held }
}

/// The answer to `GET /search?q=`: the query as the server understood it and the cards that answer it (a
/// `poster-grid` card of movies and shows, later maybe others). An empty list means nothing was found.
public struct SearchResult: Codable, Sendable, Equatable {
    public var query: String
    public var cards: [Card]

    public init(query: String = "", cards: [Card] = []) {
        self.query = query; self.cards = cards
    }

    enum CodingKeys: String, CodingKey { case query, cards }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var ids = Set<String>()
        self.init(query: c.text(.query) ?? "", cards: c.array(Card.self, .cards).filter { ids.insert($0.id).inserted })
    }

    /// Cards that have something to show (a card without items and text is nothing found).
    public var shown: [Card] {
        cards.filter { !$0.items.isEmpty || ($0.text?.isEmpty == false) }
    }
}

/// The picture types the app loads. Decided by the first bytes, not by what the server says.
public enum ImageKind: Sendable, Equatable {
    case jpeg, png, webp

    public init?(sniffing data: Data) {
        let b = [UInt8](data.prefix(12))
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF {
            self = .jpeg
        } else if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47,
                  b[4] == 0x0D, b[5] == 0x0A, b[6] == 0x1A, b[7] == 0x0A {
            self = .png
        } else if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
                  b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 {
            self = .webp
        } else {
            return nil
        }
    }
}

/// Pictures of one server: memory first, then a small disk cache, then the server (through the API client, so with
/// its login and only ever its own host). One request per picture at a time; a failure is not asked again for a
/// minute. Never stores anything the client refused, or a picture past `ImagePixels`' size limits.
public actor ImageLoader {
    public static let memoryLimit = 24 * 1024 * 1024
    public static let diskLimit = 20 * 1024 * 1024
    public static let maxAge: TimeInterval = 30 * 24 * 3600
    public static let retryAfter: TimeInterval = 60

    private let api: any CompanionAPI
    private let scope: String
    private let directory: URL?
    private var memory: [String: Data] = [:]
    private var order: [String] = []
    private var memoryBytes = 0
    private var inflight: [String: Task<Data?, Never>] = [:]
    private var failedAt: [String: Date] = [:]
    private var writes = 0
    private var requests = 0

    /// `scope` keeps servers apart (the server's id); `directory` nil = memory only.
    public init(api: any CompanionAPI, scope: String, directory: URL?) {
        self.api = api; self.scope = scope; self.directory = directory
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    /// How many times the server was asked (tests).
    public var requestCount: Int { requests }

    /// The picture's bytes, or nil (not a picture of this server, not found, too big, offline).
    public func data(for reference: String, now: Date = Date()) async -> Data? {
        guard let ref = URLPolicy.cleanImageReference(reference) else { return nil }
        let key = scope + "|" + ref
        if let hit = memory[key] {
            touch(key)
            return hit
        }
        if let disk = readDisk(key, now: now) {
            remember(key, disk)
            return disk
        }
        if let t = failedAt[key], now.timeIntervalSince(t) < Self.retryAfter { return nil }
        let task: Task<Data?, Never>
        if let running = inflight[key] {
            task = running
        } else {
            requests += 1
            // The declared pixel size is checked before anything is kept: a small file can decode to gigabytes.
            task = Task { [api] in (try? await api.image(path: ref)).flatMap { ImagePixels.isAcceptable($0) ? $0 : nil } }
            inflight[key] = task
        }
        let result = await task.value
        inflight[key] = nil
        guard let result else {
            failedAt[key] = now
            return nil
        }
        failedAt[key] = nil
        remember(key, result)
        writeDisk(key, result, now: now)
        return result
    }

    // MARK: Memory

    private func remember(_ key: String, _ data: Data) {
        if let old = memory[key] { memoryBytes -= old.count; order.removeAll { $0 == key } }
        memory[key] = data
        order.append(key)
        memoryBytes += data.count
        while memoryBytes > Self.memoryLimit, let oldest = order.first {
            order.removeFirst()
            if let gone = memory.removeValue(forKey: oldest) { memoryBytes -= gone.count }
        }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    // MARK: Disk

    /// A stable file name: FNV-1a over the key (no path characters from the server ever reach the file system).
    static func fileName(_ key: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return String(h, radix: 16) + ".img"
    }

    private func file(_ key: String) -> URL? { directory?.appendingPathComponent(Self.fileName(key)) }

    private func readDisk(_ key: String, now: Date) -> Data? {
        guard let url = file(key),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date, now.timeIntervalSince(modified) < Self.maxAge,
              let data = try? Data(contentsOf: url), data.count <= CompanionClient.maxImageBytes,
              ImagePixels.isAcceptable(data) else { return nil }
        return data
    }

    private func writeDisk(_ key: String, _ data: Data, now: Date) {
        guard let url = file(key), let directory else { return }
        try? data.write(to: url, options: .atomic)
        writes += 1
        if writes % 20 == 1 { Self.prune(directory, now: now) }
    }

    /// Removes pictures older than `maxAge`, then the oldest ones until the folder is under `diskLimit`.
    static func prune(_ directory: URL, now: Date, limit: Int = diskLimit) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        var entries: [(url: URL, size: Int, date: Date)] = []
        for url in files where url.pathExtension == "img" {
            let v = try? url.resourceValues(forKeys: Set(keys))
            let date = v?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) >= maxAge {
                try? FileManager.default.removeItem(at: url)
            } else {
                entries.append((url, v?.fileSize ?? 0, date))
            }
        }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > limit {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

/// Grey 2:3 posters made on the spot (demo mode, the reference server's idea, tests): a PNG without any image
/// library, so the same bytes come out on Linux and on the phone.
public enum PlaceholderPoster {
    public static let width = 80
    public static let height = 120

    /// A grey poster; the same `seed` gives the same picture.
    public static func png(seed: String) -> Data {
        var hash: UInt32 = 2166136261
        for b in seed.utf8 { hash = (hash ^ UInt32(b)) &* 16777619 }
        let tone = 28 + Int(hash % 24)            // 28...51: dark, like the surface
        let period = 6 + Int((hash >> 8) % 6)     // stripe width
        let slope = 1 + Int((hash >> 16) % 3)
        var raw = [UInt8]()
        raw.reserveCapacity((width + 1) * height)
        for y in 0..<height {
            raw.append(0)   // filter: none
            for x in 0..<width {
                var v = tone + y * 26 / height
                if ((x + y * slope) / period) % 2 == 0 { v += 7 }
                if y > height * 3 / 4 && y < height * 3 / 4 + 3 { v += 40 }   // a title line near the bottom
                raw.append(UInt8(min(v, 255)))
            }
        }
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = [UInt8]()
        ihdr += be32(UInt32(width)); ihdr += be32(UInt32(height))
        ihdr += [8, 0, 0, 0, 0]   // 8 bit, grayscale, deflate, filter 0, no interlace
        png += chunk("IHDR", ihdr)
        png += chunk("IDAT", zlibStored(raw))
        png += chunk("IEND", [])
        return png
    }

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    private static func chunk(_ type: String, _ body: [UInt8]) -> Data {
        let head = Array(type.utf8)
        return Data(be32(UInt32(body.count)) + head + body + be32(crc32(head + body)))
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    /// zlib with stored (uncompressed) blocks: valid, simple, and the picture is tiny anyway.
    static func zlibStored(_ raw: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var i = 0
        repeat {
            let n = min(65535, raw.count - i)
            let final: UInt8 = i + n >= raw.count ? 1 : 0
            out += [final, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            out += raw[i..<i + n]
            i += n
        } while i < raw.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in raw { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        return out + be32(b << 16 | a)
    }
}
