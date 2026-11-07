import HomelabDesign
import HomelabKit
import SwiftUI

/// Settings → Today → "Where you are": the row. Only with a real Home Assistant server (the demo one has nobody to
/// follow, and the CI shots of Settings stay as they were), or while one is chosen, so it can be turned off. Off by
/// default; the "At home" and "Away" rules appear in the rule sheet once it is set.
struct PresenceRow: View {
    let model: AppModel

    var body: some View {
        if let ha = model.homeAssistant, ha.kind == .homeAssistant {
            NavigationLink {
                PresencePicker(model: model, server: ha)
            } label: {
                LabeledContent("Where you are") {
                    Text(verbatim: model.settings.presenceEntity ?? String(localized: "Off"))
                        .foregroundStyle(Palette.secondary).lineLimitAtStandardSizes(1).truncationMode(.middle)
                }
            }
        } else if model.settings.presenceEntity != nil {
            // No Home Assistant to read it from (removed, or only the demo): presence is unknown (rules pass), and it
            // can still be turned off.
            Button("Where you are: turn off") { model.setPresenceEntity(nil) }
        }
    }
}

/// Picks the Home Assistant `person.*` or `device_tracker.*` entity that says whether I'm home. Reads the states
/// once when it opens; no location permission, nothing leaves Home Assistant but what Today already reads.
struct PresencePicker: View {
    let model: AppModel
    let server: ServerConfig
    @State private var entities: [HAEntity] = []
    @State private var loading = true
    @State private var error: APIError?
    @Environment(\.dismiss) private var dismiss

    private var candidates: [HAEntity] { Presence.candidates(entities) }
    private var chosen: String? { model.settings.presenceEntity }

    var body: some View {
        List {
            Group {
                Section {
                    row(title: String(localized: "Off"), detail: nil, id: nil)
                    ForEach(candidates) { e in
                        row(title: e.name, detail: "\(e.entityID) · \(Presence.words(e))", id: e.entityID)
                    }
                    // Chosen earlier, but not among the states now (renamed, removed, or Home Assistant didn't answer).
                    if let chosen, !candidates.contains(where: { $0.entityID == chosen }) {
                        row(title: chosen, detail: String(localized: "Not found in Home Assistant now"), id: chosen)
                    }
                } footer: {
                    SettingsFooter("Today's \"At home\" and \"Away\" rules follow this person or device in Home Assistant, which already knows where you are (its app or your router). Homelab asks for no location. When Home Assistant hasn't answered for 30 minutes, both rules show their sections.")
                }
                if loading {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                } else if let error {
                    Section { Text(verbatim: error.message).font(Typo.secondary).foregroundStyle(Palette.love) }
                } else if candidates.isEmpty {
                    Section {
                        Text("No person or device tracker in Home Assistant.").font(Typo.secondary).foregroundStyle(Palette.secondary)
                    }
                }
            }
            .surfaceRows()
        }
        .screenBackground()
        .navigationTitle("Where you are")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func row(title: String, detail: String?, id: String?) -> some View {
        Button {
            model.setPresenceEntity(id)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).foregroundStyle(Palette.text)
                    if let detail {
                        Text(verbatim: detail).font(Typo.meta).foregroundStyle(Palette.secondary)
                            .lineLimitAtStandardSizes(1).truncationMode(.middle)
                    }
                }
                Spacer()
                if id == chosen {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Palette.text)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityAddTraits(id == chosen ? .isSelected : [])
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            entities = try await model.homeAssistantAPI(for: server).states()
            error = nil
        } catch {
            let e = APIError.from(error, host: server.host)
            if e != .cancelled { self.error = e }
        }
    }
}

extension HomeModel {
    /// Where I am, from the states Today holds (M3.2 passes it to `AppModel.showContext(presence:)`).
    func presence(_ model: AppModel) -> Presence? { model.presence(in: entities, fetched: fetched) }
}

/// Keeps Home Assistant's states fresh for the presence rules while Today is open, also when the Home section (whose
/// tiles poll every 30 s) is hidden. Nothing happens unless "Where you are" is set.
struct PresenceRefresh: ViewModifier {
    let model: AppModel
    let home: HomeModel
    @Environment(\.scenePhase) private var scenePhase

    private struct Key: Hashable {
        var entity: String?
        var server: String?
        var active: Bool
    }

    func body(content: Content) -> some View {
        content.task(id: Key(entity: model.settings.presenceEntity, server: model.homeAssistant?.target,
                             active: scenePhase == .active)) {
            guard scenePhase == .active, model.presenceSetUp, let ha = model.homeAssistant else { return }
            while !Task.isCancelled {
                // Only when the tiles haven't fetched in the last minute.
                if !home.loading, home.fetched.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                    home.reset(for: ha)
                    await home.load(model.homeAssistantAPI(for: ha), host: ha.host)
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

extension View {
    /// Today: fetch Home Assistant for "Where you are" (`PresenceRefresh`).
    func presenceRefresh(_ model: AppModel, home: HomeModel) -> some View {
        modifier(PresenceRefresh(model: model, home: home))
    }
}
