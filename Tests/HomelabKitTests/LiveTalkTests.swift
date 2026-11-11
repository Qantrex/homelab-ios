import Foundation
import Testing
@testable import HomelabKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite struct SpokenTextTests {
    @Test func marksAreNotRead() {
        #expect(SpokenText.clean("**All good.** The `backup` ran at _03:00_.") == "All good. The backup ran at 03:00.")
        #expect(SpokenText.clean("~~old~~ new") == "new.")
    }

    @Test func linksAreTheirWordsAndAddressesTheirSite() {
        #expect(SpokenText.clean("See [the ad](https://www.willhaben.at/iad/x?y=1) now.") == "See the ad now.")
        #expect(SpokenText.clean("It is on https://www.willhaben.at/iad/kaufen?x=1.") == "It is on willhaben.at.")
        #expect(SpokenText.clean("![poster](https://x.example/p.jpg) Done") == "Done.")
    }

    @Test func listsAreHeardItemByItem() {
        let text = "Open:\n- Return the parcel\n- [ ] Call the dentist\n1. Study"
        #expect(SpokenText.clean(text) == "Open. Return the parcel. Call the dentist. Study.")
    }

    @Test func codeAndRulesAreLeftOutAndTablesReadByRow() {
        let text = "Here:\n```sh\nsudo rm -rf /\n```\n---\n| Host | State |\n|---|---|\n| pi-two | up |\n| mediabox | up |"
        #expect(SpokenText.clean(text) == "Here. pi-two, up. mediabox, up.")
    }

    @Test func emojiAreDropped() {
        #expect(SpokenText.clean("Done ✅ 🎉") == "Done.")
        #expect(SpokenText.sentences(SpokenText.clean("✅")) == [])
    }

    @Test func sentencesEndAtTheirMarks() {
        #expect(SpokenText.sentences("One. Two! Three? Four… Five") == ["One.", "Two!", "Three?", "Four…", "Five"])
        #expect(SpokenText.sentences("She said \"go.\" Then left.") == ["She said \"go.\"", "Then left."])
        #expect(SpokenText.sentences("Really?! Yes.") == ["Really?!", "Yes."])
    }

    @Test func numbersDatesAndAbbreviationsDoNotEndASentence() {
        #expect(SpokenText.sentences("It has 3.5 GB free. Fine.") == ["It has 3.5 GB free.", "Fine."])
        #expect(SpokenText.sentences("Am 11. November um 08:00. Dann frei.") == ["Am 11. November um 08:00.", "Dann frei."])
        #expect(SpokenText.sentences("Use a lamp, e.g. the floor lamp. Done.") == ["Use a lamp, e.g. the floor lamp.", "Done."])
        #expect(SpokenText.sentences("Dr. Huber at 15:00.") == ["Dr. Huber at 15:00."])
    }
}

@Suite struct SpeechFeedTests {
    @Test func aGrowingReplyIsHandedOutOnceSentenceBySentence() {
        var feed = SpeechFeed()
        #expect(feed.feed("Hey", final: false) == [])
        #expect(feed.feed("Hello there. All of your ser", final: false) == ["Hello there."])
        #expect(feed.feed("Hello there. All of your servers are up. The back", final: false) == ["All of your servers are up."])
        #expect(feed.feed("Hello there. All of your servers are up. The backup ran.", final: false) == [])
        #expect(feed.feed("Hello there. All of your servers are up. The backup ran.", final: true) == ["The backup ran."])
        #expect(feed.feed("Hello there. All of your servers are up. The backup ran.", final: true) == [])
    }

    @Test func theFirstPieceIsOneSentenceAndTheRestIsGrouped() {
        var feed = SpeechFeed()
        let pieces = feed.feed("One is short. Two is short. Three is short. Four is short.", final: true)
        #expect(pieces == ["One is short.", "Two is short. Three is short. Four is short."])
    }

    @Test func aLongFirstSentenceStartsAtItsFirstComma() {
        var feed = SpeechFeed()
        let text = "Everything is fine tonight, all of your servers are up and the backup finished at three. Rest now."
        #expect(feed.feed(text, final: true) == ["Everything is fine tonight,", "all of your servers are up and the backup finished at three.", "Rest now."])
        // Short, or without a comma early enough: left whole. A comma inside a number is not a pause.
        #expect(SpeechFeed.opening("The lamps are off now, as asked.") == ["The lamps are off now, as asked."])
        let plain = "School starts at eight tomorrow in room H nine three seven and I will wake you early."
        #expect(SpeechFeed.opening(plain) == [plain])
        let number = "It costs about 1,250 euros there and that is more than the limit you gave me for it."
        #expect(SpeechFeed.opening(number) == [number])
        // Only the reply's first sentence: later ones are spoken whole.
        var later = SpeechFeed()
        _ = later.feed("Hi. More", final: false)
        #expect(later.feed("Hi. " + text, final: true).first?.hasPrefix("Everything is fine tonight, all") == true)
    }

    @Test func groupsStayUnderThePieceLength() {
        var feed = SpeechFeed()
        let sentence = String(repeating: "word ", count: 30).trimmingCharacters(in: .whitespaces) + "."   // 150 characters
        let pieces = feed.feed(["Start.", sentence, sentence, sentence].joined(separator: " "), final: true)
        #expect(pieces.count == 4)
        #expect(pieces.allSatisfy { $0.count <= SpeechFeed.pieceLength })
    }

    @Test func aVeryLongSentenceIsCutAtACommaOrASpace() {
        let long = String(repeating: "and then this, ", count: 60) + "the end."
        let pieces = SpeechFeed.cut(long)
        #expect(pieces.count >= 2)
        #expect(pieces.allSatisfy { $0.count <= SpeechFeed.maxPiece && !$0.isEmpty })
        #expect(pieces.joined(separator: " ").replacingOccurrences(of: " ", with: "") == long.replacingOccurrences(of: " ", with: ""))
        var feed = SpeechFeed()
        #expect(feed.feed(long, final: true).allSatisfy { $0.count <= SpeechFeed.maxPiece })
    }

    @Test func aReplyWithNothingToSayGivesNothing() {
        var feed = SpeechFeed()
        #expect(feed.feed("```\ncode only\n```", final: true) == [])
    }
}

@Suite struct LiveTalkTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func agent(_ id: Int64, _ text: String, partial: Bool = false, job: String? = "chat", pending: [PendingAction] = []) -> ChatMessage {
        ChatMessage(id: id, ts: t0, from: .agent, job: job, status: "OK", text: text, pending: pending, partial: partial)
    }

    @Test func wordsAreSentAfterAPauseNotBefore() {
        var talk = LiveTalk(now: t0)
        #expect(talk.ready(now: t0 + 10) == nil)   // nothing said
        talk.hear("is everything", now: t0 + 1)
        talk.hear("is everything okay", now: t0 + 2)
        #expect(talk.ready(now: t0 + 3) == nil)
        talk.hear("is everything okay", now: t0 + 3.5)   // the same text again is not new speech
        #expect(talk.ready(now: t0 + 2 + LiveTalk.pause) == "is everything okay")
    }

    @Test func noiseWithoutWordsIsNotSent() {
        var talk = LiveTalk(now: t0)
        talk.hear("…", now: t0)
        #expect(talk.ready(now: t0 + 10) == nil)
    }

    @Test func theReplyIsSpokenWhileItGrowsAndThenTheMicrophoneOpens() {
        var talk = LiveTalk(now: t0)
        talk.hear("is everything okay", now: t0)
        talk.sent(after: 100, now: t0 + 2)
        #expect(talk.phase == .thinking)
        #expect(talk.said == "is everything okay")
        // Older messages, my own message and a scheduled report are not the reply.
        let before = [agent(90, "Old answer."), ChatMessage(id: 101, from: .me, text: "is everything okay"),
                      agent(102, "Watchdog: all fine.", job: "watchdog")]
        #expect(talk.update(messages: before, working: true, now: t0 + 3) == [])
        #expect(talk.phase == .thinking)
        #expect(talk.update(messages: before + [agent(103, "Yes, it is. Every", partial: true)], working: true, now: t0 + 4) == ["Yes, it is."])
        #expect(talk.phase == .speaking)
        talk.voiceIdle(now: t0 + 5)   // the voice caught up, but the reply is not complete
        #expect(talk.phase == .speaking)
        #expect(talk.update(messages: before + [agent(103, "Yes, it is. Everything is up.")], working: false, now: t0 + 6) == ["Everything is up."])
        #expect(talk.update(messages: before + [agent(103, "Yes, it is. Everything is up.")], working: false, now: t0 + 7) == [])
        talk.voiceIdle(now: t0 + 9)
        #expect(talk.phase == .listening)
        #expect(talk.heard.isEmpty)
    }

    @Test func aFinalMessageWhileTheServerStillWorksIsNotTheEnd() {
        var talk = LiveTalk(now: t0)
        talk.hear("lights off", now: t0)
        talk.sent(after: 10, now: t0)
        #expect(talk.update(messages: [agent(11, "One moment.")], working: true, now: t0 + 1) == [])
        #expect(talk.update(messages: [agent(11, "One moment."), agent(12, "The lamps are off.", job: "action")], working: false, now: t0 + 3)
                == ["One moment.", "The lamps are off."])
        talk.voiceIdle(now: t0 + 6)
        #expect(talk.phase == .listening)
    }

    @Test func aTapInterruptsAndTheRestIsNotSaid() {
        var talk = LiveTalk(now: t0)
        talk.hear("tell me everything", now: t0)
        talk.sent(after: 10, now: t0)
        _ = talk.update(messages: [agent(11, "First part. Second", partial: true)], working: true, now: t0 + 1)
        talk.interrupt(now: t0 + 2)
        #expect(talk.phase == .listening)
        #expect(talk.update(messages: [agent(11, "First part. Second part. Third part.")], working: false, now: t0 + 3) == [])
    }

    @Test func aReplyThatNeedsApprovalSaysSo() {
        let proposal = PendingAction(id: "p1", action: "restart-container", arg: "sonarr")
        var talk = LiveTalk(now: t0)
        talk.hear("restart sonarr", now: t0)
        talk.sent(after: 10, now: t0)
        _ = talk.update(messages: [agent(11, "I need your okay for that.", pending: [proposal])], working: false, now: t0 + 1)
        #expect(talk.needsApproval)
    }

    @Test func noReplyAtAllGoesBackToListening() {
        var talk = LiveTalk(now: t0)
        talk.hear("hello", now: t0)
        talk.sent(after: 10, now: t0)
        #expect(talk.update(messages: [], working: false, now: t0 + 60) == [])
        #expect(talk.phase == .thinking)
        #expect(talk.update(messages: [], working: false, now: t0 + LiveTalk.replyTimeout) == [])
        #expect(talk.phase == .listening)
    }

    @Test func muteHearsNothingUntilResumed() {
        var talk = LiveTalk(now: t0)
        talk.pause()
        talk.hear("anything", now: t0 + 1)
        #expect(talk.heard.isEmpty)
        #expect(talk.ready(now: t0 + 10) == nil)
        talk.resume(now: t0 + 11)
        #expect(talk.phase == .listening)
    }

    @Test func silenceForTooLongIsIdle() {
        var talk = LiveTalk(now: t0)
        #expect(!talk.isIdle(now: t0 + LiveTalk.idleLimit - 1))
        #expect(talk.isIdle(now: t0 + LiveTalk.idleLimit))
        talk.hear("hm", now: t0 + 5)
        #expect(!talk.isIdle(now: t0 + LiveTalk.idleLimit + 10))
    }

    @Test func aFailedSendKeepsTheWordsAndListensAgain() {
        var talk = LiveTalk(now: t0)
        talk.hear("hello there", now: t0)
        talk.sent(after: 10, now: t0 + 2)
        talk.sendFailed(now: t0 + 3)
        #expect(talk.phase == .listening)
        #expect(talk.said == "hello there")
    }
}

@Suite struct SpeechClientTests {
    let base = URL(string: "https://lab.example.ts.net")!

    @Test func aSpokenMessageCarriesTheVoiceFlagAndATypedOneDoesNot() async throws {
        let t = FakeTransport(json: #"{"ok": true, "id": 7}"#)
        let c = CompanionClient(baseURL: base, token: nil, transport: t)
        #expect(try await c.send(" is everything okay ", voice: true) == 7)
        let spoken = try #require(t.last?.httpBody)
        #expect(String(decoding: spoken, as: UTF8.self) == #"{"text":"is everything okay","voice":true}"#)
        _ = try await c.send("typed", voice: false)
        #expect(bodyJSON(t.last) == ["text": "typed"])
        _ = try await c.send("typed")
        #expect(bodyJSON(t.last) == ["text": "typed"])
    }

    @Test func speechPostsTheTextAndReadsAudio() async throws {
        var wav = Data("RIFF".utf8) + Data([36, 0, 0, 0]) + Data("WAVEfmt ".utf8)
        wav.append(Data(repeating: 0, count: 64))
        let t = FakeTransport { [wav] _ in .init(body: wav, headers: ["Content-Type": "audio/wav"]) }
        let clip = try await CompanionClient(baseURL: base, token: nil, transport: t).speech(" Hello there. ")
        #expect(clip.kind == .wav)
        #expect(clip.data == wav)
        let r = try #require(t.last)
        #expect(r.httpMethod == "POST")
        #expect(r.url?.path == "/api/v1/speech")
        #expect(bodyJSON(r) == ["text": "Hello there."])
    }

    @Test func speechRefusesWhatIsNotAudioAndTextThatIsTooLong() async {
        let html = FakeTransport { _ in .init(body: Data("<html>login</html>".utf8), headers: ["Content-Type": "audio/wav"]) }
        await #expect(throws: APIError.invalidResponse) {
            _ = try await CompanionClient(baseURL: base, token: nil, transport: html).speech("Hello.")
        }
        let none = FakeTransport(status: 404, json: "{}")
        await #expect(throws: APIError.notFound) {
            _ = try await CompanionClient(baseURL: base, token: nil, transport: none).speech("Hello.")
        }
        let c = CompanionClient(baseURL: base, token: nil, transport: none)
        await #expect(throws: APIError.self) { _ = try await c.speech(String(repeating: "a", count: SpeechFeed.maxPiece + 1)) }
        await #expect(throws: APIError.self) { _ = try await c.speech("  ") }
        #expect(none.requests.count == 1)   // the two bad texts never left the phone
    }

    @Test func audioIsRecognisedByItsFirstBytes() {
        #expect(SpeechClip(sniffing: Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0]))?.kind == .mp3)
        #expect(SpeechClip(sniffing: Data([0xFF, 0xFB, 0x90, 0x00]))?.kind == .mp3)
        #expect(SpeechClip(sniffing: Data([0xFF, 0xF1, 0x50, 0x80]))?.kind == .aac)
        #expect(SpeechClip(sniffing: Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8))?.kind == .m4a)
        #expect(SpeechClip(sniffing: Data("fLaC".utf8) + Data(count: 8))?.kind == .flac)
        #expect(SpeechClip(sniffing: Data("{\"error\": \"no\"}".utf8)) == nil)
        #expect(SpeechClip(sniffing: Data()) == nil)
    }

    @Test func aServerWithoutAVoiceAnswersNotFound() async {
        let demo = DemoBackend()
        await #expect(throws: APIError.notFound) { _ = try await demo.speech("Hello.") }
    }

    @Test func theLanguageSettingIsOmittedWhenItIsTheIPhones() throws {
        var s = AppSettings()
        #expect(s.liveLang == .system)
        let plain = try JSONEncoder().encode(s)
        s.liveLang = .german
        #expect(s.liveLanguage == .german)
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.liveLang == .german)
        s.liveLang = .system
        #expect(try JSONEncoder().encode(s) == plain)
        #expect(ServerInfo.Feature(rawValue: "speech") == .speech)
    }
}
