import AVFoundation
import HomelabKit
import Speech
import SwiftUI
import UIKit

/// The sound side of the chat's live conversation (`LiveTalk` in HomelabKit decides whose turn it is):
/// `SpeechListener` turns the microphone into words, `SpeechVoice` says the reply, `LiveTalkSession` joins both with
/// the chat. One at a time: the microphone is closed while the agent thinks and speaks, so the voice plays in full
/// quality (also over Bluetooth headphones) and never hears itself.

/// Carries a value the compiler can't check into an audio callback. Only for objects that are made for it.
private struct Unchecked<T>: @unchecked Sendable {
    let value: T
}

/// The microphone as text, on the iPhone when the language supports it (else with Apple's servers). Not tied to the
/// main actor: its callbacks come from the audio thread and the recognizer's queue.
final class SpeechListener: @unchecked Sendable {
    enum Problem: Error { case noRecognizer, notAvailable, noMicrophone }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Each start gets a number; callbacks of an earlier one are dropped.
    private var run = 0

    /// Asks for the microphone and for speech recognition (each once; later it only reads the answer).
    static func permissions() async -> LiveTalkSession.Blocker? {
        guard await AVAudioApplication.requestRecordPermission() else { return .microphone }
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        return status == .authorized ? nil : .speech
    }

    /// The recognizer for `locale`, else for the iPhone's language, else English.
    static func recognizer(_ locale: Locale) -> SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    /// Opens the microphone. `heard` gets the whole text so far on every change, `level` the loudness (0…1) about
    /// 40 times a second, `ended` is called once when the recognizer stops by itself (with its reason, or nil when it
    /// simply finished).
    func start(locale: Locale, heard: @escaping @Sendable (String) -> Void, level: @escaping @Sendable (Float) -> Void,
               ended: @escaping @Sendable (String?) -> Void) throws {
        stop()
        guard let recognizer = Self.recognizer(locale) else { throw Problem.noRecognizer }
        guard recognizer.isAvailable else { throw Problem.notAvailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        // On the iPhone when it can: nothing said leaves the phone before it is a chat message, and there is no
        // one-minute limit.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Problem.noMicrophone }
        let sink = Unchecked(value: request)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            sink.value.append(buffer)
            level(Self.loudness(buffer))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        let mine = lock.withLock { () -> Int in
            run += 1
            return run
        }
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, self.lock.withLock({ self.run == mine }) else { return }
            if let result {
                heard(result.bestTranscription.formattedString)
                if result.isFinal { ended(nil) }
            } else if let error {
                ended(error.localizedDescription)
            }
        }
    }

    func stop() {
        lock.withLock { run += 1 }
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    /// 0…1 from a buffer's RMS: -50 dB and below is 0, -10 dB and above is 1.
    static func loudness(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n {
            let s = data[0][i]
            sum += s * s
        }
        let db = 10 * log10(max(sum / Float(n), 1e-10))
        return min(max((db + 50) / 40, 0), 1)
    }
}

/// Says the pieces of a reply in order. With a server voice (`fetch`) each piece is asked for as soon as it is known,
/// one request at a time, so the next one is ready when the current one ends; a piece the server can't make is said
/// by the iPhone's own voice, and after two failures in a row the rest of the conversation is too.
@MainActor
final class SpeechVoice: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    private struct Piece {
        let text: String
        let clip: Task<SpeechClip?, Never>?
    }

    /// `POST /speech` of the selected server; nil = the iPhone's voice.
    var fetch: (@Sendable (String) async throws -> SpeechClip)?
    /// The language of the iPhone's own voice ("en-US").
    var language = "en-US"
    private var queue: [Piece] = []
    private var lastFetch: Task<SpeechClip?, Never>?
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    private var failures = 0
    /// Bumped by `stop`: a piece that was being fetched then is not played.
    private var generation = 0
    /// Something is being said or about to be.
    private(set) var isBusy = false
    /// The server's voice was used for the last piece (the screen says which voice it is).
    private(set) var usedServer = false

    override init() {
        super.init()
        synth.delegate = self
    }

    func say(_ text: String) {
        var clip: Task<SpeechClip?, Never>?
        if let fetch, failures < 2 {
            let previous = lastFetch
            clip = Task {
                _ = await previous?.value   // one request at a time: a small server makes them one after the other anyway
                guard !Task.isCancelled else { return nil }
                return try? await fetch(text)
            }
            lastFetch = clip
        }
        queue.append(Piece(text: text, clip: clip))
        if !isBusy { next() }
    }

    func stop() {
        generation += 1
        queue.forEach { $0.clip?.cancel() }
        queue = []
        lastFetch = nil
        player?.stop()
        player = nil
        utterance = nil
        synth.stopSpeaking(at: .immediate)
        isBusy = false
    }

    /// How loud the voice is right now, 0…1 (the iPhone's own voice has no meter: a steady middle).
    var level: Float {
        guard let player, player.isPlaying else { return utterance == nil ? 0 : 0.45 }
        player.updateMeters()
        return min(max((player.averagePower(forChannel: 0) + 45) / 40, 0), 1)
    }

    private func next() {
        guard !queue.isEmpty else {
            isBusy = false
            return
        }
        isBusy = true
        let piece = queue.removeFirst()
        let mine = generation
        Task {
            let clip = await piece.clip?.value
            guard mine == generation else { return }
            if let clip, play(clip) {
                failures = 0
                usedServer = true
            } else {
                if piece.clip != nil { failures += 1 }
                usedServer = false
                // The iPhone's voice can't giggle: it would read the mark out. A piece that was only a sound is skipped.
                let words = SpokenText.withoutSounds(piece.text)
                if words.contains(where: { $0.isLetter || $0.isNumber }) { speak(words) } else { next() }
            }
        }
    }

    private func play(_ clip: SpeechClip) -> Bool {
        let hint: String? = switch clip.kind {
        case .wav: AVFileType.wav.rawValue
        case .mp3: AVFileType.mp3.rawValue
        case .m4a: AVFileType.m4a.rawValue
        case .aac, .flac: nil
        }
        guard let p = try? AVAudioPlayer(data: clip.data, fileTypeHint: hint) else { return false }
        p.delegate = self
        p.isMeteringEnabled = true
        guard p.prepareToPlay(), p.play() else { return false }
        player = p
        return true
    }

    /// The iPhone's own voice: the best one installed for the language, a little slower and lower than its default.
    private func speak(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.localVoice(language)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        u.pitchMultiplier = 0.95
        u.postUtteranceDelay = 0.05
        utterance = u
        synth.speak(u)
    }

    /// Premium before Enhanced before the compact voice (Settings → Accessibility → Spoken Content → Voices loads the
    /// better ones), a woman's voice first, the exact region first.
    static func localVoice(_ language: String) -> AVSpeechSynthesisVoice? {
        let base = String(language.prefix(2)).lowercased()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().hasPrefix(base) && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            v.quality.rawValue * 100 + (v.gender == .female ? 10 : 0) + (v.language.lowercased() == language.lowercased() ? 1 : 0)
        }
        return voices.max { score($0) < score($1) } ?? AVSpeechSynthesisVoice(language: language)
    }

    private func finished(player id: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == id else { return }
        self.player = nil
        next()
    }

    private func finished(utterance id: ObjectIdentifier) {
        guard let utterance, ObjectIdentifier(utterance) == id else { return }
        self.utterance = nil
        next()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.finished(player: id) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.finished(player: id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(utterance: id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(utterance: id) }
    }
}

/// One live conversation: from the tap on the waveform button until End. Listens, sends what was said as a chat
/// message (`voice` true) once the owner pauses, says the reply as it arrives in the chat, then listens again.
@MainActor @Observable
final class LiveTalkSession {
    /// Why the conversation can't start.
    enum Blocker: Equatable, Sendable {
        case microphone, speech
        case unavailable(String)
    }

    private(set) var talk = LiveTalk()
    private(set) var blocker: Blocker?
    /// The microphone's loudness, 0…1.
    private(set) var micLevel: Float = 0
    /// A quiet line under the caption: why something didn't work ("Not sent: …").
    private(set) var note: String?
    private(set) var started = false

    @ObservationIgnored private let chat: ChatModel
    @ObservationIgnored private let listener = SpeechListener()
    @ObservationIgnored private let voice = SpeechVoice()
    @ObservationIgnored private var locale = Locale.current
    /// Sends the words as a chat message; false = it failed.
    @ObservationIgnored private var send: (String) async -> Bool = { _ in false }
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var interruptions: Task<Void, Never>?
    @ObservationIgnored private var listening = false
    /// This turn's words across the recognizer's restarts and new starts.
    @ObservationIgnored private var words = HeardText()
    /// `end` was called (the screen closed), perhaps while `start` was still asking for the microphone.
    @ObservationIgnored private var ended = false
    @ObservationIgnored private var listenFailures = 0

    init(chat: ChatModel) {
        self.chat = chat
    }

    var voiceLevel: Float { voice.level }
    /// The reply is in the server's voice (false: the iPhone's own).
    var serverVoice: Bool { voice.usedServer }

    func start(locale: Locale, speech: (@Sendable (String) async throws -> SpeechClip)?,
               send: @escaping (String) async -> Bool) async {
        guard !started else { return }
        self.locale = locale
        self.send = send
        voice.fetch = speech
        voice.language = locale.identifier(.bcp47)
        if let blocker = await SpeechListener.permissions() {
            self.blocker = blocker
            return
        }
        // Closed while the iPhone was asking: nothing may start listening now.
        guard !ended, !Task.isCancelled else { return }
        do {
            // Play and record, but never the hands-free Bluetooth profile: headphones keep their full quality and
            // the iPhone's own microphone listens.
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay])
            try audio.setActive(true)
        } catch {
            blocker = .unavailable(error.localizedDescription)
            return
        }
        started = true
        chat.live = true
        UIApplication.shared.isIdleTimerDisabled = true
        talk = LiveTalk()
        sync()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                self?.tick()
            }
        }
        interruptions = Task { [weak self] in
            // A call, an alarm, Siri: stop and wait for a tap.
            for await note in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
                if began { self?.mute() }
            }
        }
    }

    func end() {
        ended = true
        ticker?.cancel()
        interruptions?.cancel()
        ticker = nil
        interruptions = nil
        listener.stop()
        listening = false
        voice.stop()
        chat.live = false
        guard started else { return }
        started = false
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The orb: a tap interrupts the agent, or wakes a paused conversation.
    func tap() {
        switch talk.phase {
        case .thinking, .speaking:
            voice.stop()
            talk.interrupt()
        case .paused:
            try? AVAudioSession.sharedInstance().setActive(true)
            listenFailures = 0
            note = nil
            talk.resume()
        case .listening:
            return
        }
        sync()
    }

    func toggleMute() {
        if talk.phase == .paused { tap() } else { mute() }
    }

    private func mute() {
        voice.stop()
        talk.pause()
        sync()
    }

    private func tick() {
        let now = Date()
        switch talk.phase {
        case .listening:
            if let words = talk.ready(now: now) {
                submit(words)
            } else if talk.isIdle(now: now) {
                note = String(localized: "Paused after two quiet minutes.")
                talk.pause()
            }
        case .thinking, .speaking:
            for piece in talk.update(messages: chat.timeline.messages, working: chat.timeline.isWorking, now: now) {
                voice.say(piece)
            }
            if talk.phase == .speaking, !voice.isBusy { talk.voiceIdle(now: now) }
        case .paused:
            break
        }
        sync()
    }

    private func submit(_ words: String) {
        // The reply is whatever the agent says after the newest message the chat has now.
        talk.sent(after: chat.timeline.messages.last?.id ?? 0)
        note = nil
        Task {
            guard await send(words) else {
                note = String(localized: "Not sent. Say it again.")
                talk.sendFailed()
                sync()
                return
            }
        }
    }

    /// Makes the microphone match the phase: open while listening, closed otherwise.
    private func sync() {
        let wanted = started && talk.phase == .listening
        guard wanted != listening else { return }
        listening = wanted
        micLevel = 0
        guard wanted else {
            listener.stop()
            return
        }
        words = HeardText()
        open()
    }

    private func open() {
        do {
            try listener.start(locale: locale, heard: { [weak self] text in
                Task { @MainActor in self?.heard(text) }
            }, level: { [weak self] level in
                Task { @MainActor in self?.meter(level) }
            }, ended: { [weak self] reason in
                Task { @MainActor in self?.listenerEnded(reason) }
            })
        } catch {
            listening = false
            note = Self.words(for: error)
            talk.pause()
        }
    }

    /// Rises at once, falls slowly: the circle follows the voice without flickering.
    private func meter(_ level: Float) {
        guard listening else { return }
        let next = max(level, micLevel * 0.85)
        if abs(next - micLevel) > 0.01 { micLevel = next }
    }

    private func heard(_ text: String) {
        guard listening else { return }
        listenFailures = 0
        talk.hear(words.take(text))
    }

    /// The recognizer stopped by itself (its time limit, a hiccup, "no speech"): open it again and keep what was
    /// heard. Five times in a row without a word: pause and say why.
    private func listenerEnded(_ reason: String?) {
        guard listening, talk.phase == .listening else { return }
        listenFailures += 1
        if listenFailures > 5 {
            listening = false
            listener.stop()
            note = reason ?? String(localized: "The microphone stopped.")
            talk.pause()
            return
        }
        words.newSegment()
        open()
    }

    private static func words(for error: any Error) -> String {
        switch error as? SpeechListener.Problem {
        case .noRecognizer: String(localized: "This language can't be recognised on this iPhone.")
        case .notAvailable: String(localized: "Speech recognition isn't available right now.")
        case .noMicrophone: String(localized: "No microphone.")
        case nil: error.localizedDescription
        }
    }
}
