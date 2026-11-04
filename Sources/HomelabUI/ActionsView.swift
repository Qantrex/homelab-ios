import HomelabDesign
import HomelabKit
import SwiftUI

/// Proposed actions waiting for the owner: approve once, always, or deny.
struct ActionsView: View {
    let model: AppModel
    @State private var confirm: Confirmation?
    @State private var running: String?
    @State private var result: ResultMessage?

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
                    ActionRow(action: action, running: running == action.id) { verb in
                        confirm = Confirmation(action: action, verb: verb)
                    }
                }
            }
            .overlay {
                if pending.isEmpty && model.selectedStatus.snapshot != nil {
                    Placeholder(title: "Nothing to approve", symbol: "checkmark.shield",
                                message: "When your homelab proposes an action, it shows up here.")
                }
            }
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
        case .always: String(localized: "Runs it now, and lets this kind of action run by itself from now on. You can take that back with /never in the chat.")
        case .deny: String(localized: "Drops the proposal. Nothing runs.")
        }
    }

    private func press(_ c: Confirmation) async {
        guard let server = model.selected, let button = c.action.buttons[c.verb] else { return }
        running = c.action.id
        let r = await model.press(button, on: server)
        running = nil
        switch r {
        case .success(let text): result = ResultMessage(title: c.action.title, text: text)
        case .failure(let e):
            result = ResultMessage(title: String(localized: "Didn't work"),
                                   text: e == .forbidden ? String(localized: "This button is no longer valid (already handled or expired).") : e.message)
        }
    }
}

struct ActionRow: View {
    let action: PendingAction
    let running: Bool
    let tap: (PendingAction.Verb) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(action.title).font(.headline)
                Spacer()
                if let created = action.created { Text(Format.age(created)).font(.caption).foregroundStyle(.secondary) }
            }
            if let reason = action.reason { Text(markdown(reason)).font(.subheadline).foregroundStyle(.secondary) }
            HStack(spacing: 6) {
                if let job = action.job { Chip(job, symbol: "gearshape.2") }
                Chip(action.id, symbol: "number")
            }
            if running {
                HStack { ProgressView(); Text("Running…").font(.subheadline).foregroundStyle(.secondary) }
            } else if action.buttons.isEmpty {
                Text("The server offers no buttons for this action. Use the chat: /approve \(action.id)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    if action.buttons[.approve] != nil {
                        Button { tap(.approve) } label: { Label("Approve", systemImage: "checkmark") }
                            .buttonStyle(.borderedProminent)
                    }
                    if action.buttons[.always] != nil {
                        Button { tap(.always) } label: { Text("Always") }
                            .buttonStyle(.bordered)
                    }
                    Spacer()
                    if action.buttons[.deny] != nil {
                        Button(role: .destructive) { tap(.deny) } label: { Label("Deny", systemImage: "xmark") }
                            .buttonStyle(.bordered)
                    }
                }
                .controlSize(.regular)
            }
        }
        .padding(.vertical, 6)
    }
}
