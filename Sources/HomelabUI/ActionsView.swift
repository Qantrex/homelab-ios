import HomelabDesign
import HomelabKit
import SwiftUI

/// Actions I start myself ("Start", feature run-actions) and proposed actions waiting for me: approve once, always,
/// or deny.
struct ActionsView: View {
    let model: AppModel
    @State private var confirm: ProposalConfirmation?
    @State private var formFor: ActionSpec?
    /// What a link filled in for `formFor` (`homelab://actions/<name>?…`); nil for a Start tile.
    @State private var formPrefill: ItemAction?
    /// A started action's result, shown once its form sheet is gone (an alert can't show over the sheet).
    @State private var afterSheet: ResultMessage?
    /// This view's form sheet, for `AppModel.formSheetOpen`.
    @State private var sheetToken = UUID()
    @State private var result: ResultMessage?
    @State private var outcome: ActionOutcome?
    /// The Scan screen (feature `documents`).
    @State private var scanning = false

    /// Scan tile: only where the server takes documents.
    private var canScan: Bool { model.selected != nil && model.selectedStatus.features.contains(.documents) }
    private var pending: [PendingAction] { model.selectedStatus.snapshot?.state.pending ?? [] }
    private var startable: [ActionSpec] {
        model.selectedStatus.features.contains(.runActions) ? model.selectedStatus.actions.filter(\.start) : []
    }
    private var approves: Bool { model.selectedStatus.features.contains(.actions) || startable.isEmpty }
    private var nothingToApprove: LocalizedStringKey {
        Voice.line(.nothingToApprove, model.settings.voice)
            .map { LocalizedStringKey($0 + " " + String(localized: "When your homelab proposes an action, it shows up here.")) }
            ?? "When your homelab proposes an action, it shows up here."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.section) {
                    if let error = model.selectedStatus.error {
                        ErrorBanner(error: error, snapshotAge: model.selectedStatus.snapshot?.fetched) {
                            Task { await model.refresh() }
                        }
                    }
                    if !startable.isEmpty || canScan {
                        VStack(alignment: .leading, spacing: Space.titleToPanel) {
                            SectionTitle(text: "Start")
                            StartGrid(actions: startable, scanWaiting: canScan ? model.outboxCount : nil,
                                      showIds: model.settings.todayDensity == .overkill,
                                      open: { formPrefill = nil; formFor = $0 }, scan: { scanning = true })
                            if !model.outboxDropped.isEmpty {
                                NotSentRow(items: model.outboxDropped) { model.clearOutboxDropped() }
                            }
                        }
                    }
                    if approves { approveSection }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .screenBackground()
            .overlay {
                if model.selectedStatus.snapshot == nil && model.selectedStatus.error == nil {
                    ProgressView("Loading…")
                } else if pending.isEmpty && startable.isEmpty && !canScan && model.selectedStatus.snapshot != nil
                            && model.selectedStatus.error == nil {
                    Placeholder(title: "Nothing to approve", symbol: "checkmark.shield", message: nothingToApprove)
                }
            }
            .sheet(item: $formFor, onDismiss: {
                if let r = afterSheet { result = r; afterSheet = nil }
                openRequested()   // a link that came while the sheet was open
            }) { spec in
                if let server = model.selected {
                    ActionFormView(model: model, server: server, spec: spec, prefill: formPrefill) { finished(spec, $0) }
                        .onAppear { model.formSheet(sheetToken, open: true) }
                        .onDisappear { model.formSheet(sheetToken, open: false) }
                }
            }
            .sheet(isPresented: $scanning, onDismiss: { openRequested() }) {
                if let server = model.selected { ScanView(model: model, server: server) }
            }
            .onChange(of: openable) { _, _ in openRequested() }
            .onAppear { openRequested() }
            .animation(.snappy, value: pending.map(\.id))
            .refreshable { await model.refresh() }
            .navigationTitle("Actions")
            .proposalDialog($confirm, model: model) { ok, message in
                outcome = ActionOutcome(ok: ok)
                result = message
            }
            .actionFeedback(result: $result, outcome: outcome)
            .task { await model.refresh() }
        }
    }

    /// "To approve": a title and one panel; the proposals inside are split by separators.
    @ViewBuilder private var approveSection: some View {
        let quiet = pending.isEmpty && (!startable.isEmpty || model.selectedStatus.error != nil)
            && model.selectedStatus.snapshot != nil
        // Without Start tiles and without an error the full-screen placeholder says it (it would cover this).
        if !pending.isEmpty || quiet {
            VStack(alignment: .leading, spacing: Space.titleToPanel) {
                if !startable.isEmpty {
                    SectionTitle(text: "To approve", trailing: pending.isEmpty ? nil : "\(pending.count)")
                }
                if quiet {
                    Label { Text(nothingToApprove).font(.subheadline).foregroundStyle(Palette.secondary) }
                        icon: { Image(systemName: "checkmark.shield").foregroundStyle(Palette.tertiary) }
                        .panel()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(pending.enumerated()), id: \.element.id) { i, action in
                            if i > 0 { Divider().overlay(Palette.line).padding(.leading, 16) }
                            ActionRow(action: action, running: model.proposalsSending.contains(action.id),
                                      hasChat: model.selectedStatus.features.contains(.chat)) { verb in
                                confirm = ProposalConfirmation(action: action, verb: verb)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    /// What decides whether a requested form (deep link, launch argument) can open: the request and the list.
    private var openable: String {
        let s = model.selectedStatus
        return [model.openAction ?? "", "\(model.openScan)", model.tab.rawValue, startable.map(\.name).joined(separator: ","),
                "\(s.actionsFetched?.timeIntervalSince1970 ?? 0)", "\(s.knownInfo != nil)", "\(model.formSheetOpen)"]
            .joined(separator: "|")
    }

    /// Opens a requested form once this tab shows and the list knows the action. While another tab shows or a form
    /// is open (here or a card's) the request waits (`AppModel.takeOpenAction`).
    private func openRequested() {
        if model.tab == .actions, formFor == nil, !scanning, model.takeOpenScan() {   // homelab://scan
            scanning = true
            return
        }
        guard model.tab == .actions, formFor == nil, let request = model.takeOpenActionForm() else { return }
        formPrefill = request.prefill
        formFor = request.spec
    }

    private func finished(_ spec: ActionSpec, _ r: Result<ActionResult, APIError>) {
        let (ok, message) = ResultMessage.started(spec, r, model: model)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(action.title).font(.headline).foregroundStyle(Palette.text)
            if let reason = action.reason {
                Text(markdown(reason)).font(.subheadline).foregroundStyle(Palette.secondary)
            }
            meta
            Group {
                if running {
                    HStack(spacing: 8) { ProgressView(); Text("Running…").font(.subheadline).foregroundStyle(Palette.secondary) }
                } else if action.buttons.isEmpty {
                    Text(hasChat ? "The server offers no buttons for this action. Answer it in the chat."
                                 : "The server offers no buttons for this action.")
                        .font(.footnote).foregroundStyle(Palette.tertiary)
                } else {
                    ProposalButtons(action: action, tap: tap)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    /// Job, id and age as one quiet line: ids in the data font, the rest plain.
    @ViewBuilder private var meta: some View {
        let parts = [action.job.map { Text($0) },
                     Text(action.id).font(Typo.data(.footnote)),
                     action.created.map { Text(Format.age($0)) }].compactMap { $0 }
        if !parts.isEmpty {
            parts.dropFirst().reduce(parts[0]) { $0 + Text(" · ") + $1 }
                .font(.footnote).foregroundStyle(Palette.tertiary)
        }
    }
}

/// Scans and links the outbox gave up on (the owner was told "Homelab sends it later"): what, when and why, until
/// he clears it.
struct NotSentRow: View {
    let items: [Outbox.Dropped]
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(items.count == 1 ? "1 item not sent" : "\(items.count) items not sent")
                        .font(.headline).foregroundStyle(Palette.text)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.love)
                }
                Spacer()
                Button("Clear", action: clear).font(.subheadline.weight(.semibold)).buttonStyle(.plain)
                    .foregroundStyle(Palette.secondary)
            }
            ForEach(Array(items.suffix(5).enumerated()), id: \.offset) { _, d in
                VStack(alignment: .leading, spacing: 4) {
                    Text(d.what).font(.subheadline).foregroundStyle(Palette.text).lineLimit(1)
                    Text("\(Format.age(d.when)) · \(d.why)").font(.footnote).foregroundStyle(Palette.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .panel()
        .accessibilityElement(children: .combine)
    }
}
