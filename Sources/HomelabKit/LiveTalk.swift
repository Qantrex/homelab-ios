import Foundation

/// The chat's live conversation: the owner talks, the words go to the agent as a normal chat message (marked
/// `voice`), and the reply is spoken while it is still being written. This file is the part without a microphone:
/// what of a reply is said and when (`SpokenText`, `SpeechFeed`) and whose turn it is (`LiveTalk`). The audio is in
/// HomelabUI (LiveTalkAudio.swift), the screen in LiveTalkView.swift.

/// A chat reply as words to say: no Markdown marks, no code, no addresses.
public enum SpokenText {
    /// The text a voice reads for `markdown`: block by block, each ending like a sentence, so a list is heard item by
    /// item. Code blocks and rules are left out, a table is read row by row, a link is its words (a bare address its
    /// site's name), emoji are dropped.
    public static func clean(_ markdown: String) -> String {
        var parts: [String] = []
        for block in ChatMarkdown.blocks(markdown) {
            switch block {
            case .paragraph(let s), .quote(let s), .heading(let s, _):
                parts.append(closed(inline(s)))
            case .bullet(let s, _, _), .numbered(let s, _, _):
                parts.append(closed(inline(s)))
            case .table(let rows):
                // The header names the columns once; then each row as "a, b, c."
                for row in rows.dropFirst(rows.count > 1 ? 1 : 0) {
                    parts.append(closed(row.map(inline).filter { !$0.isEmpty }.joined(separator: ", ")))
                }
            case .code, .rule:
                continue
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `clean` cut into sentences, in order. A dot after a number ("11. November", "3.5") or a short abbreviation
    /// ("e.g.", "z.B.", "Dr.") does not end one.
    public static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            current.append(ch)
            if terminators.contains(ch) {
                // Take what belongs to the end: more marks ("?!", "..."), then closing quotes and brackets.
                while i + 1 < chars.count, terminators.contains(chars[i + 1]) || closers.contains(chars[i + 1]) {
                    i += 1
                    current.append(chars[i])
                }
                let atEnd = i + 1 >= chars.count
                let spaceNext = !atEnd && chars[i + 1].isWhitespace
                if (atEnd || spaceNext) && !(ch == "." && keepsGoing(current)) {
                    push(&out, current)
                    current = ""
                }
            } else if ch == "\n" {
                push(&out, current)
                current = ""
            }
            i += 1
        }
        push(&out, current)
        return out
    }

    private static let terminators: Set<Character> = [".", "!", "?", "…"]
    private static let closers: Set<Character> = ["\"", "'", ")", "]", "”", "’", "»", "“"]
    private static let abbreviations: Set<String> = [
        "e.g", "i.e", "etc", "vs", "mr", "mrs", "ms", "dr", "prof", "no", "nr", "ca", "approx", "min", "max",
        "z.b", "bzw", "usw", "inkl", "exkl", "evtl", "ggf", "d.h", "u.a", "st", "str", "tel",
    ]

    private static func push(_ out: inout [String], _ sentence: String) {
        let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only marks ("." after a dropped emoji) are nothing to say.
        if s.contains(where: { $0.isLetter || $0.isNumber }) { out.append(s) }
    }

    /// True when the dot that ends `current` is part of a number, a date or an abbreviation.
    private static func keepsGoing(_ current: String) -> Bool {
        let word = current.dropLast().split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: "([\"'“„"))
        if bare.isEmpty { return false }
        if bare.allSatisfy(\.isNumber) { return bare.count <= 2 }   // "11." a date or a list number, "450." a price
        if bare.count == 1, bare.first?.isLetter == true { return true }   // an initial
        return abbreviations.contains(bare.lowercased())
    }

    /// A block's text ending like a sentence.
    private static func closed(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return "" }
        if terminators.contains(last) || closers.contains(last) { return t }
        if last == ":" || last == ";" || last == "," { return String(t.dropLast()) + "." }
        return t + "."
    }

    /// One block's text without inline marks: `**bold**`, `_soft_` and `` `code` `` are their words, `~~struck~~` is left out,
    /// `[words](address)` is the words, a bare address is its site ("willhaben.at"), emoji are gone.
    static func inline(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\n", with: " ")
        // Pictures say nothing; links say their words.
        t = replace(t, #"!\[[^\]]*\]\([^)]*\)"#, "")
        t = replace(t, #"\[([^\]]+)\]\([^)]*\)"#, "$1")
        t = replace(t, #"<(https?://[^>\s]+)>"#, "$1")
        t = sites(t)
        t = replace(t, #"`([^`]*)`"#, "$1")
        t = replace(t, #"~~.+?~~"#, "")   // struck out = taken back
        t = replace(t, #"(\*\*|__)(.+?)\1"#, "$2")
        t = replace(t, #"(?<![\w*])\*(?!\s)([^*]+?)(?<!\s)\*(?![\w*])"#, "$1")
        t = replace(t, #"(?<![\w_])_(?!\s)([^_]+?)(?<!\s)_(?![\w_])"#, "$1")
        t = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        t = String(String.UnicodeScalarView(t.unicodeScalars.filter { !isPicture($0) }))
        t = replace(t, #"\s+"#, " ")
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// "https://www.willhaben.at/iad/kaufen?x=1" → "willhaben.at".
    private static func sites(_ t: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s)\]>]+"#) else { return t }
        var out = t
        for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            var address = String(out[r])
            var tail = ""
            while let last = address.last, ".,;:!?".contains(last) {   // the sentence's own mark stays
                tail = String(last) + tail
                address.removeLast()
            }
            var host = URL(string: address)?.host ?? ""
            if host.hasPrefix("www.") { host.removeFirst(4) }
            out.replaceSubrange(r, with: host + tail)
        }
        return out
    }

    private static func replace(_ t: String, _ pattern: String, _ with: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return t }
        return re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: with)
    }

    /// Emoji and their joiners: a voice either skips them or reads their names out.
    private static func isPicture(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x1F000...0x1FAFF, 0x2600...0x27BF, 0x2B00...0x2BFF, 0xFE00...0xFE0F, 0x200D, 0x20E3, 0xE0020...0xE007F:
            true
        default:
            false
        }
    }
}

/// Turns a reply that grows (a partial message, polled about once a second) into pieces to say, each handed out
/// once. The first piece is one sentence, so the voice starts early; later ones are grouped, because a voice sounds
/// better over a few sentences and they are made while the earlier ones play.
public struct SpeechFeed: Sendable, Equatable {
    /// Sentences already handed out.
    public private(set) var taken = 0
    /// Later pieces are filled up to about this many characters.
    public static let pieceLength = 220
    /// One request's limit (`POST /speech`): a longer sentence is cut at a comma or a space.
    public static let maxPiece = 500

    public init() {}

    /// The new pieces of `text` (the whole reply so far). While the reply is not `final` its last sentence is kept
    /// back: it may still grow.
    public mutating func feed(_ text: String, final: Bool) -> [String] {
        var sentences = SpokenText.sentences(SpokenText.clean(text))
        if !final, !sentences.isEmpty { sentences.removeLast() }
        guard sentences.count > taken else { return [] }
        let new = Array(sentences[taken...])
        var pieces: [String] = []
        var rest = new[...]
        if taken == 0, let first = rest.first {
            pieces.append(contentsOf: Self.opening(first))
            rest = rest.dropFirst()
        }
        var current = ""
        for s in rest {
            if !current.isEmpty, current.count + 1 + s.count > Self.pieceLength {
                pieces.append(current)
                current = ""
            }
            current = current.isEmpty ? s : current + " " + s
        }
        if !current.isEmpty { pieces.append(current) }
        taken = sentences.count
        return pieces.flatMap(Self.cut)
    }

    /// The very first sentence, cut once at an early comma when it is long: a small server makes speech about as
    /// fast as it is said, so a short opening ("Everything is fine tonight,") is heard seconds sooner.
    static func opening(_ sentence: String) -> [String] {
        guard sentence.count > openingLength else { return [sentence] }
        let chars = Array(sentence)
        // The last comma (or ; : –) between the 12th character and the limit, followed by a space.
        guard let at = (12..<min(openingLength, chars.count - 1)).last(where: { ",;:–—".contains(chars[$0]) && chars[$0 + 1] == " " })
        else { return [sentence] }
        let head = String(chars[...at]), tail = String(chars[(at + 1)...]).trimmingCharacters(in: .whitespaces)
        return tail.contains(where: \.isLetter) ? [head, tail] : [sentence]
    }

    /// A first sentence longer than this is cut at a comma (`opening`).
    public static let openingLength = 60

    /// A piece within `maxPiece`: cut after a comma when there is one in the second half, else at a space.
    static func cut(_ piece: String) -> [String] {
        guard piece.count > maxPiece else { return [piece] }
        let head = piece.prefix(maxPiece)
        let half = head.index(head.startIndex, offsetBy: maxPiece / 2)
        let at = head[half...].lastIndex(where: { ",;:".contains($0) }).map { head.index(after: $0) }
            ?? head.lastIndex(of: " ") ?? head.endIndex
        let first = String(piece[..<at]).trimmingCharacters(in: .whitespaces)
        let rest = String(piece[at...]).trimmingCharacters(in: .whitespaces)
        return (first.isEmpty ? [] : [first]) + (rest.isEmpty ? [] : cut(rest))
    }
}

/// Whose turn it is in a live conversation, and what to say next. No audio and no clock of its own: the screen tells
/// it what was heard, what the chat holds and when the voice finished, and does what `phase` says.
public struct LiveTalk: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// The microphone is open; `heard` is what was understood so far.
        case listening
        /// Sent. Waiting for the reply's first sentence.
        case thinking
        /// The reply is being said (and may still be growing).
        case speaking
        /// The owner muted the microphone, or nothing was said for `idleLimit`. Nothing is heard until they tap.
        case paused
    }

    public private(set) var phase: Phase = .listening
    /// What the recognizer understood in this turn so far.
    public private(set) var heard = ""
    /// What the owner said last (shown while the agent thinks and speaks).
    public private(set) var said = ""
    /// The reply's text so far, as it is spoken.
    public private(set) var reply = ""
    /// The reply asks for an approval: its buttons are in the chat, not here.
    public private(set) var needsApproval = false

    private var heardAt: Date?
    private var listeningSince: Date
    private var sentAt: Date?
    /// Messages after this id are the reply to what was sent.
    private var mark: Int64?
    private var feed = SpeechFeed()
    /// The reply is complete and all of it was handed to the voice.
    private var replyDone = false

    /// How long the owner must be quiet before their words are sent.
    public static let pause: TimeInterval = 1.6
    /// Listening with nothing said for this long pauses the microphone.
    public static let idleLimit: TimeInterval = 120
    /// No reply at all for this long (and the server not working on one): back to listening.
    public static let replyTimeout: TimeInterval = 150

    public init(now: Date = Date()) { listeningSince = now }

    /// The recognizer's text so far. Only a change counts as speech.
    public mutating func hear(_ text: String, now: Date = Date()) {
        guard phase == .listening else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != heard else { return }
        heard = t
        heardAt = now
    }

    /// The words to send now, once the owner said something and then paused; nil otherwise. The caller sends them
    /// and calls `sent`.
    public func ready(now: Date = Date()) -> String? {
        guard phase == .listening, !heard.isEmpty, let heardAt, now.timeIntervalSince(heardAt) >= Self.pause,
              heard.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return String(heard.prefix(CompanionClient.maxMessageLength))
    }

    /// Nothing was said for `idleLimit`: the microphone should not stay open for nothing.
    public func isIdle(now: Date = Date()) -> Bool {
        phase == .listening && heard.isEmpty && now.timeIntervalSince(listeningSince) >= Self.idleLimit
    }

    /// The words went out. `after` is the newest message id the chat had before (or the sent message's own id): the
    /// reply is what comes after it.
    public mutating func sent(after: Int64, now: Date = Date()) {
        said = heard
        heard = ""
        heardAt = nil
        mark = after
        sentAt = now
        feed = SpeechFeed()
        reply = ""
        replyDone = false
        needsApproval = false
        phase = .thinking
    }

    /// Sending failed (after `sent`): the owner's words stay on screen as `said` and the microphone opens again.
    public mutating func sendFailed(now: Date = Date()) {
        guard phase == .thinking else { return }
        listen(now: now)
    }

    /// The chat as it is now. Returns the new pieces to say, in order. The reply is every answer of the agent after
    /// the sent message that is not a scheduled report; it is complete when none of them is partial and the server
    /// is not working any more.
    public mutating func update(messages: [ChatMessage], working: Bool, now: Date = Date()) -> [String] {
        guard phase == .thinking || phase == .speaking, !replyDone, let mark else { return [] }
        let answers = messages.filter { $0.from == .agent && $0.id > mark && !$0.isReport }
        guard !answers.isEmpty else {
            // Nothing came and nothing is on its way.
            if !working, let sentAt, now.timeIntervalSince(sentAt) >= Self.replyTimeout { listen(now: now) }
            return []
        }
        let final = !working && !answers.contains(where: \.partial)
        reply = answers.map(\.text).joined(separator: "\n\n")
        needsApproval = final && answers.contains { !$0.pending.isEmpty }
        let pieces = feed.feed(reply, final: final)
        if final { replyDone = true }
        if !pieces.isEmpty { phase = .speaking }
        // A reply with nothing to say (only a code block, only a card): the turn is over.
        if final, phase == .thinking { listen(now: now) }
        return pieces
    }

    /// The voice said everything it was given. When the reply is complete, the owner's turn starts.
    public mutating func voiceIdle(now: Date = Date()) {
        guard phase == .speaking, replyDone else { return }
        listen(now: now)
    }

    /// A tap while the agent thinks or speaks: the rest of this reply is not said and the microphone opens.
    public mutating func interrupt(now: Date = Date()) {
        guard phase == .thinking || phase == .speaking else { return }
        replyDone = true
        listen(now: now)
    }

    /// Mute: nothing is heard and nothing is said until `resume`.
    public mutating func pause() {
        replyDone = true
        heard = ""
        heardAt = nil
        phase = .paused
    }

    public mutating func resume(now: Date = Date()) {
        guard phase == .paused else { return }
        listen(now: now)
    }

    private mutating func listen(now: Date) {
        phase = .listening
        heard = ""
        heardAt = nil
        listeningSince = now
    }
}

/// What the recognizer understood in one turn, across its restarts. A recognizer hands out the whole text so far on
/// every change, but it starts from nothing again when it is restarted, and the on-device one also does after a
/// short silence. A text that suddenly is much shorter than the one before is such a new start: what was heard
/// before is kept in front of it.
public struct HeardText: Sendable, Equatable {
    private var kept = ""
    private var last = ""

    public init() {}

    /// The turn's whole text after the recognizer said `raw`.
    public mutating func take(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A correction changes a word or two; a new start drops most of the text.
        if last.count >= 12, text.count * 2 < last.count { newSegment() }
        last = text
        return whole
    }

    /// The recognizer was restarted: the next text continues after what is there.
    public mutating func newSegment() {
        kept = whole
        last = ""
    }

    public var whole: String { [kept, last].filter { !$0.isEmpty }.joined(separator: " ") }
}

/// The language a live conversation is heard in (Settings → Advanced → Chat). The agent answers in the language it
/// is spoken to, so this is also the language of the iPhone's own voice.
public enum LiveLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case system, english, german
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "iPhone language"
        case .english: "English"
        case .german: "Deutsch"
        }
    }

    /// The locale identifier for the recognizer and the voice; nil = the iPhone's own.
    public var locale: String? {
        switch self {
        case .system: nil
        case .english: "en-US"
        case .german: "de-DE"
        }
    }
}

/// Speech from the server (`POST /speech`): the bytes of one audio file.
public struct SpeechClip: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case wav, mp3, m4a, aac, flac }
    public var data: Data
    public var kind: Kind

    /// The largest clip read (a minute of 24 kHz WAV is about 3 MB).
    public static let maxBytes = 6 * 1024 * 1024

    /// Decided by the first bytes, not by what the server says. Nil = not an audio file the iPhone plays.
    public init?(sniffing data: Data) {
        let b = [UInt8](data.prefix(12))
        func tag(_ at: Int, _ s: String) -> Bool { b.count >= at + s.utf8.count && Array(b[at..<(at + s.utf8.count)]) == Array(s.utf8) }
        let kind: Kind
        if tag(0, "RIFF"), tag(8, "WAVE") {
            kind = .wav
        } else if tag(0, "ID3") || (b.count >= 2 && b[0] == 0xFF && (b[1] & 0xE6) == 0xE2) {
            kind = .mp3   // an ID3 tag, or an MPEG audio frame (layer 3)
        } else if tag(4, "ftyp") {
            kind = .m4a
        } else if b.count >= 2, b[0] == 0xFF, (b[1] & 0xF6) == 0xF0 {
            kind = .aac   // ADTS
        } else if tag(0, "fLaC") {
            kind = .flac
        } else {
            return nil
        }
        self.data = data
        self.kind = kind
    }
}
