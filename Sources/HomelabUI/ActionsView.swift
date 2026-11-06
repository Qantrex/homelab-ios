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
                    .cardRow()
                }
                if !startable.isEmpty {
                    Section {
                        StartGrid(actions: startable) { formFor = $0 }
                            .cardRow(top: 4)
                    } header: {
                        SectionTitle(text: "Start").textCase(nil).sectionHeaderInsets()
                    }
                }
                if approves {
                    Section {
                        // With Start tiles above or an error banner, the empty state is one quiet row: the full-screen
                        // placeholder would cover them (it drew over the banner at XXL text, CI 2026-11-06).
                        if pending.isEmpty, !startable.isEmpty || model.selectedStatus.error != nil,
                           model.selectedStatus.snapshot != nil {
                            Label { Text(nothingToApprove).font(.subheadline).foregroundStyle(Palette.secondary) }
                                icon: { Image(systemName: "checkmark.shield").foregroundStyle(Palette.tertiary) }
                                .card()
                                .cardRow()
                        }
                        ForEach(pending) { action in
                            ActionRow(action: action, running: running.contains(action.id),
                                      hasChat: model.selectedStatus.features.contains(.chat)) { verb in
                                confirm = ProposalConfirmation(action: action, verb: verb)
                            }
                            .card()
                            .cardRow()
                        }
                    } header: {
                        if !startable.isEmpty {
                            SectionTitle(text: "To approve", trailing: pending.isEmpty ? nil : "\(pending.count)")
                                .textCase(nil)
                                .sectionHeaderInsets()
                        }
                    }
                }
            }
            .listSectionSpacing(.compact)
            .screenBackground()
            .overlay {
                if model.selectedStatus.snapshot == nil && model.selectedStatus.error == nil {
                    ProgressView("Loading…")
                } else if pending.isEmpty && startable.isEmpty && model.selectedStatus.snapshot != nil
                            && model.selectedStatus.error == nil {
                    Placeholder(title: "Nothing to approve", symbol: "checkmark.shield", message: nothingToApprove)
                }
            }
            .sheet(item: $formFor, onDismiss: {
                if let r = afterSheet { result = r; afterSheet = nil }
                openRequested()   // a link that came while the sheet was open
            }) { spec in
                if let server = model.selected {
                    ActionFormView(model: model, server: server, spec: spec) { finished(spec, $0) }
                        .onAppear { model.formSheet(open: true) }
                        .onDisappear { model.formSheet(open: false) }
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

    /// What decides whether a requested form (deep link, launch argument) can open: the request and the list.
    private var openable: String {
        let s = model.selectedStatus
        return [model.openAction ?? "", startable.map(\.name).joined(separator: ","),
                "\(s.actionsFetched?.timeIntervalSince1970 ?? 0)", "\(s.knownInfo != nil)", "\(model.formSheetOpen)"]
            .joined(separator: "|")
    }

    /// Opens a requested form once the list knows the action. While a form is open (here or a card's) the request
    /// waits (`AppModel.takeOpenAction`).
    private func openRequested() {
        guard formFor == nil, let spec = model.takeOpenAction() else { return }
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
    }
}

private extension View {
    /// A list row that is a panel of its own (like Lab's cards): no system row background or separator, and the
    /// same side margin for every row, so the Start grid and the cards below line up.
    func cardRow(top: CGFloat = 5) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 0, bottom: 5, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// A section title over card rows: aligned with the cards' edge, like Lab's titles.
    func sectionHeaderInsets() -> some View {
        listRowInsets(EdgeInsets(top: 8, leading: 2, bottom: 4, trailing: 2))
    }
}
