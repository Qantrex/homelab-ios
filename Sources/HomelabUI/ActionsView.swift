import HomelabDesign
import HomelabKit
import SwiftUI

/// Actions I start myself ("Start", feature run-actions) and proposed actions waiting for me: approve once, always,
/// or deny.
struct ActionsView: View {
    let model: AppModel
    @State private var confirm: ProposalConfirmation?
    @State private var formFor: ActionSpec?
    /// A Start tile with nothing to fill in: its confirm, without a form sheet.
    @State private var quickRun: ActionSpec?
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
    /// The search screen (feature `search`): from the Find tile or a `homelab://search?q=` link.
    @State private var searching: SearchRequest?
    /// The Deals screen (feature `deals`): from the Deals tile, `homelab://deals` or Today's card.
    @State private var showingDeals = false
    @Environment(\.hyper) private var hyper

    /// Scan tile: only where the server takes documents.
    private var canScan: Bool { model.selected != nil && model.selectedStatus.features.contains(.documents) }
    private var canSearch: Bool { model.selected != nil && model.selectedStatus.features.contains(.search) }
    private var canDeals: Bool { model.selected != nil && model.selectedStatus.hasDeals }
    private var pending: [PendingAction] { model.selectedStatus.snapshot?.state.pending ?? [] }
    private var startable: [ActionSpec] {
        model.selectedStatus.features.contains(.runActions) ? model.selectedStatus.actions.filter(\.start) : []
    }
    /// The Start tiles as the owner arranged them (Settings → Advanced → Start tiles): hidden ones left out.
    private var startTiles: [ActionSpec] { StartTiles.arrange(startable, model.settings.startTiles) }
    private var approves: Bool { model.selectedStatus.features.contains(.actions) || startable.isEmpty }
    /// The Start section: tiles to start actions, or the Scan tile.
    private var hasStart: Bool { !startTiles.isEmpty || canScan || canSearch || canDeals }
    /// The built-in Start tiles that are showing (Hyperdetail notes them like the server's).
    private var builtInTiles: [Hyper.BuiltInTile] {
        (canSearch ? [.find] : []) + (canDeals ? [.deals] : []) + (canScan ? [.scan] : [])
    }

    /// "N waiting" and what was given up on, whenever there is something: not tied to the Start section, which
    /// disappears with its last tile while the outbox still holds scans and links (the Scan tile, which carries the
    /// count otherwise, only exists where the server takes documents).
    @ViewBuilder
    private var outboxSection: some View {
        if model.outboxCount > 0 && !canScan {
            Label(model.outboxCount == 1 ? "1 waiting to be sent" : "\(model.outboxCount) waiting to be sent",
                  systemImage: "tray.and.arrow.up")
                .font(Typo.secondary).foregroundStyle(Palette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
        }
        if !model.outboxDropped.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                NotSentRow(items: model.outboxDropped) { model.clearOutboxDropped() }
                    .transition(.opacity)
                if let hyper {
                    ForEach(Array(model.outboxDropped.suffix(5).enumerated()), id: \.offset) { _, d in
                        HyperNote(lines: Hyper.notSent(d, now: hyper.now, calendar: hyper.calendar))
                    }
                }
            }
        }
    }

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
                        ErrorBanner(error: error, snapshotAge: model.selectedStatus.snapshot?.fetched,
                                    retry: { Task { await model.refresh() } },
                                    edit: model.selected.map { s in { model.requestEdit(s.id) } })
                    }
                    if let hyper, model.selected != nil {
                        HyperSection(title: "Server", lines: Hyper.server(
                            name: model.selected?.name ?? "none", snapshot: model.selectedStatus.snapshot,
                            info: model.selectedStatus.knownInfo, failures: model.selectedStatus.failures,
                            busy: model.selectedStatus.snapshot?.state.busy ?? [], now: hyper.now, calendar: hyper.calendar),
                                     fact: model.selected.map { Hyper.fact(server: $0.name, snapshot: model.selectedStatus.snapshot, now: hyper.now) })
                    }
                    // What waits for me first (it is time-critical), then what I can start (research #7).
                    if approves { approveSection }
                    if hasStart {
                        VStack(alignment: .leading, spacing: Space.titleToPanel) {
                            SectionTitle(text: "Start")
                            StartGrid(actions: startTiles, scanWaiting: canScan ? model.outboxCount : nil,
                                      features: model.selectedStatus.knownInfo?.features,
                                      showIds: model.settings.todayDensity.atLeastOverkill,
                                      open: { spec in
                                          formPrefill = nil
                                          guard !model.actionsRunning.contains(spec.name) else { return }   // still on its way
                                          if ActionForm(spec).needsNoInput { quickRun = spec } else { formFor = spec }
                                      }, scan: { scanning = true },
                                      search: canSearch ? { searching = SearchRequest(query: "") } : nil,
                                      deals: canDeals ? { showingDeals = true } : nil,
                                      dealsToAct: model.selectedStatus.deals?.freshAct(categories: model.settings.dealCategories).count ?? 0)
                            if hyper != nil {
                                ForEach(startTiles) { spec in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(spec.label).font(Typo.meta.weight(.semibold)).foregroundStyle(Palette.secondary)
                                        HyperNote(lines: Hyper.action(spec), fact: Hyper.fact(action: spec))
                                    }
                                }
                                ForEach(builtInTiles, id: \.rawValue) { tile in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tile.label).font(Typo.meta.weight(.semibold)).foregroundStyle(Palette.secondary)
                                        HyperNote(lines: Hyper.startTile(tile, waiting: model.outboxCount,
                                                                         toAct: model.selectedStatus.deals?.freshAct(categories: model.settings.dealCategories).count ?? 0),
                                                  fact: Hyper.fact(tile: tile))
                                    }
                                }
                            }
                        }
                    }
                    outboxSection
                }
                .rowMotion(model.outboxDropped.count)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .screenBackground()
            .overlay {
                if model.selectedStatus.snapshot == nil && model.selectedStatus.error == nil {
                    ProgressView("Loading…")
                } else if pending.isEmpty && startTiles.isEmpty && !canScan && model.outboxCount == 0 && model.outboxDropped.isEmpty && !canSearch && !canDeals && model.selectedStatus.snapshot != nil
                            && model.selectedStatus.error == nil {
                    Placeholder(title: "Nothing to approve", symbol: "checkmark.shield", message: nothingToApprove)
                }
            }
            .onChange(of: quickRun?.name) { _, name in if name == nil { openRequested() } }
            .confirmationDialog(quickRun?.label ?? "", isPresented: Binding(get: { quickRun != nil }, set: { if !$0 { quickRun = nil } }),
                                titleVisibility: .visible, presenting: quickRun) { spec in
                Button(spec.destructive ? String(localized: "Run it") : String(localized: "Run now"),
                       role: spec.destructive ? .destructive : nil) { Task { await runQuick(spec) } }
                Button("Cancel", role: .cancel) {}
            } message: { spec in
                Text(confirmText(ActionForm(spec), server: model.selected?.name ?? ""))
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
            .sheet(item: $searching, onDismiss: { openRequested() }) { request in
                if let server = model.selected { SearchView(model: model, server: server, query: request.query, held: request.held) }
            }
            .sheet(isPresented: $showingDeals, onDismiss: { openRequested() }) {
                if let server = model.selected { DealsView(model: model, server: server) }
            }
            .onChange(of: openable) { _, _ in openRequested() }
            .onAppear { openRequested() }
            .rowMotion(pending.map(\.id))
            .refreshable { await model.refresh() }
            .navigationTitle("Actions")
            .proposalDialog($confirm, model: model) { pressed, message in
                outcome = pressed
                result = message
            }
            .actionFeedback(result: $result, outcome: outcome)
            .task { await model.refresh() }
        }
    }

    /// "To approve": a title and one panel; the proposals inside are rows (`ProposalRow`) split by separators, each
    /// with Approve / Deny inline.
    @ViewBuilder private var approveSection: some View {
        let quiet = pending.isEmpty && (!startTiles.isEmpty || model.selectedStatus.error != nil)
            && model.selectedStatus.snapshot != nil
        // Without Start tiles and without an error the full-screen placeholder says it (it would cover this).
        if !pending.isEmpty || quiet {
            VStack(alignment: .leading, spacing: Space.titleToPanel) {
                // The screen's title says it when there is no Start section under it.
                if hasStart {
                    SectionTitle(text: "To approve", trailing: pending.isEmpty ? nil : "\(pending.count)")
                }
                if quiet {
                    // A small empty state: the shield over the sentence, both centred in the panel.
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.shield").font(Typo.sectionTitle.weight(.regular))
                            .foregroundStyle(Palette.tertiary)
                            .accessibilityHidden(true)
                        Text(nothingToApprove).font(Typo.secondary).foregroundStyle(Palette.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .panel()
                    .transition(.opacity)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(pending.enumerated()), id: \.element.id) { i, action in
                            if i > 0 { Divider().overlay(Palette.line).padding(.leading, 16) }
                            ProposalRow(action: action, running: model.proposalsSending.contains(action.id),
                                        hasChat: model.selectedStatus.features.contains(.chat)) { verb in
                                confirm = ProposalConfirmation(action: action, verb: verb)
                            }
                            .transition(.opacity)
                            if let hyper {
                                HyperNote(lines: Hyper.pending(action, now: hyper.now, calendar: hyper.calendar),
                                          fact: Hyper.fact(pending: action, now: hyper.now))
                                    .padding(.horizontal, 16).padding(.bottom, 12)
                            }
                        }
                    }
                    .rowsPanel()
                }
            }
        }
    }

    /// What decides whether a requested form (deep link, launch argument) can open: the request and the list.
    private var openable: String {
        let s = model.selectedStatus
        return [model.openAction ?? "", "\(model.openScan)", model.openSearch?.id.uuidString ?? "", "\(model.openDeals)", "\(model.selectedStatus.hasDeals)", model.tab.rawValue, startable.map(\.name).joined(separator: ","),
                "\(s.actionsFetched?.timeIntervalSince1970 ?? 0)", "\(s.knownInfo != nil)", "\(model.formSheetOpen)"]
            .joined(separator: "|")
    }

    /// Opens a requested form once this tab shows and the list knows the action. While another tab shows or a form
    /// is open (here or a card's) the request waits (`AppModel.takeOpenAction`).
    private func openRequested() {
        guard quickRun == nil else { return }   // a Run? confirm is up: the link waits until it's answered
        if model.tab == .actions, formFor == nil, !scanning, searching == nil, !showingDeals, model.takeOpenDeals() {   // homelab://deals
            showingDeals = true
            return
        }
        if model.tab == .actions, formFor == nil, !scanning, searching == nil, let request = model.takeOpenSearch() {   // homelab://search
            searching = request
            return
        }
        if model.tab == .actions, formFor == nil, !scanning, model.takeOpenScan() {   // homelab://scan
            scanning = true
            return
        }
        guard model.tab == .actions, formFor == nil, let request = model.takeOpenActionForm() else { return }
        formPrefill = request.prefill
        formFor = request.spec
    }

    /// Runs a Start tile that has nothing to fill in, after its confirm; the result shows as for a form.
    private func runQuick(_ spec: ActionSpec) async {
        guard let server = model.selected else { return }
        let r = await model.run(ActionForm(spec), on: server)
        let (ok, message) = ResultMessage.started(spec, r, model: model)
        outcome = ActionOutcome(ok: ok)
        result = message
    }

    private func finished(_ spec: ActionSpec, _ r: Result<ActionResult, APIError>) {
        let (ok, message) = ResultMessage.started(spec, r, model: model)
        outcome = ActionOutcome(ok: ok)
        afterSheet = message
    }
}

/// Scans and links the outbox gave up on (the owner was told "Homelab sends it later"): what, when and why, until
/// he clears it. Rows like every other (docs/DESIGN.md §6): the love glyph on the first row only, then one row per
/// item (what · why · age on the right), lined up under the first row's name.
struct NotSentRow: View {
    let items: [Outbox.Dropped]
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                glyph
                Text(items.count == 1 ? "1 item not sent" : "\(items.count) items not sent")
                    .font(Typo.headline).foregroundStyle(Palette.text)
                    .numberMotion(items.count)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button("Clear", action: clear).buttonStyle(CapsuleButtonStyle(kind: .text))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            ForEach(Array(items.suffix(5).enumerated()), id: \.offset) { _, d in
                Divider().overlay(Palette.line).padding(.leading, 16)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    glyph.hidden()   // keeps the names on one leading edge with the first row's
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.what).font(Typo.headline).foregroundStyle(Palette.text).lineLimitAtStandardSizes(1)
                        Text(d.why).font(Typo.secondary).foregroundStyle(Palette.secondary).lineLimitAtStandardSizes(2)
                    }
                    Spacer(minLength: 8)
                    Text(Format.age(d.when)).font(Typo.meta).foregroundStyle(Palette.tertiary).lineLimit(1)
                }
                // One element per item (its texts); the Clear button above stays its own element.
                .accessibilityElement(children: .combine)
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .rowsPanel()
    }

    private var glyph: some View {
        Image(systemName: "exclamationmark.triangle.fill").font(Typo.body).foregroundStyle(Palette.love)
            .accessibilityHidden(true)
    }
}
