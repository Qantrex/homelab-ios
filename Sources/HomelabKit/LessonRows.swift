import Foundation

/// The rows of the lessons card with parallel group lessons together (owner review 2026-11-08 row 33): lessons at the
/// same time are one row ("D · E1 · GGP · ITP2", the rooms underneath), and back-to-back slots with the same lessons
/// (09:50–10:40 then 10:40–11:30) are one row (09:50–11:30). The server sends one item per lesson: title = subject,
/// subtitle = "room · teacher", value = "HH:MM–HH:MM".
public enum LessonRows {
    /// A time range "09:50–10:40" (en dash, hyphen or em dash) as minutes since midnight; nil for anything else.
    static func range(_ value: String?) -> (start: Int, end: Int)? {
        guard let value else { return nil }
        let parts = value.split(whereSeparator: { "–—-".contains($0) }).map(String.init)
        guard parts.count == 2, let a = DayTimeline.minute(parts[0]), let b = DayTimeline.minute(parts[1]), a < b else { return nil }
        return (a, b)
    }

    static func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

    private struct Slot {
        var start: Int, end: Int
        var titles: [String], subtitles: [String]
        var cancelled: Bool
        var tint: Tint?
        var first: Card.Item
    }

    private enum Entry {
        case item(Card.Item)
        case slot(Slot)
    }

    /// An item that can be merged: a plain lesson with a time range and no action, link or progress.
    private static func plain(_ item: Card.Item) -> Bool {
        item.action == nil && item.url == nil && item.progress == nil && item.title?.isEmpty == false && range(item.value) != nil
    }

    private static func append(_ list: inout [String], _ text: String?) {
        if let text, !text.isEmpty, !list.contains(text) { list.append(text) }
    }

    private static func changed(_ tint: Tint?) -> Bool { tint.map { $0 != .gray } ?? false }

    /// The tint of a changed lesson (anything but grey) wins over a plain one, so the gold mark survives.
    private static func merged(_ a: Tint?, _ b: Tint?) -> Tint? {
        if changed(a) { return a }
        if changed(b) { return b }
        return a ?? b
    }

    public static func grouped(_ items: [Card.Item]) -> [Card.Item] {
        // 1. Parallel lessons: same time range and same cancelled state.
        var out: [Entry] = []
        for item in items {
            guard plain(item), let r = range(item.value) else { out.append(.item(item)); continue }
            let cancelled = item.cancelled == true
            let existing = out.indices.first { i in
                if case .slot(let s) = out[i] { return s.start == r.start && s.end == r.end && s.cancelled == cancelled }
                return false
            }
            if let at = existing, case .slot(var s) = out[at] {
                append(&s.titles, item.title); append(&s.subtitles, item.subtitle)
                s.tint = merged(s.tint, item.tint)
                out[at] = .slot(s)
            } else {
                var s = Slot(start: r.start, end: r.end, titles: [], subtitles: [], cancelled: cancelled, tint: item.tint, first: item)
                append(&s.titles, item.title); append(&s.subtitles, item.subtitle)
                out.append(.slot(s))
            }
        }
        // 2. Back-to-back slots right after each other with the same lessons.
        var result: [Entry] = []
        for entry in out {
            if case .slot(let s) = entry, let last = result.last, case .slot(var p) = last,
               p.end == s.start, p.titles == s.titles, p.subtitles == s.subtitles, p.cancelled == s.cancelled,
               changed(p.tint) == changed(s.tint) {
                p.end = s.end
                result[result.count - 1] = .slot(p)
            } else {
                result.append(entry)
            }
        }
        return result.map { entry in
            switch entry {
            case .item(let i): return i
            case .slot(let s):
                var item = s.first
                item.title = s.titles.joined(separator: " · ")
                item.subtitle = s.subtitles.isEmpty ? nil : s.subtitles.joined(separator: " · ")
                item.value = clock(s.start) + "–" + clock(s.end)
                item.tint = s.tint
                return item
            }
        }
    }
}
