import Foundation

/// What app and widget share through the App Group (test S3/S4/S7): one small JSON file.
public struct SpikeState: Sendable, Codable, Equatable {
    public var counter = 0
    public var lastWrite: Date?
    public var writer: String?             // "app", "background"
    public var backgroundRuns = 0
    public var lastBackgroundRun: Date?
    public var lastBackgroundResult: String?
    public var probeURL = ""               // the owner types it in; never shipped in the repo
    public var widgetLastRead: Date?       // widget writes this, so the app can show that the widget ran

    public init() {}
}

public enum SpikeStore {
    static let fileName = "spike-state.json"

    /// Group container if one works, else the app's own Application Support (so the app still runs if S4 fails).
    public static func directory(group: String?) -> URL {
        if let group, let url = AppGroup.containerURL(group) { return url }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public static func load(group: String?) -> SpikeState {
        let url = directory(group: group).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let state = try? decoder.decode(SpikeState.self, from: data) else { return SpikeState() }
        return state
    }

    public static func save(_ state: SpikeState, group: String?) throws {
        let url = directory(group: group).appendingPathComponent(fileName)
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    /// Load, change, save in one step.
    @discardableResult
    public static func update(group: String?, _ change: (inout SpikeState) -> Void) -> SpikeState {
        var state = load(group: group)
        change(&state)
        try? save(state, group: group)
        return state
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
