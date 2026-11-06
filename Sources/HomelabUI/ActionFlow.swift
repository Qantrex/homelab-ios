import HomelabDesign
import HomelabKit
import SwiftUI

// What the Actions tab, chat bubbles and cards share when an action runs: the proposal buttons with their confirm
// step, and the answer (a haptic and an alert).

/// The last press or start, for the haptic: success when it ran, an error buzz when it didn't.
struct ActionOutcome: Equatable {
    let id = UUID()
    let ok: Bool
}

/// An answer to show in an alert.
struct ResultMessage: Identifiable {
    let id = UUID()
    let title: String
    let text: String

    /// A started action's answer: its title and the server's text, or why it didn't run.
    static func started(_ spec: ActionSpec, _ r: Result<ActionResult, APIError>) -> (ok: Bool, message: ResultMessage) {
        switch r {
        case .success(let res):
            (res.ok, ResultMessage(title: res.ok ? spec.label : String(localized: "\(spec.label) failed"), text: res.text))
        case .failure(let e):
            (false, ResultMessage(title: e.actionFailure.title, text: e.actionFailure.text))
        }
    }
}

extension View {
    /// The answer to a pressed or started action: a success or error haptic, and its text in an alert.
    func actionFeedback(result: Binding<ResultMessage?>, outcome: ActionOutcome?) -> some View {
        sensoryFeedback(trigger: outcome) { _, new in new.map { $0.ok ? .success : .error } }
            .alert(item: result) { r in
                Alert(title: Text(r.title), message: Text(r.text), dismissButton: .default(Text("OK")))
            }
    }

    /// The confirm step for a proposal's buttons and the press after it, with the same words everywhere. `running`
    /// holds the proposals being sent; `done` gets the outcome.
    func proposalDialog(_ confirm: Binding<ProposalConfirmation?>, running: Binding<Set<String>>, model: AppModel,
                        done: @escaping (_ ok: Bool, _ message: ResultMessage) -> Void) -> some View {
        modifier(ProposalDialog(confirm: confirm, running: running, model: model, done: done))
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
    @Binding var running: Set<String>
    let model: AppModel
    let done: (_ ok: Bool, _ message: ResultMessage) -> Void

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
        guard let server = model.selected, let button = c.action.buttons[c.verb] else { return }
        running.insert(c.action.id)
        let r = await model.press(button, on: server)
        running.remove(c.action.id)
        switch r {
        case .success(let text): done(true, ResultMessage(title: c.action.title, text: text))
        case .failure(let e) where e.isForbidden:
            done(false, ResultMessage(title: String(localized: "Didn't work"),
                                      text: String(localized: "This button is no longer valid (already handled or expired).")))
        case .failure(let e):
            done(false, ResultMessage(title: e.actionFailure.title, text: e.actionFailure.text))
        }
    }
}

/// Approve, Always and Deny for one proposal, as far as the server signed them. Labels never wrap ("Ap-prove"); with
/// very large text the buttons stack instead.
struct ProposalButtons: View {
    let action: PendingAction
    var compact = false
    let tap: (PendingAction.Verb) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons(spacer: true) }
            VStack(alignment: .leading, spacing: 8) { buttons(spacer: false) }
        }
        .controlSize(compact ? .small : .regular)
    }

    @ViewBuilder
    private func buttons(spacer: Bool) -> some View {
        if action.buttons[.approve] != nil {
            // A filled button keeps white text whatever its colour; ours is white (dark mode), so set the text colour.
            Button { tap(.approve) } label: { ButtonText(title: "Approve", symbol: "checkmark").foregroundStyle(Palette.onAccent) }
                .buttonStyle(.borderedProminent)
                .fixedSize()
        }
        if action.buttons[.always] != nil {
            Button { tap(.always) } label: { ButtonText(title: "Always", symbol: nil) }
                .buttonStyle(.bordered)
                .fixedSize()
        }
        if spacer { Spacer(minLength: 8) }
        if action.buttons[.deny] != nil {
            Button(role: .destructive) { tap(.deny) } label: { ButtonText(title: "Deny", symbol: "xmark") }
                .buttonStyle(.bordered)
                .tint(Palette.love)
                .fixedSize()
        }
    }
}

/// Icon + title for the action buttons. Not `Label`: in a fixed-size row inside a List, iOS showed Labels as
/// icon-only (a blank Approve button in CI screenshots, 2026-11-04).
struct ButtonText: View {
    let title: LocalizedStringKey
    let symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
            Text(title).lineLimit(1)
        }
    }
}
