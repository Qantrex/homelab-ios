import Foundation

// Tolerant decoding. Other people's servers send odd JSON: numbers as strings, a string where a list was expected,
// null, unknown enum values. The app must show what it can and never fail the whole answer for one bad field.

/// Decodes one element of an array, or nothing if that element is malformed.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// Any JSON scalar, read as text or number as needed.
enum Scalar: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.typeMismatch(Scalar.self, .init(codingPath: c.codingPath, debugDescription: "not a scalar"))
        }
    }

    var string: String? {
        switch self {
        case .string(let s): s
        case .number(let d): d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .bool(let b): b ? "true" : "false"
        }
    }

    var double: Double? {
        switch self {
        // "nan", "inf" and "1e999" parse as Doubles too: only finite numbers count.
        case .string(let s): Double(s.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        case .number(let d): d.isFinite ? d : nil
        case .bool: nil
        }
    }

    var bool: Bool? {
        switch self {
        case .bool(let b): b
        case .number(let d): d == 0 ? false : d == 1 ? true : nil
        case .string(let s):
            switch s.lowercased() {
            case "true", "yes", "1", "on": true
            case "false", "no", "0", "off": false
            default: nil
            }
        }
    }
}

extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    func string(_ key: Key) -> String? {
        lenient(Scalar.self, key)?.string
    }

    /// A non-empty string, else nil.
    func text(_ key: Key) -> String? {
        guard let s = string(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    func double(_ key: Key) -> Double? {
        lenient(Scalar.self, key)?.double
    }

    /// A whole number, rounded and clamped into `ServerNumber.intRange` (1e30 becomes 1 000 000 000, not a trap).
    func int(_ key: Key) -> Int? {
        double(key).map { Int(clamping: $0, in: ServerNumber.intRange) }
    }

    func int64(_ key: Key) -> Int64? {
        if let i = lenient(Int64.self, key) { return i }   // exact for big ids (nanosecond timestamps)
        if let s = lenient(String.self, key), let i = Int64(s) { return i }
        return nil
    }

    func bool(_ key: Key) -> Bool? {
        lenient(Scalar.self, key)?.bool
    }

    func date(_ key: Key) -> Date? {
        switch lenient(Scalar.self, key) {
        case .string(let s): ServerDate.parse(s)
        case .number(let d): ServerDate.fromEpoch(d)
        default: nil
        }
    }

    /// An array whose bad elements are dropped. A missing or non-array value gives [].
    func array<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        (lenient([Lossy<T>].self, key) ?? []).compactMap(\.value)
    }

    /// A list of strings. A single string counts as a one-element list; non-string elements are converted or dropped.
    func strings(_ key: Key) -> [String] {
        if let one = lenient(String.self, key) { return one.isEmpty ? [] : [one] }
        return array(Scalar.self, key).compactMap(\.string)
    }

    /// A string → number map; values that aren't numbers are dropped.
    func numberMap(_ key: Key) -> [String: Double] {
        guard let raw = lenient([String: Lossy<Scalar>].self, key) else { return [:] }
        return raw.compactMapValues { $0.value?.double }
    }
}

/// Server times: ISO 8601 with or without zone and fractional seconds, or epoch seconds/milliseconds.
/// Without a zone they mean the server's local time; the app assumes the phone is in the same zone (a homelab).
public enum ServerDate {
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> Date? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let d = Double(s), s.allSatisfy({ $0.isNumber || $0 == "." }) { return fromEpoch(d) }
        for format in formats {
            if let d = cache.parse(s, format: format, zone: timeZone) { return d }
        }
        return nil
    }

    public static func fromEpoch(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        let seconds = value > 1e17 ? value / 1e9   // nanoseconds
            : value > 1e14 ? value / 1e6           // microseconds
            : value > 1e11 ? value / 1e3           // milliseconds
            : value
        // Past the year 5000 is no server time (1e30 ns would be 1e21 s): dropped, so no date arithmetic overflows.
        guard seconds < 1e11 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// For writing times the server will read (and for caches): ISO 8601 with zone.
    public static func string(_ date: Date) -> String {
        cache.string(date, format: "yyyy-MM-dd'T'HH:mm:ssXXXXX", zone: .current)
    }

    static let formats = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ssXXXXX", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd",
    ]

    /// One formatter per format and zone, made once (building one is slow, and a parse tries up to eleven). Every use
    /// holds the lock, so no formatter is used by two threads at once, on any platform.
    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private var formatters: [String: DateFormatter] = [:]

        private func formatter(_ format: String, zone: TimeZone) -> DateFormatter {
            let key = zone.identifier + "|" + format
            if let f = formatters[key] { return f }
            let f = ServerDate.formatter(format, zone: zone)
            formatters[key] = f
            return f
        }

        func parse(_ text: String, format: String, zone: TimeZone) -> Date? {
            lock.withLock { formatter(format, zone: zone).date(from: text) }
        }

        func string(_ date: Date, format: String, zone: TimeZone) -> String {
            lock.withLock { formatter(format, zone: zone).string(from: date) }
        }
    }

    private static let cache = FormatterCache()

    static func formatter(_ format: String, zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone
        f.dateFormat = format
        return f
    }
}
