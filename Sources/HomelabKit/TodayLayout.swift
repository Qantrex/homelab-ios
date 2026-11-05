import Foundation

/// The sections of Today under the mood hero. The hero always stays on top.
public enum TodaySection: String, Codable, CaseIterable, Sendable, Identifiable {
    case day       // the day's numbers (the server's "today" card)
    case waiting   // actions waiting for approval
    case home      // Home Assistant tiles
    case cards     // the other cards (media, downloads, school, …)
    case report    // the last report

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .day: "The day in numbers"
        case .waiting: "Waiting for you"
        case .home: "Home tiles"
        case .cards: "Cards"
        case .report: "Last report"
        }
    }
}

/// Which Today sections show, in which order. Stored in the settings; tolerant of old or odd data: unknown names
/// are dropped, missing sections are added at the end (so a new section appears after an update).
public struct TodayLayout: Codable, Equatable, Sendable {
    public var order: [String]
    public var hidden: [String]

    public static let standard = TodayLayout(order: TodaySection.allCases.map(\.rawValue), hidden: [])

    public init(order: [String], hidden: [String]) {
        self.order = order
        self.hidden = hidden
    }

    /// Every section once, in the stored order, new ones last.
    public var sections: [TodaySection] {
        var seen = Set<TodaySection>()
        var out: [TodaySection] = []
        for name in order {
            if let s = TodaySection(rawValue: name), seen.insert(s).inserted { out.append(s) }
        }
        return out + TodaySection.allCases.filter { !seen.contains($0) }
    }

    public var visible: [TodaySection] { sections.filter { !hidden.contains($0.rawValue) } }

    public func isVisible(_ s: TodaySection) -> Bool { !hidden.contains(s.rawValue) }

    public mutating func setVisible(_ s: TodaySection, _ on: Bool) {
        hidden.removeAll { $0 == s.rawValue }
        if !on { hidden.append(s.rawValue) }
    }

    /// Like `Array.move(fromOffsets:toOffset:)` (a SwiftUI extension, so not on Linux), on the normalized order.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var list = sections
        let moving = source.sorted().filter { $0 < list.count }.map { list[$0] }
        let before = source.filter { $0 < destination }.count
        for i in source.sorted(by: >) where i < list.count { list.remove(at: i) }
        let at = min(max(destination - before, 0), list.count)
        list.insert(contentsOf: moving, at: at)
        order = list.map(\.rawValue)
    }
}
