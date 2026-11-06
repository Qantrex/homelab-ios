import HomelabDesign
import HomelabKit
import SwiftUI
import UIKit

/// The chat with the homelab agent. Polls fast while the agent works, slowly otherwise, never in the background.
@MainActor @Observable
final class ChatModel {
    var timeline = ChatTimeline()
    var error: APIError?
    var loadedOnce = false
    private(set) var serverID: String?
    private var failures = 0
    /// Each load gets a number; an older load that finishes late doesn't overwrite a newer one.
    private var generation = 0
    /// Bumped after a send: restarts the poll loop so the fast "working" polling starts right away.
    var kick = 0

    func reset(for server: ServerConfig?) {
        guard server?.target != serverID else { return }
        serverID = server?.target
        timeline.reset()
        error = nil
        loadedOnce = false
        failures = 0
    }

    func load(_ api: any CompanionAPI, host: String) async {
        let sid = serverID
        generation += 1
        let mine = generation
        do {
            let page = try await api.messages(after: timeline.cursor)
            guard sid == serverID, mine == generation else { return }   // server switched, or a newer load ran
            timeline.merge(page)
            error = nil
            failures = 0
        } catch {
            guard sid == serverID else { return }
            let e = APIError.from(error, host: host)
            if e != .cancelled {
                self.error = e
                failures += 1
            }
        }
        loadedOnce = true
    }

    func send(_ text: String, api: any CompanionAPI, host: String) async {
        let sid = serverID
        let local = timeline.begin(text)
        do {
            let id = try await api.send(text)
            guard sid == serverID else { return }
            timeline.confirm(local, serverID: id)
            kick += 1   // restarts the poll loop: it loads at once and then polls fast while the agent works
        } catch {
            guard sid == serverID else { return }
            timeline.fail(local, message: APIError.from(error, host: host).message)
        }
    }

    var nextPoll: Duration {
        failures > 0 ? PollPolicy.backoff(failures: failures)
            : PollPolicy.chatInterval(working: timeline.isWorking, visible: true) ?? .seconds(15)
    }
}

struct ChatView: View {
    let model: AppModel
    @State private var chat = ChatModel()
    @State private var draft = ""
    /// Bumped on every send, for a light tap.
    @State private var sent = 0
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focused: Bool

    private var emptyMessage: LocalizedStringKey {
        let hint = quick.contains("/help") ? String(localized: "Ask your homelab anything, or try /help.")
                                           : String(localized: "Ask your homelab anything.")
        return LocalizedStringKey(Voice.line(.emptyChat, model.settings.voice).map { $0 + " " + hint } ?? hint)
    }

    /// Quick buttons: the commands the server says its chat understands (none = no button row).
    private var quick: [String] { model.selectedStatus.info?.commands ?? model.selectedStatus.snapshot?.info?.commands ?? [] }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = chat.error {
                    ErrorBanner(error: error, snapshotAge: nil) { Task { await load() } }
                        .padding(.horizontal)
                        .padding(.top, 6)
                }
                messages
                composer
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.impact(weight: .light), trigger: sent)
            // Restarts on server change and when the app comes back; stops while it's in the background.
            .task(id: PollKey(server: model.selected?.target, active: scenePhase == .active, kick: chat.kick)) {
                chat.reset(for: model.selected)
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: chat.nextPoll)
                }
            }
        }
    }

    private func load() async {
        guard let server = model.selected else { return }
        await chat.load(model.companion(for: server), host: server.host)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if chat.loadedOnce && chat.timeline.messages.isEmpty && chat.timeline.outgoing.isEmpty {
                        Placeholder(title: "No messages yet", symbol: "bubble.left.and.bubble.right", message: emptyMessage)
                            .padding(.top, 40)
                    }
                    ForEach(chat.timeline.messages) { m in
                        Bubble(message: m).id("m\(m.id)")
                    }
                    ForEach(chat.timeline.outgoing) { o in
                        OutgoingBubble(outgoing: o) {
                            chat.timeline.discard(o.id)
                            draft = o.text
                        }
                        .id("o\(o.id.uuidString)")
                    }
                    if chat.timeline.isWorking {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Working…").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .id("working")
                        .accessibilityLabel(Text("The agent is working"))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.timeline.messages.count + chat.timeline.outgoing.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if !quick.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(quick, id: \.self) { cmd in
                        Button(cmd) { submit(cmd) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .font(.caption.monospaced())
                    }
                }
                .padding(.horizontal)
            }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.line, lineWidth: 1))
                    .submitLabel(.send)
                    .onSubmit { submit(draft) }
                Button {
                    submit(draft)
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(trimmed.isEmpty || trimmed.count > CompanionClient.maxMessageLength)
                .accessibilityLabel(Text("Send"))
            }
            .padding(.horizontal)
            if trimmed.count > CompanionClient.maxMessageLength - 200 {
                Text("\(trimmed.count)/\(CompanionClient.maxMessageLength)")
                    .font(.caption2)
                    .foregroundStyle(trimmed.count > CompanionClient.maxMessageLength ? Palette.love : Palette.secondary)
            }
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func submit(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= CompanionClient.maxMessageLength, let server = model.selected else { return }
        if text == draft { draft = "" }
        sent += 1
        Task { await chat.send(t, api: model.companion(for: server), host: server.host) }
    }
}

struct Bubble: View {
    let message: ChatMessage

    var mine: Bool { message.from == .me }

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                if message.isReport, let job = message.job {
                    Chip(job, color: statusColor(message.status), symbol: "clock")
                }
                Text(markdown(message.text))
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(mine ? Palette.text : Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(mine ? Color.clear : Palette.line, lineWidth: 1))
                    .foregroundStyle(mine ? Palette.onAccent : Palette.text)
                    .contextMenu {
                        Button { UIPasteboardBridge.copy(message.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    }
                if let ts = message.ts {
                    Text(ts, format: .dateTime.hour().minute()).font(Typo.mono(.caption2)).foregroundStyle(Palette.tertiary)
                }
            }
            if !mine { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(mine ? "You: \(message.text)" : "Agent: \(message.text)"))
    }
}

struct OutgoingBubble: View {
    let outgoing: ChatTimeline.Outgoing
    let edit: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                Text(outgoing.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Palette.text.opacity(failed ? 0.35 : 0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(Palette.onAccent)
                switch outgoing.state {
                case .sending:
                    Text("Sending…").font(.caption2).foregroundStyle(.secondary)
                case .sent:
                    Text("Sent").font(.caption2).foregroundStyle(.secondary)
                case .failed(let why):
                    Button(action: edit) {
                        Label("Not sent: \(why) Tap to edit.", systemImage: "exclamationmark.circle")
                            .font(.caption2)
                            .foregroundStyle(Palette.love)
                            .multilineTextAlignment(.trailing)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var failed: Bool {
        if case .failed = outgoing.state { return true }
        return false
    }
}
