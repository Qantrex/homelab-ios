import HomelabDesign
import HomelabKit
import SwiftUI

/// Loads Home Assistant entities and runs taps on them. Used by the tiles on Today.
@MainActor @Observable
final class HomeModel {
    var entities: [HAEntity] = []
    var error: APIError?
    var loading = false
    var busy: Set<String> = []
    var actionError: String?
    private var loadedFor: String?

    /// A different Home Assistant (new address) means the old entities don't exist there.
    func reset(for server: ServerConfig?) {
        guard server?.target != loadedFor else { return }
        loadedFor = server?.target
        entities = []
        error = nil
        busy = []
    }

    func load(_ api: any HomeAssistantAPI, host: String) async {
        let sid = loadedFor
        loading = true
        defer { loading = false }
        do {
            let fresh = try await api.states()
            guard sid == loadedFor else { return }   // another Home Assistant now
            entities = fresh
            error = nil
        } catch {
            guard sid == loadedFor else { return }
            let e = APIError.from(error, host: host)
            if e != .cancelled { self.error = e }
        }
    }

    func tap(_ entity: HAEntity, api: any HomeAssistantAPI, host: String) async {
        let sid = loadedFor
        busy.insert(entity.entityID)
        defer { busy.remove(entity.entityID) }
        do {
            let changed = try await api.call(entity)
            guard sid == loadedFor else { return }
            for c in changed {
                if let i = entities.firstIndex(where: { $0.entityID == c.entityID }) { entities[i] = c }
            }
            // HA sometimes answers before the device reports its new state.
            if changed.isEmpty || entity.control == .toggle {
                try? await Task.sleep(for: .milliseconds(700))
                if let fresh = try? await api.states(), sid == loadedFor { entities = fresh }
            }
        } catch {
            guard sid == loadedFor else { return }
            actionError = "\(entity.name): \(APIError.from(error, host: host).message)"
        }
    }
}

/// Home Assistant on Today: only the few pinned things I use often (owner, 2026-11-05: living room lamps and
/// "stop the morning routine"), as tiles. Everything else stays in the HA app. The pins are chosen with "Edit".
struct HomeTiles: View {
    let model: AppModel
    let server: ServerConfig
    @State private var home = HomeModel()
    @State private var picking = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    private var pinned: [HAEntity] {
        let byID = Dictionary(home.entities.map { ($0.entityID, $0) }, uniquingKeysWith: { a, _ in a })
        return server.pinnedEntities.compactMap { byID[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Home", action: home.entities.isEmpty ? nil : ("EDIT", { picking = true }))
            if let error = home.error {
                ErrorBanner(error: error, snapshotAge: nil) { Task { await load() } }
            }
            if pinned.isEmpty {
                if home.loading && home.entities.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).card()
                } else if home.error == nil {
                    Button { picking = true } label: {
                        Label("Pin the lights or scripts you use most", systemImage: "pin")
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondary)
                            .card()
                    }
                    .buttonStyle(.press)
                    .disabled(home.entities.isEmpty)
                }
            } else {
                LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())]
                                                                : [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                          spacing: 10) {
                    ForEach(pinned) { e in
                        HomeTile(entity: e, busy: home.busy.contains(e.entityID)) {
                            Task { await home.tap(e, api: model.homeAssistantAPI(for: server), host: server.host) }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $picking) {
            EntityPicker(entities: home.entities, selected: server.pinnedEntities) { model.setPinned($0, for: server.id) }
        }
        .alert("Didn't work", isPresented: Binding(get: { home.actionError != nil }, set: { if !$0 { home.actionError = nil } })) {
            Button("OK") {}
        } message: {
            Text(home.actionError ?? "")
        }
        .task(id: PollKey(server: server.target, active: scenePhase == .active)) {
            home.reset(for: server)
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func load() async {
        await home.load(model.homeAssistantAPI(for: server), host: server.host)
    }
}

/// One Home Assistant tile: icon, name, state. Tap toggles a light/switch or runs a script/scene. A tile that is on
/// is filled (white on black), so the state reads without colour.
struct HomeTile: View {
    let entity: HAEntity
    let busy: Bool
    let tap: () -> Void

    @State private var taps = 0

    private var on: Bool { entity.control == .toggle && entity.isOn }

    var body: some View {
        Button {
            taps += 1
            tap()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: entitySymbol(entity)).font(.title3)
                    Spacer()
                    if busy { ProgressView().controlSize(.small).tint(on ? Palette.onAccent : Palette.text) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entity.name).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    Text(stateText.uppercased()).font(Typo.mono(.caption2)).opacity(0.7)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .foregroundStyle(on ? Palette.onAccent : Palette.text)
            .background(on ? Palette.text : Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(on ? Color.clear : Palette.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .animation(.snappy, value: on)
        }
        .buttonStyle(.press)
        .sensoryFeedback(.impact(weight: .medium), trigger: taps)
        .disabled(busy || !entity.isAvailable || entity.control == .none)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(entity.name))
        .accessibilityValue(Text(entity.displayState))
        .accessibilityAddTraits(.isButton)
    }

    private var stateText: String {
        switch entity.control {
        case .toggle: entity.isAvailable ? (entity.isOn ? String(localized: "On") : String(localized: "Off")) : entity.displayState
        case .run: entity.lastChanged.map { String(localized: "ran \(Format.age($0))") } ?? String(localized: "Tap to run")
        case .none: entity.displayState
        }
    }
}

func domainTitle(_ domain: String) -> String {
    switch domain {
    case "light": String(localized: "Lights")
    case "switch": String(localized: "Switches")
    case "fan": String(localized: "Fans")
    case "input_boolean": String(localized: "Toggles")
    case "scene": String(localized: "Scenes")
    case "script": String(localized: "Scripts")
    case "button", "input_button": String(localized: "Buttons")
    case "sensor": String(localized: "Sensors")
    case "binary_sensor": String(localized: "Contacts and motion")
    case "automation": String(localized: "Automations")
    default: domain.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

func entitySymbol(_ e: HAEntity) -> String {
    switch e.domain {
    case "light": e.isOn ? "lightbulb.fill" : "lightbulb"
    case "switch", "input_boolean": e.isOn ? "power.circle.fill" : "power.circle"
    case "fan": "fan"
    case "script": "play.circle"
    case "scene": "theatermasks"
    case "button", "input_button": "button.programmable"
    case "automation": "gearshape.2"
    case "binary_sensor":
        switch e.deviceClass {
        case "door", "garage_door": e.isOn ? "door.left.hand.open" : "door.left.hand.closed"
        case "window": "window.vertical.closed"
        case "motion", "occupancy", "presence": "figure.walk"
        default: "circle.dotted"
        }
    case "sensor":
        switch e.deviceClass {
        case "temperature": "thermometer.medium"
        case "humidity": "humidity"
        case "power", "energy": "bolt"
        case "battery": "battery.75percent"
        default: "gauge.with.dots.needle.33percent"
        }
    default: "circle"
    }
}

/// Choose which entities Today shows as tiles.
struct EntityPicker: View {
    let entities: [HAEntity]
    @State var selected: [String]
    let save: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    init(entities: [HAEntity], selected: [String], save: @escaping ([String]) -> Void) {
        self.entities = entities
        _selected = State(initialValue: selected)
        self.save = save
    }

    private var useful: [HAEntity] {
        let domains: Set<String> = ["light", "switch", "fan", "input_boolean", "scene", "script", "button", "input_button",
                                    "sensor", "binary_sensor", "automation"]
        return entities.filter { domains.contains($0.domain) }.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.entityID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                let groups = Dictionary(grouping: useful, by: \.domain)
                ForEach(groups.keys.sorted(), id: \.self) { domain in
                    Section(domainTitle(domain)) {
                        ForEach(groups[domain] ?? []) { e in
                            Button {
                                if let i = selected.firstIndex(of: e.entityID) { selected.remove(at: i) } else { selected.append(e.entityID) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(e.name).foregroundStyle(.primary)
                                        Text(e.entityID).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selected.contains(e.entityID) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                            .accessibilityAddTraits(selected.contains(e.entityID) ? .isSelected : [])
                        }
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle("Tiles on Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save(selected)
                        dismiss()
                    }
                }
            }
        }
    }
}
