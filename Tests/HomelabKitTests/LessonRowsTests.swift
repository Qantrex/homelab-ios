import Foundation
import Testing
@testable import HomelabKit

@Suite struct LessonRowsTests {
    func lesson(_ t: String, _ room: String, _ time: String, tint: Tint? = nil, cancelled: Bool? = nil) -> Card.Item {
        .init(title: t, subtitle: room, value: time, tint: tint, cancelled: cancelled)
    }

    @Test func parallelLessonsShareOneRow() {
        let rows = LessonRows.grouped([
            lesson("D", "R 1", "09:50–10:40"), lesson("E1", "R 2", "09:50–10:40"),
            lesson("GGP", "R 3", "09:50–10:40"), lesson("ITP2", "R 4", "09:50–10:40"),
            lesson("Maths", "R 9", "11:40–12:30"),
        ])
        #expect(rows.count == 2)
        #expect(rows[0].title == "D · E1 · GGP · ITP2" && rows[0].subtitle == "R 1 · R 2 · R 3 · R 4")
        #expect(rows[0].value == "09:50–10:40" && rows[1].title == "Maths")
    }

    @Test func backToBackSlotsJoin() {
        let slot1 = ["D", "E1", "GGP", "ITP2"].map { lesson($0, "R", "09:50–10:40") }
        let slot2 = ["D", "E1", "GGP", "ITP2"].map { lesson($0, "R", "10:40–11:30") }
        let rows = LessonRows.grouped(slot1 + slot2)
        #expect(rows.count == 1 && rows[0].value == "09:50–11:30")
    }

    @Test func differentOrGappedSlotsStaySeparate() {
        #expect(LessonRows.grouped([lesson("D", "R", "08:00–08:50"), lesson("E", "R", "08:50–09:40")]).count == 2)
        #expect(LessonRows.grouped([lesson("D", "R", "08:00–08:50"), lesson("D", "R", "09:00–09:50")]).count == 2)
    }

    @Test func changedLessonKeepsItsMark() {
        let rows = LessonRows.grouped([lesson("D", "R 1", "09:50–10:40"), lesson("E1", "R 2", "09:50–10:40", tint: .orange)])
        #expect(rows.count == 1 && rows[0].tint == .orange)
        // A changed second hour is not merged into a plain first one.
        let two = LessonRows.grouped([lesson("D", "R 1", "09:50–10:40"), lesson("D", "R 1", "10:40–11:30", tint: .orange)])
        #expect(two.count == 2)
    }

    @Test func cancelledStaysItsOwnRow() {
        let rows = LessonRows.grouped([lesson("D", "R", "09:00–09:50"), lesson("E", "R", "09:00–09:50", cancelled: true)])
        #expect(rows.count == 2 && rows[1].cancelled == true)
    }

    @Test func otherItemsPassThrough() {
        let odd = Card.Item(title: "Free day", value: "all day")
        #expect(LessonRows.grouped([odd]) == [odd])
    }
}
