import Foundation
import Testing
@testable import HomelabKit

/// The VoiceOver twins of the short ages and countdowns ("26 min" → "26 minutes").
@Suite struct SpokenFormatTests {
    let now = Date(timeIntervalSince1970: 1_762_291_800)

    @Test func ages() {
        #expect(Format.spokenAge(now.addingTimeInterval(-10), now: now) == "just now")
        #expect(Format.spokenAge(now.addingTimeInterval(-60), now: now) == "1 minute ago")
        #expect(Format.spokenAge(now.addingTimeInterval(-120), now: now) == "2 minutes ago")
        #expect(Format.spokenAge(now.addingTimeInterval(-3 * 3600), now: now) == "3 hours ago")
        #expect(Format.spokenAge(now.addingTimeInterval(-3700), now: now) == "1 hour ago")
        #expect(Format.spokenAge(now.addingTimeInterval(-30 * 3600), now: now) == "yesterday")
        #expect(Format.spokenAge(now.addingTimeInterval(-3 * 86400), now: now) == "3 days ago")
        #expect(Format.spokenAge(nil, now: now) == "never")
    }

    @Test func countdowns() {
        #expect(Format.spokenCountdown(minutes: 0) == "now")
        #expect(Format.spokenCountdown(minutes: 1) == "in 1 minute")
        #expect(Format.spokenCountdown(minutes: 26) == "in 26 minutes")
        #expect(Format.spokenCountdown(minutes: 60) == "in 1 hour")
        #expect(Format.spokenCountdown(minutes: 125) == "in 2 hours 5 minutes")
    }

    @Test func delays() {
        #expect(Format.spokenDelay(minutes: 3) == "3 minutes late")
        #expect(Format.spokenDelay(minutes: 1) == "1 minute late")
        #expect(Format.spokenDelay(minutes: nil) == "late")
    }

    @Test func freeText() {
        #expect(Format.spoken("40 min") == "40 minutes")
        #expect(Format.spoken("2 d") == "2 days")
        #expect(Format.spoken("1 d ago") == "1 day ago")
        #expect(Format.spoken("Delay +3 min") == "Delay 3 minutes late")
        #expect(Format.spoken("U6 07:36, today") == "U6 07:36, today")
        #expect(Format.spoken("ab12 d") == "ab12 d")   // ids stay as they are
        #expect(Format.spoken("3 days") == "3 days")
        #expect(Format.spoken("5\u{202F}h") == "5 hours")
    }
}
