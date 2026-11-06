import HomelabDesign
import HomelabKit
import SwiftUI

/// Proposed actions waiting for the owner: approve once, always, or deny.
struct ActionsView: View {
    let model: AppModel
    @State private var confirm: Confirmation?
    @State private var running: Set<String> = []
    @State private var result: ResultMessage?
    /// The last button's outcome, for the haptic: success when it ran, an error buzz when it didn't.
    @State private var outcome: Outcome?

    struct Outcome: Equatable {
        let id = UUID()
        let ok: Bool
    }

    struct Confirmation: Identifiable {
        let action: PendingAction
        let verb: PendingAction.Verb
        var id: String { action.id + verb.rawValue }
    }

    struct ResultMessage: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    private var pending: [PendingAction] { model.selectedStatus.snapshot?.state.pending ?? [] }

    var body: some View {
        NavigationStack {
            List {
                if let error = model.selectedStatus.error {
                    ErrorBanner(error: error, snapshotAge: model.selectedStatus.snapshot?.fetched) {
                        Task { await model.refresh() }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }
                ForEach(pending) { action in
                    ActionRow(action: action, running: running.contains(action.id),
                              hasChat: model.selectedStatus.features.contains(.chat)) { verb in
                        confirm = Confirmation(action: action, verb: verb)
                    }
                }
            }
            .overlay {
                if model.selectedStatus.snapshot == nil && model.selectedStatus.error == nil {
                    ProgressView("Loading…")
                } else if pending.isEmpty && model.selectedStatus.snapshot != nil {
                    Placeholder(title: "Nothing to approve", symbol: "checkmark.shield",
                                message: Voice.line(.nothingToApprove, model.settings.voice)
                                    .map { LocalizedStringKey($0 + " " + String(localized: "When your homelab proposes an action, it shows up here.")) }
                                    ?? "When your homelab proposes an action, it shows up here.")
                }
            }
            .animation(.snappy, value: pending.map(\.id))
            .sensoryFeedback(trigger: outcome) { _, new in new.map { $0.ok ? .success : .error } }
            .refreshable { await model.refresh() }
            .navigationTitle("Actions")
            .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                                titleVisibility: .visible, presenting: confirm) { c in
                Button(buttonTitle(c.verb), role: c.verb == .deny ? .destructive : nil) { Task { await press(c) } }
                Button("Cancel", role: .cancel) {}
            } message: { c in
                Text(confirmMessage(c))
            }
            .alert(item: $result) { r in
                Alert(title: Text(r.title), message: Text(r.text), dismissButton: .default(Text("OK")))
            }
            .task { await model.refresh() }
        }
    }

    private var confirmTitle: String {
        guard let c = confirm else { return "" }
        return c.action.title
    }

    private func buttonTitle(_ verb: PendingAction.Verb) -> String {
        switch verb {
        case .approve: String(localized: "Run once")
        case .always: String(localized: "Run and always allow")
        case .deny: String(localized: "Deny")
        }
    }

    private func confirmMessage(_ c: Confirmation) -> String {
        switch c.verb {
        case .approve: String(localized: "Runs this action now, one time.")
        case .always:
            model.selectedStatus.info?.standingApprovals == true
                ? String(localized: "Runs it now, and lets this kind of action run by itself from now on. The server can take that back (for example /never in the chat).")
                : String(localized: "Runs it now. Whether it may run by itself later is up to the server.")
        case .deny: String(localized: "Drops the proposal. Nothing runs.")
        }
    }

    private func press(_ c: Confirmation) async {
        guard let server = model.selected, let button = c.action.buttons[c.verb] else { return }
        running.insert(c.action.id)
        let r = await model.press(button, on: server)
        running.remove(c.action.id)
        outcome = Outcome(ok: (try? r.get()) != nil)
        switch r {
        case .success(let text): result = ResultMessage(title: c.action.title, text: text)
        case .failure(let e):
            result = ResultMessage(title: String(localized: "Didn't work"),
                                   text: e.isForbidden ? String(localized: "This button is no longer valid (already handled or expired).") : e.message)
        }
    }
}

struct ActionRow: View {
    let action: PendingAction
    let running: Bool
    let hasChat: Bool
    let tap: (PendingAction.Verb) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(action.title).font(Typo.mono(.headline, weight: .semibold))
                Spacer()
                if let created = action.created { Text(Format.age(created)).font(Typo.mono(.caption2)).foregroundStyle(Palette.tertiary) }
            }
            if let reason = action.reason { Text(markdown(reason)).font(.subheadline).foregroundStyle(.secondary) }
            HStack(spacing: 6) {
                if let job = action.job { Chip(job, symbol: "gearshape.2") }
                Chip(action.id, symbol: "number")
            }
            if running {
                HStack { ProgressView(); Text("Running…").font(.subheadline).foregroundStyle(.secondary) }
            } else if action.buttons.isEmpty {
                Text(hasChat ? "The server offers no buttons for this action. Answer it in the chat."
                             : "The server offers no buttons for this action.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // Labels never wrap ("Ap-prove"); with very large text the row stacks instead.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { buttons(spacer: true) }
                    VStack(alignment: .leading, spacing: 8) { buttons(spacer: false) }
                }
                .controlSize(.regular)
            }
        }
        .padding(.vertical, 6)
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
