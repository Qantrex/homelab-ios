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

/// The agent's messages are plain full-width text (no bubble) with their job as a quiet line above; mine are bubbles
/// on the right. A time line only after a gap (`ChatTimeline.stamps`), long reports fold after 12 lines (`ChatFold`).
struct ChatView: View {
    let model: AppModel
    @State private var chat = ChatModel()
    @State private var draft = ""
    /// Bumped on every send, for a light tap.
    @State private var sent = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var focused: Bool
    /// The send circle, growing with the text size; its tap area is at least 44 pt.
    @ScaledMetric(relativeTo: .body) private var sendSize: CGFloat = 34
    /// Approve / Always / Deny in a message: the same confirm and press as the Actions tab.
    @State private var confirm: ProposalConfirmation?
    @State private var result: ResultMessage?
    @State private var outcome: ActionOutcome?

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
                // The composer is a bottom inset of the scroll view, so the last message's buttons stay above it.
                messages
                    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.impact(weight: .light), trigger: sent)
            .proposalDialog($confirm, model: model) { ok, message in
                outcome = ActionOutcome(ok: ok)
                result = message
            }
            .actionFeedback(result: $result, outcome: outcome)
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

    /// Space above a message: tight under the same sender, more where the speaker changes.
    private func gap(_ from: ChatMessage.Sender, after previous: ChatMessage.Sender?) -> CGFloat {
        guard let previous else { return 0 }
        return previous == from ? 12 : 20
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if chat.loadedOnce && chat.timeline.messages.isEmpty && chat.timeline.outgoing.isEmpty {
                        Placeholder(title: "No messages yet", symbol: "bubble.left.and.bubble.right", message: emptyMessage)
                            .padding(.top, 40)
                    }
                    let all = chat.timeline.messages
                    let stamps = chat.timeline.stamps()
                    ForEach(Array(all.enumerated()), id: \.element.id) { i, m in
                        VStack(spacing: 0) {
                            if let stamp = stamps[m.id] {
                                StampLine(stamp: stamp)
                                    .padding(.top, i == 0 ? 8 : 24)
                                    .padding(.bottom, 12)
                            }
                            if m.from == .me {
                                MyBubble(text: m.text, time: m.ts)
                            } else {
                                AgentMessage(message: m, pending: chat.timeline.openPending(m, in: model.selectedStatus.snapshot),
                                             running: model.proposalsSending, model: model) { p, verb in
                                    confirm = ProposalConfirmation(action: p, verb: verb)
                                }
                            }
                        }
                        .padding(.top, stamps[m.id] == nil ? gap(m.from, after: i > 0 ? all[i - 1].from : nil) : 0)
                        .id("m\(m.id)")
                    }
                    ForEach(Array(chat.timeline.outgoing.enumerated()), id: \.element.id) { i, o in
                        OutgoingBubble(outgoing: o) {
                            chat.timeline.discard(o.id)
                            draft = o.text
                        }
                        .padding(.top, gap(.me, after: i > 0 ? .me : all.last?.from))
                        .id("o\(o.id.uuidString)")
                    }
                    if chat.timeline.isWorking {
                        TypingIndicator()
                            .padding(.top, 16)
                            .id("working")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.timeline.messages.count + chat.timeline.outgoing.count) { _, _ in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            // VoiceOver hears what arrives: a new reply (shortened) and that the agent started working.
            .onChange(of: chat.timeline.cursor) { old, _ in
                guard old > 0, let reply = chat.timeline.messages.last(where: { $0.from == .agent && $0.id > old })
                else { return }
                AccessibilityNotification.Announcement(String(localized: "Agent: \(Self.short(spoken(reply.text)))")).post()
            }
            .onChange(of: chat.timeline.isWorking) { _, working in
                if working { AccessibilityNotification.Announcement(String(localized: "Working…")).post() }
            }
            // On open and when the first load lands: the bottom of the newest message, even if it is taller than the
            // screen. Twice, because lazy rows are measured while scrolling.
            .onAppear { scrollToEnd(proxy) }
            .onChange(of: chat.loadedOnce) { _, _ in scrollToEnd(proxy) }
            .onChange(of: focused) { _, _ in scrollToEnd(proxy) }
        }
    }

    /// The start of a reply for an announcement: up to 200 characters, cut at a word.
    static func short(_ text: String) -> String {
        guard text.count > 200 else { return text }
        let head = text.prefix(200)
        return String(head[..<(head.lastIndex(of: " ") ?? head.endIndex)]) + "…"
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        proxy.scrollTo("bottom", anchor: .bottom)
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    /// Quick commands as quiet capsules over the field; send is a white circle once there is something to send.
    private var composer: some View {
        VStack(spacing: 8) {
            if !quick.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quick, id: \.self) { cmd in
                            Button { submit(cmd) } label: {
                                Text(cmd)
                                    .font(Typo.data(.footnote))
                                    .foregroundStyle(Palette.secondary)
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 32)
                                    .background(Palette.raised, in: Capsule())
                                    .frame(minHeight: 44)   // a 32 pt pill, a 44 pt tap area
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(Text("Sends this command"))
                        }
                    }
                    .padding(.horizontal)
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Message", text: $draft, axis: .vertical)
                    .font(Typo.body)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        // Increase Contrast: the field gets a visible edge.
                        if contrast == .increased {
                            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.line, lineWidth: 1)
                        }
                    }
                    .submitLabel(.send)
                    .onSubmit { submit(draft) }
                Button {
                    submit(draft)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(canSend ? Palette.onAccent : Palette.tertiary)
                        .frame(width: sendSize, height: sendSize)
                        .background(canSend ? Palette.text : Palette.raised, in: Circle())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .animation(.easeOut(duration: 0.15), value: canSend)
                .accessibilityLabel(Text("Send"))
            }
            .padding(.leading)
            .padding(.trailing, 10)
            if trimmed.count > CompanionClient.maxMessageLength - 200 {
                Text("\(trimmed.count)/\(CompanionClient.maxMessageLength)")
                    .font(Typo.data(.footnote))
                    .foregroundStyle(trimmed.count > CompanionClient.maxMessageLength ? Palette.love : Palette.secondary)
            }
        }
        .padding(.vertical, 8)
        .background(Palette.background)
        .tint(Palette.accent)
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !trimmed.isEmpty && trimmed.count <= CompanionClient.maxMessageLength }

    private func submit(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= CompanionClient.maxMessageLength, let server = model.selected else { return }
        if text == draft { draft = "" }
        sent += 1
        Task { await chat.send(t, api: model.companion(for: server), host: server.host) }
    }
}

/// "Today 14:32" over the first message of a day, "14:32" after a gap: centred meta.
struct StampLine: View {
    let stamp: ChatTimeline.Stamp

    var body: some View {
        HStack(spacing: 4) {
            if let day = stamp.day { Text(verbatim: day) }
            Text(stamp.time, format: .dateTime.hour().minute()).font(Typo.data(.footnote))
        }
        .font(Typo.meta)
        .foregroundStyle(Palette.tertiary)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// What VoiceOver reads for a message: the text without Markdown marks.
private func spoken(_ text: String) -> String { String(markdown(text).characters) }

/// An agent message: a quiet job line for reports, the text full width, then its proposals and cards.
struct AgentMessage: View {
    let message: ChatMessage
    /// The message's proposals that are still open (`ChatTimeline.openPending`).
    var pending: [PendingAction] = []
    var running: Set<String> = []
    /// For the cards' actions; nil = cards only show.
    var model: AppModel?
    var tap: (PendingAction, PendingAction.Verb) -> Void = { _, _ in }

    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    /// One body line, for "fold after 12 lines" at every text size.
    @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = 22

    /// Only text: one VoiceOver element. With buttons or cards inside, each part is its own.
    private var plain: Bool { pending.isEmpty && message.cards.isEmpty }
    private var folds: Bool { ChatFold.folds(height: Double(fullHeight), lineHeight: Double(lineHeight)) }
    private var folded: Bool { folds && !expanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            tag
            VStack(alignment: .leading, spacing: 12) {
                text
                ForEach(pending) { proposal($0) }
                ForEach(message.cards) { CardView(card: $0, compact: true, model: model) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(BubbleAccessibility(plain: plain, label: label))
    }

    private var label: LocalizedStringKey {
        let job = message.isReport ? message.job.map { "\($0), " } ?? "" : ""
        let time = message.ts.map { $0.formatted(date: .omitted, time: .shortened) + ": " } ?? ""
        return "Agent, \(job)\(time)\(spoken(message.text))"
    }

    /// Above a report: its job, with a dot and the word only for a warning or alert ("watchdog · alert").
    @ViewBuilder
    private var tag: some View {
        if message.isReport, let job = message.job {
            HStack(spacing: 6) {
                if let level = flagged(message.status) {
                    Circle().fill(statusColor(message.status)).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text("\(job) · \(level)")
                } else {
                    Text(job)
                }
            }
            .font(Typo.meta)
            .foregroundStyle(Palette.tertiary)
        }
    }

    /// The text, cut to 12 lines with a fade and "Show more" when it is long.
    private var text: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChatText(message.text)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                .frame(height: folded ? CGFloat(ChatFold.foldedHeight(lineHeight: lineHeight)) : nil, alignment: .top)
                .clipped()
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0),
                                           .init(color: .black, location: folded ? 0.75 : 1),
                                           .init(color: folded ? .clear : .black, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .contextMenu {
                    Button { UIPasteboardBridge.copy(message.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
            if folds {
                Button(expanded ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
                }
                .font(Typo.secondary.weight(.semibold))
                .foregroundStyle(Palette.text)
                .buttonStyle(.plain)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
        }
    }

    /// "warning" or "alert" for the statuses that get a dot; nil for everything else.
    private func flagged(_ status: String?) -> String? {
        switch status?.uppercased() {
        case "WARN", "WARNING": String(localized: "warning")
        case "ALERT", "ERROR", "PROBLEM": String(localized: "alert")
        default: nil
        }
    }

    /// A proposal made in this message, as a panel: what it would run and its buttons (none without a hub token:
    /// then it's answered in the chat).
    private func proposal(_ p: PendingAction) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(Palette.gold).accessibilityHidden(true)
                Text(p.title).font(Typo.headline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Proposed: \(p.title)"))
            if running.contains(p.id) {
                HStack { ProgressView(); Text("Running…").font(Typo.meta).foregroundStyle(Palette.secondary) }
            } else if p.buttons.isEmpty {
                Text("The server offers no buttons for this action. Answer it in the chat.")
                    .font(Typo.meta).foregroundStyle(Palette.secondary)
            } else {
                ProposalButtons(action: p, compact: true) { tap(p, $0) }
            }
        }
        .panel()
    }
}

struct BubbleAccessibility: ViewModifier {
    let plain: Bool
    let label: LocalizedStringKey

    func body(content: Content) -> some View {
        if plain {
            content.accessibilityElement(children: .combine).accessibilityLabel(Text(label))
        } else {
            content.accessibilityElement(children: .contain)
        }
    }
}

/// My message: a `raised` bubble on the right.
struct MyBubble: View {
    let text: String
    var time: Date?
    var dimmed = false

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            ChatText(text, onBubble: true)
                .foregroundStyle(dimmed ? Palette.secondary : Palette.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Palette.raised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .contextMenu {
                    Button { UIPasteboardBridge.copy(text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("You, \(time.map { $0.formatted(date: .omitted, time: .shortened) + ": " } ?? "")\(spoken(text))"))
    }
}

/// A message I just sent, until the server's copy arrives: the same bubble, quieter, with how it's going under it.
struct OutgoingBubble: View {
    let outgoing: ChatTimeline.Outgoing
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            // Opaque in every state (readable contrast); a failure says so with the icon and words under it.
            MyBubble(text: outgoing.text, dimmed: !failed)
            Group {
                switch outgoing.state {
                case .sending:
                    Text("Sending…").font(Typo.meta).foregroundStyle(Palette.tertiary)
                case .sent:
                    Text("Sent").font(Typo.meta).foregroundStyle(Palette.tertiary)
                case .failed(let why):
                    Button(action: edit) {
                        Label("Not sent: \(why) Tap to edit.", systemImage: "exclamationmark.circle")
                            .font(Typo.meta)
                            .foregroundStyle(Palette.love)
                            .multilineTextAlignment(.trailing)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var failed: Bool {
        if case .failed = outgoing.state { return true }
        return false
    }
}

/// "The agent is working": three dots pulsing in turn where its answer will appear. Still with Reduce Motion.
struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Palette.secondary)
                        .frame(width: 7, height: 7)
                        .opacity(reduceMotion ? 0.6 : 0.25 + 0.75 * pulse(t, dot: i))
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel(Text("The agent is working"))
    }

    /// 0…1, each dot a fifth of a cycle after the one before.
    private func pulse(_ t: TimeInterval, dot: Int) -> Double {
        let phase = (t / 1.2 - Double(dot) * 0.2).truncatingRemainder(dividingBy: 1)
        return max(0, sin(phase * .pi))
    }
}

/// A message's Markdown (`ChatMarkdown.blocks`): paragraphs in the body font, lists with their markers, headings
/// in semibold, code in the data font on a `raised` run or block, links in iris.
struct ChatText: View {
    let blocks: [ChatMarkdown.Block]
    /// In my bubble (already `raised`): code runs sit on `line`.
    var onBubble = false

    init(_ text: String, onBubble: Bool = false) {
        blocks = ChatMarkdown.blocks(text)
        self.onBubble = onBubble
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                block(b)
                    .padding(.top, i == 0 ? 0 : spacing(before: b, after: blocks[i - 1]))
            }
        }
        .font(Typo.body)
        .tint(Palette.iris)
        .textSelection(.enabled)
    }

    /// List items sit close together; everything else gets a paragraph's gap.
    private func spacing(before b: ChatMarkdown.Block, after previous: ChatMarkdown.Block) -> CGFloat {
        isItem(b) && isItem(previous) ? 4 : 10
    }

    private func isItem(_ b: ChatMarkdown.Block) -> Bool {
        switch b {
        case .bullet, .numbered: true
        default: false
        }
    }

    @ViewBuilder
    private func block(_ b: ChatMarkdown.Block) -> some View {
        switch b {
        case .paragraph(let s):
            Text(inline(s))
        case .heading(let s, _):
            Text(inline(s)).font(Typo.headline).accessibilityAddTraits(.isHeader)
        case let .bullet(s, indent, checked):
            item(marker: checked.map { Text(Image(systemName: $0 ? "checkmark.square" : "square")) } ?? Text(verbatim: "•"),
                 s, indent: indent)
        case let .numbered(s, number, indent):
            item(marker: Text(verbatim: number + ".").monospacedDigit(), s, indent: indent)
        case .quote(let s):
            HStack(spacing: 10) {
                Capsule().fill(Palette.line).frame(width: 3)
                Text(inline(s)).foregroundStyle(Palette.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let s, _):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: s)
                    .font(Typo.data(.footnote))
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(onBubble ? Palette.line : Palette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .table(let rows):
            table(rows)
        case .rule:
            Rectangle().fill(Palette.line).frame(height: 1).padding(.vertical, 4).accessibilityHidden(true)
        }
    }

    private func item(marker: Text, _ s: String, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker
                .foregroundStyle(Palette.secondary)
                .frame(minWidth: 14, alignment: .leading)
            Text(inline(s))
        }
        .padding(.leading, CGFloat(indent) * 16)
    }

    private func table(_ rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { r, cells in
                    GridRow {
                        ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell))
                                .font(r == 0 ? Typo.meta.weight(.semibold) : Typo.secondary)
                                .foregroundStyle(r == 0 ? Palette.secondary : Palette.text)
                                .fixedSize()
                        }
                    }
                    if r == 0 {
                        Rectangle().fill(Palette.line).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(onBubble ? Palette.line : Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Inline Markdown (`markdown`), with code in the data font on a run of `raised` and links in iris.
    private func inline(_ s: String) -> AttributedString {
        var a = markdown(s)
        for run in a.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                a[run.range].font = Typo.data(.subheadline)
                a[run.range].backgroundColor = onBubble ? Palette.line : Palette.raised
            }
            if run.link != nil {
                a[run.range].foregroundColor = Palette.iris
            }
        }
        return a
    }
}
