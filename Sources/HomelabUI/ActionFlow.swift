import HomelabDesign
import HomelabKit
import SwiftUI

// What the Actions tab, chat bubbles and cards share when an action runs: the proposal buttons with their confirm
// step, and the answer (a haptic and an alert).

/// The last press or start, for the haptic (`Motion.haptic`): success when it ran, an error buzz when it didn't.
struct ActionOutcome: Equatable {
    /// How a press that went through feels: `success` for something that runs (Approve, a started action),
    /// `selection` for a small one (a tick-off, a Deny).
    enum Feel: Equatable { case success, selection }

    let id = UUID()
    let ok: Bool
    var feel = Feel.success
}

/// An answer to show in an alert. The words come from `ActionReport` (HomelabKit, tested); these build it for each
/// place an action runs from.
struct ResultMessage: Identifiable {
    let id = UUID()
    let title: String
    let text: String

    init(_ report: ActionReport) {
        title = report.title
        text = report.text
    }

    /// A started action's answer (Actions tab, a card's form or tick-off): its label and the server's text, or why
    /// it didn't run.
    @MainActor static func started(_ spec: ActionSpec, _ r: Result<ActionResult, APIError>, model: AppModel) -> (ok: Bool, message: ResultMessage) {
        let report = ActionReport.started(spec.label, r, hasChat: model.hasChat)
        return (report.ok, ResultMessage(report.voiced(model.settings.voice)))
    }

    /// A container restart from Lab.
    @MainActor static func restart(_ container: String, _ r: Result<ActionResult, APIError>, model: AppModel) -> (ok: Bool, message: ResultMessage) {
        let report = ActionReport.restart(container, r, hasChat: model.hasChat)
        return (report.ok, ResultMessage(report.voiced(model.settings.voice)))
    }

    /// A proposal's button.
    @MainActor static func pressed(_ title: String, _ r: Result<String, APIError>, model: AppModel) -> (ok: Bool, message: ResultMessage) {
        let report = ActionReport.pressed(title, r, hasChat: model.hasChat)
        return (report.ok, ResultMessage(report.voiced(model.settings.voice)))
    }
}

extension AppModel {
    /// The selected server has a chat to look in after an unclear result.
    var hasChat: Bool { selectedStatus.features.contains(.chat) }
}

extension View {
    /// The answer to a pressed or started action: its haptic (`Motion.haptic`), and its text in an alert.
    func actionFeedback(result: Binding<ResultMessage?>, outcome: ActionOutcome?) -> some View {
        sensoryFeedback(trigger: outcome) { _, new in new.map(Motion.haptic) }
            .alert(item: result) { r in
                Alert(title: Text(r.title), message: Text(r.text), dismissButton: .default(Text("OK")))
            }
    }

    /// The confirm step for a proposal's buttons and the press after it, with the same words everywhere. The
    /// proposals being sent are `AppModel.proposalsSending`; `done` gets the outcome (a Deny feels lighter than an
    /// Approve).
    func proposalDialog(_ confirm: Binding<ProposalConfirmation?>, model: AppModel,
                        done: @escaping (_ outcome: ActionOutcome, _ message: ResultMessage) -> Void) -> some View {
        modifier(ProposalDialog(confirm: confirm, model: model, done: done))
    }
}

/// Which proposal button waits for its confirm.
struct ProposalConfirmation: Identifiable {
    let action: PendingAction
    let verb: PendingAction.Verb
    var id: String { action.id + verb.rawValue }
}

struct ProposalDialog: ViewModifier {
    @Binding var confirm: ProposalConfirmation?
    let model: AppModel
    let done: (_ outcome: ActionOutcome, _ message: ResultMessage) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(confirm?.action.title ?? "",
                                   isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                                   titleVisibility: .visible, presenting: confirm) { c in
            Button(buttonTitle(c.verb), role: c.verb == .deny ? .destructive : nil) { Task { await press(c) } }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text(message(c))
        }
    }

    private func buttonTitle(_ verb: PendingAction.Verb) -> String {
        switch verb {
        case .approve: String(localized: "Run once")
        case .always: String(localized: "Run and always allow")
        case .deny: String(localized: "Deny")
        }
    }

    private func message(_ c: ProposalConfirmation) -> String {
        switch c.verb {
        case .approve: String(localized: "Runs this action now, one time.")
        case .always:
            model.selectedStatus.info?.standingApprovals == true
                ? String(localized: "Runs it now, and lets this kind of action run by itself from now on. The server can take that back (for example /never in the chat).")
                : String(localized: "Runs it now. Whether it may run by itself later is up to the server.")
        case .deny: String(localized: "Drops the proposal. Nothing runs.")
        }
    }

    private func press(_ c: ProposalConfirmation) async {
        guard let server = model.selected, let button = c.action.buttons[c.verb],
              let r = await model.press(button, proposal: c.action.id, on: server) else { return }
        let (ok, message) = ResultMessage.pressed(c.action.title, r, model: model)
        done(ActionOutcome(ok: ok, feel: c.verb == .deny ? .selection : .success), message)
    }
}

/// One proposal as a row (docs/DESIGN.md §6): the gold shield (it waits for you) · what it runs 17 semibold · why
/// 15 secondary · its age on the right · then Approve / Always / Deny inline. `compact` (a chat bubble, whose
/// message already says why): the title and the buttons only.
struct ProposalRow: View {
    let action: PendingAction
    let running: Bool
    let hasChat: Bool
    var compact = false
    let tap: (PendingAction.Verb) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var stacked: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        glyph
                        Text(action.title).font(Typo.headline).foregroundStyle(Palette.text)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("Proposed: \(action.title)"))
                    controls
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    glyph
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(action.title).font(Typo.headline).foregroundStyle(Palette.text)
                            Spacer(minLength: 8)
                            // How long ago, and under it the clock time ("21:03", "Thu 21:03").
                            if !stacked, let created = action.created {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(Format.age(created))
                                    Text(Format.clock(created)).monospacedDigit()
                                }
                                .font(Typo.meta).foregroundStyle(Palette.tertiary)
                                .lineLimit(1)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text("\(Format.spokenAge(created)), at \(Format.clock(created))"))
                            }
                        }
                        // The whole reason: this is where the owner decides, so nothing is cut off.
                        if let reason = action.reason {
                            Text(markdown(reason)).tint(Palette.iris).font(Typo.secondary).foregroundStyle(Palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        meta
                        controls.padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .rowMotion(running)
    }

    private var glyph: some View {
        Image(systemName: "checkmark.shield").font(Typo.body).foregroundStyle(Palette.gold).accessibilityHidden(true)
    }

    @ViewBuilder private var controls: some View {
        if running {
            HStack(spacing: 8) {
                ProgressView()
                Text("Running…").font(compact ? Typo.meta : Typo.secondary).foregroundStyle(Palette.secondary)
            }
            .transition(.opacity)
        } else if action.buttons.isEmpty {
            Text(hasChat ? "The server offers no buttons for this action. Answer it in the chat."
                         : "The server offers no buttons for this action.")
                .font(Typo.meta).foregroundStyle(compact ? Palette.secondary : Palette.tertiary)
        } else {
            ProposalButtons(action: action, tap: tap).transition(.opacity)
        }
    }

    /// Job and id as one quiet line in the text font; the age and clock time too when they can't sit on the right.
    @ViewBuilder private var meta: some View {
        let parts = [action.job.map { Text($0) },
                     Text(action.id),
                     stacked ? action.created.map { Text(Format.age($0) + " · " + Format.clock($0)) } : nil].compactMap { $0 }
        if !parts.isEmpty {
            parts.dropFirst().reduce(parts[0]) { $0 + Text(" · ") + $1 }
                .font(Typo.meta).foregroundStyle(Palette.tertiary)
        }
    }
}

/// Approve, Always and Deny for one proposal, as far as the server signed them: Approve a filled white capsule,
/// Always a raised one, Deny plain text, so only one thing is loud. The same size in a chat bubble (a 44 pt hit area
/// everywhere). Labels never wrap ("Ap-prove"); with very large text the buttons stack instead.
struct ProposalButtons: View {
    let action: PendingAction
    let tap: (PendingAction.Verb) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons(spacer: true) }
            VStack(alignment: .leading, spacing: 4) { buttons(spacer: false) }
        }
    }

    @ViewBuilder
    private func buttons(spacer: Bool) -> some View {
        if action.buttons[.approve] != nil {
            Button("Approve") { tap(.approve) }
                .buttonStyle(CapsuleButtonStyle(kind: .filled))
        }
        if action.buttons[.always] != nil {
            Button("Always") { tap(.always) }
                .buttonStyle(CapsuleButtonStyle(kind: .raised))
        }
        if spacer { Spacer(minLength: 8) }
        if action.buttons[.deny] != nil {
            // Destructive for VoiceOver and the confirm; drawn as quiet text, so the two others stay the loud ones.
            Button("Deny", role: .destructive) { tap(.deny) }
                .buttonStyle(CapsuleButtonStyle(kind: .text))
        }
    }
}

/// The app's buttons inside rows and cards: a filled white capsule (the one primary action), a `raised` capsule
/// (Always, + Add, Delivered, Request), or plain secondary text (Deny, Clear). 15 semibold; the hit area is at least
/// 44 x 44 pt around the visible shape. One line, unless `wraps` (a narrow poster column at large text sizes: two
/// lines instead of running out of its column). Gives way under the finger like `.press`.
struct CapsuleButtonStyle: ButtonStyle {
    enum Kind { case filled, raised, text }

    let kind: Kind
    var wraps = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.secondary.weight(.semibold))
            .lineLimit(wraps ? 2 : 1)
            .multilineTextAlignment(.center)
            .foregroundStyle(kind == .filled ? Palette.onAccent : kind == .raised ? Palette.text : Palette.secondary)
            .padding(.horizontal, kind == .text ? 4 : wraps ? 12 : 16)
            .padding(.vertical, 8)
            .background {
                switch kind {
                case .filled: Capsule().fill(Palette.text)
                case .raised: Capsule().fill(Palette.raised)
                case .text: EmptyView()
                }
            }
            .frame(minWidth: 44, minHeight: 44)   // the hit area grows, not the capsule
            .contentShape(Rectangle())
            .fixedSize(horizontal: !wraps, vertical: true)
            .modifier(PressFeel(pressed: configuration.isPressed))
    }
}

/// The confirm text before something runs, the same for a form and a card's item action: the action's own label
/// (from the server's /actions, not the card's button text), what it will send with its visible values, and where.
func confirmText(_ form: ActionForm, server: String, label: String? = nil) -> String {
    let lines = (label.map { [$0] } ?? []) + form.summary.map { $0.label.isEmpty ? $0.value : "\($0.label): \($0.value)" }
    let what = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n\n"
    return what + String(localized: "Runs at once on \(server).")
}
