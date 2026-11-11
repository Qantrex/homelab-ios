import HomelabDesign
import HomelabKit
import SwiftUI
import UIKit

/// The chat's live conversation, over the chat: one circle that follows the voice that has the turn (the owner's
/// while it listens, the agent's while it speaks), what was heard and what is said under it, and two buttons (mute,
/// end). A tap on the circle interrupts the agent. Everything said and answered is in the chat afterwards.
struct LiveTalkView: View {
    let model: AppModel
    let chat: ChatModel
    @State private var session: LiveTalkSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .body) private var buttonSize: CGFloat = 60

    init(model: AppModel, chat: ChatModel) {
        self.model = model
        self.chat = chat
        _session = State(initialValue: LiveTalkSession(chat: chat))
    }

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            if let blocker = session.blocker {
                blocked(blocker)
            } else {
                conversation
            }
        }
        .task { await start() }
        .onDisappear { session.end() }
        // Never listens or talks from the background. Only `.background`: the permission questions and Control Centre
        // make the app inactive for a moment, and that must not end the conversation.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { dismiss() }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: session.talk.phase == .listening)
        .statusBarHidden()
    }

    private func start() async {
        guard let server = model.selected else { return dismiss() }
        let api = model.companion(for: server)
        let locale = model.settings.liveLang.locale.map(Locale.init(identifier:)) ?? Locale.current
        // The server's own voice when it has one; else the iPhone's.
        let speech: (@Sendable (String) async throws -> SpeechClip)? =
            model.selectedStatus.features.contains(.speech) ? { @Sendable text in try await api.speech(text) } : nil
        await session.start(locale: locale, speech: speech) { [chat] words in
            await chat.send(words, voice: true, api: api, host: server.host)
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Button { session.tap() } label: {
                LiveOrb(phase: session.talk.phase, micLevel: session.micLevel) { session.voiceLevel }
                    .frame(width: 220, height: 220)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(caption))
            .accessibilityHint(orbHint)
            Text(caption)
                .font(Typo.secondary)
                .foregroundStyle(Palette.secondary)
                .padding(.top, 20)
            if let note = session.note {
                Text(verbatim: note)
                    .font(Typo.meta)
                    .foregroundStyle(Palette.gold)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
            Spacer(minLength: 16)
            words
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .bottom)
                .padding(.horizontal, 24)
            if session.talk.needsApproval {
                Button("Needs your approval · Open the chat") { dismiss() }
                    .font(Typo.secondary.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .padding(.top, 8)
            }
            controls
                .padding(.top, 24)
                .padding(.bottom, 16)
        }
    }

    private var caption: LocalizedStringKey {
        switch session.talk.phase {
        case .listening: session.started ? "Listening" : "Starting…"
        case .thinking: "Thinking…"
        case .speaking: "Tap to interrupt"
        case .paused: "Paused · Tap to talk"
        }
    }

    private var orbHint: Text {
        switch session.talk.phase {
        case .thinking, .speaking: Text("Stops the answer and listens again")
        case .paused: Text("Opens the microphone again")
        case .listening: Text("Just talk. Your words are sent when you pause.")
        }
    }

    /// While listening: what was understood so far. Afterwards: what was said (quiet) and the answer as it is spoken,
    /// its newest lines.
    @ViewBuilder
    private var words: some View {
        let talk = session.talk
        VStack(spacing: 10) {
            if talk.phase == .listening || talk.phase == .paused {
                if !talk.heard.isEmpty {
                    Text(verbatim: talk.heard)
                        .font(Typo.body)
                        .foregroundStyle(Palette.text)
                        .lineLimit(5)
                        .truncationMode(.head)
                } else if !talk.reply.isEmpty {
                    Text(verbatim: SpokenText.withoutSounds(SpokenText.clean(talk.reply)))
                        .font(Typo.body)
                        .foregroundStyle(Palette.tertiary)
                        .lineLimit(4)
                        .truncationMode(.head)
                }
            } else {
                Text(verbatim: talk.said)
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(2)
                    .truncationMode(.head)
                if !talk.reply.isEmpty {
                    Text(verbatim: SpokenText.withoutSounds(SpokenText.clean(talk.reply)))
                        .font(Typo.body)
                        .foregroundStyle(Palette.text)
                        .lineLimit(6)
                        .truncationMode(.head)
                }
            }
        }
        .multilineTextAlignment(.center)
        .animation(.easeOut(duration: 0.15), value: talk.phase)
    }

    private var controls: some View {
        HStack(spacing: 40) {
            let muted = session.talk.phase == .paused
            Button { session.toggleMute() } label: {
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(muted ? Palette.onAccent : Palette.text)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(muted ? Palette.text : Palette.raised, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(muted ? Text("Unmute") : Text("Mute"))
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(Palette.raised, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("End the conversation"))
        }
    }

    private func blocked(_ blocker: LiveTalkSession.Blocker) -> some View {
        VStack(spacing: 16) {
            switch blocker {
            case .microphone:
                Placeholder(title: "No microphone access", symbol: "mic.slash",
                            message: "Allow the microphone for Homelab in the iPhone's Settings to talk to your homelab.")
            case .speech:
                Placeholder(title: "No speech recognition", symbol: "waveform.slash",
                            message: "Allow Speech Recognition for Homelab in the iPhone's Settings to talk to your homelab.")
            case .unavailable(let why):
                Placeholder(title: "Can't start", symbol: "waveform.slash", message: LocalizedStringKey(why))
            }
            if blocker == .microphone || blocker == .speech, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { openURL(url) }
                    .font(Typo.headline)
                    .foregroundStyle(Palette.text)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
            }
            Button("Close") { dismiss() }
                .font(Typo.secondary.weight(.semibold))
                .foregroundStyle(Palette.secondary)
                .buttonStyle(.plain)
                .frame(minHeight: 44)
        }
        .padding(24)
    }
}

/// The circle: it swells with the owner's voice while listening and with the agent's while speaking, breathes slowly
/// while the agent thinks, and is a quiet ring while paused. With Reduce Motion it keeps its size and only its
/// brightness changes.
struct LiveOrb: View {
    let phase: LiveTalk.Phase
    let micLevel: Float
    /// Read on every frame while the agent speaks.
    let voiceLevel: () -> Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: phase == .paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = Double(target(t))
            Canvas { canvas, size in
                let side = min(size.width, size.height)
                let base = side * 0.52
                let d = reduceMotion ? base : base * (1 + 0.55 * level)
                let rect = CGRect(x: (size.width - d) / 2, y: (size.height - d) / 2, width: d, height: d)
                if phase == .paused {
                    canvas.stroke(Path(ellipseIn: rect), with: .color(Palette.tertiary), lineWidth: 2)
                } else {
                    // A soft halo one step out, then the circle itself.
                    let halo = rect.insetBy(dx: -side * 0.07 * (0.4 + level), dy: -side * 0.07 * (0.4 + level))
                    canvas.fill(Path(ellipseIn: halo), with: .color(Palette.text.opacity(0.10 + 0.10 * level)))
                    canvas.fill(Path(ellipseIn: rect), with: .color(Palette.text.opacity(reduceMotion ? 0.55 + 0.45 * level : 1)))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// 0…1 for this frame.
    private func target(_ t: TimeInterval) -> Float {
        switch phase {
        case .listening: micLevel
        case .thinking: Float(0.25 + 0.2 * sin(t * 2.2))
        case .speaking: voiceLevel()
        case .paused: 0
        }
    }
}
