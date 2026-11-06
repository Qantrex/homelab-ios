import HomelabDesign
import HomelabKit
import SwiftUI

/// Actions I start myself ("Start", feature run-actions) and proposed actions waiting for me: approve once, always,
/// or deny.
struct ActionsView: View {
    let model: AppModel
    @State private var confirm: ProposalConfirmation?
    @State private var formFor: ActionSpec?
    /// A started action's result, shown once its form sheet is gone (an alert can't show over the sheet).
    @State private var afterSheet: ResultMessage?
    @State private var running: Set<String> = []
    @State private var result: ResultMessage?
    @State private var outcome: ActionOutcome?

    private var pending: [PendingAction] { model.selectedStatus.snapshot?.state.pending ?? [] }
    private var startable: [ActionSpec] {
        model.selectedStatus.features.contains(.runActions) ? model.selectedStatus.actions : []
    }
    private var approves: Bool { model.selectedStatus.features.contains(.actions) || startable.isEmpty }
    private var nothingToApprove: LocalizedStringKey {
        Voice.line(.nothingToApprove, model.settings.voice)
            .map { LocalizedStringKey($0 + " " + String(localized: "When your homelab proposes an action, it shows up here.")) }
            ?? "When your homelab proposes an action, it shows up here."
    }

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
                if !startable.isEmpty {
                    Section {
                        StartGrid(actions: startable) { formFor = $0 }
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                    } header: {
                        SectionTitle(text: "Start").textCase(nil)
                    }
                }
                if approves {
                    Section {
                        if pending.isEmpty, !startable.isEmpty, model.selectedStatus.snapshot != nil {
                            // With Start tiles above, the empty state is one quiet row, not a full-screen placeholder.
                            Label { Text(nothingToApprove).font(.subheadline).foregroundStyle(Palette.secondary) }
                                icon: { Image(systemName: "checkmark.shield").foregroundStyle(Palette.tertiary) }
                        }
                        ForEach(pending) { action in
                            ActionRow(action: action, running: running.contains(action.id),
                                      hasChat: model.selectedStatus.features.contains(.chat)) { verb in
                                confirm = ProposalConfirmation(action: action, verb: verb)
                            }
                        }
                    } header: {
                        if !startable.isEmpty {
                            SectionTitle(text: "To approve", trailing: pending.isEmpty ? nil : "\(pending.count)").textCase(nil)
                        }
                    }
                }
            }
            .overlay {
                if model.selectedStatus.snapshot == nil && model.selectedStatus.error == nil {
                    ProgressView("Loading…")
                } else if pending.isEmpty && startable.isEmpty && model.selectedStatus.snapshot != nil {
                    Placeholder(title: "Nothing to approve", symbol: "checkmark.shield", message: nothingToApprove)
                }
            }
            .sheet(item: $formFor, onDismiss: {
                if let r = afterSheet { result = r; afterSheet = nil }
            }) { spec in
                if let server = model.selected {
                    ActionFormView(model: model, server: server, spec: spec) { finished(spec, $0) }
                }
            }
            .onChange(of: openable) { _, _ in openRequested() }
            .onAppear { openRequested() }
            .animation(.snappy, value: pending.map(\.id))
            .refreshable { await model.refresh() }
            .navigationTitle("Actions")
            .proposalDialog($confirm, running: $running, model: model) { ok, message in
                outcome = ActionOutcome(ok: ok)
                result = message
            }
            .actionFeedback(result: $result, outcome: outcome)
            .task { await model.refresh() }
        }
    }

    /// A requested form (deep link, launch argument) can open once the list knows the action.
    private var openable: String? {
        model.openAction.flatMap { name in startable.contains { $0.name == name } ? name : nil }
    }

    private func openRequested() {
        guard let name = openable, let spec = startable.first(where: { $0.name == name }) else { return }
        model.openAction = nil
        formFor = spec
    }

    private func finished(_ spec: ActionSpec, _ r: Result<ActionResult, APIError>) {
        let (ok, message) = ResultMessage.started(spec, r)
        outcome = ActionOutcome(ok: ok)
        afterSheet = message
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
                ProposalButtons(action: action, tap: tap)
            }
        }
        .padding(.vertical, 6)
    }
}
