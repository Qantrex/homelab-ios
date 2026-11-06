import Foundation
import Testing
@testable import HomelabKit

/// How the chat lays out its messages: time lines after gaps, folding long reports, Markdown blocks.
@Suite struct ChatLayoutTests {
    static let vienna: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Vienna")!
        return cal
    }()

    func at(_ hour: Int, _ minute: Int, day: Int = 6) -> Date {
        Self.vienna.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    // MARK: Time lines

    @Test func timeLineOnlyAfterATenMinuteGap() {
        var t = ChatTimeline()
        t.merge(MessagePage(messages: [
            ChatMessage(id: 1, ts: at(9, 0), from: .me, text: "status?"),
            ChatMessage(id: 2, ts: at(9, 1), from: .agent, text: "All fine."),
            ChatMessage(id: 3, ts: at(9, 10), from: .me, text: "9 min after the last one"),
            ChatMessage(id: 4, ts: at(9, 20), from: .agent, text: "exactly 10 min"),
            ChatMessage(id: 5, from: .agent, text: "no time: neither stamped nor counted"),
            ChatMessage(id: 6, ts: at(9, 29), from: .me, text: "9 min after 4"),
            ChatMessage(id: 7, ts: at(14, 0), from: .agent, text: "afternoon report"),
        ]))
        let s = t.stamps(now: at(15, 0), calendar: Self.vienna)
        #expect(s[1] == ChatTimeline.Stamp(day: "Today", time: at(9, 0)))
        #expect(s[4] == ChatTimeline.Stamp(day: nil, time: at(9, 20)))
        #expect(s[7] == ChatTimeline.Stamp(day: nil, time: at(14, 0)))
        #expect(Set(s.keys) == [1, 4, 7])
    }

    @Test func aNewDayAlwaysGetsItsDayEvenAfterAShortGap() {
        var t = ChatTimeline()
        t.merge(MessagePage(messages: [
            ChatMessage(id: 1, ts: at(23, 58, day: 5), from: .me, text: "late"),
            ChatMessage(id: 2, ts: at(0, 1), from: .agent, text: "3 min later, but tomorrow"),
        ]))
        let s = t.stamps(now: at(8, 0), calendar: Self.vienna)
        #expect(s[1]?.day == "Yesterday" && s[2]?.day == "Today")
    }

    // MARK: Folding

    @Test func foldsOnlyWhenItHidesARealChunk() {
        #expect(ChatFold.shownLines == 12)
        #expect(!ChatFold.folds(lines: 12))
        #expect(!ChatFold.folds(lines: 15))   // "Show more" for 3 lines is not worth a tap
        #expect(ChatFold.folds(lines: 16))
        #expect(ChatFold.lines(height: 22 * 20, lineHeight: 22) == 20)
        #expect(ChatFold.lines(height: 22 * 12 + 3, lineHeight: 22) == 12)   // spacing between blocks rounds away
        #expect(ChatFold.lines(height: 100, lineHeight: 0) == 0)
        #expect(ChatFold.folds(height: 22 * 30, lineHeight: 22))
        #expect(!ChatFold.folds(height: 22 * 4, lineHeight: 22))
        #expect(ChatFold.foldedHeight(lineHeight: 22) == 264)
    }

    // MARK: Markdown

    typealias Block = ChatMarkdown.Block

    @Test func plainTextKeepsItsLineBreaks() {
        #expect(ChatMarkdown.blocks("media: ok\npi: ok") == [.paragraph("media: ok\npi: ok")])
        #expect(ChatMarkdown.blocks("one\n\n\ntwo") == [.paragraph("one"), .paragraph("two")])
        #expect(ChatMarkdown.blocks("").isEmpty)
        #expect(ChatMarkdown.blocks("**Bold** start") == [.paragraph("**Bold** start")])
    }

    @Test func listsHeadingsAndRules() {
        let text = """
        ## Nightly report
        Two things:
        - sonarr **restarted**
          after the update
        * [x] backup ran
        + [ ] prune images
            - nested
        1. first
        2) second
        ---
        #hashtag stays text
        """
        #expect(ChatMarkdown.blocks(text) == [
            .heading("Nightly report", level: 2),
            .paragraph("Two things:"),
            .bullet("sonarr **restarted**\nafter the update", indent: 0, checked: nil),
            .bullet("backup ran", indent: 0, checked: true),
            .bullet("prune images", indent: 0, checked: false),
            .bullet("nested", indent: 2, checked: nil),
            .numbered("first", number: "1", indent: 0),
            .numbered("second", number: "2", indent: 0),
            .rule,
            .paragraph("#hashtag stays text"),
        ])
    }

    @Test func codeBlocksKeepEverythingInside() {
        let text = """
        Run this:
        ```sh
          docker restart sonarr
        - not a bullet

        ```
        Done.
        """
        #expect(ChatMarkdown.blocks(text) == [
            .paragraph("Run this:"),
            .code("  docker restart sonarr\n- not a bullet\n", language: "sh"),
            .paragraph("Done."),
        ])
        // An unclosed fence still shows its code.
        #expect(ChatMarkdown.blocks("```\nuptime") == [.code("uptime", language: nil)])
    }

    @Test func quotesAndTables() {
        let text = """
        > the agent said
        > twice
        | Host | Load |
        |------|-----:|
        | media | 1.85 |
        | pi |  |
        after
        """
        #expect(ChatMarkdown.blocks(text) == [
            .quote("the agent said\ntwice"),
            .table([["Host", "Load"], ["media", "1.85"], ["pi", ""]]),
            .paragraph("after"),
        ])
    }

    // MARK: Personality preview

    @Test func previewSampleFollowsThePersonality() {
        let now = at(12, 0)
        let down = HomelabState(status: .problem, hosts: [Host(id: "media", reachable: false)])
        #expect(Voice.sample(for: down, level: .alarm, personality: .off, now: now, calendar: Self.vienna) == nil)
        for p in [Personality.dry, .snarky, .ultrakill] {
            let take = Voice.take(for: down, personality: p, now: now, calendar: Self.vienna)
            let sample = Voice.sample(for: down, level: .alarm, personality: p, now: now, calendar: Self.vienna)
            #expect(sample != nil && sample == take?.text)
            #expect(sample?.contains("media") == true)
            // A tap moves on to another take, and wraps around.
            let count = Voice.takeCount(for: down, personality: p, now: now, calendar: Self.vienna)
            if count > 1 {
                #expect(Voice.sample(for: down, level: .alarm, personality: p, variant: 1, now: now,
                                     calendar: Self.vienna) != sample)
            }
            #expect(Voice.sample(for: down, level: .alarm, personality: p, variant: count, now: now,
                                 calendar: Self.vienna) == sample)
        }
        // Nothing loaded: the mood's general line, the same one Today shows.
        #expect(Voice.sample(for: nil, level: .unknown, personality: .snarky, now: now, calendar: Self.vienna)
                == Voice.line(.unknown, .snarky, on: now, calendar: Self.vienna))
    }
}
