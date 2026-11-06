import Foundation

// Sharing to the homelab (step 5): a link or a PDF goes to the server's `POST /documents` and `POST /share`. The
// Scan tab and the share extension use the same code. Foundation only, so it is tested on Linux.

/// The limits both sides know. The server checks them again.
public enum ShareLimits {
    public static let maxPDFBytes = 25 * 1024 * 1024
    public static let maxImages = 20
    public static let maxURLLength = 2048
    public static let maxPDFTitle = 128
    public static let maxShareTitle = 200
    public static let outboxItems = 10
    public static let outboxBytes = 100 * 1024 * 1024
    /// An outbox item the server never took is dropped after this long.
    public static let outboxMaxAge: TimeInterval = 7 * 24 * 3600
}

/// What the user shares: a web link or a PDF (a scan, a shared file, shared photos made into one PDF).
public enum ShareItem: Sendable, Equatable {
    case url(URL, title: String?)
    case pdf(Data, title: String?)

    public var title: String? {
        switch self {
        case .url(_, let t), .pdf(_, let t): t
        }
    }
}

/// Where the server will route an item (the server decides again; this is what the screen announces).
public enum ShareDestination: Sendable, Equatable {
    case willhaben(adID: String)
    case readLater
    case paperless

    public var label: String {
        switch self {
        case .willhaben: "Price check on willhaben"
        case .readLater: "Read later"
        case .paperless: "To Paperless"
        }
    }

    public var feature: ServerInfo.Feature {
        self == .paperless ? .documents : .share
    }
}

/// Why something can't be shared. `message` is shown as it is.
public enum ShareRefusal: Error, Equatable, Sendable {
    case nothing
    case noLink
    case notWeb(scheme: String)
    case credentials
    case tooLong
    case notPDF
    case tooLarge(bytes: Int)
    case tooManyImages

    public var message: String {
        switch self {
        case .nothing: "Homelab can share links, text with a link, PDFs and photos."
        case .noLink: "That text has no web link in it. Homelab only takes links, not plain text."
        case .notWeb(let scheme): "Homelab only takes web links (http or https), not \(scheme.isEmpty ? "this" : scheme + ":")."
        case .credentials: "That link contains a user name or password, so it is not sent."
        case .tooLong: "That link is too long (over \(ShareLimits.maxURLLength) characters)."
        case .notPDF: "That file is not a PDF."
        case .tooLarge(let bytes): "That is \(Self.mb(bytes)) MB, more than the \(ShareLimits.maxPDFBytes / 1_048_576) MB the server takes."
        case .tooManyImages: "Up to \(ShareLimits.maxImages) photos at once."
        }
    }

    /// For `CompanionClient`, which throws `APIError`s.
    var apiError: APIError { .badRequest(message) }

    static func mb(_ bytes: Int) -> String { String(format: "%.1f", Double(bytes) / 1_048_576) }
}

public enum ShareRouter {
    /// The first http(s) link in free text ("Look at https://www.willhaben.at/iad/x-123456789/ !"). Trailing
    /// punctuation is not part of the link.
    public static func firstURL(in text: String) -> URL? {
        for token in text.split(whereSeparator: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "\"" }) {
            let lower = token.lowercased()
            guard let r = lower.range(of: "https://") ?? lower.range(of: "http://") else { continue }
            let start = token.index(token.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.lowerBound))
            var s = String(token[start...])
            // Trailing punctuation isn't part of the link; a closing bracket only when it has no partner in the link
            // ("(see https://x.org/a)" loses it, "https://en.wikipedia.org/wiki/Foo_(bar)" keeps it).
            while let last = s.last {
                if ".,;:!?'’”".contains(last) { s.removeLast(); continue }
                if let open = ["(": ")", "[": "]", "{": "}"].first(where: { $0.value == String(last) })?.key,
                   s.filter({ String($0) == open }).count < s.filter({ $0 == last }).count {
                    s.removeLast(); continue
                }
                break
            }
            if let url = URL(string: s), url.host?.isEmpty == false { return url }
        }
        return nil
    }

    /// A link the server may get: http(s) only, a host, no user:password, at most 2048 characters.
    public static func check(_ url: URL) throws -> URL {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { throw ShareRefusal.notWeb(scheme: scheme) }
        guard url.host?.isEmpty == false else { throw ShareRefusal.noLink }
        guard url.user == nil, url.password == nil else { throw ShareRefusal.credentials }
        guard url.absoluteString.count <= ShareLimits.maxURLLength else { throw ShareRefusal.tooLong }
        return url
    }

    /// A shared link, or text with a link in it. Anything else is refused.
    public static func item(url: URL, title: String? = nil) throws -> ShareItem {
        .url(try check(url), title: cleanTitle(title, max: ShareLimits.maxShareTitle))
    }

    public static func item(text: String, title: String? = nil) throws -> ShareItem {
        // A text that already is a link (some apps share it as text) or has one inside.
        guard let url = firstURL(in: text) else {
            // "javascript:..." or "file:///..." get their own words; other text has no link.
            let first = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            if let m = first.wholeMatch(of: /([A-Za-z][A-Za-z0-9+.-]{0,15}):\S+/) {
                throw ShareRefusal.notWeb(scheme: String(m.1).lowercased())
            }
            throw ShareRefusal.noLink
        }
        return try item(url: url, title: title)
    }

    public static func item(pdf data: Data, title: String? = nil) throws -> ShareItem {
        guard data.starts(with: Data("%PDF-".utf8)) else { throw ShareRefusal.notPDF }
        guard data.count <= ShareLimits.maxPDFBytes else { throw ShareRefusal.tooLarge(bytes: data.count) }
        return .pdf(data, title: cleanTitle(title, max: ShareLimits.maxPDFTitle))
    }

    /// The willhaben ad id (digits) of `https://www.willhaben.at/iad/...-1234567890/` or `...?adId=1234567890`.
    public static func willhabenAdID(_ url: URL) -> String? {
        guard let host = url.host?.lowercased(), host == "willhaben.at" || host == "www.willhaben.at",
              url.path.hasPrefix("/iad/") else { return nil }
        if let m = url.path.wholeMatch(of: /.*-(\d{6,12})\/?/) { return String(m.1) }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let v = items.first(where: { $0.name == "adId" })?.value, v.wholeMatch(of: /\d{6,12}/) != nil { return v }
        return nil
    }

    public static func destination(for item: ShareItem) -> ShareDestination {
        switch item {
        case .pdf: .paperless
        case .url(let url, _): willhabenAdID(url).map { .willhaben(adID: $0) } ?? .readLater
        }
    }

    /// Control characters out, whitespace trimmed, cut to `max` characters; nil when nothing is left.
    public static func cleanTitle(_ title: String?, max: Int) -> String? {
        guard let title else { return nil }
        let scalars = title.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : String($0) }
        let text = scalars.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.isEmpty ? nil : String(text.prefix(max))
    }

    /// "Scan 2026-11-06 14:05"
    public static func defaultScanTitle(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Scan " + f.string(from: now)
    }
}

/// The server's answer to `POST /documents` and `POST /share`.
public struct ShareReply: Decodable, Sendable, Equatable {
    public var ok: Bool
    public var id: String?
    public var route: String?
    public var text: String

    public init(ok: Bool = true, id: String? = nil, route: String? = nil, text: String) {
        self.ok = ok; self.id = id; self.route = route; self.text = text
    }

    enum CodingKeys: String, CodingKey { case ok, id, route, text }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = c.bool(.ok) ?? true
        id = c.text(.id)
        route = c.text(.route)
        text = c.text(.text) ?? "Sent."
    }
}

extension APIError {
    /// The answer to `POST /documents` and `POST /share`: a 409 (the same id is still being handled) is worth a
    /// retry, the other 4xx the server gives for the content (400, 411, 413, 415, 422) never change.
    public static func fromUpload(status: Int, body: Data) -> APIError? {
        switch status {
        case 409: return .serverSaid(status: 409, text: serverErrorText(body) ?? "The server is still handling this.")
        case 411: return .badRequest(serverErrorText(body) ?? "The server needs a Content-Length.")
        case 400, 413, 415, 422:
            return .badRequest(serverErrorText(body) ?? (status == 413 ? "The server says it is too large." : ""))
        case 429: return .tooManyRequests
        default: return from(status: status, body: body)
        }
    }

    /// The server looked at the content and said no. Trying again later changes nothing.
    public var isPermanentRejection: Bool {
        if case .badRequest = self { return true }
        return false
    }
}

public enum ShareOutcome: Sendable, Equatable {
    case sent(text: String)
    /// Saved in the outbox; Homelab sends it when it can.
    case queued
    case failed(String)

    public static let queuedText = "Saved, Homelab sends it when it can."
}

/// Sends one item, or saves it in the outbox. `api` is nil where no token is available (the share extension on a
/// token server): the item then goes to the outbox, and the app sends it.
public enum ShareSender {
    public static func send(_ item: ShareItem, id: String = UUID().uuidString.lowercased(), server: ServerConfig,
                            api: (any CompanionAPI)?, features: Set<ServerInfo.Feature>?, outbox: Outbox,
                            now: Date = Date()) async -> ShareOutcome {
        let destination = ShareRouter.destination(for: item)
        if let features, !features.contains(destination.feature) {
            return .failed(destination == .paperless
                ? "\(server.name) doesn't take documents."
                : "\(server.name) doesn't take shared links.")
        }
        guard let api else { return enqueue(item, id: id, server: server, outbox: outbox, now: now) }
        do {
            let reply: ShareReply
            switch item {
            case .pdf(let data, let title): reply = try await api.upload(pdf: data, title: title, id: id)
            case .url(let url, let title): reply = try await api.share(url: url, title: title, id: id)
            }
            return reply.ok ? .sent(text: reply.text) : .failed(reply.text)
        } catch let e as APIError {
            if e.isTransient || e.mayHaveRun, !e.isPermanentRejection {
                return enqueue(item, id: id, server: server, outbox: outbox, now: now)
            }
            return .failed(e.message)
        } catch {
            return .failed(APIError.from(error, host: server.host).message)
        }
    }

    static func enqueue(_ item: ShareItem, id: String, server: ServerConfig, outbox: Outbox, now: Date) -> ShareOutcome {
        do {
            try outbox.add(item, id: id, server: server.id, now: now)
            return .queued
        } catch let e as OutboxError {
            return .failed(e.message)
        } catch {
            return .failed("Couldn't save it for later.")
        }
    }
}
