import HomelabDesign
import HomelabKit
import SwiftUI

/// The first run after a save (`FirstRun`): what the servers offer, then "Start with" the three presets, the suggested
/// one picked. Start writes the preset (Today's sections and density), Skip leaves Today as it is. With Home Assistant
/// tiles to pin, the tile picker opens next; then Today. Inside `WelcomeView`'s navigation stack.
struct FoundView: View {
    let model: AppModel
    /// Home Assistant's entities: nil while they load (or without Home Assistant).
    @State private var entities: [HAEntity]?
    @State private var homeError: APIError?

    private var canPickTiles: Bool { FirstRun.canPickTiles(hasHA: model.homeAssistant != nil, entities: entities) }

    var body: some View {
        Form {
            Group {
                if let lab = model.selected { labSection(lab) }
                if let ha = model.homeAssistant { homeSection(ha) }
                addMore
                startWith
            }
            .surfaceRows()
            .headerProminence(.increased)
        }
        .screenBackground()
        .navigationTitle("Found")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Skip") { model.startFirstRun(with: nil, canPickTiles: canPickTiles) }
                    .accessibilityHint(Text("Keeps Today as it is"))
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start") { model.startFirstRun(with: model.firstRunPreset, canPickTiles: canPickTiles) }
                    .accessibilityHint(Text("Sets up Today with \(model.firstRunPreset.title)"))
            }
        }
        .task(id: model.homeAssistant?.target) { await loadHome() }
        // The editor's Save already asked the server; this covers a run that starts at Found (screenshots).
        .task(id: model.selected?.id) {
            if model.selected != nil, model.selectedStatus.knownInfo == nil, !model.selectedStatus.loading {
                await model.refresh()
            }
        }
        // The tile picker, right after Start or Skip. Done pins the tiles; Done and Cancel both end the run.
        .sheet(isPresented: Binding(get: { model.firstRun?.step == .tiles },
                                    set: { if !$0 { model.finishFirstRun() } })) {
            if let ha = model.homeAssistant {
                EntityPicker(entities: entities ?? [], selected: ha.pinnedEntities, names: ha.tileNames,
                             icons: ha.tileIcons) {
                    model.setPinned($0, names: $1, icons: $2, for: ha.id)
                }
            }
        }
    }

    // MARK: Found

    /// The Homelab server: what its /info offers, or that it is being asked, or why it didn't answer.
    @ViewBuilder
    private func labSection(_ lab: ServerConfig) -> some View {
        let status = model.selectedStatus
        Section {
            if status.knownInfo != nil {
                ForEach(FirstRun.offers(features: status.features)) { offerRow($0) }
            } else if let error = status.error {
                problemRow(error.message)
                Button("Try again") { Task { await model.refresh() } }
            } else if status.snapshot != nil, !status.loading {
                // /info failed but /state answered: what the data shows, and a way to ask again. No endless spinner.
                ForEach(FirstRun.offers(features: status.features)) { offerRow($0) }
                problemRow(FirstRun.unreadableOffers)
                Button("Try again") { Task { await model.refresh() } }
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Asking \(lab.host)…").foregroundStyle(Palette.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text(verbatim: lab.name)
        }
    }

    /// Home Assistant: its tiles in words ("12 lights and 3 scenes").
    private func homeSection(_ ha: ServerConfig) -> some View {
        Section {
            if let homeError {
                problemRow(homeError.message)
                Button("Try again") { Task { await loadHome() } }
            } else {
                offerRow(FirstRun.homeOffer(entities: entities), loading: entities == nil)
            }
        } header: {
            Text(verbatim: ha.name)
        }
    }

    /// The other kind of server, while the run has none of it.
    @ViewBuilder
    private var addMore: some View {
        if model.homeAssistant == nil || model.selected == nil {
            Section {
                if model.homeAssistant == nil {
                    Button { model.beginFirstRun(adding: .homeAssistant) } label: {
                        Label("Add Home Assistant too", systemImage: "plus")
                    }
                }
                if model.selected == nil {
                    Button { model.beginFirstRun(adding: .companion) } label: {
                        Label("Add a Homelab server too", systemImage: "plus")
                    }
                }
            }
        }
    }

    private func offerRow(_ offer: FirstRun.Offer, loading: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: offer.symbol).foregroundStyle(Palette.secondary).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: offer.title).foregroundStyle(Palette.text)
                if let detail = offer.detail {
                    Text(verbatim: detail).font(Typo.secondary).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if loading { ProgressView().accessibilityLabel(Text("Loading")) }
        }
        .accessibilityElement(children: .combine)
    }

    /// Why a server didn't answer: a love glyph and the words (never colour alone).
    private func problemRow(_ message: String) -> some View {
        Label {
            Text(verbatim: message).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.love)
        }
    }

    // MARK: Start with

    private var startWith: some View {
        let picked = model.firstRunPreset
        let suggested = model.firstRunSuggested
        return Section {
            ForEach(StartPreset.allCases) { p in
                let label = p == suggested ? String(localized: "\(p.title), suggested. \(p.summary)")
                                           : "\(p.title). \(p.summary)"
                Button { model.pickStart(p) } label: { presetRow(p, picked: p == picked, suggested: p == suggested) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: label))
                    .accessibilityAddTraits(p == picked ? [.isButton, .isSelected] : .isButton)
            }
        } header: {
            Text("Start with")
        } footer: {
            SettingsFooter(verbatim: FirstRun.startWithFooter)
        }
    }

    /// "Home  Suggested" over its one line, a checkmark when picked.
    private func presetRow(_ p: StartPreset, picked: Bool, suggested: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                (Text(verbatim: p.title).font(Typo.headline).foregroundColor(Palette.text)
                    + (suggested ? Text("  Suggested").font(Typo.meta).foregroundColor(Palette.tertiary) : Text(verbatim: "")))
                Text(verbatim: p.summary).font(Typo.secondary).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Palette.text)
                .opacity(picked ? 1 : 0)
        }
        .contentShape(Rectangle())
    }

    private func loadHome() async {
        entities = nil
        homeError = nil
        guard let ha = model.homeAssistant else { return }
        do {
            entities = try await model.homeAssistantAPI(for: ha).states()
        } catch {
            let e = APIError.from(error, host: ha.host)
            if e != .cancelled { homeError = e }
        }
    }
}
