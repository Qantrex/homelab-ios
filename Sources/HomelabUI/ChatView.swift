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
    private(set) var serverID: UUID?
    private var failures = 0

    func reset(for server: ServerConfig?) {
        guard server?.id != serverID else { return }
        serverID = server?.id
        timeline.reset()
        error = nil
        loadedOnce = false
        failures = 0
    }

    func load(_ api: any CompanionAPI, host: String) async {
        do {
            let page = try await api.messages(after: timeline.cursor)
            timeline.merge(page)
            error = nil
            failures = 0
        } catch {
            let e = APIError.from(error, host: host)
            if e != .cancelled {
                self.error = e
                failures += 1
            }
        }
        loadedOnce = true
    }

    func send(_ text: String, api: any CompanionAPI, host: String) async {
        let local = timeline.begin(text)
        do {
            let id = try await api.send(text)
            timeline.confirm(local, serverID: id)
            await load(api, host: host)
        } catch {
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
    @FocusState private var focused: Bool

    private static let quick = ["/pending", "/last", "/memory", "/usage", "/help"]

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
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: model.selected?.id) {
                chat.reset(for: model.selected)
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
                        Placeholder(title: "No messages yet", symbol: "bubble.left.and.bubble.right",
                                    message: "Ask your homelab anything, or try /help.")
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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.quick, id: \.self) { cmd in
                        Button(cmd) { submit(cmd) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .font(.caption.monospaced())
                    }
                }
                .padding(.horizontal)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
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
                    .foregroundStyle(trimmed.count > CompanionClient.maxMessageLength ? .red : .secondary)
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
                    .background(mine ? Color.accentColor : Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(mine ? Color.white : Color.primary)
                    .contextMenu {
                        Button { UIPasteboard.general.string = message.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                    }
                if let ts = message.ts {
                    Text(ts, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.secondary)
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
                    .background(Color.accentColor.opacity(failed ? 0.35 : 0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.white)
                switch outgoing.state {
                case .sending:
                    Text("Sending…").font(.caption2).foregroundStyle(.secondary)
                case .sent:
                    Text("Sent").font(.caption2).foregroundStyle(.secondary)
                case .failed(let why):
                    Button(action: edit) {
                        Label("Not sent: \(why) Tap to edit.", systemImage: "exclamationmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.red)
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
